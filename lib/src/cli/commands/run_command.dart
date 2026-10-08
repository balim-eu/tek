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
import '../../run/prompt.dart';
import '../../run/requirements.dart';
import 'tek_command.dart';

const _helpFlags = {'--help', '-h'};
const _helpAi = '--help-ai';
const _prompt = 'prompt';
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
    if (args.first == _prompt) return _agentPrompt(ref, manifest, local, args.skip(1).toList());

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
    await RequirementChecker().check('${architecture.reference} $commandName', requirements);

    if (!jsonMode) {
      return context.executor.runInteractive(
        architecture,
        commandName,
        parsed.passthrough,
        environment: parsed.environment,
      );
    }

    final result = await context.executor.runCaptured(
      architecture,
      commandName,
      parsed.passthrough,
      environment: parsed.environment,
    );
    final ok = result.exitCode == 0;
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
    final path = command.helpAi;
    if (path == null) return null;
    final architecture = local ??
        await context.ensureInstalled(
          ref,
          output: output,
          registry: argResults!.option('registry'),
          install: argResults!.flag('install'),
        );
    if (architecture.executable case final executable?) {
      final result = await Process.run(
        executable,
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
    final file = File(p.joinAll([architecture.directory, ...p.posix.split(path)]));
    if (!await file.exists()) {
      throw TekException(
        ErrorCodes.integrityCheckFailed,
        'Installed package ${architecture.reference} is missing $path. '
        'Reinstall it with "tek install ${architecture.reference} --force".',
      );
    }
    return file.readAsString();
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

  Future<int> _agentPrompt(
    ArchitectureRef ref,
    Manifest manifest,
    InstalledArchitecture? local,
    List<String> args,
  ) async {
    if (args.length == 1 && _helpFlags.contains(args.single)) {
      output.success({
        'architecture': manifest.id,
        'version': '${manifest.version}',
        'command': _prompt,
        'usage': 'tek $ref $_prompt <task>',
      }, (out) {
        final style = output.style;
        out
          ..writeln('${style.id(manifest.id)}${style.dim('@')}${style.version('${manifest.version}')} '
              '${style.bold(style.command(_prompt))}')
          ..writeln('Print a prompt that starts an AI agent on a task: the system prompt of ${manifest.id}, '
              'how to work with it, followed by the task as user prompt. Copy it into the agent.')
          ..writeln()
          ..writeln('${style.heading('Usage:')} tek $ref $_prompt <task>')
          ..writeln('       tek $ref $_prompt < task.md')
          ..writeln()
          ..writeln(style.heading('Examples:'))
          ..writeln('  tek $ref $_prompt "Build a shop app with a product list and a cart."')
          ..writeln('  tek $ref $_prompt < task.md | pbcopy');
      });
      return 0;
    }
    var task = (args.isNotEmpty && args.first == '--' ? args.skip(1) : args).join(' ').trim();
    if (task.isEmpty && !stdin.hasTerminal) task = (await stdin.transform(utf8.decoder).join()).trim();
    if (task.isEmpty) {
      throw TekException(
        ErrorCodes.usage,
        'Pass the task for the agent, e.g. tek $ref $_prompt "Build a shop app with a cart", or pipe it in.',
        exitCode: 64,
      );
    }
    final prompt = agentPrompt(manifest, '$ref', task);
    output.success({
      'architecture': manifest.id,
      'version': '${manifest.version}',
      'installed': local != null,
      'systemPrompt': systemPrompt(manifest, '$ref'),
      'userPrompt': task,
      'prompt': prompt,
    }, (out) => out.write(prompt));
    return 0;
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
