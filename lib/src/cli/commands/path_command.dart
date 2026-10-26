import 'dart:io';

import 'package:path/path.dart' as p;

import '../../runtime/shell.dart';
import '../terminal.dart';
import 'tek_command.dart';

const _systemFolders = {'/usr/bin', '/bin', '/usr/sbin', '/sbin', '/usr/local/bin', '/usr/local/sbin'};
const _systemPrefixes = ['/usr/', '/System/', '/Library/Apple/', '/opt/homebrew/', '/snap/', '/Applications/'];

class PathCommand extends TekCommand {
  PathCommand(super.context) {
    argParser.addFlag('remove',
        negatable: false,
        help: "Take tek's line out of the shell profiles, its links out of /usr/local/bin and forget what it recorded. "
            'The tools stay installed.');
  }

  @override
  String get name => 'path';

  @override
  String get description => 'List PATH, each folder marked tek, system or yours, or undo what tek added to it.';

  @override
  String get invocation => 'tek path [--remove]';

  @override
  Future<int> run() async {
    expectArguments(0);
    if (argResults!.flag('remove')) return _remove();
    final record = context.pathStore.read();
    final executable = tekExecutable;
    final tekFolder = executable == null ? null : p.dirname(executable);
    final entries = [
      for (final folder in (Platform.environment['PATH'] ?? '').split(':'))
        if (folder.isNotEmpty) folder,
    ];
    String label(String folder) {
      if (record.folderPaths.contains(folder) || folder == tekFolder) return 'tek';
      if (_systemFolders.contains(folder) || _systemPrefixes.any(folder.startsWith)) return 'system';
      return 'yours';
    }

    String? toolOf(String folder) {
      for (final recorded in record.folders) {
        if (recorded.path == folder) return recorded.tool;
      }
      return folder == tekFolder ? 'tek itself' : null;
    }

    final off = [
      for (final folder in record.folderPaths)
        if (!entries.contains(folder)) folder
    ];
    output.success({
      'path': [
        for (final folder in entries)
          {'folder': folder, 'kind': label(folder), if (toolOf(folder) != null) 'tool': toolOf(folder)},
      ],
      'notOnPath': off,
      'env': {for (final MapEntry(:key, :value) in record.env.entries) key: value.toJson()},
      'profiles': record.profiles,
      'links': record.links,
    }, (out) {
      final style = output.style;
      for (final folder in entries) {
        final kind = label(folder);
        final tool = toolOf(folder);
        final styled = switch (kind) {
          'tek' => style.cyan(kind.padRight(6)),
          'system' => style.dim(kind.padRight(6)),
          _ => kind.padRight(6)
        };
        out.writeln('  $styled ${displayPath(folder)}${tool == null ? '' : style.dim('  $tool')}');
      }
      for (final folder in off) {
        out.writeln(
            '  ${style.yellow('off   ')} ${displayPath(folder)}${style.dim('  not on PATH in this shell: eval "\$(tek shellenv)"')}');
      }
      if (record.env.isNotEmpty) {
        out
          ..writeln()
          ..writeln(style.heading('Variables'));
        for (final MapEntry(:key, :value) in record.env.entries) {
          final set = Platform.environment[key];
          out.writeln(
              '  $key=${value.value}${style.dim('  ${value.tool}${set == null ? ', not set in this shell' : ''}')}');
        }
      }
      if (record.profiles.isNotEmpty) {
        out
          ..writeln()
          ..writeln(style.dim('The tek shellenv line is in ${record.profiles.map(displayPath).join(', ')}.'));
      }
    });
    return 0;
  }

  int _remove() {
    final store = context.pathStore;
    final record = store.read();
    final removed = <String>[];
    final problems = <String>[];
    for (final profile in record.profiles) {
      try {
        if (removeTekLine(profile)) removed.add('the tek shellenv line from ${displayPath(profile)}');
      } on FileSystemException catch (e) {
        problems.add('${displayPath(profile)}: ${e.osError?.message ?? e.message}');
      }
    }
    for (final link in record.links) {
      try {
        if (FileSystemEntity.isLinkSync(link)) {
          Link(link).deleteSync();
          removed.add(link);
        }
      } on FileSystemException catch (e) {
        problems.add('$link: ${e.osError?.message ?? e.message}');
      }
    }
    if (record.profileD case final file?) {
      try {
        if (File(file).existsSync()) {
          File(file).deleteSync();
          removed.add(file);
        }
      } on FileSystemException catch (e) {
        problems.add('$file: ${e.osError?.message ?? e.message}');
      }
    }
    if (problems.isEmpty) store.write(PathRecord());
    output.success({'removed': removed, 'problems': problems}, (out) {
      final style = output.style;
      for (final item in removed) {
        out.writeln('${style.success} Removed $item');
      }
      for (final problem in problems) {
        out.writeln('${style.failure} ${style.red(problem)}');
      }
      if (removed.isEmpty && problems.isEmpty) out.writeln('${style.success} tek added nothing to PATH.');
      if (problems.isEmpty) out.writeln(style.dim('The tools stay installed; doctor shows the ones off PATH again.'));
    });
    return problems.isEmpty ? 0 : 1;
  }
}
