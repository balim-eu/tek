import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../../architecture_ref.dart';
import '../../errors.dart';
import '../../install/installed_architecture.dart';
import '../../manifest.dart';
import '../../run/ai_help.dart';
import '../../run/command_line.dart';
import '../../run/built_in_commands.dart';
import '../../runtime/checker.dart';
import '../../runtime/project.dart';
import '../terminal.dart';
import 'install_tools.dart';
import 'tek_command.dart';

const _helpFlags = {'--help', '-h'};
const _helpAi = '--help-ai';
const _doctor = 'doctor';
const _version = 'version';

class RunCommand extends TekCommand {
  RunCommand(super.context) {
    argParser
      ..addOption('registry', abbr: 'r', help: 'Resolve and install from the named registry.')
      ..addFlag('install', defaultsTo: true, help: 'Install the architecture if it is not installed yet.');
  }

  @override
  final ArgParser argParser = ArgParser(allowTrailingOptions: false);

  @override
  String get name => 'run';

  @override
  String get description => 'Run a command provided by an installed architecture.';

  @override
  String get invocation => 'tek run <publisher/name@version> <command> [arguments]';

  bool _trailingJson = false;

  @override
  bool get jsonMode => super.jsonMode || _trailingJson;

  @override
  Future<int> run() async {
    final ref = ArchitectureRef.parse(argument(0, 'publisher/name@version'));
    final args = <String>[];
    var separated = false;
    for (final arg in rest.skip(1)) {
      if (!separated && arg == '--json') {
        _trailingJson = true;
        continue;
      }
      if (arg == '--') separated = true;
      args.add(arg);
    }

    final (manifest, local) = await _manifest(ref);
    if (args.isEmpty || _helpFlags.contains(args.first)) return _architectureHelp(ref, manifest, local);
    if (args.first == _helpAi) return _architectureAiHelp(ref, manifest, local);
    if (args.first == '--$_version' || args.first == _version)
      return _architectureVersion(manifest, local, args.skip(1));
    if (args.first == _doctor) return _checkSoftware(ref, manifest, args.skip(1).toList());
    if (args.first == installToolsCommand) return _installTools(ref, manifest, local, args.skip(1).toList());

    final command = manifest.command(args.first);
    if (command == null) {
      final commandName = args.first;
      final available = manifest.commands.keys.toList();
      throw TekException(
        ErrorCodes.commandNotFound,
        '${manifest.id}@${manifest.version} does not provide command "$commandName". Available: ${available.join(', ')}.',
        exitCode: 64,
        details: {'available': available},
      );
    }
    final commandName = command.name;
    final requirements = manifest.requirementsFor(command);
    final commandLine = CommandLine(reference: '$ref', command: command, requirements: requirements);
    if (commandLine.requestsAiHelp(args.sublist(1))) {
      return _commandAiHelp(manifest, commandLine, await _guide(ref, command, local), local);
    }
    final parsed = commandLine.parse(args.sublist(1));
    if (parsed.help) {
      output.success({
        'architecture': manifest.id,
        'version': '${manifest.version}',
        ...commandLine.toJson(),
      }, (out) {
        final style = output.style;
        out
          ..writeln('${style.id(manifest.id)}${style.dim('@')}${style.version('${manifest.version}')} '
              '${style.bold(style.command(command.name))}')
          ..writeln(commandLine.render(style));
      });
      return 0;
    }
    for (final warning in parsed.warnings) {
      output.warning(warning);
    }
    final os = manifest.osFor(command);
    if (os != null && !os.contains(Platform.operatingSystem)) {
      throw TekException(
        ErrorCodes.unsupportedPlatform,
        '${manifest.id}@${manifest.version} $commandName only runs on ${os.join(', ')}, not ${Platform.operatingSystem}.',
      );
    }

    final architecture = local ??
        await context.ensureInstalled(
          ref,
          output: output,
          registry: argResults!.option('registry'),
          install: argResults!.flag('install'),
        );
    final checker = await context.toolChecker();
    final statuses = await Future.wait(requirements.map(checker.inspect));
    final problems = [
      for (final status in statuses)
        if (status.problem case final problem?) problem
    ];
    if (problems.isNotEmpty) {
      throw TekException(
        ErrorCodes.requirementsNotMet,
        '${architecture.reference} $commandName needs:\n${problems.map((problem) => '  - $problem').join('\n')}',
        hint: 'Install what is missing with: tek $ref $installToolsCommand',
        details: {'problems': problems},
      );
    }
    final environment = {
      ...parsed.environment,
      ...runtimeEnvironment(checker, [...requirements, ...manifest.optionalRequirements]),
    };

    if (!jsonMode) {
      final exitCode = await context.executor.runInteractive(
        architecture,
        commandName,
        parsed.passthrough,
        environment: environment,
      );
      if (exitCode == 0) _recordProject(commandName, parsed.parameters, architecture.reference);
      return exitCode;
    }

    final result = await context.executor.runCaptured(
      architecture,
      commandName,
      parsed.passthrough,
      environment: environment,
    );
    final ok = result.exitCode == 0;
    if (ok) _recordProject(commandName, parsed.parameters, architecture.reference);
    output.result({
      'ok': ok,
      'architecture': architecture.id,
      'version': '${architecture.version}',
      'command': commandName,
      'exitCode': result.exitCode,
      'output': _decode(result.stdout),
      if (!ok)
        'error': TekException(
          ErrorCodes.commandFailed,
          'Command "$commandName" of ${architecture.reference} exited with code ${result.exitCode}.',
        ).toJson(),
    });
    return result.exitCode;
  }

  /// After create: the tek.yaml of the new project, which names the architecture and version it was made with.
  void _recordProject(String command, Map<String, Object?> parameters, String reference) {
    if (command != 'create') return;
    final directory = parameters['directory'];
    if (directory is! String || !Directory(directory).existsSync()) return;
    ProjectFile.writeArchitecture(directory, reference);
  }

  Future<int> _installTools(
    ArchitectureRef ref,
    Manifest manifest,
    InstalledArchitecture? local,
    List<String> args,
  ) async {
    final parser = installToolsParser();
    final ArgResults results;
    try {
      results = parser.parse(args);
    } on FormatException catch (e) {
      throw TekException(ErrorCodes.usage, e.message, exitCode: 64);
    }
    if (results.flag('help')) {
      output.success({
        'architecture': manifest.id,
        'version': '${manifest.version}',
        'command': installToolsCommand,
        'usage': 'tek $ref $installToolsCommand [options]',
      }, (out) {
        final style = output.style;
        final targets = {for (final r in manifest.optionalRequirements) ...r.targets};
        out
          ..writeln('${style.id(manifest.id)}${style.dim('@')}${style.version('${manifest.version}')} '
              '${style.bold(style.command(installToolsCommand))}')
          ..writeln('Install the tools ${manifest.id} needs that are missing on this machine, with the steps of the '
              'registry for this system, asking once.')
          ..writeln()
          ..writeln('${style.heading('Usage:')} tek $ref $installToolsCommand [options]')
          ..writeln()
          ..writeln(parser.usage);
        if (targets.isNotEmpty) {
          out
            ..writeln()
            ..writeln('${style.heading('Targets:')} ${targets.join(', ')}');
        }
      });
      return 0;
    }
    if (results.rest.isNotEmpty) {
      throw TekException(ErrorCodes.usage, '$installToolsCommand takes no arguments, got "${results.rest.join(' ')}".',
          exitCode: 64);
    }
    if (local == null) {
      await context.ensureInstalled(
        ref,
        output: output,
        registry: argResults!.option('registry'),
        install: argResults!.flag('install'),
      );
    }
    return InstallTools(context, output).run('$ref', manifest, results);
  }

  Future<(Manifest, InstalledArchitecture?)> _manifest(ArchitectureRef ref) async {
    final registry = argResults!.option('registry');
    final exact = ref.constraint.exact;
    final local = registry != null
        ? null
        : exact != null
            ? await context.installed.find(ref.id, exact)
            : await context.installed.select(ref);
    if (local != null) return (local.manifest, local);
    final resolved = await (await context.registries()).resolve(ref, registry: registry);
    final manifest = await resolved.registry.manifest(resolved.architecture, resolved.version);
    if (manifest == null) {
      throw TekException(
        ErrorCodes.invalidManifest,
        'Registry "${resolved.registry.config.name}" does not provide a manifest for ${resolved.reference}.',
      );
    }
    return (manifest, null);
  }

  Future<String?> _guide(ArchitectureRef ref, ManifestCommand command, InstalledArchitecture? local) async {
    if (command.helpAi == null) return null;
    final architecture = local ??
        await context.ensureInstalled(
          ref,
          output: output,
          registry: argResults!.option('registry'),
          install: argResults!.flag('install'),
        );
    final result = await Process.run(
      architecture.executable,
      const [],
      environment: {'TEK_COMMAND': command.name, 'TEK_HELP_AI': '1'},
      stdoutEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw TekException(
        ErrorCodes.commandFailed,
        '${architecture.reference} has no guide for ${command.name}, its executable exited with code ${result.exitCode}.',
      );
    }
    return result.stdout as String;
  }

  int _commandAiHelp(Manifest manifest, CommandLine commandLine, String? guide, InstalledArchitecture? local) {
    final markdown = commandAiHelp(commandLine, guide: guide);
    output.success({
      'architecture': manifest.id,
      'version': '${manifest.version}',
      'command': commandLine.command.name,
      if (commandLine.command.helpAi != null) 'helpAi': commandLine.command.helpAi,
      'markdown': markdown,
      'installed': local != null,
    }, (out) => out.write(markdown));
    return 0;
  }

  int _architectureAiHelp(ArchitectureRef ref, Manifest manifest, InstalledArchitecture? local) {
    final markdown = architectureAiHelp('$ref', manifest);
    output.success({
      'architecture': manifest.id,
      'version': '${manifest.version}',
      'markdown': markdown,
      'installed': local != null,
    }, (out) => out.write(markdown));
    return 0;
  }

  int _architectureHelp(ArchitectureRef ref, Manifest manifest, InstalledArchitecture? local) {
    final usage = 'tek $ref <command> [arguments]';
    final commands = manifest.commands.values.toList();
    final rows = withBuiltInCommands(manifest, [
      for (final c in commands)
        (c.aliases.isEmpty ? c.name : '${c.name} (${c.aliases.join(', ')})', c.description ?? ''),
    ]);
    output.success({
      'architecture': manifest.id,
      'version': '${manifest.version}',
      'name': manifest.name,
      if (manifest.description != null) 'description': manifest.description,
      'usage': usage,
      'commands': [
        for (final c in commands) c.toJson(),
        for (final (name, description) in builtInCommands(manifest)) {'name': name, 'description': description},
      ],
      'runtime': manifest.toJson()['runtime'],
      'installed': local != null,
    }, (out) {
      final style = output.style;
      final title = manifest.name != manifest.id ? '  ${style.bold(manifest.name)}' : '';
      out.writeln('${style.id(manifest.id)}${style.dim('@')}${style.version('${manifest.version}')}$title');
      if (manifest.description != null) out.writeln(manifest.description);
      out
        ..writeln()
        ..writeln('${style.heading('Usage:')} $usage')
        ..writeln()
        ..writeln(style.heading('Commands:'));
      writeTable(out, rows, key: style.command);
      if (manifest.requirements.isNotEmpty) {
        out
          ..writeln()
          ..writeln(style.heading('Requirements:'));
        writeTable(out, [for (final r in manifest.requirements) (r.tool, r.version ?? 'any')]);
      }
      out
        ..writeln()
        ..writeln(style.dim('Run "tek $ref <command> --help" for details about a command, '
            'or --help-ai for a guide with examples for AI agents.'));
    });
    return 0;
  }

  Future<int> _checkSoftware(ArchitectureRef ref, Manifest manifest, List<String> args) async {
    if (args.length == 1 && _helpFlags.contains(args.single)) {
      output.success({
        'architecture': manifest.id,
        'version': '${manifest.version}',
        'command': _doctor,
        'usage': 'tek $ref $_doctor',
      }, (out) {
        final style = output.style;
        out
          ..writeln('${style.id(manifest.id)}${style.dim('@')}${style.version('${manifest.version}')} '
              '${style.bold(style.command(_doctor))}')
          ..writeln('Check the software ${manifest.id} needs on this machine: what every command needs, what single '
              'commands need and what is optional, with the version and the place it was found.')
          ..writeln()
          ..writeln('${style.heading('Usage:')} tek $ref $_doctor');
      });
      return 0;
    }
    if (args.isNotEmpty) {
      throw TekException(ErrorCodes.usage, '$_doctor takes no arguments, got "${args.join(' ')}".', exitCode: 64);
    }
    final runtime = {for (final requirement in manifest.requirements) requirement.tool};
    final byCommand = <String, (Requirement, List<String>)>{};
    for (final command in manifest.commands.values) {
      for (final requirement in command.requires.where((r) => !runtime.contains(r.tool))) {
        final key = '${requirement.tool}\u0000${requirement.version}\u0000${requirement.command}';
        final (existing, commands) = byCommand[key] ?? (requirement, <String>[]);
        byCommand[key] = (existing, [...commands, command.name]);
      }
    }
    final checker = await context.toolChecker();
    final [required, commands, optional] = await Future.wait([
      Future.wait(manifest.requirements.map(checker.inspect)),
      Future.wait([for (final (requirement, _) in byCommand.values) checker.inspect(requirement)]),
      Future.wait(manifest.optionalRequirements.map(checker.inspect)),
    ]);
    final users = [for (final (_, names) in byCommand.values) names];
    final missing = [...required, ...commands].where((status) => !status.ok).length;
    final optionalMissing = [
      for (final status in optional)
        if (!status.ok) status
    ];
    final data = {
      'ok': missing == 0,
      'architecture': manifest.id,
      'version': '${manifest.version}',
      'required': [for (final status in required) status.toJson()],
      'commands': [
        for (final (index, status) in commands.indexed) {...status.toJson(), 'commands': users[index]},
      ],
      'optional': [for (final status in optional) status.toJson()],
    };
    if (jsonMode) {
      output.result(data);
      return missing == 0 ? 0 : 1;
    }
    final style = output.style;
    final all = [...required, ...commands, ...optional];
    final toolWidth = all.fold(0, (width, s) => s.requirement.tool.length > width ? s.requirement.tool.length : width);
    final versionWidth = all.fold(
        3,
        (width, s) =>
            (s.requirement.version ?? 'any').length > width ? (s.requirement.version ?? 'any').length : width);
    String found(ToolStatus status) => switch (status.state) {
          ToolState.skipped =>
            status.detail ?? 'only on ${(status.requirement.os ?? status.tool?.os ?? const []).join(', ')}',
          ToolState.ok => [
              status.version ?? 'installed',
              if (status.path != null) displayPath(p.dirname(status.path!)),
              if (!status.onPath) '(off PATH)',
            ].join('  '),
          ToolState.outdated =>
            'found ${status.version}${status.path == null ? '' : ' in ${displayPath(p.dirname(status.path!))}'}',
          ToolState.failed => 'its check fails',
          ToolState.unreadable => 'version unreadable',
          ToolState.missing => 'missing',
        };
    void section(String title, List<ToolStatus> statuses, {List<List<String>>? names}) {
      if (statuses.isEmpty) return;
      stdout
        ..writeln()
        ..writeln(style.heading(title));
      for (final (index, status) in statuses.indexed) {
        final requirement = status.requirement;
        final mark = status.skipped
            ? style.dim('-')
            : status.ok
                ? style.success
                : title == 'Optional'
                    ? style.warning
                    : style.failure;
        final note = [
          if (names != null) names[index].join(', '),
          if (requirement.targets.isNotEmpty) 'for ${requirement.targets.join(', ')}',
          if (requirement.description != null) requirement.description!,
          if (!status.ok && status.tool == null && requirement.install != null) 'install: ${requirement.install}',
        ].join(' · ');
        final line =
            '  $mark ${requirement.tool.padRight(toolWidth)}  ${(requirement.version ?? 'any').padRight(versionWidth)}  '
            '${found(status)}';
        stdout.writeln('$line${note.isEmpty ? '' : '  ${style.dim(note)}'}'.trimRight());
      }
    }

    stdout.writeln('${style.id(manifest.id)}${style.dim('@')}${style.version('${manifest.version}')} '
        '${style.bold(style.command(_doctor))}');
    section('Required by every command', required);
    section('Required by some commands', commands, names: users);
    section('Optional', optional);
    stdout.writeln();
    if (missing == 0) {
      stdout.writeln('${style.success} Everything ${manifest.id} needs is installed.');
    } else {
      stdout
        ..writeln(
            '${style.failure} ${style.red('${missing == 1 ? '1 required program is' : '$missing required programs are'} '
                'missing or outdated.')}')
        ..writeln('  Install ${missing == 1 ? 'it' : 'them'} with: tek $ref $installToolsCommand');
    }
    final targets = {for (final status in optionalMissing) ...status.requirement.targets};
    if (optionalMissing.isNotEmpty) {
      stdout.writeln(style.dim('  Optional ones with: tek $ref $installToolsCommand '
          '${targets.isEmpty ? '--optional' : '--with ${targets.join(',')}'}'));
    }
    return missing == 0 ? 0 : 1;
  }

  int _architectureVersion(Manifest manifest, InstalledArchitecture? local, Iterable<String> extra) {
    if (extra.isNotEmpty) {
      throw TekException(ErrorCodes.usage, '$_version takes no arguments, got "${extra.join(' ')}".', exitCode: 64);
    }
    output.success(
      {'architecture': manifest.id, 'version': '${manifest.version}', 'installed': local != null},
      (out) => out.writeln('${output.style.id(manifest.id)} ${output.style.version('${manifest.version}')}'),
    );
    return 0;
  }

  Object? _decode(String stdout) {
    final trimmed = stdout.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } on FormatException {
      return stdout;
    }
  }
}
