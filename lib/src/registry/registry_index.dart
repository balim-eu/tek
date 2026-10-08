import 'package:pub_semver/pub_semver.dart';

import '../architecture_ref.dart';
import '../errors.dart';

const supportedRegistrySchemaVersion = 2;

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

class RegistryIndex {
  const RegistryIndex({required this.schemaVersion, required this.architectures});

  factory RegistryIndex.fromJson(Object? json, {required Uri source}) {
    final reader = _Reader(source);
    final root = reader.map(json, 'registry');
    final schemaVersion = root['schemaVersion'];
    if (schemaVersion is! int) reader.fail('schemaVersion must be an integer');
    if (schemaVersion > supportedRegistrySchemaVersion) {
      throw TekException(
        ErrorCodes.unsupportedSchemaVersion,
        'Registry $source uses schemaVersion $schemaVersion, which this version of tek does not support.',
      );
    }
    final architectures = <String, RegistryArchitecture>{};
    for (final (index, entry) in reader.list(root['architectures'], 'architectures').indexed) {
      final architecture = RegistryArchitecture._fromJson(entry, reader, 'architectures[$index]');
      if (architectures.containsKey(architecture.id)) {
        reader.fail('architecture ${architecture.id} is listed more than once');
      }
      architectures[architecture.id] = architecture;
    }
    return RegistryIndex(schemaVersion: schemaVersion, architectures: architectures.values.toList());
  }

  final int schemaVersion;
  final List<RegistryArchitecture> architectures;

  RegistryArchitecture? find(String id) {
    for (final architecture in architectures) {
      if (architecture.id == id) return architecture;
    }
    return null;
  }
}

class RegistryArchitecture {
  const RegistryArchitecture({
    required this.id,
    required this.publisher,
    required this.name,
    required this.versions,
    this.description,
    this.keywords = const [],
  });

  factory RegistryArchitecture._fromJson(Object? json, _Reader reader, String path) {
    final map = reader.map(json, path);
    final id = reader.string(map['id'], '$path.id');
    if (!isValidArchitectureId(id)) reader.fail('$path.id "$id" is not a valid architecture id');
    final [publisher, name] = id.split('/');
    if (map['publisher'] != null && map['publisher'] != publisher) {
      reader.fail('$path.publisher does not match id $id');
    }
    if (map['name'] != null && map['name'] != name) {
      reader.fail('$path.name does not match id $id');
    }
    final versions = <Version, RegistryVersion>{};
    for (final (index, entry) in reader.list(map['versions'], '$path.versions').indexed) {
      final version = RegistryVersion._fromJson(entry, reader, '$path.versions[$index]');
      if (versions.containsKey(version.version)) {
        reader.fail('$id@${version.version} is listed more than once');
      }
      versions[version.version] = version;
    }
    final keywords = map['keywords'];
    return RegistryArchitecture(
      id: id,
      publisher: publisher,
      name: name,
      description: reader.optionalString(map['description'], '$path.description'),
      keywords: keywords is List ? [for (final k in keywords) '$k'] : const [],
      versions: versions.values.toList()..sort((a, b) => a.version.compareTo(b.version)),
    );
  }

  final String id;
  final String publisher;
  final String name;
  final String? description;
  final List<String> keywords;
  final List<RegistryVersion> versions;

  List<Version> get versionNumbers => [for (final v in versions) v.version];

  Version? get latest => VersionSelector.parse(null).select(versionNumbers);

  RegistryVersion? version(Version version) {
    for (final candidate in versions) {
      if (candidate.version == version) return candidate;
    }
    return null;
  }

  bool matches(String query) {
    final terms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final haystack = [id, description ?? '', ...keywords].join(' ').toLowerCase();
    return terms.every(haystack.contains);
  }
}

class RegistryVersion {
  const RegistryVersion({
    required this.version,
    required this.artifacts,
    this.manifest,
    this.release,
  });

  factory RegistryVersion._fromJson(Object? json, _Reader reader, String path) {
    final map = reader.map(json, path);
    final text = reader.string(map['version'], '$path.version');
    final Version version;
    try {
      version = parseSemver(text);
    } on FormatException {
      reader.fail('$path.version "$text" is not a valid semantic version');
    }
    final artifacts = <String, RegistryArtifact>{
      if (map['artifacts'] != null)
        for (final MapEntry(:key, :value) in reader.map(map['artifacts'], '$path.artifacts').entries)
          if (RegExp(r'^[a-z]+-[a-z0-9]+$').hasMatch(key))
            key: RegistryArtifact._fromJson(value, reader, '$path.artifacts.$key')
          else
            key: reader.fail('$path.artifacts key "$key" must be <os>-<arch>, e.g. macos-arm64'),
    };
    if (artifacts.isEmpty) reader.fail('$path needs artifacts, one executable per platform');
    return RegistryVersion(
      version: version,
      manifest: reader.optionalUri(map['manifest'], '$path.manifest'),
      release: reader.optionalUri(map['release'], '$path.release'),
      artifacts: artifacts,
    );
  }

  final Version version;
  final Uri? manifest;
  final Uri? release;
  final Map<String, RegistryArtifact> artifacts;

  RegistryArtifact? artifactFor(String platform) => artifacts[platform];
}

class RegistryArtifact {
  const RegistryArtifact({required this.url, required this.sha256, this.signature});

  factory RegistryArtifact._fromJson(Object? json, _Reader reader, String path) {
    final map = reader.map(json, path);
    final url = reader.optionalUri(map['url'], '$path.url') ?? reader.fail('$path.url is required');
    String? checksum = reader.optionalString(map['sha256'], '$path.sha256');
    final structured = map['checksum'];
    if (checksum == null && structured is Map) {
      if (structured['algorithm'] != 'sha256') {
        reader.fail('$path.checksum.algorithm must be "sha256"');
      }
      checksum = reader.string(structured['value'], '$path.checksum.value');
    }
    if (checksum == null) reader.fail('$path.sha256 is required');
    final normalized = normalizeSha256(checksum);
    if (normalized == null) reader.fail('$path.sha256 "$checksum" is not a valid SHA-256 checksum');
    final signature = map['signature'];
    return RegistryArtifact(
      url: url,
      sha256: normalized,
      signature: signature is Map ? signature.cast<String, Object?>() : null,
    );
  }

  final Uri url;
  final String sha256;
  final Map<String, Object?>? signature;

  Map<String, Object?> toJson() => {
        'url': '$url',
        'sha256': sha256,
        if (signature != null) 'signature': signature,
      };
}

String? normalizeSha256(String value) {
  var text = value.trim().toLowerCase();
  if (text.startsWith('sha256:')) text = text.substring(7);
  return _sha256.hasMatch(text) ? text : null;
}

class _Reader {
  _Reader(this.source);

  final Uri source;

  Never fail(String message) =>
      throw TekException(ErrorCodes.invalidRegistry, 'Registry $source is invalid: $message.');

  Map<String, Object?> map(Object? value, String path) {
    if (value is Map) return value.cast<String, Object?>();
    fail('$path must be an object');
  }

  List<Object?> list(Object? value, String path) {
    if (value is List) return value;
    fail('$path must be an array');
  }

  String string(Object? value, String path) {
    if (value is String && value.isNotEmpty) return value;
    fail('$path must be a non-empty string');
  }

  String? optionalString(Object? value, String path) {
    if (value == null) return null;
    return string(value, path);
  }

  Uri? optionalUri(Object? value, String path) {
    final text = optionalString(value, path);
    if (text == null) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) fail('$path "$text" is not a valid URL');
    return source.resolveUri(uri);
  }
}
