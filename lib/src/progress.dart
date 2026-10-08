import 'dart:async';

abstract interface class Progress {
  Future<T> step<T>(String label, FutureOr<T> Function() work, {String? Function(T result)? done});
}

class SilentProgress implements Progress {
  const SilentProgress();

  @override
  Future<T> step<T>(String label, FutureOr<T> Function() work, {String? Function(T result)? done}) async => work();
}

String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000 * 1000) return '${(bytes / 1000).toStringAsFixed(1)} kB';
  return '${(bytes / (1000 * 1000)).toStringAsFixed(1)} MB';
}

String shortSha(String sha256) => sha256.length > 12 ? '${sha256.substring(0, 12)}…' : sha256;
