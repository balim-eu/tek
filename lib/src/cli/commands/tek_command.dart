import 'package:args/command_runner.dart';

import '../context.dart';
import '../output.dart';

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
