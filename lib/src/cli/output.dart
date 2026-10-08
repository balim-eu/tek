import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import '../progress.dart';
import 'terminal.dart';

class Output implements Progress {
  Output({required this.json})
      : style = Style(enabled: !json && colorsEnabled(stdout)),
        errorStyle = Style(enabled: !json && colorsEnabled(stderr));

  final bool json;
  final Style style;
  final Style errorStyle;

  static const _encoder = JsonEncoder.withIndent('  ');

  void success(Map<String, Object?> data, void Function(StringSink out) human) {
    if (json) {
      stdout.writeln(_encoder.convert({'ok': true, ...data}));
    } else {
      human(stdout);
    }
  }

  void result(Map<String, Object?> data) => stdout.writeln(_encoder.convert(data));

  void progress(String message) {
    if (!json) stderr.writeln(errorStyle.dim(message));
  }

  void completed(String message) {
    if (!json) stderr.writeln('${errorStyle.success} ${_details(message, errorStyle)}');
  }

  void warning(String message) {
    if (!json) stderr.writeln('${errorStyle.warning} ${errorStyle.yellow(message)}');
  }

  void error(TekException error, {String? usage}) {
    if (json) {
      stdout.writeln(_encoder.convert({'ok': false, 'error': error.toJson()}));
      return;
    }
    final [first, ...more] = error.message.split('\n');
    stderr.writeln('${errorStyle.failure} ${errorStyle.red(first)}');
    for (final line in more) {
      stderr.writeln(line);
    }
    for (final line in error.hint?.split('\n') ?? const <String>[]) {
      stderr.writeln('  $line');
    }
    if (usage != null) stderr.writeln('\n${errorStyle.dim(usage)}');
  }

  void usage(String text) {
    if (json) {
      stdout.writeln(_encoder.convert({'ok': true, 'usage': text}));
    } else {
      stdout.writeln(text);
    }
  }

  @override
  Future<T> step<T>(String label, FutureOr<T> Function() work, {String? Function(T result)? done}) async {
    if (json) return work();
    final spinner = Spinner.start(label, errorStyle);
    try {
      final result = await work();
      spinner?.stop();
      final message = done == null ? label : done(result);
      if (message != null) stderr.writeln('${errorStyle.success} ${_details(message, errorStyle)}');
      return result;
    } catch (_) {
      spinner?.stop();
      stderr.writeln('${errorStyle.failure} $label');
      rethrow;
    }
  }

  static String _details(String message, Style style) {
    final open = message.lastIndexOf(' (');
    if (open == -1 || !message.endsWith(')')) return message;
    return '${message.substring(0, open)} ${style.dim(message.substring(open + 1))}';
  }
}
