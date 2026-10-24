import '../terminal.dart';
import 'tek_command.dart';

class SearchCommand extends TekCommand {
  SearchCommand(super.context) {
    argParser.addOption('registry', abbr: 'r', help: 'Only search the named registry.');
  }

  @override
  String get name => 'search';

  @override
  String get description => 'List the architectures of the configured registries, with a query those whose name '
      'contains it.';

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
        out.writeln(style.dim(query.isEmpty ? 'No architectures found.' : 'No architecture name contains "$query".'));
        if (query.isNotEmpty) out.writeln(style.dim('List them all with: tek search'));
        return;
      }
      final names = {for (final hit in results.hits) hit.registry.config.name};
      final rows = <List<Cell>>[];
      for (final hit in results.hits) {
        final architecture = hit.architecture;
        final version = '${architecture.latest ?? architecture.versionNumbers.lastOrNull ?? ''}';
        final description = firstSentence(architecture.description ?? '');
        rows.add([
          (architecture.id, style.id(architecture.id)),
          (version, style.version(version)),
          if (names.length > 1) (hit.registry.config.name, hit.registry.config.name),
          (description, description),
        ]);
      }
      writeColumns(out, style, ['ARCHITECTURE', 'LATEST', if (names.length > 1) 'REGISTRY', 'DESCRIPTION'], rows,
          width: terminalWidth());
      final count = results.hits.length;
      final found = query.isEmpty
          ? '$count architecture${count == 1 ? '' : 's'}${names.length == 1 ? ' in ${names.single}' : ''}'
          : '$count architecture${count == 1 ? '' : 's'} whose name contains "$query"';
      out
        ..writeln()
        ..writeln(style.dim('$found · versions and commands: tek info <architecture>'));
    });
    return 0;
  }
}
