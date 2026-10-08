import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import '../fetcher.dart';

const bearerAuth = 'bearer';
const basicAuth = 'basic';
const supportedAuthTypes = {bearerAuth, basicAuth};

const _gitHubHosts = {'github.com', 'api.github.com', 'raw.githubusercontent.com'};
final _gitHubReleaseAsset = RegExp(r'^/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$');

bool isGitHubHost(Uri uri) => _gitHubHosts.contains(uri.host.toLowerCase());

String? gitHubRepository(Uri uri) {
  if (!isGitHubHost(uri)) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return segments.length >= 2 ? '${segments[0]}/${segments[1]}' : null;
}

String authNoun(String type) => switch (type) {
      bearerAuth => 'token',
      basicAuth => 'username and password',
      _ => '$type credentials',
    };

String authLabel(String type) => switch (type) {
      bearerAuth => 'a token',
      basicAuth => 'a username and password',
      _ => '$type credentials',
    };

String credentialOptions(String type) =>
    type == basicAuth ? '--username <name> --password <password>' : '--token <token>';

class AuthInfo {
  const AuthInfo(this.type, {this.description, this.permissions = const [], this.url, this.hosts = const []});

  static AuthInfo? fromJson(Object? json) => switch (json) {
        'token' => const AuthInfo(bearerAuth),
        final String type => AuthInfo(type),
        final Map map => AuthInfo(
            '${map['type'] ?? bearerAuth}',
            description: map['description'] as String?,
            permissions: [for (final permission in map['permissions'] as List? ?? const []) '$permission'],
            url: map['url'] is String ? Uri.tryParse(map['url'] as String) : null,
            hosts: [for (final host in map['hosts'] as List? ?? const []) '$host'.toLowerCase()],
          ),
        _ => null,
      };

  final String type;
  final String? description;
  final List<String> permissions;
  final Uri? url;
  final List<String> hosts;

  bool get isSupported => supportedAuthTypes.contains(type);

  Map<String, Object?> toJson() => {
        'type': type,
        if (description != null) 'description': description,
        if (permissions.isNotEmpty) 'permissions': permissions,
        if (url != null) 'url': '$url',
        if (hosts.isNotEmpty) 'hosts': hosts,
      };

  List<String> details(Uri registryUrl) {
    final repository = gitHubRepository(registryUrl);
    final description = this.description ??
        (repository != null && type == bearerAuth
            ? 'A GitHub token with read access to the contents of $repository.'
            : null);
    return [
      if (description != null) description,
      for (final (index, permission) in permissions.indexed)
        '${index == 0 ? 'Permissions' : ''}'.padRight(13) + permission,
      if (url != null) '${'Get one at'.padRight(13)}$url',
    ];
  }

  void ensureSupported(String registry) {
    if (isSupported) return;
    throw TekException(
      ErrorCodes.config,
      'Registry "$registry" uses $type authentication, which this version of tek does not support.',
      hint: 'Update tek with "tek update".',
    );
  }
}

class Credential {
  const Credential.bearer(String this.token)
      : type = bearerAuth,
        username = null,
        password = null;

  const Credential.basic(String this.username, String this.password)
      : type = basicAuth,
        token = null;

  static Credential? fromJson(Object? json) => switch (json) {
        final String token when token.isNotEmpty => Credential.bearer(token),
        {'type': basicAuth, 'username': final String username, 'password': final String password} =>
          Credential.basic(username, password),
        {'token': final String token} when token.isNotEmpty => Credential.bearer(token),
        _ => null,
      };

  final String type;
  final String? token;
  final String? username;
  final String? password;

  String get authorization =>
      type == basicAuth ? 'Basic ${base64.encode(utf8.encode('$username:$password'))}' : 'Bearer $token';

  Map<String, Object?> toJson() =>
      type == basicAuth ? {'type': type, 'username': username, 'password': password} : {'type': type, 'token': token};
}

String credentialVariable(String registry, String field) =>
    'TEK_REGISTRY_${registry.toUpperCase().replaceAll('-', '_')}_$field';

Credential? environmentCredential(String registry) {
  final env = Platform.environment;
  final token = env[credentialVariable(registry, 'TOKEN')]?.trim();
  if (token != null && token.isNotEmpty) return Credential.bearer(token);
  final username = env[credentialVariable(registry, 'USERNAME')]?.trim();
  final password = env[credentialVariable(registry, 'PASSWORD')];
  if (username != null && username.isNotEmpty && password != null) return Credential.basic(username, password);
  return null;
}

String? environmentSource(String registry, Credential credential) =>
    credential.type == basicAuth ? credentialVariable(registry, 'PASSWORD') : credentialVariable(registry, 'TOKEN');

String credentialHint(String registry, Uri url, AuthInfo info, {required String next, bool rejected = false}) => [
      if (rejected)
        info.type == basicAuth
            ? 'Check the username and password of $registry.'
            : 'Check that the token of $registry is valid and has not expired.',
      if (!rejected) '$registry needs ${authLabel(info.type)}.',
      ...info.details(url),
      next,
    ].join('\n');

class RegistryAuth implements Credentials {
  RegistryAuth(this.registryName, this.registryUrl, this.info, this.credential);

  final String registryName;
  final Uri registryUrl;
  final AuthInfo? info;
  final Credential? credential;

  AuthInfo get _info => info ?? AuthInfo(credential?.type ?? bearerAuth);

  Set<String> get hosts => {
        ...(isGitHubHost(registryUrl) ? _gitHubHosts : {registryUrl.host.toLowerCase()}),
        ...?info?.hosts,
      };

  @override
  bool appliesTo(Uri uri) => hosts.contains(uri.host.toLowerCase());

  @override
  String authorization() {
    final credential = this.credential;
    if (credential == null) {
      throw TekException(
        ErrorCodes.authenticationRequired,
        'No ${authNoun(_info.type)} is saved for registry "$registryName".',
        hint: credentialHint(
          registryName,
          registryUrl,
          _info,
          next: 'Save it with: tek registry login $registryName',
        ),
      );
    }
    return credential.authorization;
  }

  @override
  String get hint => credentialHint(
        registryName,
        registryUrl,
        _info,
        rejected: true,
        next: 'Replace it with: tek registry login $registryName',
      );

  Future<Uri> artifactUri(Uri uri, Fetcher fetcher) async {
    final match =
        isGitHubHost(registryUrl) && uri.host == 'github.com' ? _gitHubReleaseAsset.firstMatch(uri.path) : null;
    if (match == null) return uri;
    final [owner, repository, tag, name] = [for (var i = 1; i <= 4; i++) Uri.decodeComponent(match[i]!)];
    final release = Uri.https('api.github.com', '/repos/$owner/$repository/releases/tags/$tag');
    final json = jsonDecode(await fetcher.readString(
      release,
      errorCode: ErrorCodes.downloadFailed,
      credentials: this,
      accept: 'application/vnd.github+json',
    ));
    final assets = json is Map ? json['assets'] : null;
    for (final asset in assets is List ? assets : const []) {
      if (asset is Map && asset['name'] == name && asset['url'] is String) return Uri.parse(asset['url'] as String);
    }
    throw TekException(ErrorCodes.downloadFailed, 'Release $tag of $owner/$repository has no asset named $name.');
  }
}

class CredentialStore {
  CredentialStore(this.path);

  final String path;

  Future<Credential?> credential(String registry) async => environmentCredential(registry) ?? await saved(registry);

  Future<Credential?> saved(String registry) async => (await _read())[registry];

  Future<void> save(String registry, Credential credential) async {
    final credentials = await _read();
    credentials[registry] = credential;
    await _write(credentials);
  }

  Future<bool> remove(String registry) async {
    final credentials = await _read();
    if (credentials.remove(registry) == null) return false;
    await _write(credentials);
    return true;
  }

  Future<Map<String, Credential>> _read() async {
    final file = File(path);
    if (!await file.exists()) return {};
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      throw TekException(ErrorCodes.config, 'Credentials file $path is not valid JSON.');
    }
    final entries = decoded is Map ? decoded['credentials'] ?? decoded['tokens'] : null;
    return {
      if (entries is Map)
        for (final MapEntry(:key, :value) in entries.entries)
          if (Credential.fromJson(value) case final credential?) '$key': credential,
    };
  }

  Future<void> _write(Map<String, Credential> credentials) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString('');
    if (!Platform.isWindows) await Process.run('chmod', ['600', temp.path]);
    final document = {
      'credentials': {for (final MapEntry(:key, :value) in credentials.entries) key: value.toJson()},
    };
    await temp.writeAsString('${const JsonEncoder.withIndent('  ').convert(document)}\n', flush: true);
    await temp.rename(file.path);
  }
}

bool canPrompt() {
  if (!stdin.hasTerminal || stdioType(stderr) != StdioType.terminal) return false;
  try {
    stdin.echoMode;
    return true;
  } on StdinException {
    return false;
  }
}

String readSecret(String label, {bool trim = true}) => _readInput(label, hidden: true, trim: trim);

String readLine(String label) => _readInput(label, hidden: false, trim: true);

String _readInput(String label, {required bool hidden, required bool trim}) {
  String? line;
  if (canPrompt()) {
    stderr.write('$label: ');
    if (hidden) stdin.echoMode = false;
    try {
      line = stdin.readLineSync();
    } finally {
      if (hidden) {
        stdin.echoMode = true;
        stderr.writeln();
      }
    }
  } else {
    line = stdin.readLineSync();
  }
  final value = trim ? line?.trim() ?? '' : line ?? '';
  if (value.isEmpty) throw TekException(ErrorCodes.usage, 'No ${label.toLowerCase()} was provided.', exitCode: 64);
  return value;
}
