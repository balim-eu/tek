import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../fetcher.dart';
import 'registry_auth.dart';

final _registryName = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

class RegistryConfig {
  const RegistryConfig({required this.name, required this.url, this.type = 'index', this.auth});

  factory RegistryConfig.fromJson(Object? json) {
    if (json is! Map || json['name'] is! String || json['url'] is! String) {
      throw TekException(ErrorCodes.config, 'Invalid registry entry in configuration: $json');
    }
    return RegistryConfig(
      name: json['name'] as String,
      url: Uri.parse(json['url'] as String),
      type: json['type'] as String? ?? 'index',
      auth: AuthInfo.fromJson(json['auth']),
    );
  }

  final String name;
  final Uri url;
  final String type;
  final AuthInfo? auth;

  Map<String, Object?> toJson() => {
        'name': name,
        'url': '$url',
        if (type != 'index') 'type': type,
        if (auth != null) 'auth': auth!.toJson(),
      };

  static bool isValidName(String name) => _registryName.hasMatch(name);

  static String deriveName(Uri url) {
    if (url.scheme == 'file') {
      final segments = p.split(p.dirname(url.toFilePath()));
      return _slug(segments.isEmpty ? 'local' : segments.last);
    }
    final host = url.host.toLowerCase();
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    if ((host == 'raw.githubusercontent.com' || host == 'github.com') && segments.length >= 2) {
      return _slug('${segments[0]}-${segments[1]}');
    }
    final labels = host.split('.').where((l) => !const {'www', 'raw', 'registry'}.contains(l)).toList();
    if (labels.length > 1) labels.removeLast();
    return _slug(labels.isEmpty ? host : labels.join('-'));
  }

  static String _slug(String value) {
    final slug = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'registry' : slug;
  }
}

class RegistryConfigStore {
  RegistryConfigStore(this.path);

  final String path;

  Future<List<RegistryConfig>> load() async {
    final document = await _read();
    final registries = document['registries'];
    if (registries == null) return [];
    if (registries is! List) {
      throw TekException(ErrorCodes.config, 'Invalid "registries" in $path.');
    }
    return [for (final entry in registries) RegistryConfig.fromJson(entry)];
  }

  Future<RegistryConfig> get(String name) async {
    for (final registry in await load()) {
      if (registry.name == name) return registry;
    }
    throw TekException(ErrorCodes.registryNotFound, 'No registry named "$name" is configured.');
  }

  Future<(RegistryConfig, bool)> add(String name, Uri url, {AuthInfo? auth}) async {
    if (!RegistryConfig.isValidName(name)) {
      throw TekException(
        ErrorCodes.usage,
        'Invalid registry name "$name". Use lowercase letters, digits, "-" and "_".',
        exitCode: 64,
      );
    }
    Fetcher.ensureSecure(url);
    final registries = await load();
    final config = RegistryConfig(name: name, url: url, auth: auth);
    final index = registries.indexWhere((r) => r.name == name);
    if (index == -1) {
      registries.add(config);
    } else {
      registries[index] = config;
    }
    await _save(registries);
    return (config, index != -1);
  }

  Future<RegistryConfig> remove(String name) async {
    final registries = await load();
    final index = registries.indexWhere((r) => r.name == name);
    if (index == -1) {
      throw TekException(ErrorCodes.registryNotFound, 'No registry named "$name" is configured.');
    }
    final removed = registries.removeAt(index);
    await _save(registries);
    return removed;
  }

  Future<Map<String, Object?>> _read() async {
    final file = File(path);
    if (!await file.exists()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      throw TekException(ErrorCodes.config, 'Configuration file $path is not valid JSON.');
    }
    throw TekException(ErrorCodes.config, 'Configuration file $path must contain a JSON object.');
  }

  Future<void> _save(List<RegistryConfig> registries) async {
    final document = await _read();
    document['registries'] = [for (final r in registries) r.toJson()];
    final file = File(path);
    await file.parent.create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString('${const JsonEncoder.withIndent('  ').convert(document)}\n');
    await temp.rename(file.path);
  }
}
