import '../../host.dart';
import '../../architecture_ref.dart';
import '../../errors.dart';
import '../../install/installed_architecture.dart';
import '../../manifest.dart';
import '../../registry/registry.dart';
import '../terminal.dart';
import 'tek_command.dart';

const _offlineFallback = {
  ErrorCodes.architectureNotFound,
  ErrorCodes.versionNotFound,
  ErrorCodes.registryUnavailable,
  ErrorCodes.noRegistries,
};

class InfoCommand extends TekCommand {
  InfoCommand(super.context) {
    argParser.addOption('registry', abbr: 'r', help: 'Resolve the architecture from the named registry.');
  }

  @override
  String get name => 'info';

  @override
  String get description => 'Show details about an architecture version.';

  @override
  String get invocation => 'tek info <publisher/name@version>';

  @override
  Future<int> run() async {
    final ref = ArchitectureRef.parse(argument(0, 'publisher/name@version'));
    expectArguments(1);

    ResolvedArchitecture? resolved;
    TekException? registryError;
    try {
      resolved = await (await context.registries()).resolve(ref, registry: argResults!.option('registry'));
    } on TekException catch (e) {
      if (!_offlineFallback.contains(e.code)) rethrow;
      registryError = e;
    }

    InstalledArchitecture? installed;
    Manifest? manifest;
    if (resolved != null) {
      installed = await _installed(resolved.id, resolved);
      try {
        manifest = await resolved.registry.manifest(resolved.architecture, resolved.version);
      } on TekException catch (e) {
        output.warning('Unable to load manifest: ${e.message}');
      }
      manifest ??= installed?.manifest;
    } else {
      installed = await context.installed.select(ref);
      if (installed == null) throw registryError!;
      manifest = installed.manifest;
      output.warning('${registryError!.message} Showing the installed copy.');
    }

    final id = resolved?.id ?? installed!.id;
    final version = '${resolved?.versionNumber ?? installed!.version}';
    final description = manifest?.description ?? resolved?.architecture.description;
    final versions = resolved?.architecture.versionNumbers;
    final latest = resolved?.architecture.latest;

    output.success({
      'architecture': id,
      'version': version,
      'source': resolved != null ? 'registry' : 'installed',
      if (manifest != null) 'name': manifest.name,
      if (description != null) 'description': description,
      if (manifest != null) 'publisher': manifest.publisher.toJson(),
      if (manifest?.license != null) 'license': manifest!.license,
      if (manifest != null) 'commands': [for (final c in manifest.commands.values) c.toJson()],
      if (manifest != null) 'runtime': manifest.toJson()['runtime'],
      if (resolved != null) 'registry': resolved.registry.config.name,
      if (resolved?.version.artifactFor(hostPlatform) case final artifact?) 'artifact': artifact.toJson(),
      if (resolved != null && resolved.version.artifacts.isNotEmpty)
        'platforms': resolved.version.artifacts.keys.toList(),
      if (resolved?.version.release != null) 'release': '${resolved!.version.release}',
      if (versions != null) 'versions': [for (final v in versions) '$v'],
      if (latest != null) 'latest': '$latest',
      'installed': installed != null,
      if (installed != null) 'path': installed.directory,
    }, (out) {
      final style = output.style;
      final title = manifest != null && manifest.name != id ? '  ${style.bold(manifest.name)}' : '';
      out.writeln('${style.id(id)}${style.dim('@')}${style.version(version)}$title');
      if (description != null) out.writeln(description);
      out.writeln();
      writeTable(
          out,
          [
            if (manifest != null) ('Publisher', manifest.publisher.displayName),
            if (manifest?.license != null) ('License', manifest!.license!),
            if (resolved != null) ('Registry', resolved.registry.config.name),
            ('Installed', installed != null ? displayPath(installed.directory) : style.dim('no')),
            if (resolved != null && resolved.version.artifacts.isNotEmpty)
              ('Platforms', resolved.version.artifacts.keys.join(', ')),
            if (resolved?.version.artifactFor(hostPlatform) case final artifact?) ...[
              ('Package', style.dim('${artifact.url}')),
              ('SHA-256', style.dim(artifact.sha256)),
            ],
          ],
          indent: '',
          key: style.dim);
      if (manifest != null) {
        out
          ..writeln()
          ..writeln(style.heading('Commands'));
        writeTable(
            out,
            [
              for (final c in manifest.commands.values)
                (c.aliases.isEmpty ? c.name : '${c.name} (${c.aliases.join(', ')})', c.description ?? ''),
            ],
            key: style.command);
        if (manifest.requirements.isNotEmpty) {
          out
            ..writeln()
            ..writeln(style.heading('Requirements'));
          writeTable(out, [for (final r in manifest.requirements) (r.tool, r.version ?? 'any')]);
        }
      }
      if (versions != null) {
        out
          ..writeln()
          ..writeln(style.heading('Versions'));
        final newest = versions.reversed.toList();
        for (final v in newest.take(10)) {
          out.writeln(v == latest ? '  ${style.version('$v')} ${style.dim('latest')}' : '  $v');
        }
        if (newest.length > 10) out.writeln(style.dim('  +${newest.length - 10} older'));
      }
      out
        ..writeln()
        ..writeln(style.dim('Run: tek $id --help'));
    });
    return 0;
  }

  Future<InstalledArchitecture?> _installed(String id, ResolvedArchitecture resolved) async {
    try {
      return await context.installed.find(id, resolved.versionNumber);
    } on TekException {
      return null;
    }
  }
}
