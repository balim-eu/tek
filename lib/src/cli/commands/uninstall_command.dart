import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../../architecture_ref.dart';
import '../../errors.dart';
import '../terminal.dart';
import 'tek_command.dart';

class UninstallCommand extends TekCommand {
  UninstallCommand(super.context);

  @override
  String get name => 'uninstall';

  @override
  String get description => 'Remove an installed architecture from disk.';

  @override
  String get invocation => 'tek uninstall <publisher/name[@version]>';

  @override
  Future<int> run() async {
    final input = argument(0, 'publisher/name[@version]');
    expectArguments(1);
    final ref = ArchitectureRef.parse(input);
    final home = context.home;
    final architectureDir = Directory(home.architectureDir(ref.id));
    final installed = await context.installed.versions(ref.id);
    final allVersions = !input.contains('@');

    final List<Version> versions;
    if (allVersions) {
      versions = installed;
    } else if (ref.constraint.exact case final exact?) {
      versions = await Directory(home.versionDir(ref.id, '$exact')).exists() ? [exact] : [];
    } else if (ref.constraint.isLatest) {
      final latest = ref.constraint.select(installed);
      versions = [if (latest != null) latest];
    } else {
      versions = installed.where(ref.constraint.allows).toList();
    }

    final removeArchitecture = allVersions && await architectureDir.exists();
    if (versions.isEmpty && !removeArchitecture) {
      throw TekException(
        ErrorCodes.notInstalled,
        installed.isEmpty
            ? '${ref.id} is not installed.'
            : 'No installed version of ${ref.id} matches "${ref.constraint.text}". Installed: ${installed.join(', ')}.',
        details: {
          'installed': [for (final v in installed) '$v']
        },
      );
    }

    final removed = <String>[];
    if (removeArchitecture) {
      await architectureDir.delete(recursive: true);
      removed.add(architectureDir.path);
    } else {
      for (final version in versions) {
        final dir = Directory(home.versionDir(ref.id, '$version'));
        await dir.delete(recursive: true);
        removed.add(dir.path);
      }
      await _deleteIfEmpty(architectureDir);
    }
    await _deleteIfEmpty(architectureDir.parent);
    final remaining = installed.where((v) => !versions.contains(v)).toList();

    output.success({
      'architecture': ref.id,
      'versions': [for (final v in versions) '$v'],
      'removed': removed,
      'remaining': [for (final v in remaining) '$v'],
    }, (out) {
      final style = output.style;
      if (versions.isEmpty) out.writeln('${style.success} Uninstalled ${style.id(ref.id)}');
      for (final version in versions) {
        out.writeln('${style.success} Uninstalled ${style.id(ref.id)}${style.dim('@')}${style.version('$version')}');
      }
      for (final path in removed) {
        out.writeln(style.dim('  Removed ${displayPath(path)}'));
      }
      if (remaining.isNotEmpty) {
        out.writeln(style.dim('  Still installed: ${remaining.map((v) => '${ref.id}@$v').join(', ')}'));
      }
    });
    return 0;
  }

  Future<void> _deleteIfEmpty(Directory dir) async {
    if (!await dir.exists() || !p.isWithin(context.home.architecturesDir, dir.path)) return;
    if (await dir.list().isEmpty) await dir.delete();
  }
}
