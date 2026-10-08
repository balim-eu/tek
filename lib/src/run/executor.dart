import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../install/installed_architecture.dart';
import '../tek_home.dart';
import '../version.dart';

class CapturedRun {
  const CapturedRun(this.exitCode, this.stdout);

  final int exitCode;
  final String stdout;
}

class _Invocation {
  const _Invocation(this.executable, this.arguments, {this.runInShell = false});

  final String executable;
  final List<String> arguments;
  final bool runInShell;
}

class Executor {
  Executor(this.home);

  final TekHome home;

  Future<int> runInteractive(
    InstalledArchitecture architecture,
    String command,
    List<String> args, {
    Map<String, String> environment = const {},
  }) async {
    final invocation = await _prepare(architecture, command, args);
    final process = await _start(
      invocation,
      architecture,
      command,
      environment,
      json: false,
      mode: ProcessStartMode.inheritStdio,
    );
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    if (!Platform.isWindows) {
      subscriptions
        ..add(ProcessSignal.sigint.watch().listen((_) {}))
        ..add(ProcessSignal.sigterm.watch().listen((signal) => process.kill(signal)));
    }
    try {
      return await process.exitCode;
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }

  Future<CapturedRun> runCaptured(
    InstalledArchitecture architecture,
    String command,
    List<String> args, {
    Map<String, String> environment = const {},
  }) async {
    final invocation = await _prepare(architecture, command, args);
    final process = await _start(
      invocation,
      architecture,
      command,
      environment,
      json: true,
      mode: ProcessStartMode.normal,
    );
    unawaited(process.stdin.close());
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = stderr.addStream(process.stderr);
    final exitCode = await process.exitCode;
    await errors;
    return CapturedRun(exitCode, await output);
  }

  Future<_Invocation> _prepare(InstalledArchitecture architecture, String command, List<String> args) async {
    await architecture.verifyIntegrity();
    if (!architecture.manifest.commands.containsKey(command)) {
      final available = architecture.manifest.commands.keys.toList();
      throw TekException(
        ErrorCodes.commandNotFound,
        '${architecture.reference} does not provide command "$command". Available: ${available.join(', ')}.',
        exitCode: 64,
        details: {'available': available},
      );
    }
    final commandLine = architecture.commandLine(command);
    if (commandLine == null) {
      throw TekException(
        ErrorCodes.unsupportedPlatform,
        '${architecture.reference} does not provide an entrypoint for "$command" on ${Platform.operatingSystem}.',
      );
    }
    final [program, ...fixed] = commandLine;
    final arguments = [...fixed, ...args];
    if (!Platform.isWindows) return _Invocation(program, arguments);
    final isPackageFile = p.isAbsolute(program) && File(program).existsSync();
    return switch (p.extension(program).toLowerCase()) {
      '.exe' => _Invocation(program, arguments),
      '.cmd' || '.bat' => _Invocation(program, arguments, runInShell: true),
      '.ps1' => _Invocation('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', program, ...arguments]),
      _ when isPackageFile => _Invocation('sh', [program, ...arguments]),
      _ => _Invocation(program, arguments, runInShell: true),
    };
  }

  Future<Process> _start(
    _Invocation invocation,
    InstalledArchitecture architecture,
    String command,
    Map<String, String> parameters, {
    required bool json,
    required ProcessStartMode mode,
  }) async {
    final environment = {
      ...parameters,
      'TEK_VERSION': tekVersion,
      'TEK_HOME': home.root,
      'TEK_ARCHITECTURE': architecture.id,
      'TEK_ARCHITECTURE_VERSION': '${architecture.version}',
      'TEK_ARCHITECTURE_DIR': architecture.directory,
      'TEK_COMMANDS_DIR': architecture.commandsDir,
      'TEK_FILES_DIR': architecture.filesDir,
      'TEK_COMMAND': command,
      'TEK_JSON': json ? '1' : '0',
    };
    try {
      return await Process.start(
        invocation.executable,
        invocation.arguments,
        environment: environment,
        runInShell: invocation.runInShell,
        mode: mode,
      );
    } on ProcessException catch (e) {
      throw TekException(
        ErrorCodes.commandFailed,
        'Unable to start "$command" for ${architecture.reference}: ${e.message}',
      );
    }
  }
}
