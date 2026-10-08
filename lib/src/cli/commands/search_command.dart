import 'tek_command.dart';

class SearchCommand extends TekCommand {
  SearchCommand(super.context) {
    argParser.addOption('registry', abbr: 'r', help: 'Only search the named registry.');
  }

  @override
  String get name => 'search';

  @override
  String get description => 'Search configured registries for architectures.';

  @override
  String get invocation => 'tek search [query]';

  @override
  Future<int> run() async {
    final query = rest.join(' ');
    final registries = await context.registries();
    final results = await output.step(
      'Searching registries',
      () => registries.search(query, registry: argResults!.option('registry')),
      done: (_) => null,
    );
    for (final failure in results.failures) {
      output.warning('Registry "${failure.registry.config.name}" is unavailable: ${failure.error.message}');
    }

    output.success({
      'query': query,
      'architectures': [
        for (final hit in results.hits)
          {
            'id': hit.architecture.id,
            'publisher': hit.architecture.publisher,
            'name': hit.architecture.name,
            if (hit.architecture.description != null) 'description': hit.architecture.description,
            'registry': hit.registry.config.name,
            if (hit.architecture.latest != null) 'latest': '${hit.architecture.latest}',
            'versions': [for (final v in hit.architecture.versionNumbers) '$v'],
          },
      ],
      if (results.failures.isNotEmpty) 'warnings': [for (final f in results.failures) f.toJson()],
    }, (out) {
      final style = output.style;
      if (results.hits.isEmpty) {
        out.writeln(style.dim(query.isEmpty ? 'No architectures found.' : 'No architectures found matching "$query".'));
        return;
      }
      for (final (index, hit) in results.hits.indexed) {
        final architecture = hit.architecture;
        final latest = architecture.latest;
        if (index > 0) out.writeln();
        out.writeln('${style.id(architecture.id)}${latest == null ? '' : ' ${style.version('$latest')}'}');
        if (architecture.description != null) out.writeln('  ${architecture.description}');
        final versions = architecture.versionNumbers.reversed.map((v) => '$v').toList();
        final shown = versions.take(5).join(', ');
        final more = versions.length > 5 ? ' +${versions.length - 5} more' : '';
        out.writeln(style.dim('  versions $shown$more · registry ${hit.registry.config.name}'));
      }
      final count = results.hits.length;
      out
        ..writeln()
        ..writeln(style.dim('$count architecture${count == 1 ? '' : 's'} found'));
    });
    return 0;
  }
}
