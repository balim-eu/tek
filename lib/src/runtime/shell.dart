import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'checker.dart';
import 'system.dart';

/// A folder tek made visible to shells, and the tool it did it for.
class RecordedFolder {
  const RecordedFolder(this.path, this.tool);

  final String path;
  final String tool;

  Map<String, Object?> toJson() => {'path': path, 'tool': tool};
}

/// A variable tek sets in shells, and the tool it did it for.
class RecordedVariable {
  const RecordedVariable(this.value, this.tool);

  final String value;
  final String tool;

  Map<String, Object?> toJson() => {'value': value, 'tool': tool};
}

/// ~/.tek/path.json: everything tek made visible to shells, so tek path can label it and tek path --remove undo it.
class PathRecord {
  PathRecord({
    List<RecordedFolder>? folders,
    Map<String, RecordedVariable>? env,
    List<String>? profiles,
    List<String>? links,
    this.profileD,
  })  : folders = folders ?? [],
        env = env ?? {},
        profiles = profiles ?? [],
        links = links ?? [];

  final List<RecordedFolder> folders;
  final Map<String, RecordedVariable> env;

  /// The shell profiles tek wrote its line into.
  final List<String> profiles;

  /// The links tek made in /usr/local/bin, as root.
  final List<String> links;

  /// /etc/profile.d/tek.sh when tek wrote it, as root.
  String? profileD;

  bool get isEmpty => folders.isEmpty && env.isEmpty && profiles.isEmpty && links.isEmpty && profileD == null;

  List<String> get folderPaths => [for (final folder in folders) folder.path];

  Map<String, Object?> toJson() => {
        'folders': [for (final folder in folders) folder.toJson()],
        'env': {for (final MapEntry(:key, :value) in env.entries) key: value.toJson()},
        'profiles': profiles,
        'links': links,
        if (profileD != null) 'profileD': profileD,
      };

  static PathRecord fromJson(Object? json) {
    if (json is! Map) return PathRecord();
    final folders = json['folders'], env = json['env'], profiles = json['profiles'], links = json['links'];
    return PathRecord(
      folders: [
        if (folders is List)
          for (final folder in folders)
            if (folder is Map && folder['path'] is String) RecordedFolder(folder['path'], '${folder['tool'] ?? ''}'),
      ],
      env: {
        if (env is Map)
          for (final MapEntry(:key, :value) in env.entries)
            if (value is Map && value['value'] is String)
              '$key': RecordedVariable(value['value'], '${value['tool'] ?? ''}'),
      },
      profiles: [
        if (profiles is List)
          for (final profile in profiles) '$profile'
      ],
      links: [
        if (links is List)
          for (final link in links) '$link'
      ],
      profileD: json['profileD'] as String?,
    );
  }
}

class PathStore {
  PathStore(this.path);

  final String path;

  PathRecord read() {
    final file = File(path);
    if (!file.existsSync()) return PathRecord();
    try {
      return PathRecord.fromJson(jsonDecode(file.readAsStringSync()));
    } on FormatException {
      return PathRecord();
    }
  }

  void write(PathRecord record) {
    final file = File(path);
    if (record.isEmpty) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(record.toJson())}\n');
  }
}

/// What tek did to make new folders and variables visible.
class ShellChanges {
  const ShellChanges({this.profiles = const [], this.links = const [], this.github = false, this.profileD});

  final List<String> profiles;
  final List<String> links;
  final bool github;
  final String? profileD;

  bool get isEmpty => profiles.isEmpty && links.isEmpty && !github && profileD == null;
}

/// Makes the folders and variables of [record] visible where each kind of shell looks: the tek shellenv line in the
/// profiles of a person's shells, links in /usr/local/bin and /etc/profile.d/tek.sh as root, and $GITHUB_PATH and
/// $GITHUB_ENV in GitHub Actions. [added] and [addedEnv] are what is new since the last time.
ShellChanges applyShellChanges(
  PathRecord record,
  HostSystem host, {
  required List<String> added,
  required Map<String, String> addedEnv,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  if (Platform.isWindows) return const ShellChanges();
  var github = false;
  if (env['GITHUB_PATH'] case final file? when file.isNotEmpty && added.isNotEmpty) {
    File(file).writeAsStringSync('${added.join('\n')}\n', mode: FileMode.append);
    github = true;
  }
  if (env['GITHUB_ENV'] case final file? when file.isNotEmpty && addedEnv.isNotEmpty) {
    File(file).writeAsStringSync(
      '${[for (final MapEntry(:key, :value) in addedEnv.entries) '$key=$value'].join('\n')}\n',
      mode: FileMode.append,
    );
    github = true;
  }
  if (host.root) {
    final links = <String>[];
    for (final folder in record.folderPaths) {
      final directory = Directory(folder);
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync()) {
        if (entity is Directory) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.') || findOnPath(name, folder) == null) continue;
        final link = p.join('/usr/local/bin', name);
        if (FileSystemEntity.typeSync(link, followLinks: false) != FileSystemEntityType.notFound) continue;
        Link(link).createSync(entity.path);
        links.add(link);
        record.links.add(link);
      }
    }
    String? profileD;
    if (record.env.isNotEmpty) {
      const file = '/etc/profile.d/tek.sh';
      File(file).writeAsStringSync([
        '# The variables of the tools tek installed, see tek path.',
        for (final MapEntry(:key, :value) in record.env.entries) 'export $key="${_escapeDouble(value.value)}"',
        '',
      ].join('\n'));
      record.profileD = file;
      profileD = file;
    }
    return ShellChanges(links: links, github: github, profileD: profileD);
  }
  final profiles = <String>[];
  if (added.isNotEmpty || addedEnv.isNotEmpty) {
    for (final (profile, line) in profileLines(host, env)) {
      if (record.profiles.contains(profile) && _hasLine(profile)) continue;
      if (_writeLine(profile, line)) profiles.add(profile);
      if (!record.profiles.contains(profile)) record.profiles.add(profile);
    }
  }
  return ShellChanges(profiles: profiles, github: github);
}

/// The executable of tek that the profiles' line runs, null when tek runs from its sources with dart.
String? get tekExecutable {
  final executable = Platform.resolvedExecutable;
  final name = p.basenameWithoutExtension(executable);
  return name == 'tek' ? executable : null;
}

/// The profiles of this person's shells and the line each gets, e.g. ~/.zshrc and
/// [ -x "$HOME/.local/bin/tek" ] && eval "$("$HOME/.local/bin/tek" shellenv)".
List<(String, String)> profileLines(HostSystem host, Map<String, String> environment) {
  final home = environment['HOME'];
  final executable = tekExecutable;
  if (home == null || home.isEmpty || executable == null) return const [];
  final shown = p.isWithin(home, executable) ? '\$HOME/${p.relative(executable, from: home)}' : executable;
  final posix = '[ -x "$shown" ] && eval "\$("$shown" shellenv)"';
  final fish = 'test -x "$shown"; and "$shown" shellenv fish | source';
  final shell = p.basename(environment['SHELL'] ?? '');
  String file(String name) => p.join(home, name);
  bool exists(String name) => File(file(name)).existsSync();
  final lines = <(String, String)>[];
  if (host.os == 'macos') {
    lines.add((file('.zshrc'), posix));
    if (shell == 'bash' || exists('.bash_profile')) lines.add((file('.bash_profile'), posix));
  } else {
    lines.add((file('.bashrc'), posix));
    if (exists('.profile') || !exists('.bash_profile')) lines.add((file('.profile'), posix));
    if (exists('.bash_profile') && !File(file('.bash_profile')).readAsStringSync().contains('.bashrc')) {
      lines.add((file('.bash_profile'), posix));
    }
    if (shell == 'zsh' || exists('.zshrc')) lines.add((file('.zshrc'), posix));
  }
  if (shell == 'fish' || exists('.config/fish/config.fish')) lines.add((file('.config/fish/config.fish'), fish));
  return lines;
}

bool _hasLine(String profile) {
  final file = File(profile);
  return file.existsSync() && file.readAsLinesSync().any(isTekLine);
}

/// Whether [line] is the line tek writes into profiles.
bool isTekLine(String line) => line.contains('tek') && line.contains(' shellenv') && line.contains('-x');

bool _writeLine(String profile, String line) {
  final file = File(profile);
  if (file.existsSync()) {
    final text = file.readAsStringSync();
    if (text.split('\n').any(isTekLine)) return false;
    file.writeAsStringSync('${text.isEmpty || text.endsWith('\n') ? '' : '\n'}$line\n', mode: FileMode.append);
  } else {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$line\n');
  }
  return true;
}

/// Takes tek's line out of [profile], returning whether it was there.
bool removeTekLine(String profile) {
  final file = File(profile);
  if (!file.existsSync()) return false;
  final lines = file.readAsStringSync().split('\n');
  final kept = [
    for (final line in lines)
      if (!isTekLine(line)) line
  ];
  if (kept.length == lines.length) return false;
  file.writeAsStringSync(kept.join('\n'));
  return true;
}

/// What tek shellenv prints for [shell]: the folders of [record] that PATH doesn't have yet, after it, and the
/// variables that aren't set yet. For a Dockerfile every folder and variable, as ENV lines.
String shellenvScript(String shell, PathRecord record, Map<String, String> environment, {String? tekFolder}) {
  final path = environment['PATH'] ?? '';
  final present = path.split(':').toSet();
  final all = [if (tekFolder != null) tekFolder, ...record.folderPaths];
  final folders = shell == 'dockerfile'
      ? record.folderPaths
      : [
          for (final f in all)
            if (!present.contains(f)) f
        ];
  final variables = {
    for (final MapEntry(:key, :value) in record.env.entries)
      if (shell == 'dockerfile' || (environment[key] ?? '').isEmpty) key: value.value,
  };
  final lines = <String>[];
  switch (shell) {
    case 'fish':
      if (folders.isNotEmpty) lines.add('set -gx PATH \$PATH ${folders.map(_quoteDouble).join(' ')};');
      for (final MapEntry(:key, :value) in variables.entries) {
        lines.add('set -gx $key ${_quoteDouble(value)};');
      }
    case 'pwsh':
      if (folders.isNotEmpty) lines.add('\$env:PATH = "\$env:PATH${folders.map((f) => ':$f').join()}"');
      for (final MapEntry(:key, :value) in variables.entries) {
        lines.add('\$env:$key = "$value"');
      }
    case 'dockerfile':
      final parts = [
        if (folders.isNotEmpty) 'PATH="${folders.join(':')}:\$PATH"',
        for (final MapEntry(:key, :value) in variables.entries) '$key=${_quoteDouble(value)}',
      ];
      if (parts.isNotEmpty) lines.add('ENV ${parts.join(' ')}');
    default:
      if (folders.isNotEmpty) lines.add('export PATH="\$PATH:${folders.map(_escapeDouble).join(':')}"');
      for (final MapEntry(:key, :value) in variables.entries) {
        lines.add('export $key=${_quoteDouble(value)}');
      }
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

String _escapeDouble(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$').replaceAll('`', r'\`');

String _quoteDouble(String value) => '"${_escapeDouble(value)}"';
