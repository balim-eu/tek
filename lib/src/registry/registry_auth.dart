import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import '../fetcher.dart';

const tokenAuth = 'token';

const _gitHubHosts = {'github.com', 'api.github.com', 'raw.githubusercontent.com'};
final _gitHubReleaseAsset = RegExp(r'^/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$');

class TokenAuth implements Credentials {
  TokenAuth(this.registryName, this.registryUrl, this._token);

  final String registryName;
  final Uri registryUrl;
  final String? _token;

  bool get isGitHub => _gitHubHosts.contains(registryUrl.host.toLowerCase());

  Set<String> get hosts => isGitHub ? _gitHubHosts : {registryUrl.host.toLowerCase()};

  String? get gitHubRepository {
    if (!isGitHub) return null;
    final segments = registryUrl.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.length >= 2 ? '${segments[0]}/${segments[1]}' : null;
  }

  @override
  bool appliesTo(Uri uri) => hosts.contains(uri.host.toLowerCase());

  @override
  Future<String> token() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw TekException(
        ErrorCodes.authenticationRequired,
        'No token is stored for registry "$registryName". Add it again with '
        '"tek registry add $registryName $registryUrl --token <token>".',
      );
    }
    return token;
  }

  @override
  String get hint {
    final repository = gitHubRepository;
    final access = repository == null
        ? 'Check that the token is valid and has not expired.'
        : 'Check that the token has read access to the contents of $repository and has not expired.';
    return '$access Replace it with "tek registry add $registryName $registryUrl --token <token>".';
  }

  Future<Uri> artifactUri(Uri uri, Fetcher fetcher) async {
    final match = isGitHub && uri.host == 'github.com' ? _gitHubReleaseAsset.firstMatch(uri.path) : null;
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

  Future<String?> token(String registry) async => (await _read())[registry];

  Future<void> setToken(String registry, String token) async {
    final tokens = await _read();
    tokens[registry] = token;
    await _write(tokens);
  }

  Future<void> remove(String registry) async {
    final tokens = await _read();
    if (tokens.remove(registry) != null) await _write(tokens);
  }

  Future<Map<String, String>> _read() async {
    final file = File(path);
    if (!await file.exists()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      final tokens = decoded is Map ? decoded['tokens'] : null;
      return tokens is Map ? tokens.cast<String, String>() : {};
    } on FormatException {
      throw TekException(ErrorCodes.config, 'Credentials file $path is not valid JSON.');
    }
  }

  Future<void> _write(Map<String, String> tokens) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString('');
    if (!Platform.isWindows) await Process.run('chmod', ['600', temp.path]);
    await temp.writeAsString('${const JsonEncoder.withIndent('  ').convert({'tokens': tokens})}\n', flush: true);
    await temp.rename(file.path);
  }
}

String readTokenFromStdin() {
  String? line;
  if (stdin.hasTerminal) {
    stderr.write('Token: ');
    stdin.echoMode = false;
    try {
      line = stdin.readLineSync();
    } finally {
      stdin.echoMode = true;
      stderr.writeln();
    }
  } else {
    line = stdin.readLineSync();
  }
  final token = line?.trim() ?? '';
  if (token.isEmpty) throw TekException(ErrorCodes.usage, 'No token was provided.', exitCode: 64);
  return token;
}
