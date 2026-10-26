import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../manifest.dart';
import 'catalog.dart';
import 'checker.dart';
import 'shell.dart';
import 'system.dart';
import 'tool.dart';

const _homebrewInstaller =
    'NONINTERACTIVE=1 /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"';

/// A tool the plan installs, and the entries of the runtime it is for.
class PlannedTool {
  PlannedTool(this.tool, this.key, this.steps, this.entries, {this.dependency = false});

  final ToolDefinition tool;

  /// The key of the install matrix the steps come from, e.g. apt or macos.
  final String key;
  final List<InstallStep> steps;
  final List<ToolStatus> entries;

  /// Whether only another tool of the plan needs it.
  final bool dependency;

  Map<String, Object?> toJson() => {
        'tool': tool.name,
        'for': [for (final entry in entries) entry.requirement.tool],
        'key': key,
        'steps': [for (final step in steps) step.toJson()],
        if (dependency) 'dependency': true,
      };
}

/// An entry tek can't install on this machine, and why.
class UnavailableTool {
  const UnavailableTool(this.status, this.reason);

  final ToolStatus status;
  final String reason;

  Map<String, Object?> toJson() => {...status.toJson(), 'reason': reason};
}

/// What install-tools does on this machine: the preparation, the tools in order, and what it leaves.
class InstallPlan {
  InstallPlan({
    required this.host,
    required this.statuses,
    required this.preparation,
    required this.tools,
    required this.unavailable,
  });

  final HostSystem host;

  /// Every entry, as the check found it before the install.
  final List<ToolStatus> statuses;

  /// What tek prepares first: Homebrew on macOS, the base packages on Linux.
  final List<InstallStep> preparation;
  final List<PlannedTool> tools;
  final List<UnavailableTool> unavailable;

  bool get isEmpty => tools.isEmpty;

  bool get needsRoot => [...preparation, for (final tool in tools) ...tool.steps].any((step) => step.root);

  List<ToolStatus> get present => [
        for (final status in statuses)
          if (status.ok && !status.skipped) status
      ];

  List<ToolStatus> get skipped => [
        for (final status in statuses)
          if (status.skipped) status
      ];

  Map<String, Object?> toJson() => {
        'platform': host.display,
        'preparation': [for (final step in preparation) step.toJson()],
        'tools': [for (final tool in tools) tool.toJson()],
        'present': [for (final status in present) status.toJson()],
        'skipped': [for (final status in skipped) status.toJson()],
        'unavailable': [for (final item in unavailable) item.toJson()],
      };
}

/// The outcome of one installed tool.
class InstalledTool {
  const InstalledTool(this.planned, this.statuses, {this.manual});

  final PlannedTool planned;
  final List<ToolStatus> statuses;

  /// What only a person can do, when a step of the tool needs one.
  final String? manual;

  bool get ok => manual == null && statuses.every((status) => status.ok);

  Map<String, Object?> toJson() => {
        'tool': planned.tool.name,
        'ok': ok,
        'checks': [for (final status in statuses) status.toJson()],
        if (manual != null) 'manual': manual,
      };
}

class InstallOutcome {
  const InstallOutcome(this.installed, this.folders, this.env, this.shell);

  final List<InstalledTool> installed;
  final List<String> folders;
  final Map<String, String> env;
  final ShellChanges shell;
}

/// Plans and runs the install of a runtime's tools.
class ToolInstaller {
  ToolInstaller({
    required this.catalog,
    required this.checker,
    required this.host,
    required this.pathStore,
    Map<String, String>? environment,
  }) : environment = environment ?? Platform.environment;

  final ToolCatalog catalog;
  final ToolChecker checker;
  final HostSystem host;
  final PathStore pathStore;
  final Map<String, String> environment;

  Future<InstallPlan> plan(List<Requirement> entries) async {
    if (host.musl) {
      throw TekException(
        ErrorCodes.unsupportedPlatform,
        'This Linux uses musl, e.g. Alpine; tek and its tools need glibc. Use a Debian, Ubuntu or Amazon Linux image.',
      );
    }
    final statuses = await Future.wait(entries.map(checker.inspect));
    final unavailable = <UnavailableTool>[];

    // First the tools of the entries that are missing, each once with every entry it is for.
    final top = <String, PlannedTool>{};
    for (final status in statuses) {
      if (status.ok) continue;
      final tool = status.tool;
      if (tool == null) {
        final hint = status.requirement.install;
        unavailable.add(UnavailableTool(
          status,
          hint == null ? 'no registry tool provides ${status.requirement.tool}' : 'install it by hand: $hint',
        ));
        continue;
      }
      if (top[tool.name] case final planned?) {
        planned.entries.add(status);
        continue;
      }
      final steps = tool.stepsFor(host);
      if (steps == null) {
        unavailable.add(UnavailableTool(status, '${tool.name} has no steps for ${host.display}'));
        continue;
      }
      top[tool.name] = PlannedTool(tool, steps.key, steps.value, [status]);
    }

    // Then the order: every tool after the ones it requires. A required tool that one of the planned tools provides,
    // like the Dart of Flutter, comes from that one instead of its own.
    final order = <PlannedTool>[];
    final visiting = <String>{};
    Future<void> visit(PlannedTool planned) async {
      if (order.contains(planned) || !visiting.add(planned.tool.name)) return;
      for (final name in planned.tool.requires) {
        final provider = top[name] ??
            top.values.where((t) => t.tool.provides.contains(name)).firstOrNull ??
            order.where((t) => t.tool.name == name || t.tool.provides.contains(name)).firstOrNull;
        if (provider != null) {
          await visit(provider);
          continue;
        }
        final required = catalog.byName(name);
        if (required == null) continue;
        final status = await checker.inspect(Requirement(tool: required.provides.first, toolName: name));
        if (status.ok) continue;
        final steps = required.stepsFor(host);
        if (steps == null) {
          unavailable
              .add(UnavailableTool(status, 'needed by ${planned.tool.name}, it has no steps for ${host.display}'));
          continue;
        }
        await visit(PlannedTool(required, steps.key, steps.value, [status], dependency: true));
      }
      visiting.remove(planned.tool.name);
      order.add(planned);
    }

    for (final planned in top.values.toList()) {
      await visit(planned);
    }
    return InstallPlan(
      host: host,
      statuses: statuses,
      preparation: order.isEmpty ? const [] : await _preparation(order),
      tools: order,
      unavailable: unavailable,
    );
  }

  /// What the system needs before the first tool: Homebrew on macOS when a step uses brew, the base packages on
  /// Linux when they are missing, and fresh package lists for apt.
  Future<List<InstallStep>> _preparation(List<PlannedTool> tools) async {
    final steps = [for (final tool in tools) ...tool.steps];
    if (host.os == 'macos') {
      final usesBrew = steps.any((step) => step.command?.contains('brew ') ?? false);
      return usesBrew && homebrewExecutable(host) == null ? [InstallStep(command: _homebrewInstaller)] : const [];
    }
    if (host.os != 'linux') return const [];
    final commands = {'curl': 'curl', 'git': 'git', 'tar': 'tar', 'unzip': 'unzip'};
    final path = environment['PATH'] ?? '';
    switch (host.packageManager) {
      case 'apt':
        final packages = [
          if (!File('/etc/ssl/certs/ca-certificates.crt').existsSync()) 'ca-certificates',
          for (final MapEntry(key: program, value: package) in commands.entries)
            if (findOnPath(program, path) == null) package,
          if (findOnPath('gpg', path) == null) 'gnupg',
          if (findOnPath('xz', path) == null) 'xz-utils',
        ];
        final usesApt = steps.any((step) => step.command?.contains('apt-get install') ?? false);
        if (packages.isEmpty && !(usesApt && _aptListsEmpty())) return const [];
        return [
          InstallStep(
            command: packages.isEmpty
                ? 'apt-get update'
                : 'apt-get update && apt-get install -y --no-install-recommends ${packages.join(' ')}',
            root: true,
          ),
        ];
      case 'dnf':
        final packages = [
          if (!File('/etc/pki/tls/certs/ca-bundle.crt').existsSync()) 'ca-certificates',
          for (final MapEntry(key: program, value: package) in commands.entries)
            if (findOnPath(program, path) == null) package,
          if (findOnPath('gpg', path) == null) 'gnupg2',
          if (findOnPath('xz', path) == null) 'xz',
          if (findOnPath('find', path) == null) 'findutils',
          if (findOnPath('which', path) == null) 'which',
        ];
        return packages.isEmpty ? const [] : [InstallStep(command: 'dnf install -y ${packages.join(' ')}', root: true)];
      default:
        return const [];
    }
  }

  bool _aptListsEmpty() {
    final lists = Directory('/var/lib/apt/lists');
    if (!lists.existsSync()) return true;
    return !lists.listSync().any((entity) => entity.path.endsWith('_Packages') || entity.path.endsWith('Packages.lz4'));
  }

  /// Runs [plan]: the preparation, then each tool's steps, checking each tool after its last step and recording the
  /// folders its programs landed in that PATH doesn't have.
  Future<InstallOutcome> run(
    InstallPlan plan, {
    required void Function(String message) progress,
    required void Function(String message) completed,
    required void Function(String message) warning,
    bool json = false,
    String? workingDirectory,
  }) async {
    if (plan.needsRoot && !host.canRunAsRoot) {
      throw TekException(
        ErrorCodes.requirementsNotMet,
        'Some steps need root, and this user is not root and has no sudo.',
        hint: 'Run tek as root, or install sudo and give this user the right to use it.',
      );
    }
    final record = pathStore.read();
    final folders = <String>[];
    final variables = <String, String>{};
    final installed = <InstalledTool>[];
    final bin = host.root ? '/usr/local/bin' : p.join(environment['HOME'] ?? '', '.local', 'bin');
    Directory(bin).createSync(recursive: true);

    Map<String, String> stepEnvironment() {
      final base = checker.environmentFor([
        for (final tool in plan.tools) tool.tool,
        for (final status in plan.statuses)
          if (status.tool != null) status.tool!,
      ]);
      final brew = homebrewExecutable(host);
      return {
        ...base,
        'PATH': appendToPath(base['PATH'] ?? '', [
          if (brew != null) p.dirname(brew),
          ...record.folderPaths,
        ]),
        'DEBIAN_FRONTEND': 'noninteractive',
        'NONINTERACTIVE': '1',
        'TEK_OS': host.os,
        'TEK_ARCH': host.arch,
        'TEK_BIN': bin,
        if (host.os == 'macos') 'HOMEBREW_PREFIX': homebrewPrefix(host),
      };
    }

    for (final step in plan.preparation) {
      progress('Preparing ${host.distroName ?? host.display}');
      await _runStep(step, stepEnvironment(), json: json, workingDirectory: workingDirectory);
      if (step.command == _homebrewInstaller) _writeHomebrewLine();
    }

    for (final tool in plan.tools) {
      // What the preparation or an earlier tool brought, e.g. git with the base packages, needs no steps of its own.
      checker.reset();
      final already = await Future.wait(tool.entries.map((entry) => checker.inspect(entry.requirement)));
      final ran = !already.every((status) => status.ok);
      if (ran) progress('Installing ${tool.tool.name} (${tool.key})');
      String? manual;
      for (final step in ran ? tool.steps : const <InstallStep>[]) {
        if (step.isManual) {
          manual = step.manual;
          warning('${tool.tool.name} needs you: ${step.manual}');
          break;
        }
        await _runStep(step, stepEnvironment(), json: json, workingDirectory: workingDirectory);
      }
      checker.reset();
      final statuses = await Future.wait(tool.entries.map((entry) => checker.inspect(entry.requirement)));
      final result = InstalledTool(tool, statuses, manual: manual);
      installed.add(result);
      if (manual != null) continue;
      final problems = [
        for (final status in statuses)
          if (status.problem != null) status.problem!
      ];
      if (problems.isNotEmpty) {
        final hidden = [
          for (final status in statuses)
            if (status.state == ToolState.outdated && status.path != null) status,
        ];
        throw TekException(
          ErrorCodes.commandFailed,
          'The steps of ${tool.tool.name} ran, but ${problems.join('; ')}.',
          hint: hidden.isEmpty
              ? null
              : [
                  for (final status in hidden)
                    'The ${status.requirement.tool} in ${p.dirname(status.path!)} comes first on PATH and hides the new '
                        'one; remove it, or put ${tool.tool.binFor(host, environment).join(':')} in front of it.',
                ].join('\n'),
          details: {
            'tool': tool.tool.name,
            'checks': [for (final status in statuses) status.toJson()]
          },
        );
      }
      for (final status in statuses) {
        final folder = status.hiddenFolder;
        if (folder != null && !record.folderPaths.contains(folder)) {
          record.folders.add(RecordedFolder(folder, tool.tool.name));
          folders.add(folder);
        }
      }
      final env = tool.tool.envFor(host, environment);
      for (final MapEntry(:key, :value) in env.entries) {
        if ((environment[key] ?? '').isNotEmpty || record.env.containsKey(key)) continue;
        record.env[key] = RecordedVariable(value, tool.tool.name);
        variables[key] = value;
      }
      completed('${tool.tool.name}${_found(statuses)}');
    }
    final shell = applyShellChanges(record, host, added: folders, addedEnv: variables, environment: environment);
    pathStore.write(record);
    return InstallOutcome(installed, folders, variables, shell);
  }

  String _found(List<ToolStatus> statuses) {
    final parts = [
      for (final status in statuses)
        [
          status.requirement.tool,
          if (status.version != null) status.version!,
          if (status.path != null) 'in ${_home(p.dirname(status.path!))}',
        ].join(' '),
    ];
    return parts.isEmpty ? '' : ' (${parts.join(', ')})';
  }

  String _home(String path) {
    final home = environment['HOME'];
    if (home == null || home.isEmpty || !p.isWithin(home, path)) return path;
    return '~/${p.relative(path, from: home)}';
  }

  Future<void> _runStep(
    InstallStep step,
    Map<String, String> environment, {
    required bool json,
    String? workingDirectory,
  }) async {
    final command = step.command!;
    final List<String> arguments;
    if (step.root && !host.root) {
      const passed = ['DEBIAN_FRONTEND', 'NONINTERACTIVE', 'TEK_OS', 'TEK_ARCH', 'TEK_BIN', 'HOMEBREW_PREFIX', 'PATH'];
      arguments = [
        'sudo',
        'env',
        for (final name in passed)
          if (environment[name] case final value?) '$name=$value',
        '/bin/sh',
        '-c',
        command,
      ];
    } else {
      arguments = ['/bin/sh', '-c', command];
    }
    stderr.writeln('  \$ ${step.root ? '(root) ' : ''}$command');
    final process = await Process.start(
      arguments.first,
      arguments.skip(1).toList(),
      environment: environment,
      includeParentEnvironment: false,
      workingDirectory: workingDirectory,
      mode: json ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
    );
    if (json) {
      unawaited(process.stdin.close());
      await Future.wait([
        process.stdout.listen(stderr.add).asFuture<void>(),
        process.stderr.listen(stderr.add).asFuture<void>(),
      ]);
    }
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw TekException(
        ErrorCodes.commandFailed,
        'A step failed with exit code $exitCode: ${step.root ? 'root: ' : ''}$command',
        details: {'step': step.toJson(), 'exitCode': exitCode},
      );
    }
  }

  /// Homebrew's line in ~/.zprofile, written only when tek installed Homebrew itself, as its installer asks.
  void _writeHomebrewLine() {
    final brew = homebrewExecutable(host);
    final home = environment['HOME'];
    if (brew == null || home == null) return;
    final file = File(p.join(home, '.zprofile'));
    final line = 'eval "\$($brew shellenv)"';
    final text = file.existsSync() ? file.readAsStringSync() : '';
    if (text.contains('brew shellenv')) return;
    file.writeAsStringSync('${text.isEmpty || text.endsWith('\n') ? '' : '\n'}$line\n', mode: FileMode.append);
  }
}

/// Where Homebrew is: /opt/homebrew on Apple Silicon, /usr/local on Intel.
String homebrewPrefix(HostSystem host) => host.arch == 'arm64' ? '/opt/homebrew' : '/usr/local';

/// Homebrew's brew, null when it isn't installed.
String? homebrewExecutable(HostSystem host) {
  if (host.os != 'macos') return null;
  final brew = p.join(homebrewPrefix(host), 'bin', 'brew');
  if (File(brew).existsSync()) return brew;
  return findOnPath('brew', Platform.environment['PATH'] ?? '');
}

/// Asks [question] on the terminal, true for y or yes. False without a terminal.
bool confirm(String question) {
  if (!stdin.hasTerminal) return false;
  stderr.write('$question [y/N] ');
  final answer = stdin.readLineSync(encoding: utf8)?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}
