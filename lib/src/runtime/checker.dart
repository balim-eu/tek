import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../manifest.dart';
import 'catalog.dart';
import 'system.dart';
import 'tool.dart';

final _versionPattern = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?');

enum ToolState { ok, skipped, missing, failed, outdated, unreadable }

/// What a check found for one entry of a runtime.
class ToolStatus {
  const ToolStatus(
    this.requirement,
    this.state, {
    this.tool,
    this.path,
    this.version,
    this.onPath = true,
    this.detail,
  });

  final Requirement requirement;
  final ToolState state;

  /// The registry tool that provides it, with the entry's overrides.
  final ToolDefinition? tool;

  /// Where the program was found.
  final String? path;
  final String? version;

  /// Whether the program is on PATH, or only in a folder of its tool's bin.
  final bool onPath;
  final String? detail;

  bool get ok => state == ToolState.ok || state == ToolState.skipped;

  bool get skipped => state == ToolState.skipped;

  /// The folder the program was found in when it isn't on PATH, which tek makes visible to shells.
  String? get hiddenFolder => !onPath && path != null ? p.dirname(path!) : null;

  /// What is wrong, e.g. "cargo >=1.94.0, found 1.85.0 in /usr/bin".
  String? get problem => switch (state) {
        ToolState.ok || ToolState.skipped => null,
        ToolState.missing => '${requirement.display}, but ${requirement.tool} is not installed',
        ToolState.failed => '${requirement.display}, but ${detail ?? 'its check failed'}',
        ToolState.outdated => '${requirement.display}, found $version${path == null ? '' : ' in ${p.dirname(path!)}'}',
        ToolState.unreadable =>
          '${requirement.display}, but its version could not be read${detail == null ? '' : ' from $detail'}',
      };

  Map<String, Object?> toJson() => {
        ...requirement.toJson(),
        'status': switch (state) {
          ToolState.ok => 'ok',
          ToolState.skipped => 'skipped',
          ToolState.missing => 'missing',
          ToolState.failed => 'failed',
          ToolState.outdated => 'outdated',
          ToolState.unreadable => 'unreadable',
        },
        if (version != null) 'found': version,
        if (path != null) 'path': path,
        if (!onPath && path != null) 'onPath': false,
        if (problem != null) 'problem': problem,
        if (tool != null) 'registryTool': tool!.name,
      };
}

/// Checks the tools of runtimes: finds each program on PATH or in its tool's bin, runs its check, reads its version.
class ToolChecker {
  ToolChecker({
    required this.catalog,
    required this.host,
    Map<String, String>? environment,
    this.recordedFolders = const [],
  }) : baseEnvironment = environment ?? Platform.environment;

  final ToolCatalog catalog;
  final HostSystem host;
  final Map<String, String> baseEnvironment;

  /// The folders tek made visible to shells, from ~/.tek/path.json.
  final List<String> recordedFolders;

  final _results = <String, Future<ToolStatus>>{};

  Future<ToolStatus> inspect(Requirement requirement) {
    final key = [
      requirement.tool,
      requirement.version,
      requirement.command,
      requirement.toolName,
      requirement.os?.join(','),
    ].join('\u0000');
    return _results[key] ??= _inspect(requirement);
  }

  /// Forgets what was found, after an install changed the machine.
  void reset() => _results.clear();

  /// The environment a tool's check and steps run with: the current one, with every folder of [tools]' bin and of
  /// [recordedFolders] after PATH and their variables where they aren't set.
  Map<String, String> environmentFor(Iterable<ToolDefinition> tools) {
    final environment = {...baseEnvironment};
    final variables = <String, String>{};
    for (final tool in tools) {
      for (final MapEntry(:key, :value) in tool.envFor(host, environment).entries) {
        if ((environment[key] ?? '').isEmpty) variables.putIfAbsent(key, () => value);
      }
    }
    environment.addAll(variables);
    final folders = [
      for (final tool in tools) ...tool.binFor(host, environment),
      ...recordedFolders,
    ];
    environment['PATH'] = appendToPath(environment['PATH'] ?? '', folders);
    return environment;
  }

  Future<ToolStatus> _inspect(Requirement requirement) async {
    final tool = catalog.effective(requirement);
    final os = requirement.os ?? tool?.os;
    if (os != null && !os.contains(host.os)) return ToolStatus(requirement, ToolState.skipped, tool: tool);

    final tools = [
      if (tool != null) tool,
      for (final name in tool?.requires ?? const <String>[])
        if (catalog.byName(name) case final required?) required,
    ];
    final environment = environmentFor(tools);
    final onPath = findOnPath(requirement.tool, baseEnvironment['PATH'] ?? '');
    final inBin = onPath ?? findOnPath(requirement.tool, environment['PATH'] ?? '');
    final found = onPath ?? inBin;
    final command = requirement.command ?? tool?.command;

    if (command == null && !requirement.checksVersion) {
      return found == null
          ? ToolStatus(requirement, ToolState.missing, tool: tool)
          : ToolStatus(requirement, ToolState.ok, tool: tool, path: found, onPath: onPath != null);
    }
    if (command == null && found == null) return ToolStatus(requirement, ToolState.missing, tool: tool);
    // The registry's checks are POSIX shell; on Windows, where tek installs no tools, one that needs sh is left out.
    if (Platform.isWindows && command != null && command.contains(r'$')) {
      return ToolStatus(requirement, ToolState.skipped, tool: tool, detail: 'checked on macOS and Linux');
    }

    final ProcessResult result;
    final shown = command ?? '${requirement.tool} --version';
    try {
      result = await (command == null
              ? Process.run(found!, ['--version'], environment: environment, includeParentEnvironment: false)
              : runShell(command, environment))
          .timeout(const Duration(seconds: 60));
    } on ProcessException {
      return ToolStatus(requirement, ToolState.missing, tool: tool);
    } on TimeoutException {
      return ToolStatus(requirement, ToolState.failed, tool: tool, path: found, detail: '"$shown" did not finish');
    }
    if (result.exitCode != 0) {
      // A shell that finds no such program exits with 127, a program it can't run with 126.
      final missing = found == null || result.exitCode == 127;
      return ToolStatus(
        requirement,
        missing ? ToolState.missing : ToolState.failed,
        tool: tool,
        path: found,
        onPath: onPath != null,
        detail: '"$shown" failed with exit code ${result.exitCode}',
      );
    }
    final match = _versionPattern.firstMatch('${result.stdout}\n${result.stderr}');
    final version =
        match == null ? null : Version(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3] ?? '0'));
    final location = found ?? (command == null ? null : _programIn(command, environment));
    final where = location == null ? null : p.normalize(location);
    final visible =
        onPath != null || (location != null && findOnPath(p.basename(location), baseEnvironment['PATH'] ?? '') != null);
    if (!requirement.checksVersion) {
      return ToolStatus(requirement, ToolState.ok,
          tool: tool, path: where, version: version?.toString(), onPath: found == null ? true : visible);
    }
    if (version == null) {
      return ToolStatus(requirement, ToolState.unreadable, tool: tool, path: where, detail: '"$shown"');
    }
    final constraint = VersionConstraint.parse(requirement.version!);
    return ToolStatus(
      requirement,
      constraint.allows(version) ? ToolState.ok : ToolState.outdated,
      tool: tool,
      path: where,
      version: '$version',
      onPath: found == null ? true : visible,
    );
  }

  /// The program a check command runs first, when it names one by path or that PATH has, e.g. sdkmanager for
  /// "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --version.
  String? _programIn(String command, Map<String, String> environment) {
    final first = RegExp(r'''^\s*(?:"([^"]+)"|'([^']+)'|(\S+))''').firstMatch(command);
    if (first == null) return null;
    final word = expandVariables(first[1] ?? first[2] ?? first[3]!, environment);
    if (word.contains('/')) return File(word).existsSync() ? word : null;
    return findOnPath(word, environment['PATH'] ?? '');
  }
}

/// Runs [command] in sh, or cmd on Windows, with exactly [environment].
Future<ProcessResult> runShell(String command, Map<String, String> environment, {String? workingDirectory}) =>
    Platform.isWindows
        ? Process.run('cmd', ['/c', command], environment: environment, workingDirectory: workingDirectory)
        : Process.run('/bin/sh', ['-c', command],
            environment: environment, includeParentEnvironment: false, workingDirectory: workingDirectory);

/// The path of [program] in the first folder of [path] that has it, on Windows also with .exe, .bat and .cmd.
String? findOnPath(String program, String path) {
  final extensions = Platform.isWindows ? ['.exe', '.bat', '.cmd', ''] : [''];
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    for (final extension in extensions) {
      final file = File(p.join(directory, '$program$extension'));
      if (file.existsSync() && (Platform.isWindows || _executable(file))) return file.path;
    }
  }
  return null;
}

bool _executable(File file) {
  final stat = file.statSync();
  return stat.type != FileSystemEntityType.directory && stat.mode & 0x49 != 0;
}

/// [path] with every folder of [folders] that it doesn't list yet after it.
String appendToPath(String path, Iterable<String> folders) {
  final separator = Platform.isWindows ? ';' : ':';
  final entries = [
    for (final entry in path.split(separator))
      if (entry.isNotEmpty) entry
  ];
  for (final folder in folders) {
    if (folder.isNotEmpty && !entries.contains(folder)) entries.add(folder);
  }
  return entries.join(separator);
}

/// What a command of an architecture runs with on top of the current environment: the folders of its tools' bin and
/// the ones tek recorded after PATH, and its tools' variables where they aren't set.
Map<String, String> runtimeEnvironment(ToolChecker checker, Iterable<Requirement> requirements) {
  final tools = [
    for (final requirement in requirements)
      if (checker.catalog.effective(requirement) case final tool?) tool,
  ];
  final environment = checker.environmentFor(tools);
  return {
    for (final MapEntry(:key, :value) in environment.entries)
      if (checker.baseEnvironment[key] != value) key: value,
  };
}
