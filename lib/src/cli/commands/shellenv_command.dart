import 'dart:io';

import 'package:path/path.dart' as p;

import '../../errors.dart';
import '../../runtime/shell.dart';
import 'tek_command.dart';

const shells = ['zsh', 'bash', 'sh', 'fish', 'pwsh', 'dockerfile'];

class ShellenvCommand extends TekCommand {
  ShellenvCommand(super.context);

  @override
  String get name => 'shellenv';

  @override
  String get description => 'Print the PATH and the variables of the tools tek installed, for a shell or a Dockerfile.';

  @override
  String get invocation => 'tek shellenv [${shells.join('|')}]';

  @override
  Future<int> run() async {
    expectArguments(1);
    final shell = rest.isEmpty ? _currentShell() : rest.first;
    if (!shells.contains(shell)) {
      throw TekException(ErrorCodes.usage, 'tek shellenv knows ${shells.join(', ')}, not "$shell".', exitCode: 64);
    }
    final record = context.pathStore.read();
    final executable = tekExecutable;
    final script = shellenvScript(
      shell,
      record,
      Platform.environment,
      tekFolder: executable == null ? null : p.dirname(executable),
    );
    if (jsonMode) {
      output.result({
        'ok': true,
        'shell': shell,
        'folders': record.folderPaths,
        'env': {for (final MapEntry(:key, :value) in record.env.entries) key: value.value},
        'script': script,
      });
      return 0;
    }
    stdout.write(script);
    return 0;
  }

  String _currentShell() {
    final name = p.basename(Platform.environment['SHELL'] ?? '');
    return switch (name) {
      'fish' => 'fish',
      'pwsh' || 'powershell' => 'pwsh',
      'zsh' => 'zsh',
      'bash' => 'bash',
      _ => 'sh',
    };
  }
}
