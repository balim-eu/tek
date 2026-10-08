import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../fetcher.dart';
import '../progress.dart';
import '../version.dart';

final binaryTempName = Platform.isWindows ? '.tek.tmp.exe' : '.tek.tmp';
const windowsBinaryBackupName = 'tek.exe.old';

final _cliVersion = RegExp(r'^(\d{4}-\d{2}-\d{2})(?:-rc\.(\d+))?$');

class CliVersion implements Comparable<CliVersion> {
  const CliVersion(this.date, [this.rc]);

  static CliVersion? tryParse(String value) {
    final match = _cliVersion.firstMatch(value.trim());
    if (match == null) return null;
    return CliVersion(match[1]!, match[2] == null ? null : int.parse(match[2]!));
  }

  final String date;
  final int? rc;

  bool get isPreRelease => rc != null;

  @override
  int compareTo(CliVersion other) {
    final byDate = date.compareTo(other.date);
    if (byDate != 0) return byDate;
    if (rc == other.rc) return 0;
    if (rc == null) return 1;
    if (other.rc == null) return -1;
    return rc!.compareTo(other.rc!);
  }

  bool operator >(CliVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is CliVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(date, rc);

  @override
  String toString() => rc == null ? date : '$date-rc.$rc';
}

class CliRelease {
  const CliRelease(this.version, this.assets);

  final CliVersion version;
  final Map<String, Uri> assets;

  String get tag => '$version';
}

class CliReleases {
  CliReleases(this._fetcher);

  final Fetcher _fetcher;

  static Uri get api => Uri.parse(
        Platform.environment['TEK_RELEASES_API'] ?? 'https://api.github.com/repos/$tekRepository/releases?per_page=100',
      );

  Future<List<CliRelease>> list() async {
    final Object? json;
    try {
      json = jsonDecode(await _fetcher.readString(
        api,
        errorCode: ErrorCodes.updateFailed,
        accept: 'application/vnd.github+json',
      ));
    } on FormatException {
      throw TekException(ErrorCodes.updateFailed, 'The release list at $api is not valid JSON.');
    }
    final releases = <CliRelease>[];
    for (final release in json is List ? json : const []) {
      if (release is! Map || release['draft'] == true) continue;
      final version = CliVersion.tryParse('${release['tag_name']}');
      if (version == null) continue;
      final assets = <String, Uri>{
        for (final asset in release['assets'] is List ? release['assets'] as List : const [])
          if (asset is Map && asset['name'] is String && asset['browser_download_url'] is String)
            asset['name'] as String: Uri.parse(asset['browser_download_url'] as String),
      };
      releases.add(CliRelease(version, assets));
    }
    return releases;
  }

  Future<CliRelease?> latest({required bool preRelease}) async {
    final candidates = (await list()).where((r) => preRelease || !r.version.isPreRelease).toList();
    if (candidates.isEmpty) return null;
    return candidates.reduce((a, b) => b.version > a.version ? b : a);
  }
}

File? installedBinary() {
  final executable = Platform.resolvedExecutable;
  return p.basenameWithoutExtension(executable) == 'tek' ? File(executable) : null;
}

List<File> binaryLeftovers(File binary) => [
      File(p.join(binary.parent.path, binaryTempName)),
      File(p.join(binary.parent.path, windowsBinaryBackupName)),
    ];

Future<void> removeBinaryLeftovers(File binary) async {
  for (final file in binaryLeftovers(binary)) {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      continue;
    }
  }
}

String platformAssetName() {
  final os = switch (Platform.operatingSystem) {
    'linux' || 'macos' || 'windows' => Platform.operatingSystem,
    final other => throw TekException(ErrorCodes.unsupportedPlatform, 'tek has no builds for $other.'),
  };
  final arch = switch (Abi.current()) {
    Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => 'x64',
    Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => 'arm64',
    final other => throw TekException(ErrorCodes.unsupportedPlatform, 'tek has no builds for $other.'),
  };
  return os == 'windows' ? 'tek-$os-$arch.zip' : 'tek-$os-$arch.tar.gz';
}

Future<void> installRelease(
  CliRelease release,
  File binary,
  Fetcher fetcher, {
  Progress progress = const SilentProgress(),
}) async {
  final assetName = platformAssetName();
  final assetUrl = release.assets[assetName];
  final sumsUrl = release.assets['SHA256SUMS'];
  if (assetUrl == null || sumsUrl == null) {
    throw TekException(ErrorCodes.updateFailed, 'Release ${release.tag} has no $assetName build with checksums.');
  }

  final (archive, expected) = await progress.step(
    'Downloading tek ${release.tag}',
    () async {
      final sums = await fetcher.readString(sumsUrl, errorCode: ErrorCodes.updateFailed);
      final archive = await fetcher.readBytes(
        assetUrl,
        errorCode: ErrorCodes.updateFailed,
        timeout: const Duration(minutes: 10),
      );
      return (archive, _checksumFor(sums, assetName));
    },
    done: (result) => 'Downloaded tek ${release.tag} ($assetName, ${formatBytes(result.$1.length)})',
  );
  await progress.step(
    'Verifying checksum',
    () {
      final actual = sha256.convert(archive).toString();
      if (expected != actual) {
        throw TekException(
          ErrorCodes.checksumMismatch,
          'Checksum verification failed for $assetName: expected $expected, got $actual.',
        );
      }
      return actual;
    },
    done: (actual) => 'Verified checksum (sha256:${shortSha(actual)})',
  );
  await progress.step(
    'Installing tek ${release.tag}',
    () => _replaceBinary(release, binary, archive),
    done: (_) => 'Replaced the tek binary',
  );
}

Future<void> _replaceBinary(CliRelease release, File binary, Uint8List archive) async {
  final executable = _extractBinary(archive, windows: Platform.isWindows);
  final temp = File(p.join(binary.parent.path, binaryTempName));
  try {
    await temp.writeAsBytes(executable, flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['755', temp.path]);
      if (chmod.exitCode != 0) throw FileSystemException('chmod failed', temp.path);
    }
    final check = await Process.run(temp.path, ['--version']);
    if (check.exitCode != 0 || !'${check.stdout}'.contains(release.tag)) {
      throw TekException(
        ErrorCodes.updateFailed,
        'The downloaded tek ${release.tag} did not start correctly; ${binary.path} was left unchanged.',
      );
    }
    if (Platform.isWindows) {
      final backup = File(p.join(binary.parent.path, windowsBinaryBackupName));
      if (await backup.exists()) await backup.delete();
      await binary.rename(backup.path);
    }
    await temp.rename(binary.path);
  } on FileSystemException catch (e) {
    throw TekException(
      ErrorCodes.updateFailed,
      'Unable to replace ${binary.path}: ${e.osError?.message ?? e.message}. '
      '${Platform.isWindows ? 'Close other tek processes and try again.' : 'Run "sudo tek update" if it is installed in a system directory.'}',
    );
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}

String _checksumFor(String sums, String assetName) {
  for (final line in const LineSplitter().convert(sums)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length == 2 && (parts[1] == assetName || parts[1] == '*$assetName')) return parts[0].toLowerCase();
  }
  throw TekException(ErrorCodes.updateFailed, 'SHA256SUMS does not list $assetName.');
}

Uint8List _extractBinary(Uint8List bytes, {required bool windows}) {
  final name = windows ? 'tek.exe' : 'tek';
  final Archive archive;
  try {
    archive =
        windows ? ZipDecoder().decodeBytes(bytes) : TarDecoder().decodeBytes(const GZipDecoder().decodeBytes(bytes));
  } catch (e) {
    throw TekException(ErrorCodes.updateFailed, 'The downloaded archive is invalid: $e');
  }
  for (final entry in archive) {
    if (entry.isFile && p.posix.basename(entry.name.replaceAll(r'\', '/')) == name) return entry.content;
  }
  throw TekException(ErrorCodes.updateFailed, 'The downloaded archive does not contain $name.');
}
