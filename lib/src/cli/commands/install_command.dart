import '../../architecture_ref.dart';
import '../../registry/registry.dart';
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
  String get description => 'Download, verify, and install one or more architectures.';

  @override
  String get invocation => 'tek install <publisher/name@version>...';

  @override
  Future<int> run() async {
    argument(0, 'publisher/name@version');
    final refs = [for (final input in rest) ArchitectureRef.parse(input)];
    final output = this.output;
    final style = output.style;
    final registries = await context.registries();
    // Every architecture resolves before any installs, so one that doesn't stops the command with nothing installed.
    final resolved = <ResolvedArchitecture>[];
    for (final ref in refs) {
      resolved.add(await output.step(
        'Resolving $ref',
        () => registries.resolve(ref, registry: argResults!.option('registry')),
        done: (resolved) => ref.constraint.exact == null ? 'Resolved $ref to ${resolved.reference}' : null,
      ));
    }
    final results = <Map<String, Object?>>[];
    final lines = <void Function(StringSink)>[];
    for (final architecture in resolved) {
      final stopwatch = Stopwatch()..start();
      final result = await context.installer.install(architecture, force: argResults!.flag('force'), progress: output);
      final installed = result.installed;
      final seconds = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      results.add({
        'architecture': installed.id,
        'version': '${installed.version}',
        'installed': true,
        'alreadyInstalled': result.alreadyInstalled,
        'sha256': installed.receipt.sha256,
        'registry': architecture.registry.config.name,
        'path': installed.directory,
        'commands': installed.manifest.commands.keys.toList(),
      });
      lines.add((out) {
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
    }
    await context.toolCatalog(refresh: true);
    output.success(results.length == 1 ? results.single : {'architectures': results}, (out) {
      for (final (index, line) in lines.indexed) {
        if (index > 0) out.writeln();
        line(out);
      }
    });
    return 0;
  }
}
