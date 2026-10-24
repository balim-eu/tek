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
      for (final (index, MapEntry(key: id, value: versions)) in byId.entries.indexed) {
        final shown = versions.first;
        final update = updates[id];
        if (index > 0) out.writeln();
        final others = versions.skip(1).map((v) => '${v.version}').join(', ');
        out.writeln(
            '${style.id(id)} ${style.version('${shown.version}')}${others.isEmpty ? '' : style.dim(', $others')}'
            '${update == null ? '' : '  ${style.update} ${style.version('${update.versionNumber}')} available'}');
        if (shown.manifest.description != null) out.writeln('  ${shown.manifest.description}');
        final meta = [
          'commands ${shown.manifest.commands.keys.join(', ')}',
          if (shown.receipt.registry != null) 'registry ${shown.receipt.registry}',
          'installed ${shown.receipt.installedAt.toLocal().toIso8601String().substring(0, 10)}',
        ].join(' · ');
        out.writeln(style.dim('  $meta'));
        if (update != null) out.writeln(style.dim('  Update: tek install ${update.reference}'));
      }
      final count = byId.length;
      final versionCount = installed.length;
      out
        ..writeln()
        ..writeln(style.dim('$count architecture${count == 1 ? '' : 's'} installed'
            '${versionCount != count ? ' ($versionCount versions)' : ''} in ${displayPath(context.home.architecturesDir)}'));
      if (updates.isNotEmpty) {
        out.writeln('${style.update} ${updates.length} update${updates.length == 1 ? '' : 's'} available');
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
