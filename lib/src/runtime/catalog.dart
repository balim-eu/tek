import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../manifest.dart';
import 'tool.dart';

/// The tools of every configured registry, the first registry's tool winning when two have the same name.
class ToolCatalog {
  ToolCatalog(this.tools, {this.problems = const []});

  /// Reads the tools of each registry in [registries], in their order, skipping the ones that don't parse.
  factory ToolCatalog.fromRegistries(List<(String, Map<String, Object?>)> registries) {
    final tools = <String, ToolDefinition>{};
    final problems = <String>[];
    for (final (registry, definitions) in registries) {
      for (final MapEntry(key: name, value: json) in definitions.entries) {
        if (tools.containsKey(name)) continue;
        try {
          tools[name] = ToolDefinition.fromJson(name, json);
        } on FormatException catch (e) {
          problems.add('The tool $name of registry "$registry" is invalid: ${e.message}.');
        }
      }
    }
    return ToolCatalog(tools, problems: problems);
  }

  final Map<String, ToolDefinition> tools;
  final List<String> problems;

  ToolDefinition? byName(String name) => tools[name];

  /// The registry tool that provides the program of [requirement]: the one it names with tool:, else the one of its
  /// name, else the first that lists the program under provides.
  ToolDefinition? providing(Requirement requirement) {
    if (requirement.toolName case final name?) return tools[name];
    final named = tools[requirement.tool];
    if (named != null && named.provides.contains(requirement.tool)) return named;
    for (final tool in tools.values) {
      if (tool.provides.contains(requirement.tool)) return tool;
    }
    return named;
  }

  /// The tool that installs [requirement] with the fields its entry overrides, or one made of the entry alone when it
  /// brings its own install matrix. Null when neither the registry nor the entry knows how to install it.
  ToolDefinition? effective(Requirement requirement) {
    final tool = providing(requirement);
    if (tool == null) {
      if (requirement.installSteps == null && requirement.bin == null && requirement.env == null) return null;
      return ToolDefinition(
        name: requirement.tool,
        provides: [requirement.tool],
        command: requirement.command,
        bin: requirement.bin ?? const {},
        env: requirement.env ?? const {},
        install: requirement.installSteps ?? const {},
      );
    }
    return tool.withOverrides(
      command: requirement.command,
      bin: requirement.bin,
      env: requirement.env,
      install: requirement.installSteps,
    );
  }
}

/// ~/.tek/tools.json: the tools of each registry as tek last read them, so commands check their tools without asking
/// the registries.
class ToolCache {
  ToolCache(this.path);

  final String path;

  Map<String, Map<String, Object?>> read() {
    final file = File(path);
    if (!file.existsSync()) return const {};
    try {
      final json = jsonDecode(file.readAsStringSync());
      final registries = (json as Map)['registries'];
      if (registries is! Map) return const {};
      return {
        for (final MapEntry(:key, :value) in registries.entries)
          if (value is Map && value['tools'] is Map) '$key': (value['tools'] as Map).cast<String, Object?>(),
      };
    } on FormatException {
      return const {};
    }
  }

  bool get exists => File(path).existsSync();

  void write(Map<String, Map<String, Object?>> registries) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final updatedAt = DateTime.now().toUtc().toIso8601String();
    file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
          'registries': {
            for (final MapEntry(:key, :value) in registries.entries) key: {'updatedAt': updatedAt, 'tools': value},
          },
        })}\n');
  }
}

String toolCachePath(String tekHome) => p.join(tekHome, 'tools.json');
