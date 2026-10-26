import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../../errors.dart';
import '../../manifest.dart';
import '../../runtime/checker.dart';
import '../../runtime/system.dart';
import '../../runtime/tool_installer.dart';
import '../context.dart';
import '../output.dart';
import '../terminal.dart';

const installToolsCommand = 'install-tools';

ArgParser installToolsParser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Print this usage information.')
  ..addMultiOption('with',
      valueHelp: 'target|tool', help: 'Also install the optional tools of these targets, or these tools by name.')
  ..addFlag('optional', negatable: false, help: 'Also install every optional tool.')
  ..addFlag('yes', abbr: 'y', negatable: false, help: 'Install without asking.')
  ..addFlag('dry-run', negatable: false, help: 'Print the steps for this machine without running them.');

/// The entries install-tools installs: what every command needs, what single commands need, and the optional tools
/// of the targets or names in [include], or all of them with [optional]. Throws for a name the manifest doesn't know.
List<Requirement> selectEntries(Manifest manifest, List<String> include, {required bool optional}) {
  final entries = <String, Requirement>{for (final r in manifest.requirements) r.tool: r};
  for (final command in manifest.commands.values) {
    for (final requirement in command.requires) {
      entries.putIfAbsent(requirement.tool, () => requirement);
    }
  }
  final known = {
    ...entries.keys,
    for (final r in manifest.optionalRequirements) ...[r.tool, ...r.targets],
  };
  final unknown = [
    for (final name in include)
      if (!known.contains(name)) name
  ];
  if (unknown.isNotEmpty) {
    final targets = {for (final r in manifest.optionalRequirements) ...r.targets};
    throw TekException(
      ErrorCodes.usage,
      '${manifest.id} has no optional tool or target ${unknown.join(', ')}.',
      hint: [
        if (targets.isNotEmpty) 'Targets: ${targets.join(', ')}',
        if (manifest.optionalRequirements.isNotEmpty)
          'Optional tools: ${manifest.optionalRequirements.map((r) => r.tool).join(', ')}',
      ].join('\n'),
      exitCode: 64,
    );
  }
  for (final requirement in manifest.optionalRequirements) {
    if (optional || include.contains(requirement.tool) || requirement.targets.any(include.contains)) {
      entries.putIfAbsent(requirement.tool, () => requirement);
    }
  }
  return entries.values.toList();
}

class InstallTools {
  InstallTools(this.context, this.output);

  final TekContext context;
  final Output output;

  Future<int> run(String reference, Manifest manifest, ArgResults args) async {
    final style = output.style;
    final errors = output.errorStyle;
    final host = await context.host();
    if (host.os == 'windows') {
      throw TekException(
        ErrorCodes.unsupportedPlatform,
        'tek installs tools on macOS and Linux. On Windows, run tek inside WSL2.',
        hint: 'Turn WSL2 on with: wsl --install -d Ubuntu-24.04',
      );
    }
    final entries = selectEntries(manifest, args.multiOption('with'), optional: args.flag('optional'));
    final catalog = await output.step('Reading the tools of the registries', () => context.toolCatalog(refresh: true),
        done: (_) => null);
    for (final problem in catalog.problems) {
      output.warning(problem);
    }
    final checker = await context.toolChecker();
    final installer = ToolInstaller(catalog: catalog, checker: checker, host: host, pathStore: context.pathStore);
    final plan = await installer.plan(entries);
    final dryRun = args.flag('dry-run');

    if (output.json && (dryRun || plan.isEmpty)) {
      output.result({
        'ok': plan.unavailable.isEmpty,
        'architecture': manifest.id,
        'version': '${manifest.version}',
        'dryRun': dryRun,
        ...plan.toJson(),
      });
      return plan.unavailable.isEmpty ? 0 : 1;
    }
    if (!output.json) _printPlan(reference, manifest, plan, host);

    if (plan.isEmpty) {
      if (!output.json) {
        stderr.writeln(plan.unavailable.isEmpty
            ? '${errors.success} Everything ${manifest.id} needs is installed.'
            : '${errors.failure} ${errors.red('Nothing tek can install is missing; the rest needs a person, above.')}');
      }
      return plan.unavailable.isEmpty ? 0 : 1;
    }
    if (dryRun) return 0;
    if (!args.flag('yes')) {
      final count = plan.tools.length;
      if (!stdin.hasTerminal) {
        throw TekException(
          ErrorCodes.usage,
          '$installToolsCommand asks before it installs, and there is no terminal to ask in.',
          hint: 'Run it with --yes to install without asking: tek $reference $installToolsCommand --yes',
          exitCode: 64,
        );
      }
      if (!confirm('Install ${count == 1 ? 'it' : 'them'}?')) {
        stderr.writeln(errors.dim('Nothing was installed.'));
        return 1;
      }
    }

    final outcome = await installer.run(
      plan,
      progress: output.progress,
      completed: output.completed,
      warning: output.warning,
      json: output.json,
    );
    final manual = [
      for (final tool in outcome.installed)
        if (tool.manual != null) tool
    ];
    final ok = manual.isEmpty && plan.unavailable.isEmpty;
    if (output.json) {
      output.result({
        'ok': ok,
        'architecture': manifest.id,
        'version': '${manifest.version}',
        ...plan.toJson(),
        'installed': [for (final tool in outcome.installed) tool.toJson()],
        'folders': outcome.folders,
        'env': outcome.env,
        'profiles': outcome.shell.profiles,
        'links': outcome.shell.links,
      });
      return ok ? 0 : 1;
    }
    final shell = outcome.shell;
    if (shell.links.isNotEmpty)
      stderr.writeln(errors.dim('Linked ${shell.links.length} programs into /usr/local/bin.'));
    if (shell.profileD != null) stderr.writeln(errors.dim('Their variables are in ${shell.profileD}.'));
    for (final profile in shell.profiles) {
      stderr.writeln(errors.dim('Added the tek shellenv line to ${displayPath(profile)}.'));
    }
    if ((outcome.folders.isNotEmpty || outcome.env.isNotEmpty) && !host.root) {
      stderr.writeln('New terminals have the tools; this one after: ${style.bold('eval "\$(tek shellenv)"')}');
    }
    if (!ok) {
      stderr.writeln('${errors.failure} ${errors.red('Some tools need a person, above.')}');
      return 1;
    }
    stderr.writeln('${errors.success} Everything ${manifest.id} needs is installed.');
    return 0;
  }

  void _printPlan(String reference, Manifest manifest, InstallPlan plan, HostSystem host) {
    final style = output.errorStyle;
    final rows = <(String, String, String, String)>[];
    final planned = {
      for (final tool in plan.tools)
        for (final entry in tool.entries) entry.requirement.tool: tool
    };
    for (final status in plan.statuses) {
      final requirement = status.requirement;
      final mark = status.skipped
          ? style.dim('-')
          : status.ok
              ? style.success
              : planned.containsKey(requirement.tool)
                  ? style.cyan('↓')
                  : style.failure;
      final found = switch (status.state) {
        ToolState.skipped => status.detail ?? 'only on ${(requirement.os ?? status.tool?.os ?? const []).join(', ')}',
        ToolState.ok => [
            if (status.version != null) status.version!,
            if (status.path != null) displayPath(p.dirname(status.path!)),
          ].join('  '),
        ToolState.outdated => 'found ${status.version}',
        ToolState.failed => 'its check fails',
        _ => 'missing',
      };
      rows.add((mark, requirement.tool, requirement.checksVersion ? requirement.version! : '', found));
    }
    for (final tool in plan.tools.where((t) => t.dependency)) {
      rows.add((style.cyan('↓'), tool.tool.name, '', 'needed by another tool'));
    }
    final nameWidth = rows.fold(0, (w, r) => r.$2.length > w ? r.$2.length : w);
    final versionWidth = rows.fold(0, (w, r) => r.$3.length > w ? r.$3.length : w);
    stderr.writeln('${style.id(manifest.id)}${style.dim('@')}${style.version('${manifest.version}')} '
        'on ${host.distroName == null ? host.display : '${host.distroName} ${host.arch}'}');
    for (final (mark, name, version, found) in rows) {
      stderr.writeln(
          '  $mark ${name.padRight(nameWidth)}  ${version.padRight(versionWidth)}  ${style.dim(found)}'.trimRight());
    }
    for (final item in plan.unavailable) {
      stderr.writeln('${style.failure} ${style.red('${item.status.requirement.tool}: ${item.reason}')}');
    }
    if (plan.isEmpty) return;
    stderr
      ..writeln()
      ..writeln(style.bold('Steps for ${host.display}${plan.needsRoot ? ', the ones marked root as root' : ''}:'));
    for (final step in plan.preparation) {
      stderr.writeln('  ${style.dim('prepare')}  ${step.root ? style.yellow('root ') : ''}${step.command}');
    }
    final width = plan.tools.fold(7, (w, t) => t.tool.name.length > w ? t.tool.name.length : w);
    for (final tool in plan.tools) {
      for (final (index, step) in tool.steps.indexed) {
        final label = index == 0 ? tool.tool.name.padRight(width) : ''.padRight(width);
        final text = step.isManual
            ? style.yellow('by hand: ${step.manual}')
            : '${step.root ? style.yellow('root ') : ''}${step.command}';
        stderr.writeln('  ${style.dim(label)}  $text');
      }
    }
    stderr.writeln();
  }
}
