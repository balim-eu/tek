import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'architecture_ref.dart';
import 'errors.dart';

const supportedManifestSchemaVersion = 2;

final _commandName = RegExp(r'^[a-z][a-z0-9-]*$');
final _parameterName = RegExp(r'^[a-z][a-z0-9-]*$');
final _environmentName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
const _reservedOptions = {'help', 'help-ai', 'json'};
const _reservedCommands = {'doctor', 'prompt', 'version'};
const operatingSystems = {'linux', 'macos', 'windows'};

enum ValueType {
  string('value'),
  int('int'),
  number('number'),
  file('file'),
  directory('dir'),
  url('url');

  const ValueType(this.placeholder);

  final String placeholder;

  static ValueType? tryParse(String value) {
    for (final type in values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

class ManifestPublisher {
  const ManifestPublisher({required this.id, this.name});

  final String id;
  final String? name;

  String get displayName => name == null || name == id ? id : '$name ($id)';

  Map<String, Object?> toJson() => {'id': id, if (name != null) 'name': name};
}

class Requirement {
  const Requirement({required this.tool, this.version, this.command, this.install, this.description, this.os});

  final String tool;
  final String? version;
  final String? command;
  final String? install;
  final String? description;
  final List<String>? os;

  bool get appliesHere => os == null || os!.contains(Platform.operatingSystem);

  bool get checksVersion => version != null && version != 'any' && version != '*';

  String get display => checksVersion ? '$tool $version' : tool;

  Map<String, Object?> toJson() => {
        'tool': tool,
        if (version != null) 'version': version,
        if (command != null) 'command': command,
        if (install != null) 'install': install,
        if (description != null) 'description': description,
        if (os != null) 'os': os,
      };
}

class CommandArgument {
  const CommandArgument({
    required this.name,
    this.description,
    this.required = true,
    this.defaultValue,
    this.multiple = false,
    this.type = ValueType.string,
    this.allowed,
    this.allowedHelp = const {},
    this.pattern,
  });

  final String name;
  final String? description;
  final bool required;
  final String? defaultValue;
  final bool multiple;
  final ValueType type;
  final List<String>? allowed;
  final Map<String, String> allowedHelp;
  final String? pattern;

  String get usage {
    final label = multiple ? '<$name>...' : '<$name>';
    return required ? label : '[$label]';
  }

  Map<String, Object?> toJson() => {
        'name': name,
        if (description != null) 'description': description,
        'type': type.name,
        'required': required,
        if (defaultValue != null) 'default': defaultValue,
        if (multiple) 'multiple': true,
        if (allowed != null) 'allowed': allowed,
        if (pattern != null) 'pattern': pattern,
      };
}

class CommandOption {
  const CommandOption({
    required this.name,
    this.description,
    this.flag = false,
    this.type = ValueType.string,
    this.multiple = false,
    this.defaultValue,
    this.allowed,
    this.allowedHelp = const {},
    this.required = false,
    this.abbr,
    this.env,
    this.hidden = false,
    this.deprecated,
    this.splitCommas = true,
    this.pattern,
    this.names,
  });

  final String name;
  final String? description;
  final bool flag;
  final ValueType type;
  final bool multiple;
  final Object? defaultValue;
  final List<String>? allowed;
  final Map<String, String> allowedHelp;
  final bool required;
  final String? abbr;
  final String? env;
  final bool hidden;
  final String? deprecated;
  final bool splitCommas;
  final String? pattern;
  final String? names;

  bool matchesName(String value) => names != null && RegExp('^(?:$names)\$').hasMatch(value);

  Map<String, Object?> toJson() => {
        'name': name,
        if (description != null) 'description': description,
        if (names != null) 'names': names,
        'type': flag ? 'flag' : type.name,
        if (multiple) 'multiple': true,
        if (defaultValue != null) 'default': defaultValue,
        if (allowed != null) 'allowed': allowed,
        if (required) 'required': true,
        if (abbr != null) 'abbr': abbr,
        if (env != null) 'env': env,
        if (hidden) 'hidden': true,
        if (deprecated != null) 'deprecated': deprecated,
        if (pattern != null) 'pattern': pattern,
      };
}

class CommandExample {
  const CommandExample(this.arguments, [this.description]);

  final String arguments;
  final String? description;

  Map<String, Object?> toJson() => {'arguments': arguments, if (description != null) 'description': description};
}

class ManifestCommand {
  const ManifestCommand({
    required this.name,
    this.description,
    this.aliases = const [],
    this.arguments = const [],
    this.options = const [],
    this.requires = const [],
    this.examples = const [],
    this.optionsFirst = false,
    this.os,
    this.helpAi,
  });

  final String name;
  final String? description;
  final List<String> aliases;
  final List<CommandArgument> arguments;
  final List<CommandOption> options;
  final List<Requirement> requires;
  final List<CommandExample> examples;
  final bool optionsFirst;
  final List<String>? os;
  final String? helpAi;

  bool get declaresParameters => arguments.isNotEmpty || options.isNotEmpty;

  Map<String, Object?> toJson() => {
        'name': name,
        if (description != null) 'description': description,
        if (aliases.isNotEmpty) 'aliases': aliases,
        if (arguments.isNotEmpty) 'arguments': [for (final a in arguments) a.toJson()],
        if (options.isNotEmpty) 'options': [for (final o in options) o.toJson()],
        if (requires.isNotEmpty) 'requires': [for (final r in requires) r.toJson()],
        if (examples.isNotEmpty) 'examples': [for (final e in examples) e.toJson()],
        if (optionsFirst) 'optionsFirst': true,
        if (os != null) 'os': os,
        if (helpAi != null) 'helpAi': helpAi,
      };
}

class Manifest {
  const Manifest({
    required this.schemaVersion,
    required this.id,
    required this.name,
    required this.version,
    required this.publisher,
    required this.commands,
    required this.requirements,
    this.optionalRequirements = const [],
    this.description,
    this.license,
    this.os,
    this.systemPrompt,
    this.source,
  });

  factory Manifest.parse(String source, {String? location}) {
    final where = location == null ? '' : ' ($location)';
    Object? document;
    try {
      document = loadYaml(source);
    } on YamlException catch (e) {
      throw _invalid('Manifest is not valid YAML$where: ${e.message}');
    }
    if (document is! YamlMap) throw _invalid('Manifest must be a YAML mapping$where.');

    final schemaVersion = document['schemaVersion'];
    if (schemaVersion is! int || schemaVersion < 1) {
      throw _invalid('Manifest schemaVersion must be a positive integer$where.');
    }
    if (schemaVersion < supportedManifestSchemaVersion) {
      throw _invalid('Manifest schemaVersion $schemaVersion is no longer supported, architectures use schemaVersion '
          '$supportedManifestSchemaVersion$where.');
    }
    if (schemaVersion > supportedManifestSchemaVersion) {
      throw TekException(
        ErrorCodes.unsupportedSchemaVersion,
        'Manifest schemaVersion $schemaVersion is not supported by this version of tek$where. '
        'Update tek with "tek update".',
      );
    }

    final id = _string(document, 'id', where);
    if (!isValidArchitectureId(id)) throw _invalid('Manifest id "$id" is invalid$where.');

    final versionText = _string(document, 'version', where);
    final Version version;
    try {
      version = parseSemver(versionText);
    } on FormatException {
      throw _invalid('Manifest version "$versionText" is not a valid semantic version$where.');
    }

    final publisherNode = document['publisher'];
    if (publisherNode is! YamlMap) throw _invalid('Manifest publisher must be a mapping$where.');
    final publisher = ManifestPublisher(
      id: _string(publisherNode, 'publisher.id', where, key: 'id'),
      name: _optionalString(publisherNode, 'name', where),
    );
    if (publisher.id != id.split('/').first) {
      throw _invalid('Manifest publisher.id "${publisher.id}" does not match id "$id"$where.');
    }

    final shared = _parseOptions(document['options'], 'options', where);

    final commandsNode = document['commands'];
    if (commandsNode is! YamlMap || commandsNode.isEmpty) {
      throw _invalid('Manifest must declare at least one command$where.');
    }
    final commands = <String, ManifestCommand>{};
    final names = <String>{};
    for (final entry in commandsNode.entries) {
      final name = entry.key;
      if (name is! String || !_commandName.hasMatch(name)) {
        throw _invalid('Manifest command name "$name" is invalid$where.');
      }
      final value = entry.value;
      if (value != null && value is! YamlMap) {
        throw _invalid('Manifest command "$name" must be a mapping$where.');
      }
      final command = _parseCommand(name, value as YamlMap?, shared, where);
      for (final alias in [name, ...command.aliases]) {
        if (_reservedCommands.contains(alias)) {
          throw _invalid('Manifest command name or alias "$alias" is reserved by tek$where.');
        }
        if (!names.add(alias)) throw _invalid('Manifest command name or alias "$alias" is used more than once$where.');
      }
      commands[name] = command;
    }

    final requirements = <Requirement>[];
    final optionalRequirements = <Requirement>[];
    final runtime = document['runtime'];
    if (runtime != null) {
      if (runtime is! YamlMap) throw _invalid('Manifest runtime must be a mapping$where.');
      requirements.addAll(_parseRequirements(runtime['required'], 'runtime.required', where));
      optionalRequirements.addAll(_parseRequirements(runtime['optional'], 'runtime.optional', where));
    }

    return Manifest(
      schemaVersion: schemaVersion,
      id: id,
      name: _optionalString(document, 'name', where) ?? id,
      version: version,
      publisher: publisher,
      description: _optionalString(document, 'description', where)?.trim(),
      license: _optionalString(document, 'license', where),
      commands: commands,
      requirements: requirements,
      optionalRequirements: optionalRequirements,
      os: _parseOs(document['os'], 'os', where),
      systemPrompt: _optionalString(document, 'systemPrompt', where)?.trim(),
      source: source,
    );
  }

  final int schemaVersion;
  final String? systemPrompt;
  final String? source;
  final String id;
  final String name;
  final Version version;
  final ManifestPublisher publisher;
  final String? description;
  final String? license;
  final Map<String, ManifestCommand> commands;
  final List<Requirement> requirements;
  final List<Requirement> optionalRequirements;
  final List<String>? os;

  ManifestCommand? command(String nameOrAlias) {
    final direct = commands[nameOrAlias];
    if (direct != null) return direct;
    for (final command in commands.values) {
      if (command.aliases.contains(nameOrAlias)) return command;
    }
    return null;
  }

  List<String>? osFor(ManifestCommand command) => command.os ?? os;

  List<Requirement> requirementsFor(ManifestCommand command) {
    final merged = {for (final r in requirements) r.tool: r};
    for (final r in command.requires) {
      merged[r.tool] = r;
    }
    return merged.values.toList();
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'name': name,
        'version': '$version',
        'publisher': publisher.toJson(),
        if (description != null) 'description': description,
        if (license != null) 'license': license,
        if (os != null) 'os': os,
        'commands': [for (final command in commands.values) command.toJson()],
        'runtime': {
          'required': {for (final r in requirements) r.tool: r.version ?? 'any'},
          if (optionalRequirements.isNotEmpty)
            'optional': {for (final r in optionalRequirements) r.tool: r.version ?? 'any'},
        },
      };

  static ManifestCommand _parseCommand(String name, YamlMap? node, List<CommandOption> shared, String where) {
    final context = 'command "$name"';
    node ??= YamlMap();

    final aliases = <String>[];
    final aliasesNode = node['aliases'];
    if (aliasesNode != null) {
      if (aliasesNode is! YamlList) throw _invalid('Manifest $context aliases must be a list$where.');
      for (final alias in aliasesNode) {
        if (alias is! String || !_commandName.hasMatch(alias)) {
          throw _invalid('Manifest $context alias "$alias" is invalid$where.');
        }
        aliases.add(alias);
      }
    }

    final arguments = <CommandArgument>[];
    final argumentsNode = node['arguments'];
    if (argumentsNode != null) {
      if (argumentsNode is! YamlList) throw _invalid('Manifest $context arguments must be a list$where.');
      for (final item in argumentsNode) {
        if (item is! YamlMap) throw _invalid('Manifest $context arguments must be mappings$where.');
        final argName = _parameter(item['name'], '$context argument', where);
        final field = '$context argument "$argName"';
        final defaultValue = _optionalString(item, 'default', where);
        final (allowed, allowedHelp) = _parseAllowed(item['allowed'], field, where);
        final type = _parseType(item['type'], field, where, allowFlag: false);
        arguments.add(CommandArgument(
          name: argName,
          description: _optionalString(item, 'description', where)?.trim(),
          required: _bool(item['required'], defaultValue == null, '$field required', where),
          defaultValue: defaultValue,
          multiple: _bool(item['multiple'], false, '$field multiple', where),
          type: type ?? ValueType.string,
          allowed: allowed,
          allowedHelp: allowedHelp,
          pattern: _parsePattern(item['pattern'], field, where),
        ));
      }
    }
    for (final (index, argument) in arguments.indexed) {
      if (argument.multiple && index != arguments.length - 1) {
        throw _invalid('Manifest $context: only the last argument may be multiple$where.');
      }
      if (argument.required && index > 0 && !arguments[index - 1].required) {
        throw _invalid('Manifest $context: required argument "${argument.name}" follows an optional one$where.');
      }
    }

    final own = _parseOptions(node['options'], '$context options', where);
    for (final option in own) {
      if (shared.any((s) => s.name == option.name)) {
        throw _invalid('Manifest $context option "${option.name}" is already declared in the shared options$where.');
      }
    }
    final options = [...shared, ...own];
    final names = <String>{};
    for (final parameter in [...arguments.map((a) => a.name), ...options.map((o) => o.name)]) {
      if (!names.add(parameter)) throw _invalid('Manifest $context declares "$parameter" more than once$where.');
    }
    final abbreviations = <String>{};
    for (final option in options) {
      if (option.abbr != null && !abbreviations.add(option.abbr!)) {
        throw _invalid('Manifest $context uses the abbreviation "-${option.abbr}" more than once$where.');
      }
    }

    final examples = <CommandExample>[];
    final examplesNode = node['examples'];
    if (examplesNode != null) {
      if (examplesNode is! YamlList) throw _invalid('Manifest $context examples must be a list$where.');
      for (final example in examplesNode) {
        examples.add(switch (example) {
          final String value => CommandExample(value),
          final YamlMap value => CommandExample(
              _string(value, '$context example arguments', where, key: 'arguments'),
              _optionalString(value, 'description', where)?.trim(),
            ),
          _ => throw _invalid('Manifest $context examples must be strings or mappings$where.'),
        });
      }
    }

    final helpAi = _optionalString(node, 'helpAi', where);
    if (helpAi != null && (!_isSafeRelativePath(helpAi) || !helpAi.endsWith('.md'))) {
      throw _invalid('Manifest $context helpAi must be a relative path to a .md file in the package$where.');
    }

    return ManifestCommand(
      name: name,
      description: _optionalString(node, 'description', where)?.trim(),
      aliases: aliases,
      arguments: arguments,
      options: options,
      requires: _parseRequirements(node['requires'], '$context requires', where),
      examples: examples,
      optionsFirst: _bool(node['optionsFirst'], false, '$context optionsFirst', where),
      os: _parseOs(node['os'], '$context os', where),
      helpAi: helpAi,
    );
  }

  static List<CommandOption> _parseOptions(Object? node, String context, String where) {
    if (node == null) return [];
    if (node is! YamlMap) throw _invalid('Manifest $context must be a mapping$where.');
    final options = <CommandOption>[];
    for (final entry in node.entries) {
      final optionName = _parameter(entry.key, '$context option', where);
      final field = '$context option "$optionName"';
      if (_reservedOptions.contains(optionName)) throw _invalid('Manifest $field is reserved by tek$where.');
      final item = entry.value ?? YamlMap();
      if (item is! YamlMap) throw _invalid('Manifest $field must be a mapping$where.');
      final rawType = item['type'];
      final flag = rawType == 'flag';
      final type = flag ? ValueType.string : _parseType(rawType, field, where, allowFlag: true) ?? ValueType.string;
      final multiple = _bool(item['multiple'], false, '$field multiple', where);
      final (allowed, allowedHelp) = _parseAllowed(item['allowed'], field, where);
      final abbr = _optionalString(item, 'abbr', where);
      if (abbr != null && (abbr.length != 1 || abbr == 'h' || !RegExp(r'^[A-Za-z]$').hasMatch(abbr))) {
        throw _invalid('Manifest $field abbr must be a single letter other than h$where.');
      }
      final env = _optionalString(item, 'env', where);
      if (env != null && !_environmentName.hasMatch(env)) {
        throw _invalid('Manifest $field env "$env" is not a valid environment variable name$where.');
      }
      final pattern = _parsePattern(item['pattern'], field, where);
      if (flag && (multiple || allowed != null || pattern != null)) {
        throw _invalid('Manifest $field: flags cannot be multiple or have allowed values or a pattern$where.');
      }
      final names = _parsePattern(item['names'], '$field names', where);
      if (names != null && (flag || abbr != null || env != null || item['default'] != null)) {
        throw _invalid('Manifest $field: options with names cannot be flags or have an abbr, env or default$where.');
      }
      final rawDefault = item['default'];
      final Object? defaultValue = switch (rawDefault) {
        null => null,
        final YamlList list when multiple => [for (final v in list) '$v'],
        final bool value when flag => value,
        final Object value when !flag && !multiple && value is! YamlList && value is! YamlMap => '$value',
        final Object value when multiple && value is! YamlMap => ['$value'],
        _ => throw _invalid('Manifest $field has an invalid default$where.'),
      };
      options.add(CommandOption(
        name: optionName,
        description: _optionalString(item, 'description', where)?.trim(),
        flag: flag,
        type: type,
        multiple: multiple,
        defaultValue: defaultValue,
        allowed: allowed,
        allowedHelp: allowedHelp,
        required: _bool(item['required'], false, '$field required', where),
        abbr: abbr,
        env: env,
        hidden: _bool(item['hidden'], false, '$field hidden', where),
        deprecated: switch (item['deprecated']) {
          null || false => null,
          true => 'This option is deprecated.',
          final Object message => '$message',
        },
        splitCommas: _bool(item['splitCommas'], true, '$field splitCommas', where),
        pattern: pattern,
        names: names,
      ));
    }
    return options;
  }

  static ValueType? _parseType(Object? value, String field, String where, {required bool allowFlag}) {
    if (value == null) return null;
    final type = value is String ? ValueType.tryParse(value) : null;
    if (type != null) return type;
    final allowedTypes = [if (allowFlag) 'flag', ...ValueType.values.map((t) => t.name)];
    throw _invalid('Manifest $field type must be one of ${allowedTypes.join(', ')}$where.');
  }

  static (List<String>?, Map<String, String>) _parseAllowed(Object? node, String field, String where) {
    return switch (node) {
      null => (null, const <String, String>{}),
      final YamlList list => ([for (final v in list) '$v'], const <String, String>{}),
      final YamlMap map => (
          [for (final key in map.keys) '$key'],
          {
            for (final entry in map.entries)
              if (entry.value != null) '${entry.key}': '${entry.value}',
          },
        ),
      _ => throw _invalid('Manifest $field allowed must be a list or a mapping$where.'),
    };
  }

  static String? _parsePattern(Object? node, String field, String where) {
    if (node == null) return null;
    if (node is! String) throw _invalid('Manifest $field pattern must be a string$where.');
    try {
      RegExp(node);
    } on FormatException catch (e) {
      throw _invalid('Manifest $field pattern is not a valid regular expression: ${e.message}$where.');
    }
    return node;
  }

  static List<String>? _parseOs(Object? node, String field, String where) {
    if (node == null) return null;
    if (node is! YamlList || node.isEmpty) throw _invalid('Manifest $field must be a non-empty list$where.');
    final values = [for (final v in node) '$v'];
    for (final value in values) {
      if (!operatingSystems.contains(value)) {
        throw _invalid('Manifest $field value "$value" must be one of ${operatingSystems.join(', ')}$where.');
      }
    }
    return values;
  }

  static List<Requirement> _parseRequirements(Object? node, String context, String where) {
    if (node == null) return const [];
    if (node is! YamlMap) throw _invalid('Manifest $context must be a mapping$where.');
    return [
      for (final entry in node.entries)
        switch (entry.value) {
          null => Requirement(tool: '${entry.key}'),
          final YamlMap value => Requirement(
              tool: '${entry.key}',
              version: _optionalString(value, 'version', where),
              command: _optionalString(value, 'command', where),
              install: _optionalString(value, 'install', where),
              description: _optionalString(value, 'description', where)?.trim(),
              os: _parseOs(value['os'], '$context ${entry.key} os', where),
            ),
          final Object value => Requirement(tool: '${entry.key}', version: '$value'),
        },
    ];
  }

  static TekException _invalid(String message) => TekException(ErrorCodes.invalidManifest, message);

  static String _parameter(Object? value, String context, String where) {
    if (value is String && _parameterName.hasMatch(value)) return value;
    throw _invalid('Manifest $context name "$value" is invalid$where.');
  }

  static bool _bool(Object? value, bool fallback, String field, String where) {
    if (value == null) return fallback;
    if (value is bool) return value;
    throw _invalid('Manifest $field must be true or false$where.');
  }

  static String _string(YamlMap map, String field, String where, {String? key}) {
    final value = map[key ?? field];
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is num) return '$value';
    throw _invalid('Manifest field "$field" is required$where.');
  }

  static String? _optionalString(YamlMap map, String key, String where) {
    final value = map[key];
    if (value == null) return null;
    if (value is String || value is num || value is bool) return '$value';
    throw _invalid('Manifest field "$key" must be a string$where.');
  }

  static bool _isSafeRelativePath(String path) {
    if (path.isEmpty || p.posix.isAbsolute(path) || p.windows.isAbsolute(path)) return false;
    return !p.posix.split(path.replaceAll(r'\', '/')).contains('..');
  }
}

List<String> splitCommandLine(String input) {
  final tokens = <String>[];
  final current = StringBuffer();
  var hasToken = false;
  String? quote;
  for (final char in input.split('')) {
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        current.write(char);
      }
    } else if (char == '"' || char == "'") {
      quote = char;
      hasToken = true;
    } else if (char.trim().isEmpty) {
      if (hasToken) tokens.add(current.toString());
      current.clear();
      hasToken = false;
    } else {
      current.write(char);
      hasToken = true;
    }
  }
  if (quote != null) throw const FormatException('Unterminated quote.');
  if (hasToken) tokens.add(current.toString());
  return tokens;
}

String parameterEnvironmentName(String name) => 'TEK_PARAM_${name.toUpperCase().replaceAll('-', '_')}';
