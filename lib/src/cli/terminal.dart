import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

bool colorsEnabled(Stdout sink) {
  final env = Platform.environment;
  if ((env['NO_COLOR'] ?? '').isNotEmpty) return false;
  final force = env['FORCE_COLOR'] ?? env['CLICOLOR_FORCE'];
  if (force != null && force.isNotEmpty && force != '0') return true;
  if (env['TERM'] == 'dumb') return false;
  return sink.supportsAnsiEscapes;
}

class Style {
  const Style({required this.enabled});

  final bool enabled;

  String _wrap(String text, String code) => enabled && text.isNotEmpty ? '\x1B[${code}m$text\x1B[0m' : text;

  String bold(String text) => _wrap(text, '1');

  String dim(String text) => _wrap(text, '2');

  String red(String text) => _wrap(text, '31');

  String green(String text) => _wrap(text, '32');

  String yellow(String text) => _wrap(text, '33');

  String blue(String text) => _wrap(text, '34');

  String magenta(String text) => _wrap(text, '35');

  String cyan(String text) => _wrap(text, '36');

  String id(String text) => bold(cyan(text));

  String version(String text) => green(text);

  String command(String text) => cyan(text);

  String heading(String text) => bold(text);

  String get success => green('✓');

  String get failure => red('✗');

  String get warning => yellow('!');

  String get update => cyan('↑');

  String get question => cyan('?');

  String get bullet => dim('•');

  String get arrow => dim('→');
}

String displayPath(String path) {
  final home = Platform.isWindows ? Platform.environment['USERPROFILE'] : Platform.environment['HOME'];
  if (home == null || home.isEmpty) return path;
  if (path == home) return '~';
  return p.isWithin(home, path) ? '~${p.separator}${p.relative(path, from: home)}' : path;
}

class Spinner {
  Spinner._(this._label, this._style) {
    _render();
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      _frame = (_frame + 1) % _frames.length;
      _render();
    });
  }

  static Spinner? start(String label, Style style) {
    if (!style.enabled) return null;
    return Spinner._(label, style);
  }

  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  final String _label;
  final Style _style;
  late final Timer _timer;
  var _frame = 0;

  void _render() => stderr.write('\r\x1B[2K${_style.cyan(_frames[_frame])} $_label${_style.dim('…')}');

  void stop() {
    _timer.cancel();
    stderr.write('\r\x1B[2K');
  }
}
