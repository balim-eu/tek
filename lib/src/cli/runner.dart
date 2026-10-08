import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../architecture_ref.dart';
import '../errors.dart';
import '../version.dart';
import 'commands/info_command.dart';
import 'commands/install_command.dart';
import 'commands/list_command.dart';
import 'commands/registry_command.dart';
import 'commands/run_command.dart';
import 'commands/search_command.dart';
import 'commands/uninstall_command.dart';
import 'commands/update_command.dart';
import 'context.dart';
import 'output.dart';

class TekCommandRunner extends CommandRunner<int> {
  TekCommandRunner(this.context) : super('tek', 'Discover, install, and run Tek architectures.') {
    argParser
      ..addFlag('json', negatable: false, help: 'Print machine-readable JSON to stdout.')
      ..addFlag('version', negatable: false, help: 'Print the tek version.');
    addCommand(SearchCommand(context));
    addCommand(InfoCommand(context));
    addCommand(InstallCommand(context));
    addCommand(ListCommand(context));
    addCommand(RunCommand(context));
    addCommand(RegistryCommand(context));
    addCommand(UpdateCommand(context));
    addCommand(UninstallCommand(context));
  }

  final TekContext context;
  Output _output = Output(json: false);

  @override
  String get invocation => 'tek <command> [arguments]';

  @override
  String get usageFooter => '\nArchitectures can also be run directly:\n'
      '  tek <publisher/name@version> <command> [arguments]';

  @override
  void printUsage() => _output.usage(usage);

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults.flag('version') && topLevelResults.command == null) {
      _output.success({'version': tekVersion},
          (out) => out.writeln('${_output.style.bold('tek')} ${_output.style.version(tekVersion)}'));
      return 0;
    }
    return super.runCommand(topLevelResults);
  }

  Future<int> execute(List<String> arguments) async {
    final args = rewriteDirectInvocation(arguments);
    _output = Output(json: jsonRequested(args));
    try {
      return await run(args) ?? 0;
    } on UsageException catch (e) {
      _output.error(TekException(ErrorCodes.usage, e.message, exitCode: 64), usage: e.usage);
      return 64;
    } on TekException catch (e) {
      _output.error(e);
      return e.exitCode;
    } on FileSystemException catch (e) {
      _output.error(TekException(ErrorCodes.io, '${e.message}${e.path == null ? '' : ': ${e.path}'}'));
      return 1;
    } catch (e) {
      _output.error(TekException(ErrorCodes.internal, '$e'));
      return 70;
    } finally {
      context.close();
    }
  }

  List<String> rewriteDirectInvocation(List<String> arguments) {
    final index = arguments.indexWhere((arg) => !arg.startsWith('-'));
    if (index == -1) return arguments;
    final candidate = arguments[index];
    if (commands.containsKey(candidate) || !looksLikeArchitectureRef(candidate)) return arguments;
    return [...arguments.take(index), 'run', ...arguments.skip(index)];
  }

  static bool jsonRequested(List<String> arguments) {
    for (final arg in arguments) {
      if (arg == '--') return false;
      if (arg == '--json') return true;
    }
    return false;
  }
}

Future<int> runTek(List<String> arguments) => TekCommandRunner(TekContext()).execute(arguments);
