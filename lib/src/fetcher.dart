import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'version.dart';

const _loopbackHosts = {'localhost', '127.0.0.1', '::1', '[::1]'};
const _redirectStatuses = {301, 302, 303, 307, 308};
const _maxRedirects = 5;

abstract interface class Credentials {
  bool appliesTo(Uri uri);

  Future<String> token();

  String get hint;
}

class Fetcher {
  Fetcher({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static Uri parseLocation(String input) {
    final uri = Uri.tryParse(input);
    if (uri != null && const {'http', 'https', 'file'}.contains(uri.scheme)) return uri;
    return Uri.file(p.absolute(input));
  }

  static void ensureSecure(Uri uri) {
    switch (uri.scheme) {
      case 'https' || 'file':
        return;
      case 'http' when _loopbackHosts.contains(uri.host):
        return;
      case 'http':
        throw TekException(
          ErrorCodes.insecureUrl,
          'Refusing to use insecure URL $uri. Use HTTPS.',
        );
      default:
        throw TekException(
          ErrorCodes.insecureUrl,
          'Unsupported URL scheme "${uri.scheme}" in $uri.',
        );
    }
  }

  Future<Uint8List> readBytes(
    Uri uri, {
    required String errorCode,
    Duration timeout = const Duration(seconds: 30),
    Credentials? credentials,
    String? accept,
  }) async {
    ensureSecure(uri);
    if (uri.scheme == 'file') {
      try {
        return await File.fromUri(uri).readAsBytes();
      } on FileSystemException catch (e) {
        throw TekException(errorCode, 'Unable to read ${uri.toFilePath()}: ${e.osError?.message ?? e.message}.');
      }
    }
    try {
      return await _get(uri, errorCode, credentials, accept).timeout(timeout);
    } on TimeoutException {
      throw TekException(errorCode, 'Request to $uri timed out.');
    } on SocketException catch (e) {
      throw TekException(errorCode, 'Unable to reach $uri: ${e.osError?.message ?? e.message}.');
    } on http.ClientException catch (e) {
      throw TekException(errorCode, 'Request to $uri failed: ${e.message}.');
    } on HandshakeException catch (e) {
      throw TekException(errorCode, 'TLS handshake with $uri failed: ${e.message}.');
    }
  }

  Future<String> readString(Uri uri, {required String errorCode, Credentials? credentials, String? accept}) async {
    final bytes = await readBytes(uri, errorCode: errorCode, credentials: credentials, accept: accept);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw TekException(errorCode, 'Response from $uri is not valid UTF-8.');
    }
  }

  Future<Uint8List> _get(Uri uri, String errorCode, Credentials? credentials, String? accept) async {
    var current = uri;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final authenticated = credentials != null && credentials.appliesTo(current);
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers['User-Agent'] = 'tek/$tekVersion';
      if (accept != null) request.headers['Accept'] = accept;
      if (authenticated) request.headers['Authorization'] = 'Bearer ${await credentials.token()}';

      final response = await http.Response.fromStream(await _client.send(request));
      final status = response.statusCode;
      final location = response.headers['location'];
      if (_redirectStatuses.contains(status) && location != null) {
        current = current.resolve(location);
        ensureSecure(current);
        continue;
      }
      if (status == 200) return response.bodyBytes;
      if (authenticated && const {401, 403, 404}.contains(status)) {
        throw TekException(
          ErrorCodes.accessDenied,
          'Access to $uri was denied (HTTP $status). ${credentials.hint}',
          details: {'status': status},
        );
      }
      if (!authenticated && const {401, 403}.contains(status)) {
        throw TekException(
          ErrorCodes.authenticationRequired,
          '$uri requires authentication (HTTP $status).',
          details: {'status': status},
        );
      }
      throw TekException(errorCode, 'Request to $uri failed with HTTP $status.', details: {'status': status});
    }
    throw TekException(errorCode, 'Request to $uri was redirected too many times.');
  }

  void close() => _client.close();
}
