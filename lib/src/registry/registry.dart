import 'dart:convert';
import 'dart:typed_data';

import 'package:pub_semver/pub_semver.dart';

import '../architecture_ref.dart';
import '../errors.dart';
import '../fetcher.dart';
import '../manifest.dart';
import 'registry_auth.dart';
import 'registry_config.dart';
import 'registry_index.dart';

abstract interface class Registry {
  RegistryConfig get config;

  Future<RegistryIndex> index();

  Future<List<RegistryArchitecture>> search(String query);

  Future<RegistryArchitecture?> find(String id);

  Future<Manifest?> manifest(RegistryArchitecture architecture, RegistryVersion version);

  Future<Uint8List> download(RegistryArtifact artifact);
}

Registry openRegistry(RegistryConfig config, Fetcher fetcher, {Credential? credential}) {
  return switch (config.type) {
    'index' => IndexRegistry(config, fetcher, credential: credential),
    _ => throw TekException(
        ErrorCodes.unsupportedRegistryType,
        'Registry "${config.name}" has unsupported type "${config.type}".',
      ),
  };
}

class IndexRegistry implements Registry {
  IndexRegistry(this.config, this._fetcher, {Credential? credential})
      : _auth = config.auth == null && credential == null
            ? null
            : RegistryAuth(config.name, config.url, config.auth, credential);

  @override
  final RegistryConfig config;
  final Fetcher _fetcher;
  final RegistryAuth? _auth;
  Future<RegistryIndex>? _index;

  @override
  Future<RegistryIndex> index() => _index ??= _load();

  Future<RegistryIndex> _load() async {
    config.auth?.ensureSupported(config.name);
    final String text;
    try {
      text = await _fetcher.readString(config.url, errorCode: ErrorCodes.registryUnavailable, credentials: _auth);
    } on TekException catch (e) {
      if (_auth != null || !const {401, 403, 404}.contains(e.details?['status'])) rethrow;
      throw TekException(
        e.code,
        e.message,
        hint: 'If the registry is private, save its credentials with: tek registry login ${config.name}',
        details: e.details,
      );
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw TekException(ErrorCodes.invalidRegistry, 'Registry ${config.url} is not valid JSON.');
    }
    return RegistryIndex.fromJson(json, source: config.url);
  }

  @override
  Future<List<RegistryArchitecture>> search(String query) async {
    final architectures = (await index()).architectures;
    return [
      for (final a in architectures)
        if (a.matches(query)) a
    ];
  }

  @override
  Future<RegistryArchitecture?> find(String id) async => (await index()).find(id);

  @override
  Future<Manifest?> manifest(RegistryArchitecture architecture, RegistryVersion version) async {
    final uri = version.manifest;
    if (uri == null) return null;
    final text = await _fetcher.readString(uri, errorCode: ErrorCodes.registryUnavailable, credentials: _auth);
    final manifest = Manifest.parse(text, location: '$uri');
    if (manifest.id != architecture.id || manifest.version != version.version) {
      throw TekException(
        ErrorCodes.invalidManifest,
        'Manifest $uri describes ${manifest.id}@${manifest.version}, expected ${architecture.id}@${version.version}.',
      );
    }
    return manifest;
  }

  @override
  Future<Uint8List> download(RegistryArtifact artifact) async {
    final url = await _auth?.artifactUri(artifact.url, _fetcher) ?? artifact.url;
    return _fetcher.readBytes(
      url,
      errorCode: ErrorCodes.downloadFailed,
      timeout: const Duration(minutes: 10),
      credentials: _auth,
      accept: 'application/octet-stream',
    );
  }
}

class ResolvedArchitecture {
  const ResolvedArchitecture(this.registry, this.architecture, this.version);

  final Registry registry;
  final RegistryArchitecture architecture;
  final RegistryVersion version;

  String get id => architecture.id;

  Version get versionNumber => version.version;

  String get reference => '$id@$versionNumber';
}

class SearchHit {
  const SearchHit(this.registry, this.architecture);

  final Registry registry;
  final RegistryArchitecture architecture;
}

class RegistryFailure {
  const RegistryFailure(this.registry, this.error);

  final Registry registry;
  final TekException error;

  Map<String, Object?> toJson() => {'registry': registry.config.name, ...error.toJson()};
}

class SearchResults {
  const SearchResults(this.hits, this.failures);

  final List<SearchHit> hits;
  final List<RegistryFailure> failures;
}

class RegistrySet {
  RegistrySet(this.registries);

  static Future<RegistrySet> load(RegistryConfigStore store, CredentialStore credentials, Fetcher fetcher) async {
    final configs = await store.load();
    return RegistrySet([
      for (final config in configs)
        openRegistry(config, fetcher, credential: await credentials.credential(config.name)),
    ]);
  }

  final List<Registry> registries;

  List<Registry> select(String? name) {
    if (name != null) {
      for (final registry in registries) {
        if (registry.config.name == name) return [registry];
      }
      throw TekException(ErrorCodes.registryNotFound, 'No registry named "$name" is configured.');
    }
    if (registries.isEmpty) {
      throw TekException(
        ErrorCodes.noRegistries,
        'No registries are configured. Add one with "tek registry add <name> <url>".',
      );
    }
    return registries;
  }

  Future<SearchResults> search(String query, {String? registry}) async {
    final hits = <SearchHit>[];
    final failures = <RegistryFailure>[];
    final seen = <String>{};
    for (final candidate in select(registry)) {
      try {
        for (final architecture in await candidate.search(query)) {
          if (seen.add(architecture.id)) hits.add(SearchHit(candidate, architecture));
        }
      } on TekException catch (e) {
        failures.add(RegistryFailure(candidate, e));
      }
    }
    if (hits.isEmpty && failures.isNotEmpty && failures.length == select(registry).length) {
      throw failures.first.error;
    }
    hits.sort((a, b) => a.architecture.id.compareTo(b.architecture.id));
    return SearchResults(hits, failures);
  }

  Future<ResolvedArchitecture> resolve(ArchitectureRef ref, {String? registry}) async {
    final candidates = select(registry);
    final failures = <RegistryFailure>[];
    for (final candidate in candidates) {
      final RegistryArchitecture? architecture;
      try {
        architecture = await candidate.find(ref.id);
      } on TekException catch (e) {
        failures.add(RegistryFailure(candidate, e));
        continue;
      }
      if (architecture == null) continue;
      final selected = ref.constraint.select(architecture.versionNumbers);
      if (selected == null) {
        throw TekException(
          ErrorCodes.versionNotFound,
          'No version of ${ref.id} matches "${ref.constraint.text}".',
          details: {
            'registry': candidate.config.name,
            'versions': [for (final v in architecture.versionNumbers) '$v'],
          },
        );
      }
      return ResolvedArchitecture(candidate, architecture, architecture.version(selected)!);
    }
    if (failures.length == candidates.length) throw failures.first.error;
    throw TekException(
      ErrorCodes.architectureNotFound,
      'Architecture $ref was not found.',
      details: failures.isEmpty
          ? null
          : {
              'unavailableRegistries': [for (final f in failures) f.toJson()]
            },
    );
  }
}
