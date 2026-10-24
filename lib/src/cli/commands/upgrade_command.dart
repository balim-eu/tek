import '../../architecture_ref.dart';
import '../../errors.dart';
import '../../install/installed_architecture.dart';
import '../../registry/registry.dart';
import '../../registry/updates.dart';
import 'tek_command.dart';

class UpgradeCommand extends TekCommand {
  UpgradeCommand(super.context) {
    argParser.addFlag('pre-release', negatable: false, help: 'Upgrade to pre-releases (-rc.N) too.');
  }

  @override
  String get name => 'upgrade';

  @override
  String get description => 'Upgrade installed architectures to the latest version of their registry.';

  @override
  String get invocation => 'tek upgrade [publisher/name...]';

  @override
  Future<int> run() async {
    final preRelease = argResults!.flag('pre-release');
    final ids = <String>{};
    for (final argument in rest) {
      final ref = ArchitectureRef.parse(argument);
      if (!ref.constraint.isLatest) {
        usageException('tek upgrade takes architectures without a version, e.g. ${ref.id}, not $argument.');
      }
      ids.add(ref.id);
    }

    final listing = await context.installed.all();
    for (final problem in listing.problems) {
      output.warning(problem.message);
    }
    final newest = <String, InstalledArchitecture>{};
    for (final architecture in listing.installed) {
      newest.putIfAbsent(architecture.id, () => architecture);
    }
    for (final id in ids) {
      if (!newest.containsKey(id)) {
        throw TekException(ErrorCodes.notInstalled, '$id is not installed. Install it with "tek install $id".');
      }
    }
    final selected = [
      for (final architecture in newest.values)
        if (ids.isEmpty || ids.contains(architecture.id)) architecture,
    ];

    final check = selected.isEmpty
        ? const UpdateCheck({}, [])
        : await output.step(
            'Checking for updates',
            () async => checkUpdates(await context.registries(), selected, preRelease: preRelease),
            done: (_) => null,
          );
    for (final failure in check.failures) {
      output.warning('Registry "${failure.registry.config.name}" is unavailable: ${failure.error.message}');
    }

    final upgraded = <(InstalledArchitecture, ResolvedArchitecture)>[];
    final failed = <(InstalledArchitecture, ResolvedArchitecture, TekException)>[];
    for (final architecture in selected) {
      final update = check.update(architecture);
      if (update == null) continue;
      try {
        await context.installer.install(update, progress: output);
        upgraded.add((architecture, update));
      } on TekException catch (e) {
        output.warning('Upgrading ${architecture.id} to ${update.versionNumber} failed: ${e.message}');
        failed.add((architecture, update, e));
      }
    }
    final current = [
      for (final architecture in selected)
        if (check.latest.containsKey(architecture.id) && check.update(architecture) == null) architecture,
    ];
    final unknown = [
      for (final architecture in selected)
        if (!check.latest.containsKey(architecture.id)) architecture,
    ];

    final data = {
      'preRelease': preRelease,
      'upgraded': [
        for (final (from, to) in upgraded) {'id': from.id, 'from': '${from.version}', 'to': '${to.versionNumber}'},
      ],
      'upToDate': [for (final architecture in current) architecture.id],
      if (unknown.isNotEmpty) 'notChecked': [for (final architecture in unknown) architecture.id],
      if (failed.isNotEmpty)
        'failed': [
          for (final (from, to, error) in failed)
            {'id': from.id, 'from': '${from.version}', 'to': '${to.versionNumber}', 'error': error.toJson()},
        ],
      if (check.failures.isNotEmpty) 'warnings': [for (final f in check.failures) f.toJson()],
    };
    if (output.json && failed.isNotEmpty) {
      output.result({'ok': false, ...data});
      return 1;
    }
    output.success(data, (out) {
      final style = output.style;
      if (selected.isEmpty) {
        out
          ..writeln(style.dim('No architectures installed.'))
          ..writeln(style.dim('Install one with: tek install <publisher/name>'));
        return;
      }
      for (final (from, to) in upgraded) {
        out.writeln('${style.update} ${style.id(from.id)} ${style.dim('${from.version}')} ${style.arrow} '
            '${style.version('${to.versionNumber}')}');
      }
      for (final (from, to, _) in failed) {
        out.writeln('${style.failure} ${style.id(from.id)} ${style.dim('${from.version}')} ${style.arrow} '
            '${style.version('${to.versionNumber}')} ${style.red('failed')}');
      }
      for (final architecture in unknown) {
        out.writeln('${style.warning} ${style.id(architecture.id)} ${style.dim('${architecture.version}')} '
            '${style.yellow(check.failures.isEmpty ? 'is in no registry' : 'was not checked')}');
      }
      final counts = [
        if (upgraded.isNotEmpty) '${upgraded.length} upgraded',
        if (failed.isNotEmpty) '${failed.length} failed',
        if (current.isNotEmpty) '${current.length} up to date',
        if (unknown.isNotEmpty) '${unknown.length} not checked',
      ].join(', ');
      if (upgraded.isNotEmpty || failed.isNotEmpty || unknown.isNotEmpty) out.writeln();
      final channel = preRelease ? ' ${style.dim('(pre-releases included)')}' : '';
      out.writeln(upgraded.isEmpty && failed.isEmpty && unknown.isEmpty
          ? '${style.success} ${selected.length == 1 ? '${selected.single.id} is' : 'Every architecture is'} up to date'
              '$channel'
          : '${failed.isEmpty ? style.success : style.failure} $counts$channel');
      if (upgraded.isNotEmpty) {
        out.writeln(
            style.dim('  The older versions stay installed, remove one with: tek uninstall <publisher/name@version>'));
      }
    });
    return failed.isEmpty ? 0 : 1;
  }
}
