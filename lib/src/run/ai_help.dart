import '../manifest.dart';
import 'command_line.dart';
import 'built_in_commands.dart';

String commandAiHelp(CommandLine line, {String? guide}) {
  final command = line.command;
  final buffer = StringBuffer();
  if (guide != null && guide.trim().isNotEmpty) {
    buffer.writeln(guide.trim());
  } else {
    buffer.writeln('# ${command.name}');
    if (command.description != null) {
      buffer
        ..writeln()
        ..writeln(command.description);
    }
    if (command.examples.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## Examples');
      for (final example in command.examples) {
        buffer.writeln();
        if (example.description != null) {
          buffer
            ..writeln(example.description)
            ..writeln();
        }
        buffer
          ..writeln('```sh')
          ..writeln('${line.invocation} ${example.arguments}')
          ..writeln('```');
      }
    }
  }
  buffer
    ..writeln()
    ..writeln('## Usage')
    ..writeln()
    ..writeln('```sh')
    ..writeln(line.synopsis)
    ..writeln('```');
  if (command.aliases.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('Aliases: ${command.aliases.map((a) => '`$a`').join(', ')}');
  }
  if (command.arguments.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Arguments')
      ..writeln();
    for (final argument in command.arguments) {
      final notes = [
        if (!argument.required) 'optional',
        if (argument.multiple) 'repeatable',
        if (argument.type != ValueType.string) argument.type.name,
        if (argument.defaultValue != null) 'default `${argument.defaultValue}`',
        if (argument.pattern != null) 'must match `${argument.pattern}`',
      ];
      buffer.writeln(_item('`${argument.usage.replaceAll(RegExp(r'[\[\]]'), '')}`', notes, argument.description));
      _allowed(buffer, argument.allowed, argument.allowedHelp);
    }
  }
  final options = [
    for (final option in command.options)
      if (!option.hidden) option
  ];
  if (options.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Options')
      ..writeln();
    for (final option in options) {
      final label = option.names != null
          ? '--<${option.name}> <${option.type.placeholder}>'
          : option.flag
              ? option.defaultValue == true
                  ? '--[no-]${option.name}'
                  : '--${option.name}'
              : '--${option.name} <${option.type.placeholder}>';
      final notes = [
        if (option.names != null) '`<${option.name}>` must match `${option.names}`',
        if (option.required) 'required',
        if (option.multiple)
          option.splitCommas && option.names == null ? 'repeatable or comma separated' : 'repeatable',
        if (option.defaultValue case final Object value when !option.flag) 'default ${_value(value)}',
        if (option.pattern != null) 'must match `${option.pattern}`',
        if (option.env != null) 'env `${option.env}`',
        if (option.deprecated != null) 'deprecated: ${option.deprecated}',
      ];
      final names = option.abbr == null ? '`$label`' : '`-${option.abbr}`, `$label`';
      buffer.writeln(_item(names, notes, option.description));
      _allowed(buffer, option.allowed, option.allowedHelp);
    }
  }
  if (line.requirements.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Requirements')
      ..writeln();
    for (final requirement in line.requirements) {
      buffer.writeln('- ${requirement.display}');
    }
  }
  buffer
    ..writeln()
    ..writeln(line.passthroughNote);
  return buffer.toString();
}

String architectureAiHelp(String reference, Manifest manifest) {
  final buffer = StringBuffer()..writeln('# ${manifest.id}@${manifest.version}');
  if (manifest.name != manifest.id) {
    buffer
      ..writeln()
      ..writeln('**${manifest.name}**');
  }
  if (manifest.description != null) {
    buffer
      ..writeln()
      ..writeln(manifest.description!.trim());
  }
  buffer
    ..writeln()
    ..writeln('## Usage')
    ..writeln()
    ..writeln('```sh')
    ..writeln('tek $reference <command> [arguments]')
    ..writeln('```')
    ..writeln()
    ..writeln('Run `tek $reference <command> --help-ai` for the guide of a command, with examples and every option.')
    ..writeln()
    ..writeln('## Commands')
    ..writeln();
  final rows = withBuiltInCommands(manifest, [
    for (final command in manifest.commands.values) (command.name, command.description ?? ''),
  ]);
  for (final (name, description) in rows) {
    final aliases = manifest.commands[name]?.aliases ?? const <String>[];
    buffer.writeln('- `$name`${aliases.isEmpty ? '' : ' (${aliases.map((a) => '`$a`').join(', ')})'}'
        '${description.isEmpty ? '' : ': $description'}');
  }
  if (manifest.requirements.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Requirements')
      ..writeln();
    for (final requirement in manifest.requirements) {
      buffer.writeln('- ${requirement.display}');
    }
  }
  return buffer.toString();
}

String _item(String names, List<String> notes, String? description) =>
    '- $names${notes.isEmpty ? '' : ' (${notes.join(', ')})'}${description == null ? '' : ': $description'}';

void _allowed(StringBuffer buffer, List<String>? allowed, Map<String, String> help) {
  if (allowed == null) return;
  for (final value in allowed) {
    buffer.writeln('  - `$value`${help[value] == null ? '' : ': ${help[value]}'}');
  }
}

String _value(Object value) => switch (value) {
      final List<Object?> values => values.map((v) => '`$v`').join(', '),
      _ => '`$value`',
    };
