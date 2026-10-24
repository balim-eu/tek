import 'dart:math';

import 'package:args/command_runner.dart';

import '../context.dart';
import '../output.dart';
import '../terminal.dart';

abstract class TekCommand extends Command<int> {
  TekCommand(this.context) {
    argParser.addFlag('json', negatable: false, help: 'Print machine-readable JSON to stdout.');
  }

  final TekContext context;

  bool get jsonMode => (globalResults?.flag('json') ?? false) || (argResults?.flag('json') ?? false);

  Output get output => Output(json: jsonMode);

  List<String> get rest => argResults!.rest;

  String argument(int index, String name) {
    if (rest.length <= index) usageException('Missing required argument <$name>.');
    return rest[index];
  }

  void expectArguments(int max) {
    if (rest.length > max) usageException('Unexpected arguments: ${rest.skip(max).join(' ')}.');
  }

  @override
  void printUsage() => output.usage(usage);
}

void writeTable(
  StringSink out,
  Iterable<(String, String)> rows, {
  String indent = '  ',
  String Function(String key)? key,
}) {
  final list = rows.toList();
  if (list.isEmpty) return;
  final width = list.map((row) => row.$1.length).reduce((a, b) => a > b ? a : b);
  for (final (name, value) in list) {
    final padded = value.isEmpty ? name : name.padRight(width);
    final styled = key == null ? padded : key(padded);
    out.writeln(value.isEmpty ? '$indent$styled' : '$indent$styled  $value');
  }
}

/// A cell of [writeColumns]: its text, and the text as it is printed, e.g. in color.
typedef Cell = (String text, String styled);

/// Writes [rows] in columns two spaces apart, aligned by the text of their cells, under the titles of [header] in dim.
/// With a [width], it cuts the last column of a row that is wider with an ellipsis, unless less than 16 characters
/// would be left of it.
void writeColumns(StringSink out, Style style, List<String> header, List<List<Cell>> rows, {int? width}) {
  final lines = [
    [for (final title in header) (title, style.dim(title))],
    ...rows,
  ];
  final widths = [for (var i = 0; i < header.length; i++) lines.map((cells) => cells[i].$1.length).reduce(max)];
  for (final cells in lines) {
    final line = StringBuffer();
    var offset = 0;
    for (final (i, (text, styled)) in cells.indexed) {
      if (i < cells.length - 1) {
        line.write('$styled${' ' * (widths[i] - text.length + 2)}');
        offset += widths[i] + 2;
      } else if (width != null && text.length > width - offset && width - offset >= 16) {
        line.write('${text.substring(0, width - offset - 1).trimRight()}…');
      } else {
        line.write(styled);
      }
    }
    out.writeln('$line'.trimRight());
  }
}

/// The first sentence of [description], on one line.
String firstSentence(String description) {
  final text = description.replaceAll(RegExp(r'\s+'), ' ').trim();
  final end = RegExp(r'[.!?](?= [A-Z`"]|$)').firstMatch(text);
  return end == null ? text : text.substring(0, end.end);
}
