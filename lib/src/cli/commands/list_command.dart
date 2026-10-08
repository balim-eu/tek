import '../../architecture_ref.dart';
import '../../install/installed_architecture.dart';
import '../terminal.dart';
import 'tek_command.dart';

class ListCommand extends TekCommand {
  ListCommand(super.context);

  @override
  String get name => 'list';

  @override
  List<String> get aliases => const ['ls'];

  @override
  String get description => 'List installed architectures.';

  @override
  String get invocation => 'tek list [publisher/name[@version]]';

  @override
  Future<int> run() async {
    expectArguments(1);
    final installed = await _installed();
    final empty = rest.isEmpty
        ? 'No architectures installed.'
        : 'No installed version of ${ArchitectureRef.parse(rest.first).id} matches.';

    final byId = <String, List<InstalledArchitecture>>{};
    for (final architecture in installed) {
      byId.putIfAbsent(architecture.id, () => []).add(architecture);
    }

    output.success({
      'architectures': [
        for (final MapEntry(key: id, value: versions) in byId.entries)
          {
            'id': id,
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
    }, (out) {
      final style = output.style;
      if (byId.isEmpty) {
        out
          ..writeln(style.dim(empty))
          ..writeln(style.dim('Install one with: tek install <publisher/name>'));
        return;
      }
      for (final (index, MapEntry(key: id, value: versions)) in byId.entries.indexed) {
        final newest = versions.first;
        if (index > 0) out.writeln();
        final others = versions.skip(1).map((v) => '${v.version}').join(', ');
        out.writeln(
            '${style.id(id)} ${style.version('${newest.version}')}${others.isEmpty ? '' : style.dim(', $others')}');
        if (newest.manifest.description != null) out.writeln('  ${newest.manifest.description}');
        final meta = [
          'commands ${newest.manifest.commands.keys.join(', ')}',
          if (newest.receipt.registry != null) 'registry ${newest.receipt.registry}',
          'installed ${newest.receipt.installedAt.toLocal().toIso8601String().substring(0, 10)}',
        ].join(' · ');
        out.writeln(style.dim('  $meta'));
      }
      final count = byId.length;
      final versionCount = installed.length;
      out
        ..writeln()
        ..writeln(style.dim('$count architecture${count == 1 ? '' : 's'} installed'
            '${versionCount != count ? ' ($versionCount versions)' : ''} in ${displayPath(context.home.architecturesDir)}'));
    });
    return 0;
  }

  Future<List<InstalledArchitecture>> _installed() async {
    final listing = await context.installed.all();
    for (final problem in listing.problems) {
      output.warning(problem.message);
    }
    if (rest.isEmpty) return listing.installed;
    final filter = ArchitectureRef.parse(rest.first);
    return [
      for (final architecture in listing.installed)
        if (architecture.id == filter.id && filter.constraint.allows(architecture.version)) architecture,
    ];
  }
}
