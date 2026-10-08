import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import '../install/installed_architecture.dart';
import '../tek_home.dart';
import '../version.dart';

class CapturedRun {
  const CapturedRun(this.exitCode, this.stdout);

  final int exitCode;
  final String stdout;
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
    await _prepare(architecture, command);
    final process = await _start(
      architecture,
      command,
      args,
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
    await _prepare(architecture, command);
    final process = await _start(
      architecture,
      command,
      args,
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

  Future<void> _prepare(InstalledArchitecture architecture, String command) async {
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
  }

  Future<Process> _start(
    InstalledArchitecture architecture,
    String command,
    List<String> args,
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
      'TEK_COMMAND': command,
      'TEK_JSON': json ? '1' : '0',
    };
    try {
      return await Process.start(
        architecture.executable,
        args,
        environment: environment,
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
