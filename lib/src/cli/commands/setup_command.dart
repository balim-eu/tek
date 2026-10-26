import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../architecture_ref.dart';
import '../../errors.dart';
import '../../install/installed_architecture.dart';
import '../../run/command_line.dart';
import '../../runtime/checker.dart';
import '../../runtime/project.dart';
import '../terminal.dart';
import 'install_tools.dart';
import 'tek_command.dart';

/// A folder of the project and the architecture that sets it up.
class _Part {
  _Part(this.directory, this.reference);

  final String directory;
  final String reference;
}

class SetupCommand extends TekCommand {
  SetupCommand(super.context);

  @override
  String get name => 'setup';

  @override
  String get description => 'Set a project up with the architecture its tek.yaml names, every product of it too.';

  @override
  String get invocation => 'tek setup [directory]';

  @override
  Future<int> run() async {
    expectArguments(1);
    final directory = p.normalize(p.absolute(rest.isEmpty ? '.' : rest.first));
    final project = ProjectFile.read(directory) ??
        (throw TekException(
          ErrorCodes.config,
          'There is no $projectFileName in ${displayPath(directory)}.',
          hint: 'A project made with tek create has one. Create one with: tek <architecture> create <directory>',
        ));
    final parts = _parts(project);
    if (parts.isEmpty) {
      throw TekException(
        ErrorCodes.config,
        '${displayPath(p.join(directory, projectFileName))} names no architecture.',
        hint: 'Name the one the project was made with, e.g. architecture: tek/rust-api',
      );
    }

    final style = output.errorStyle;
    final architectures = <String, InstalledArchitecture>{};
    for (final part in parts) {
      architectures[part.reference] ??=
          await context.ensureInstalled(ArchitectureRef.parse(part.reference), output: output);
    }
    final checker = await context.toolChecker();
    final missing = <String, List<String>>{};
    for (final part in parts) {
      final manifest = architectures[part.reference]!.manifest;
      final setup = manifest.command('setup');
      final requirements = setup == null ? manifest.requirements : manifest.requirementsFor(setup);
      for (final status in await Future.wait(requirements.map(checker.inspect))) {
        if (status.problem case final problem?) (missing[part.reference] ??= []).add(problem);
      }
    }
    if (missing.isNotEmpty) {
      throw TekException(
        ErrorCodes.requirementsNotMet,
        [
          for (final MapEntry(key: reference, value: problems) in missing.entries)
            '$reference needs:\n${problems.toSet().map((problem) => '  - $problem').join('\n')}',
        ].join('\n'),
        hint: 'Install what is missing with:\n${[
          for (final reference in missing.keys) '  tek ${ArchitectureRef.parse(reference).id} $installToolsCommand',
        ].join('\n')}',
        details: {'missing': missing},
      );
    }

    final results = <Map<String, Object?>>[];
    for (final part in parts) {
      final architecture = architectures[part.reference]!;
      final manifest = architecture.manifest;
      final setup = manifest.command('setup');
      final shown = displayPath(part.directory);
      if (setup == null) {
        if (!jsonMode) stderr.writeln(style.dim('${architecture.reference} has nothing to set up in $shown.'));
        results.add({'directory': part.directory, 'architecture': architecture.reference, 'setup': false});
        continue;
      }
      if (parts.length > 1) output.progress('Setting up $shown with ${architecture.reference}');
      final line =
          CommandLine(reference: architecture.id, command: setup, requirements: manifest.requirementsFor(setup));
      final takesDirectory = setup.arguments.isNotEmpty && setup.arguments.first.name == 'directory';
      // The folder as the person named it, relative to where tek setup runs, so the setup's messages read the same.
      final relative = p.relative(part.directory, from: Directory.current.path);
      final parsed = line.parse(takesDirectory ? [relative] : const []);
      final environment = {
        ...parsed.environment,
        ...runtimeEnvironment(checker, [...manifest.requirementsFor(setup), ...manifest.optionalRequirements]),
      };
      final int exitCode;
      Object? captured;
      if (jsonMode) {
        final result =
            await context.executor.runCaptured(architecture, setup.name, parsed.passthrough, environment: environment);
        exitCode = result.exitCode;
        captured = _decode(result.stdout);
      } else {
        exitCode = await context.executor
            .runInteractive(architecture, setup.name, parsed.passthrough, environment: environment);
      }
      results.add({
        'directory': part.directory,
        'architecture': architecture.reference,
        'setup': true,
        'exitCode': exitCode,
        if (captured != null) 'output': captured,
      });
      if (exitCode != 0) {
        if (jsonMode) {
          output.result({
            'ok': false,
            'parts': results,
            'error': TekException(ErrorCodes.commandFailed,
                    'The setup of ${architecture.reference} in $shown exited with code $exitCode.')
                .toJson(),
          });
        } else {
          stderr.writeln('${style.failure} ${style.red('The setup of ${architecture.reference} in $shown exited with '
              'code $exitCode.')}');
        }
        return exitCode;
      }
    }
    output.success({'directory': directory, 'parts': results}, (out) {
      if (parts.length > 1) stderr.writeln('${style.success} ${displayPath(directory)} is set up');
    });
    return 0;
  }

  /// The folders to set up: the project's own architecture, then every product's, from the product's own tek.yaml or
  /// its entry in the project's.
  List<_Part> _parts(ProjectFile project) {
    final parts = <_Part>[];
    final seen = <String>{};
    void add(String directory, String? reference) {
      if (reference == null || !looksLikeArchitectureRef(reference)) return;
      if (seen.add('$directory\u0000$reference')) parts.add(_Part(directory, reference));
    }

    add(project.directory, project.architecture);
    for (final product in project.products) {
      final directory = p.normalize(p.join(project.directory, product.path));
      if (!Directory(directory).existsSync()) continue;
      add(directory, ProjectFile.read(directory)?.architecture ?? product.architecture);
    }
    return parts;
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
