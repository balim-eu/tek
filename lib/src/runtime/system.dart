import 'dart:ffi';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

/// The machine tek runs on, as far as installing tools goes: its system, CPU, Linux distro and package manager, and
/// whether it runs as root or can use sudo.
class HostSystem {
  const HostSystem({
    required this.os,
    required this.arch,
    this.distro,
    this.distroName,
    this.version,
    this.versionText,
    this.packageManager,
    this.root = false,
    this.sudo = false,
    this.musl = false,
  });

  /// macos, linux or windows.
  final String os;

  /// x64 or arm64.
  final String arch;

  /// The ID of /etc/os-release on Linux, e.g. ubuntu, debian or amzn.
  final String? distro;

  /// The PRETTY_NAME of /etc/os-release, e.g. Ubuntu 24.04.1 LTS, or macOS 15.5.
  final String? distroName;

  /// The version of the distro, or of macOS, e.g. 24.4.0 for Ubuntu 24.04.
  final Version? version;

  /// The version as the system writes it, e.g. 24.04.
  final String? versionText;

  /// apt or dnf on Linux.
  final String? packageManager;

  final bool root;

  /// Whether sudo is there to run the steps that need root.
  final bool sudo;

  /// Whether the C library is musl, e.g. on Alpine, which tek's executables don't run on.
  final bool musl;

  static Future<HostSystem> detect() async {
    final os = Platform.operatingSystem;
    final arch = switch (Abi.current()) {
      Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
      _ => 'x64',
    };
    if (Platform.isWindows) return HostSystem(os: os, arch: arch);
    final root = await _isRoot();
    final sudo = !root && _onPath('sudo');
    if (Platform.isMacOS) {
      var text = '';
      try {
        text = '${(await Process.run('/usr/bin/sw_vers', ['-productVersion'])).stdout}'.trim();
      } on ProcessException {
        text = '';
      }
      return HostSystem(
        os: os,
        arch: arch,
        distroName: text.isEmpty ? 'macOS' : 'macOS $text',
        version: parseLooseVersion(text),
        versionText: text.isEmpty ? null : text,
        root: root,
        sudo: sudo,
      );
    }
    final release = readOsRelease();
    return HostSystem(
      os: os,
      arch: arch,
      distro: release['ID'],
      distroName: release['PRETTY_NAME'] ?? release['NAME'],
      version: parseLooseVersion(release['VERSION_ID'] ?? ''),
      versionText: release['VERSION_ID'],
      packageManager: _onPath('apt-get')
          ? 'apt'
          : _onPath('dnf')
              ? 'dnf'
              : null,
      root: root,
      sudo: sudo,
      musl: _isMusl(),
    );
  }

  /// The platform as the install matrix names it, e.g. ubuntu 24.04 arm64 or macos 15.5 arm64.
  String get display {
    final name = os == 'linux' ? (distro ?? 'linux') : os;
    final number = versionText != null
        ? ' $versionText'
        : version == null
            ? ''
            : ' ${formatLooseVersion(version!)}';
    return '$name$number $arch';
  }

  /// The bases of the install matrix's keys this system matches, the most specific first.
  List<String> get bases => [
        if (os == 'linux' && distro != null) distro!,
        if (os == 'linux' && packageManager != null) packageManager!,
        os,
        if (os != 'windows') 'unix',
        'any',
      ];

  /// Whether tek can run the steps that need root: as root, or through sudo.
  bool get canRunAsRoot => root || sudo;

  static Future<bool> _isRoot() async {
    try {
      final id = File('/usr/bin/id').existsSync() ? '/usr/bin/id' : 'id';
      final result = await Process.run(id, ['-u']);
      return '${result.stdout}'.trim() == '0';
    } on ProcessException {
      return false;
    }
  }

  static bool _onPath(String program) {
    for (final directory in (Platform.environment['PATH'] ?? '').split(':')) {
      if (directory.isNotEmpty && File('$directory/$program').existsSync()) return true;
    }
    return false;
  }

  static bool _isMusl() {
    try {
      return Directory('/lib').listSync().any((entity) => entity.path.contains('ld-musl-'));
    } on FileSystemException {
      return false;
    }
  }
}

/// The fields of /etc/os-release, e.g. ID=ubuntu and VERSION_ID=24.04.
Map<String, String> readOsRelease([String path = '/etc/os-release']) {
  final file = File(path);
  if (!file.existsSync()) return const {};
  final fields = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final match = RegExp(r'^([A-Z_]+)=(.*)$').firstMatch(line.trim());
    if (match == null) continue;
    var value = match[2]!;
    if (value.length >= 2 && (value.startsWith('"') || value.startsWith("'")) && value.endsWith(value[0])) {
      value = value.substring(1, value.length - 1);
    }
    fields[match[1]!] = value;
  }
  return fields;
}

/// A version like 24.04, 13 or 2023 as 24.4.0, 13.0.0 or 2023.0.0, null when it has no number.
Version? parseLooseVersion(String text) {
  final match = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(text.trim());
  if (match == null) return null;
  return Version(int.parse(match[1]!), int.parse(match[2] ?? '0'), int.parse(match[3] ?? '0'));
}

/// [version] as a system names it: 24.04 for Ubuntu's 24.4.0 is printed as 24.4, 13.0.0 as 13.
String formatLooseVersion(Version version) => [
      '${version.major}',
      if (version.minor != 0 || version.patch != 0) '${version.minor}',
      if (version.patch != 0) '${version.patch}',
    ].join('.');
