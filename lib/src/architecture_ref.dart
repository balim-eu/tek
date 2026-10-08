import 'package:pub_semver/pub_semver.dart';

import 'errors.dart';

final _segment = RegExp(r'^[a-z0-9][a-z0-9_-]*$');
final _semver = RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
  r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?'
  r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);

bool isValidSegment(String value) => _segment.hasMatch(value);

bool isValidArchitectureId(String value) {
  final parts = value.split('/');
  return parts.length == 2 && parts.every(isValidSegment);
}

bool looksLikeArchitectureRef(String value) {
  final at = value.indexOf('@');
  return isValidArchitectureId(at == -1 ? value : value.substring(0, at));
}

Version parseSemver(String value) {
  if (!_semver.hasMatch(value)) {
    throw FormatException('"$value" is not a valid semantic version.');
  }
  return Version.parse(value);
}

class ArchitectureRef {
  const ArchitectureRef({
    required this.publisher,
    required this.name,
    required this.constraint,
  });

  factory ArchitectureRef.parse(String input) {
    final at = input.indexOf('@');
    final id = at == -1 ? input : input.substring(0, at);
    final constraintText = at == -1 ? null : input.substring(at + 1);
    final parts = id.split('/');
    if (parts.length != 2 || !parts.every(isValidSegment)) {
      throw TekException(
        ErrorCodes.invalidReference,
        'Invalid architecture reference "$input". Expected publisher/name@version.',
        exitCode: 64,
      );
    }
    return ArchitectureRef(
      publisher: parts[0],
      name: parts[1],
      constraint: VersionSelector.parse(constraintText),
    );
  }

  final String publisher;
  final String name;
  final VersionSelector constraint;

  String get id => '$publisher/$name';

  @override
  String toString() => constraint.isLatest ? id : '$id@${constraint.text}';
}

class VersionSelector {
  const VersionSelector._(this.text, this.constraint);

  factory VersionSelector.parse(String? input) {
    final text = input?.trim() ?? '';
    if (text.isEmpty || text == 'latest') {
      return const VersionSelector._('latest', null);
    }
    try {
      return VersionSelector._(text, _parseConstraint(text));
    } on FormatException {
      throw TekException(
        ErrorCodes.invalidConstraint,
        'Invalid version constraint "$text".',
        exitCode: 64,
      );
    }
  }

  final String text;
  final VersionConstraint? constraint;

  bool get isLatest => constraint == null;

  Version? get exact {
    final value = constraint;
    return value is Version ? value : null;
  }

  bool allows(Version version) => constraint?.allows(version) ?? true;

  Version? select(Iterable<Version> versions) {
    final matching = versions.where(allows).toList();
    if (matching.isEmpty) return null;
    final stable = matching.where((v) => !v.isPreRelease).toList();
    final candidates = stable.isNotEmpty ? stable : matching;
    return candidates.reduce((a, b) => a > b ? a : b);
  }

  static VersionConstraint _parseConstraint(String text) {
    final major = RegExp(r'^v?(\d+)$').firstMatch(text);
    if (major != null) {
      final m = int.parse(major[1]!);
      return VersionRange(
        min: Version(m, 0, 0),
        max: Version(m + 1, 0, 0),
        includeMin: true,
      );
    }
    final minor = RegExp(r'^v?(\d+)\.(\d+)$').firstMatch(text);
    if (minor != null) {
      final m = int.parse(minor[1]!);
      final n = int.parse(minor[2]!);
      return VersionRange(
        min: Version(m, n, 0),
        max: Version(m, n + 1, 0),
        includeMin: true,
      );
    }
    if (text.startsWith('~')) {
      final base = Version.parse(text.substring(1).trim());
      return VersionRange(
        min: base,
        max: Version(base.major, base.minor + 1, 0),
        includeMin: true,
      );
    }
    return VersionConstraint.parse(text.startsWith('v') ? text.substring(1) : text);
  }
}
