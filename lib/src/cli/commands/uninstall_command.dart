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
  String get description => 'Remove one or more installed architectures from disk; their tools stay installed.';

  @override
  String get invocation => 'tek uninstall <publisher/name[@version]>...';

  @override
  Future<int> run() async {
    argument(0, 'publisher/name[@version]');
    final results = <Map<String, Object?>>[];
    final failures = <TekException>[];
    for (final input in rest) {
      try {
        results.add(await _uninstall(input));
      } on TekException catch (e) {
        if (e.code != ErrorCodes.notInstalled) rethrow;
        failures.add(e);
      }
    }
    if (results.isEmpty && failures.length == 1) throw failures.single;
    final style = output.style;
    final data = results.length == 1 && failures.isEmpty
        ? results.single
        : {
            'architectures': results,
            if (failures.isNotEmpty) 'notInstalled': [for (final failure in failures) failure.toJson()],
          };
    if (output.json) {
      output.result({'ok': failures.isEmpty, ...data});
    } else {
      for (final result in results) {
        final id = result['architecture'] as String;
        final versions = result['versions'] as List<String>;
        if (versions.isEmpty) stdout.writeln('${style.success} Uninstalled ${style.id(id)}');
        for (final version in versions) {
          stdout.writeln('${style.success} Uninstalled ${style.id(id)}${style.dim('@')}${style.version(version)}');
        }
        for (final path in result['removed'] as List<String>) {
          stdout.writeln(style.dim('  Removed ${displayPath(path)}'));
        }
        final remaining = result['remaining'] as List<String>;
        if (remaining.isNotEmpty) {
          stdout.writeln(style.dim('  Still installed: ${remaining.map((v) => '$id@$v').join(', ')}'));
        }
      }
      for (final failure in failures) {
        output.error(failure);
      }
    }
    return failures.isEmpty ? 0 : 1;
  }

  Future<Map<String, Object?>> _uninstall(String input) async {
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
    return {
      'architecture': ref.id,
      'versions': [for (final v in versions) '$v'],
      'removed': removed,
      'remaining': [for (final v in remaining) '$v'],
    };
  }

  Future<void> _deleteIfEmpty(Directory dir) async {
    if (!await dir.exists() || !p.isWithin(context.home.architecturesDir, dir.path)) return;
    if (await dir.list().isEmpty) await dir.delete();
  }
}
