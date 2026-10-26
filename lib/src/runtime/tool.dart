import 'package:pub_semver/pub_semver.dart';

import 'system.dart';

final _toolName = RegExp(r'^[a-z][a-z0-9_-]*$');
final _matrixKey = RegExp(r'^([a-z][a-z0-9_.-]*?)(?:>=(\d+(?:\.\d+){0,2}))?(?:-(x64|arm64))?$');
final _environmentName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _variable = RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)');

/// A key of an install matrix, e.g. ubuntu>=24.04-arm64: a platform, from a version on, on one CPU.
class MatrixKey {
  const MatrixKey(this.base, {this.version, this.arch});

  static MatrixKey? tryParse(String key) {
    final match = _matrixKey.firstMatch(key);
    if (match == null) return null;
    return MatrixKey(match[1]!, version: match[2] == null ? null : parseLooseVersion(match[2]!), arch: match[3]);
  }

  final String base;
  final Version? version;
  final String? arch;
}

/// The value of [matrix] for [host]: its most specific key, a distro before its package manager before its system
/// before unix before any, a version key before a plain one (the highest version that the host has reached) and a key
/// for the host's CPU before one for every CPU. Null when no key matches.
MapEntry<String, T>? selectFromMatrix<T>(Map<String, T> matrix, HostSystem host) {
  MapEntry<String, T>? best;
  List<num>? bestRank;
  for (final entry in matrix.entries) {
    final key = MatrixKey.tryParse(entry.key);
    if (key == null) continue;
    final baseIndex = host.bases.indexOf(key.base);
    if (baseIndex == -1) continue;
    if (key.arch != null && key.arch != host.arch) continue;
    if (key.version != null) {
      final versioned = key.base == host.distro || key.base == 'macos';
      if (!versioned || host.version == null || host.version! < key.version!) continue;
    }
    final version = key.version;
    final rank = <num>[
      baseIndex,
      version == null ? 1 : 0,
      version == null ? 0 : -(version.major * 1e6 + version.minor * 1e3 + version.patch),
      key.arch == null ? 1 : 0,
    ];
    if (bestRank == null || _lower(rank, bestRank)) {
      best = entry;
      bestRank = rank;
    }
  }
  return best;
}

bool _lower(List<num> a, List<num> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return a[i] < b[i];
  }
  return false;
}

/// [text] with ~ at its start for the home folder and $VAR, ${VAR} and ${VAR:-default} from [environment].
String expandVariables(String text, Map<String, String> environment) {
  var value = text;
  final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '';
  if (value == '~' || value.startsWith('~/')) value = '$home${value.substring(1)}';
  return value.replaceAllMapped(_variable, (match) {
    final name = match[1] ?? match[3]!;
    final current = environment[name];
    if (current != null && current.isNotEmpty) return current;
    final fallback = match[2];
    return fallback == null ? '' : expandVariables(fallback, environment);
  });
}

/// A step of a tool's install: a command run as the user or as root, or what only a person can do.
class InstallStep {
  const InstallStep({this.command, this.root = false, this.manual});

  final String? command;
  final bool root;
  final String? manual;

  bool get isManual => manual != null;

  Map<String, Object?> toJson() => {
        if (command != null) 'command': command,
        if (root) 'root': true,
        if (manual != null) 'manual': manual,
      };

  @override
  String toString() => manual ?? (root ? 'root: $command' : command!);
}

/// A tool of the registry, tools/<name>.yaml: the programs it brings, how to check them, where they land and how it
/// installs on every platform.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.provides,
    this.description,
    this.command,
    this.requires = const [],
    this.os,
    this.bin = const {},
    this.env = const {},
    this.install = const {},
  });

  /// Reads [json], a tool as the registry lists it. Throws a [FormatException] naming what is wrong.
  factory ToolDefinition.fromJson(String name, Object? json) {
    if (!_toolName.hasMatch(name)) throw FormatException('the tool name "$name" is invalid');
    if (json is! Map) throw FormatException('tool $name must be a mapping');
    final map = json.cast<String, Object?>();
    const known = {'description', 'provides', 'command', 'requires', 'os', 'bin', 'env', 'install'};
    for (final key in map.keys) {
      if (!known.contains(key)) throw FormatException('tool $name has the unknown field "$key"');
    }
    return ToolDefinition(
      name: name,
      description: _optionalString(map['description'], '$name description'),
      provides: _strings(map['provides'], '$name provides') ?? [name],
      command: _optionalString(map['command'], '$name command'),
      requires: _strings(map['requires'], '$name requires') ?? const [],
      os: _strings(map['os'], '$name os'),
      bin: parseBin(map['bin'], '$name bin'),
      env: parseEnv(map['env'], '$name env'),
      install: parseInstall(map['install'], '$name install'),
    );
  }

  final String name;
  final String? description;
  final List<String> provides;
  final String? command;
  final List<String> requires;
  final List<String>? os;

  /// The folders its programs land in, by matrix key; the key "any" when it is the same everywhere.
  final Map<String, List<String>> bin;

  /// Variables its users need, by name and matrix key.
  final Map<String, Map<String, String>> env;

  /// The steps per matrix key.
  final Map<String, List<InstallStep>> install;

  bool appliesTo(HostSystem host) => os == null || os!.contains(host.os);

  /// The folders of [bin] for [host], expanded with [environment].
  List<String> binFor(HostSystem host, Map<String, String> environment) => [
        for (final folder in selectFromMatrix(bin, host)?.value ?? const <String>[])
          expandVariables(folder, environment),
      ];

  /// The variables of [env] for [host], expanded with [environment].
  Map<String, String> envFor(HostSystem host, Map<String, String> environment) => {
        for (final MapEntry(key: name, value: matrix) in env.entries)
          if (selectFromMatrix(matrix, host) case final selected?) name: expandVariables(selected.value, environment),
      };

  /// The steps for [host] and the key they come from, null when the matrix has none for it.
  MapEntry<String, List<InstallStep>>? stepsFor(HostSystem host) => selectFromMatrix(install, host);

  /// This tool with the fields an architecture's entry overrides.
  ToolDefinition withOverrides({
    String? command,
    Map<String, List<String>>? bin,
    Map<String, Map<String, String>>? env,
    Map<String, List<InstallStep>>? install,
  }) =>
      ToolDefinition(
        name: name,
        description: description,
        provides: provides,
        command: command ?? this.command,
        requires: requires,
        os: os,
        bin: bin ?? this.bin,
        env: env ?? this.env,
        install: install ?? this.install,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        if (description != null) 'description': description,
        'provides': provides,
        if (command != null) 'command': command,
        if (requires.isNotEmpty) 'requires': requires,
        if (os != null) 'os': os,
      };

  static Map<String, List<String>> parseBin(Object? node, String field) {
    if (node == null) return const {};
    if (node is String || node is List) return {'any': _strings(node, field)!};
    if (node is! Map) throw FormatException('$field must be a folder, a list of folders or a matrix');
    return {
      for (final MapEntry(:key, :value) in node.entries) _key('$key', field): _strings(value, '$field.$key')!,
    };
  }

  static Map<String, Map<String, String>> parseEnv(Object? node, String field) {
    if (node == null) return const {};
    if (node is! Map) throw FormatException('$field must be a mapping of variables');
    return {
      for (final MapEntry(:key, :value) in node.entries)
        _variableName('$key', field): switch (value) {
          final String text => {'any': text},
          final Map matrix => {
              for (final MapEntry(key: platform, value: text) in matrix.entries)
                _key('$platform', '$field.$key'):
                    text is String ? text : throw FormatException('$field.$key.$platform must be a string'),
            },
          _ => throw FormatException('$field.$key must be a string or a matrix of strings'),
        },
    };
  }

  static Map<String, List<InstallStep>> parseInstall(Object? node, String field) {
    if (node == null) return const {};
    if (node is! Map) throw FormatException('$field must be a matrix of steps');
    return {
      for (final MapEntry(:key, :value) in node.entries) _key('$key', field): _steps(value, '$field.$key'),
    };
  }

  static List<InstallStep> _steps(Object? node, String field) {
    final items = node is List ? node : [node];
    if (items.isEmpty) throw FormatException('$field must list at least one step');
    return [
      for (final (index, item) in items.indexed)
        switch (item) {
          final String command when command.trim().isNotEmpty => InstallStep(command: command),
          final Map step when step.length == 1 && step['root'] is String =>
            InstallStep(command: step['root'], root: true),
          final Map step when step.length == 1 && step['manual'] is String => InstallStep(manual: step['manual']),
          _ => throw FormatException('$field[$index] must be a command, root: <command> or manual: <text>'),
        },
    ];
  }

  static String _key(String key, String field) {
    if (MatrixKey.tryParse(key) == null) {
      throw FormatException('$field has the invalid key "$key", e.g. macos, apt, ubuntu>=24.04 or linux-arm64');
    }
    return key;
  }

  static String _variableName(String name, String field) {
    if (!_environmentName.hasMatch(name)) throw FormatException('$field names the invalid variable "$name"');
    return name;
  }

  static String? _optionalString(Object? value, String field) {
    if (value == null) return null;
    if (value is String && value.trim().isNotEmpty) return value;
    throw FormatException('$field must be a string');
  }

  static List<String>? _strings(Object? value, String field) => switch (value) {
        null => null,
        final String text => [text],
        final List list when list.every((item) => item is String) => [for (final item in list) item as String],
        _ => throw FormatException('$field must be a string or a list of strings'),
      };
}
