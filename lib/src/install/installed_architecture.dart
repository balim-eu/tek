import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../architecture_ref.dart';
import '../errors.dart';
import '../manifest.dart';
import '../tek_home.dart';

const installReceiptFile = '.tek-install.json';

String get executableName => Platform.isWindows ? 'run.exe' : 'run';

class InstallReceipt {
  const InstallReceipt({
    required this.id,
    required this.version,
    required this.sha256,
    required this.installedAt,
    required this.files,
    this.registry,
    this.registryUrl,
    this.artifactUrl,
  });

  factory InstallReceipt.fromJson(Map<String, Object?> json) {
    final files = json['files'];
    return InstallReceipt(
      id: json['id'] as String,
      version: json['version'] as String,
      sha256: json['sha256'] as String,
      installedAt: DateTime.parse(json['installedAt'] as String),
      files: files is Map ? files.cast<String, String>() : const {},
      registry: json['registry'] as String?,
      registryUrl: json['registryUrl'] as String?,
      artifactUrl: json['artifactUrl'] as String?,
    );
  }

  final String id;
  final String version;
  final String sha256;
  final DateTime installedAt;
  final Map<String, String> files;
  final String? registry;
  final String? registryUrl;
  final String? artifactUrl;

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'id': id,
        'version': version,
        'sha256': sha256,
        'installedAt': installedAt.toUtc().toIso8601String(),
        if (registry != null) 'registry': registry,
        if (registryUrl != null) 'registryUrl': registryUrl,
        if (artifactUrl != null) 'artifactUrl': artifactUrl,
        'files': files,
      };
}

class InstalledArchitecture {
  const InstalledArchitecture(this.directory, this.manifest, this.receipt);

  final String directory;
  final Manifest manifest;
  final InstallReceipt receipt;

  String get id => manifest.id;

  Version get version => manifest.version;

  String get reference => '$id@$version';

  String get executable => p.join(directory, executableName);

  Future<void> verifyIntegrity() async {
    final actual = await hashDirectory(directory);
    final expected = receipt.files;
    final problems = <String>[
      for (final path in expected.keys)
        if (!actual.containsKey(path)) 'missing $path' else if (actual[path] != expected[path]) 'modified $path',
      for (final path in actual.keys)
        if (!expected.containsKey(path)) 'unexpected $path',
    ];
    if (problems.isNotEmpty) {
      throw TekException(
        ErrorCodes.integrityCheckFailed,
        'Installed package $reference failed verification (${problems.take(3).join(', ')}${problems.length > 3 ? ', ...' : ''}). '
        'Reinstall it with "tek install $reference --force".',
        details: {'problems': problems},
      );
    }
  }

  static Future<Map<String, String>> hashDirectory(String directory) async {
    final hashes = <String, String>{};
    await for (final entity in Directory(directory).list(recursive: true, followLinks: false)) {
      if (entity is Link) {
        hashes[p.posix.joinAll(p.split(p.relative(entity.path, from: directory)))] = 'symlink';
        continue;
      }
      if (entity is! File) continue;
      final relative = p.posix.joinAll(p.split(p.relative(entity.path, from: directory)));
      if (relative == installReceiptFile) continue;
      hashes[relative] = sha256.convert(await entity.readAsBytes()).toString();
    }
    return hashes;
  }
}

class InstalledListing {
  const InstalledListing(this.installed, this.problems);

  final List<InstalledArchitecture> installed;
  final List<TekException> problems;
}

class InstalledStore {
  InstalledStore(this.home);

  final TekHome home;

  Future<List<Version>> versions(String id) async {
    final dir = Directory(home.architectureDir(id));
    if (!await dir.exists()) return [];
    final versions = <Version>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (!await File(p.join(entity.path, installReceiptFile)).exists()) continue;
      try {
        versions.add(parseSemver(p.basename(entity.path)));
      } on FormatException {
        continue;
      }
    }
    return versions..sort();
  }

  Future<InstalledArchitecture?> find(String id, Version version) async {
    final dir = home.versionDir(id, '$version');
    if (!await File(p.join(dir, installReceiptFile)).exists()) return null;
    return load(dir);
  }

  Future<InstalledArchitecture?> select(ArchitectureRef ref) async {
    final selected = ref.constraint.select(await versions(ref.id));
    return selected == null ? null : find(ref.id, selected);
  }

  Future<InstalledListing> all() async {
    final root = Directory(home.architecturesDir);
    final installed = <InstalledArchitecture>[];
    final problems = <TekException>[];
    if (!await root.exists()) return InstalledListing(installed, problems);
    await for (final publisher in root.list(followLinks: false)) {
      if (publisher is! Directory) continue;
      await for (final name in publisher.list(followLinks: false)) {
        final id = '${p.basename(publisher.path)}/${p.basename(name.path)}';
        if (name is! Directory || !isValidArchitectureId(id)) continue;
        for (final version in await versions(id)) {
          try {
            installed.add((await find(id, version))!);
          } on TekException catch (e) {
            problems.add(e);
          }
        }
      }
    }
    installed.sort((a, b) {
      final byId = a.id.compareTo(b.id);
      return byId != 0 ? byId : b.version.compareTo(a.version);
    });
    return InstalledListing(installed, problems);
  }

  Future<InstalledArchitecture> load(String dir) async {
    try {
      final receiptJson = jsonDecode(await File(p.join(dir, installReceiptFile)).readAsString());
      final receipt = InstallReceipt.fromJson((receiptJson as Map).cast<String, Object?>());
      final manifestPath = p.join(dir, 'manifest.yaml');
      final manifest = Manifest.parse(await File(manifestPath).readAsString(), location: manifestPath);
      if (manifest.id != receipt.id || '${manifest.version}' != receipt.version) {
        throw TekException(
          ErrorCodes.integrityCheckFailed,
          'Installed manifest in $dir does not match its install receipt.',
        );
      }
      return InstalledArchitecture(dir, manifest, receipt);
    } on TekException {
      rethrow;
    } catch (e) {
      final reference = '${p.basename(p.dirname(p.dirname(dir)))}/${p.basename(p.dirname(dir))}@${p.basename(dir)}';
      throw TekException(
        ErrorCodes.integrityCheckFailed,
        'The installation of $reference is broken. Remove it with "tek uninstall $reference" and install it again.',
        details: {'path': dir, 'cause': '$e'},
      );
    }
  }
}
