import '../../errors.dart';
import '../../self/self_install.dart';
import '../../version.dart';
import '../terminal.dart';
import 'tek_command.dart';

class UpdateCommand extends TekCommand {
  UpdateCommand(super.context) {
    argParser
      ..addFlag('pre-release',
          negatable: false, help: 'Update to the latest pre-release (-rc.N) instead of the latest release.')
      ..addFlag('check', negatable: false, help: 'Only check whether an update is available.');
  }

  @override
  String get name => 'update';

  @override
  String get description => 'Update tek to the latest release.';

  @override
  Future<int> run() async {
    expectArguments(0);
    final output = this.output;
    final style = output.style;
    final preRelease = argResults!.flag('pre-release');
    final channel = preRelease ? 'pre-release' : 'stable';
    final current = CliVersion.tryParse(tekVersion);
    final latest = await output.step(
      'Checking for updates',
      () => CliReleases(context.fetcher).latest(preRelease: preRelease),
      done: (_) => null,
    );
    if (latest == null) {
      throw TekException(
        ErrorCodes.updateFailed,
        'No $channel releases of tek were found.${preRelease ? '' : ' Try "tek update --pre-release".'}',
      );
    }
    final available = current == null || latest.version > current;
    final command = 'tek update${preRelease ? ' --pre-release' : ''}';

    if (!available || argResults!.flag('check')) {
      output.success({
        'current': tekVersion,
        'latest': latest.tag,
        'channel': channel,
        'updateAvailable': available,
        'updated': false,
      }, (out) {
        if (available) {
          out
            ..writeln('${style.update} Update available: ${style.dim(tekVersion)} → ${style.version(latest.tag)}')
            ..writeln(style.dim('  Run: $command'));
        } else if (current != latest.version) {
          out.writeln(
              '${style.success} tek ${style.version(tekVersion)} is newer than the ${preRelease ? 'latest pre-release' : 'latest release'} '
              '${style.dim(latest.tag)}');
        } else {
          out.writeln('${style.success} tek ${style.version(tekVersion)} is up to date ${style.dim('($channel)')}');
        }
      });
      return 0;
    }

    final binary = installedBinary();
    if (binary == null) {
      throw TekException(
        ErrorCodes.updateFailed,
        'tek update only works for an installed tek binary. Reinstall with the install script instead.',
      );
    }
    await removeBinaryLeftovers(binary);
    await installRelease(latest, binary, context.fetcher, progress: output);

    output.success({
      'current': tekVersion,
      'latest': latest.tag,
      'channel': channel,
      'updateAvailable': true,
      'updated': true,
      'path': binary.path,
    }, (out) {
      out
        ..writeln('${style.success} Updated tek ${style.dim(tekVersion)} → ${style.version(latest.tag)}')
        ..writeln(style.dim('  ${displayPath(binary.path)}'));
    });
    return 0;
  }
}
