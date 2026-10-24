import '../../architecture_ref.dart';
import '../../install/installed_architecture.dart';
import '../../registry/updates.dart';
import '../terminal.dart';
import 'tek_command.dart';

class ListCommand extends TekCommand {
  ListCommand(super.context) {
    argParser
      ..addFlag('pre-release', negatable: false, help: 'Count pre-releases (-rc.N) as updates too.')
      ..addFlag('offline', negatable: false, help: 'Skip the check of the registries for newer versions.');
  }

  @override
  String get name => 'list';

  @override
  List<String> get aliases => const ['ls'];

  @override
  String get description => 'List installed architectures and the newer versions their registries have.';

  @override
  String get invocation => 'tek list [publisher/name[@version]]';

  @override
  Future<int> run() async {
    expectArguments(1);
    final all = await _installed();
    final filter = rest.isEmpty ? null : ArchitectureRef.parse(rest.first);
    final installed = [
      for (final architecture in all)
        if (filter == null || (architecture.id == filter.id && filter.constraint.allows(architecture.version)))
          architecture,
    ];
    final empty = filter == null ? 'No architectures installed.' : 'No installed version of ${filter.id} matches.';

    final byId = <String, List<InstalledArchitecture>>{};
    for (final architecture in installed) {
      byId.putIfAbsent(architecture.id, () => []).add(architecture);
    }
    final newest = <String, InstalledArchitecture>{
      for (final architecture in all.reversed)
        if (byId.containsKey(architecture.id)) architecture.id: architecture,
    };

    final preRelease = argResults!.flag('pre-release');
    final check = argResults!.flag('offline') || byId.isEmpty ? null : await _checkUpdates(newest.values, preRelease);
    final updates = {
      for (final MapEntry(key: id, value: architecture) in newest.entries)
        if (check?.update(architecture) case final update?) id: update,
    };

    output.success({
      'architectures': [
        for (final MapEntry(key: id, value: versions) in byId.entries)
          {
            'id': id,
            if (check?.latest[id] case final latest?) ...{
              'latest': '${latest.versionNumber}',
              'updateAvailable': updates.containsKey(id),
            },
            'versions': [
              for (final v in versions)
                {
                  'version': '${v.version}',
                  'path': v.directory,
                  'installedAt': v.receipt.installedAt.toUtc().toIso8601String(),
                  if (v.receipt.registry != null) 'registry': v.receipt.registry,
                  'commands': v.manifest.commands.keys.toList(),
                },
            ],
          },
      ],
      if (check != null && check.failures.isNotEmpty) 'warnings': [for (final f in check.failures) f.toJson()],
    }, (out) {
      final style = output.style;
      if (byId.isEmpty) {
        out
          ..writeln(style.dim(empty))
          ..writeln(style.dim('Install one with: tek install <publisher/name>'));
        return;
      }
      final rows = <List<Cell>>[];
      for (final MapEntry(key: id, value: versions) in byId.entries) {
        final newest = '${versions.first.version}';
        final more = versions.length > 3 ? ' +${versions.length - 3}' : '';
        final shown = [for (final v in versions.take(3)) '${v.version}'].join(', ') + more;
        final update = updates[id]?.versionNumber;
        final registry = versions.first.receipt.registry ?? '';
        final installed = versions.first.receipt.installedAt.toLocal().toIso8601String().substring(0, 10);
        rows.add([
          (id, style.id(id)),
          (shown, '${style.version(newest)}${style.dim(shown.substring(newest.length))}'),
          if (check != null) update == null ? ('', '') : ('↑ $update', '${style.update} ${style.version('$update')}'),
          (registry, registry),
          (installed, style.dim(installed)),
        ]);
      }
      writeColumns(out, style, ['ARCHITECTURE', 'VERSION', if (check != null) 'UPDATE', 'REGISTRY', 'INSTALLED'], rows);
      final count = byId.length;
      final versionCount = installed.length;
      out
        ..writeln()
        ..writeln(style.dim('$count architecture${count == 1 ? '' : 's'} installed'
            '${versionCount != count ? ' ($versionCount versions)' : ''} in ${displayPath(context.home.architecturesDir)}'));
      if (updates.isNotEmpty) {
        out.writeln('${style.update} ${updates.length} update${updates.length == 1 ? '' : 's'} available, '
            'upgrade with: tek upgrade${preRelease ? ' --pre-release' : ''}');
      } else if (check != null && check.failures.isEmpty) {
        out.writeln('${style.success} Up to date${preRelease ? ' ${style.dim('(pre-releases included)')}' : ''}');
      }
    });
    return 0;
  }

  Future<List<InstalledArchitecture>> _installed() async {
    final listing = await context.installed.all();
    for (final problem in listing.problems) {
      output.warning(problem.message);
    }
    return listing.installed;
  }

  Future<UpdateCheck> _checkUpdates(Iterable<InstalledArchitecture> newest, bool preRelease) async {
    final registries = await context.registries();
    final check = await output.step(
      'Checking for updates',
      () => checkUpdates(registries, newest, preRelease: preRelease),
      done: (_) => null,
    );
    for (final failure in check.failures) {
      output.warning('Registry "${failure.registry.config.name}" is unavailable: ${failure.error.message}');
    }
    return check;
  }
}
