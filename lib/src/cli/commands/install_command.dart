import '../../architecture_ref.dart';
import '../terminal.dart';
import 'tek_command.dart';

class InstallCommand extends TekCommand {
  InstallCommand(super.context) {
    argParser
      ..addOption('registry', abbr: 'r', help: 'Install from the named registry.')
      ..addFlag('force', abbr: 'f', negatable: false, help: 'Reinstall even if the version is already installed.');
  }

  @override
  String get name => 'install';

  @override
  String get description => 'Download, verify, and install an architecture.';

  @override
  String get invocation => 'tek install <publisher/name@version>';

  @override
  Future<int> run() async {
    final ref = ArchitectureRef.parse(argument(0, 'publisher/name@version'));
    expectArguments(1);
    final output = this.output;
    final style = output.style;
    final stopwatch = Stopwatch()..start();
    final registries = await context.registries();
    final resolved = await output.step(
      'Resolving $ref',
      () => registries.resolve(ref, registry: argResults!.option('registry')),
      done: (resolved) => ref.constraint.exact == null ? 'Resolved $ref to ${resolved.reference}' : null,
    );
    final result = await context.installer.install(resolved, force: argResults!.flag('force'), progress: output);
    final installed = result.installed;
    final seconds = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);

    output.success({
      'architecture': installed.id,
      'version': '${installed.version}',
      'installed': true,
      'alreadyInstalled': result.alreadyInstalled,
      'sha256': installed.receipt.sha256,
      'registry': resolved.registry.config.name,
      'path': installed.directory,
      'commands': installed.manifest.commands.keys.toList(),
    }, (out) {
      final reference = '${style.id(installed.id)}${style.dim('@')}${style.version('${installed.version}')}';
      out
        ..writeln(result.alreadyInstalled
            ? '${style.success} $reference is already installed'
            : '${style.success} Installed $reference ${style.dim('in ${seconds}s')}')
        ..writeln();
      writeTable(
          out,
          [
            ('Location', displayPath(installed.directory)),
            ('Commands', installed.manifest.commands.keys.map(style.command).join(', ')),
            ('Help', 'tek ${installed.id} --help'),
          ],
          key: style.dim);
    });
    return 0;
  }
}
