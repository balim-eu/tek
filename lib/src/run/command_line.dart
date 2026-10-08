import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../cli/terminal.dart';
import '../errors.dart';
import '../manifest.dart';

const _helpFlags = {'--help', '-h'};
const _helpAiFlags = {'--help-ai'};
const _trueValues = {'1', 'true', 'yes', 'on'};
const _falseValues = {'0', 'false', 'no', 'off'};

class ParsedCommand {
  const ParsedCommand({
    required this.help,
    this.parameters = const {},
    this.environment = const {'TEK_PARAMS': '{}'},
    this.passthrough = const [],
    this.warnings = const [],
  });

  final bool help;
  final Map<String, Object?> parameters;
  final Map<String, String> environment;
  final List<String> passthrough;
  final List<String> warnings;
}

class CommandLine {
  CommandLine({
    required this.reference,
    required this.command,
    required this.requirements,
    Map<String, String>? environment,
  }) : _environment = environment ?? Platform.environment;

  final String reference;
  final ManifestCommand command;
  final List<Requirement> requirements;
  final Map<String, String> _environment;

  String get invocation => 'tek $reference ${command.name}';

  late final ArgParser parser = _buildParser();

  ArgParser _buildParser() {
    final parser = ArgParser(allowTrailingOptions: !command.optionsFirst)
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Print this usage information.')
      ..addFlag('help-ai', negatable: false, help: 'Print a guide with examples for AI agents in Markdown.');
    for (final option in command.options) {
      if (option.names != null) continue;
      final help = _optionHelp(option);
      if (option.flag) {
        final defaultValue = option.defaultValue == true;
        parser.addFlag(
          option.name,
          abbr: option.abbr,
          help: help,
          defaultsTo: defaultValue,
          negatable: defaultValue,
          hide: option.hidden,
        );
        continue;
      }
      final defaultValue = option.defaultValue;
      parser.addMultiOption(
        option.name,
        abbr: option.abbr,
        help: help,
        valueHelp: option.type.placeholder,
        defaultsTo: switch (defaultValue) {
          final List<String> values => values,
          final String value => [value],
          _ => null,
        },
        allowed: option.allowed,
        allowedHelp: option.allowedHelp.isEmpty ? null : option.allowedHelp,
        splitCommas: option.multiple && option.splitCommas,
        hide: option.hidden,
      );
    }
    return parser;
  }

  String? _optionHelp(CommandOption option) {
    final notes = [
      if (option.required) 'required',
      if (option.env != null) 'env: ${option.env}',
      if (option.pattern != null) 'must match ${option.pattern}',
      if (option.deprecated != null) 'deprecated: ${option.deprecated}',
    ];
    final description = option.description;
    if (notes.isEmpty) return description;
    final suffix = '(${notes.join(', ')})';
    return description == null ? suffix : '$description $suffix';
  }

  bool requestsAiHelp(List<String> args) {
    final separator = args.indexOf('--');
    final before = separator == -1 ? args : args.sublist(0, separator);
    return command.declaresParameters ? _requests(before, _helpAiFlags) : before.any(_helpAiFlags.contains);
  }

  ParsedCommand parse(List<String> args) {
    final separator = args.indexOf('--');
    final before = separator == -1 ? args : args.sublist(0, separator);
    final after = separator == -1 ? const <String>[] : args.sublist(separator + 1);

    if (!command.declaresParameters) {
      if (before.any(_helpFlags.contains)) return const ParsedCommand(help: true);
      return ParsedCommand(help: false, passthrough: [...before, ...after]);
    }

    if (_requests(before, _helpFlags)) return const ParsedCommand(help: true);
    final (rest, named) = _named(before);
    final ArgResults results;
    try {
      results = parser.parse(rest);
    } on ArgParserException catch (e) {
      throw _usage(e.message);
    }

    final parameters = <String, Object?>{};
    final environment = <String, String>{};
    final warnings = <String>[];
    final positionals = results.rest;
    var index = 0;
    for (final argument in command.arguments) {
      final label = '<${argument.name}>';
      if (argument.multiple) {
        final values = positionals.skip(index).toList();
        if (values.isEmpty && argument.required) throw _usage('Missing argument $label.');
        parameters[argument.name] = [for (final v in values) _argumentValue(argument, v, label)];
        environment[parameterEnvironmentName(argument.name)] = values.join(',');
        index = positionals.length;
        continue;
      }
      final String? value;
      if (index < positionals.length) {
        value = positionals[index++];
      } else if (argument.required) {
        throw _usage('Missing argument $label.');
      } else {
        value = argument.defaultValue;
      }
      parameters[argument.name] = value == null ? null : _argumentValue(argument, value, label);
      if (value != null) environment[parameterEnvironmentName(argument.name)] = value;
    }
    final leftover = positionals.skip(index).toList();
    if (leftover.isNotEmpty && !command.optionsFirst) {
      throw _usage('Unexpected argument${leftover.length > 1 ? 's' : ''}: ${leftover.join(' ')}.');
    }

    final missing = <String>[];
    for (final option in command.options) {
      if (option.names != null) {
        final given = named[option] ?? const <String, List<String>>{};
        if (given.isEmpty && option.required) missing.add('--<${option.name}>');
        final values = <String, Object>{
          for (final MapEntry(key: name, value: values) in given.entries)
            name: option.multiple
                ? [for (final value in values) _namedValue(option, name, value)]
                : values.length == 1
                    ? _namedValue(option, name, values.single)
                    : throw _usage('Option --$name was given more than once.'),
        };
        parameters[option.name] = values;
        environment[parameterEnvironmentName(option.name)] = jsonEncode(values);
        continue;
      }
      final label = '--${option.name}';
      final parsed = results.wasParsed(option.name);
      if (parsed && option.deprecated != null) warnings.add('$label is deprecated: ${option.deprecated}');
      final fromEnv = !parsed && option.env != null ? _environment[option.env!] : null;
      final envName = parameterEnvironmentName(option.name);

      if (option.flag) {
        final value = fromEnv == null || fromEnv.isEmpty ? results.flag(option.name) : _bool(fromEnv, option);
        parameters[option.name] = value;
        environment[envName] = '$value';
        continue;
      }

      var values = results.multiOption(option.name);
      if (fromEnv != null && fromEnv.isNotEmpty) {
        values = option.multiple && option.splitCommas ? fromEnv.split(',').map((v) => v.trim()).toList() : [fromEnv];
        for (final value in values) {
          if (option.allowed != null && !option.allowed!.contains(value)) {
            throw _usage('"$value" from \$${option.env} is not an allowed value for $label.');
          }
        }
      }
      if (!option.multiple && values.length > 1) throw _usage('Option $label was given more than once.');
      if (values.isEmpty && option.required) {
        missing.add('$label${option.env == null ? '' : ' (or set \$${option.env})'}');
        continue;
      }
      final converted = [for (final v in values) _optionValue(option, v, label)];
      if (option.multiple) {
        parameters[option.name] = converted;
        environment[envName] = values.join(option.splitCommas ? ',' : '\n');
      } else {
        parameters[option.name] = converted.isEmpty ? null : converted.single;
        if (values.isNotEmpty) environment[envName] = values.single;
      }
    }

    if (missing.isNotEmpty) {
      final list = missing.length == 1
          ? missing.single
          : '${missing.sublist(0, missing.length - 1).join(', ')} and ${missing.last}';
      throw _usage('Missing option${missing.length == 1 ? '' : 's'} $list.');
    }

    environment['TEK_PARAMS'] = jsonEncode(parameters);
    return ParsedCommand(
      help: false,
      parameters: parameters,
      environment: environment,
      passthrough: [...leftover, ...after],
      warnings: warnings,
    );
  }

  (List<String>, Map<CommandOption, Map<String, List<String>>>) _named(List<String> args) {
    final families = [
      for (final option in command.options)
        if (option.names != null) option,
    ];
    if (families.isEmpty) return (args, const {});
    final rest = <String>[];
    final named = <CommandOption, Map<String, List<String>>>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) {
        rest.add(arg);
        if (command.optionsFirst && !arg.startsWith('-')) {
          rest.addAll(args.skip(i + 1));
          break;
        }
        continue;
      }
      final equals = arg.indexOf('=');
      final name = arg.substring(2, equals == -1 ? arg.length : equals);
      final declared = parser.options[name] ?? (name.startsWith('no-') ? parser.options[name.substring(3)] : null);
      final family = declared == null ? families.where((o) => o.matchesName(name)).firstOrNull : null;
      if (family == null) {
        rest.add(arg);
        if (declared != null && !declared.isFlag && equals == -1 && i + 1 < args.length) rest.add(args[++i]);
        continue;
      }
      final value = equals != -1
          ? arg.substring(equals + 1)
          : i + 1 < args.length
              ? args[++i]
              : throw _usage('Option --$name needs a value.');
      ((named[family] ??= {})[name] ??= []).add(value);
    }
    return (rest, named);
  }

  Object _namedValue(CommandOption option, String name, String value) {
    if (option.allowed != null && !option.allowed!.contains(value)) {
      throw _usage('"$value" is not an allowed value for --$name. Allowed: ${option.allowed!.join(', ')}.');
    }
    return _optionValue(option, value, '--$name');
  }

  bool _requests(List<String> before, Set<String> flags) {
    if (!command.optionsFirst) return before.any(flags.contains);
    for (final arg in before) {
      if (flags.contains(arg)) return true;
      if (!arg.startsWith('-')) return false;
    }
    return false;
  }

  Object _argumentValue(CommandArgument argument, String value, String label) {
    if (argument.allowed != null && !argument.allowed!.contains(value)) {
      throw _usage('"$value" is not an allowed value for $label. Allowed: ${argument.allowed!.join(', ')}.');
    }
    return _convert(value, argument.type, argument.pattern, label);
  }

  Object _optionValue(CommandOption option, String value, String label) =>
      _convert(value, option.type, option.pattern, label);

  Object _convert(String value, ValueType type, String? pattern, String label) {
    if (pattern != null && !RegExp('^(?:$pattern)\$').hasMatch(value)) {
      throw _usage('$label must match $pattern, got "$value".');
    }
    switch (type) {
      case ValueType.string:
        return value;
      case ValueType.int:
        return int.tryParse(value) ?? (throw _usage('$label must be a whole number, got "$value".'));
      case ValueType.number:
        return num.tryParse(value) ?? (throw _usage('$label must be a number, got "$value".'));
      case ValueType.file:
        if (!File(value).existsSync()) throw _usage('$label must be an existing file, got "$value".');
        return value;
      case ValueType.directory:
        if (!Directory(value).existsSync()) throw _usage('$label must be an existing directory, got "$value".');
        return value;
      case ValueType.url:
        final uri = Uri.tryParse(value);
        if (uri == null || !uri.hasScheme || (uri.host.isEmpty && uri.scheme != 'file')) {
          throw _usage('$label must be an absolute URL, got "$value".');
        }
        return value;
    }
  }

  bool _bool(String value, CommandOption option) {
    final normalized = value.trim().toLowerCase();
    if (_trueValues.contains(normalized)) return true;
    if (_falseValues.contains(normalized)) return false;
    throw _usage('\$${option.env} must be true or false for --${option.name}, got "$value".');
  }

  String get usage => render(const Style(enabled: false));

  String get synopsis {
    final positional = command.declaresParameters
        ? [
            if (command.optionsFirst && command.options.isNotEmpty) '[options]',
            for (final a in command.arguments) a.usage,
            if (!command.optionsFirst && command.options.isNotEmpty) '[options]',
          ].join(' ')
        : '[arguments]';
    return positional.isEmpty ? invocation : '$invocation $positional';
  }

  String get passthroughNote => switch ((command.declaresParameters, command.optionsFirst)) {
        (false, _) => 'Arguments are passed to the command unchanged.',
        (true, true) => 'Options must come before the arguments; everything after the arguments, '
            'or after "--", is passed to the command unchanged.',
        (true, false) => 'Arguments after "--" are passed to the command unchanged.',
      };

  String render(Style style) {
    final buffer = StringBuffer();
    if (command.description != null) {
      buffer
        ..writeln(command.description)
        ..writeln();
    }
    buffer.writeln('${style.heading('Usage:')} $synopsis');
    if (command.aliases.isNotEmpty) {
      buffer.writeln('${style.heading('Aliases:')} ${command.aliases.map(style.command).join(', ')}');
    }

    if (command.arguments.isNotEmpty) {
      final width = command.arguments.map((a) => a.name.length + 2).reduce((a, b) => a > b ? a : b);
      buffer
        ..writeln()
        ..writeln(style.heading('Arguments:'));
      for (final argument in command.arguments) {
        final details = [
          if (argument.description != null) argument.description!,
          if (argument.type != ValueType.string) '(${argument.type.name})',
          if (argument.pattern != null) '(must match ${argument.pattern})',
          if (argument.defaultValue != null) '(defaults to "${argument.defaultValue}")',
          if (!argument.required && argument.defaultValue == null) '(optional)',
          if (argument.allowed != null && argument.allowedHelp.isEmpty) '[${argument.allowed!.join(', ')}]',
        ].join(' ');
        buffer.writeln('  ${style.command('<${argument.name}>'.padRight(width))}  $details'.trimRight());
        if (argument.allowedHelp.isNotEmpty) {
          final valueWidth = argument.allowed!.map((v) => v.length).reduce((a, b) => a > b ? a : b);
          for (final value in argument.allowed!) {
            buffer.writeln(
                '${' ' * (width + 6)}${value.padRight(valueWidth)}  ${argument.allowedHelp[value] ?? ''}'.trimRight());
          }
        }
      }
    }

    buffer
      ..writeln()
      ..writeln(style.heading('Options:'))
      ..writeln(parser.usage.split('\n').map((line) => '  $line'.trimRight()).join('\n'));
    final column = [
      for (final line in parser.usage.split('\n'))
        if (RegExp(r'^\s*(?:-\w, )?\s*--\S+\s+(?=\S)').firstMatch('  $line') case final match?) match.end,
    ].fold(0, (a, b) => a > b ? a : b);
    for (final option in command.options.where((o) => o.names != null && !o.hidden)) {
      final notes = [
        if (option.required) 'required',
        if (option.multiple) 'repeatable',
        '<${option.name}> must match ${option.names}',
        if (option.pattern != null) 'value must match ${option.pattern}',
      ];
      final label = '      --<${option.name}>=<${option.type.placeholder}>';
      final help = '${option.description == null ? '' : '${option.description} '}(${notes.join(', ')})';
      buffer.writeln(label.length + 2 > column ? '$label\n${' ' * column}$help' : '${label.padRight(column)}$help');
    }

    if (requirements.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(style.heading('Requirements:'));
      for (final requirement in requirements) {
        buffer.writeln('  ${requirement.display}');
      }
    }

    if (command.examples.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(style.heading('Examples:'));
      for (final example in command.examples) {
        buffer.writeln('  $invocation ${example.arguments}');
        if (example.description != null) buffer.writeln(style.dim('      ${example.description}'));
      }
    }

    buffer
      ..writeln()
      ..write(style.dim(passthroughNote));
    return buffer.toString();
  }

  Map<String, Object?> toJson() => {
        'command': command.name,
        if (command.description != null) 'description': command.description,
        if (command.aliases.isNotEmpty) 'aliases': command.aliases,
        'usage': usage,
        'arguments': [for (final a in command.arguments) a.toJson()],
        'options': [for (final o in command.options) o.toJson()],
        'requirements': [for (final r in requirements) r.toJson()],
        if (command.examples.isNotEmpty) 'examples': [for (final e in command.examples) e.toJson()],
        if (command.optionsFirst) 'optionsFirst': true,
        if (command.helpAi != null) 'helpAi': command.helpAi,
      };

  TekException _usage(String message) => TekException(
        ErrorCodes.usage,
        '$message Run "$invocation --help" for usage.',
        exitCode: 64,
      );
}
