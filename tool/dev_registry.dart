import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tek/src/errors.dart';
import 'package:tek/src/host.dart';
import 'package:tek/src/install/package_archive.dart';
import 'package:tek/src/manifest.dart';
import 'package:tek/src/tek_home.dart';

const _ignoredFiles = {'.DS_Store', 'Thumbs.db'};

class _Version {
  _Version(this.publisher, this.name, this.version, this.files, this.executable);

  final String publisher;
  final String name;
  final String version;
  final Map<String, File> files;
  final String? executable;

  String get id => '$publisher/$name';

  String get reference => '$id@$version';

  String get tag => '$publisher-$name-$version';
}

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('Usage: dart run tool/dev_registry.dart <registry repository> <out>');
    exit(64);
  }
  final source = Directory(p.absolute(arguments[0]));
  final out = Directory(p.absolute(arguments[1]));
  final architectures = Directory(p.join(source.path, 'architectures'));
  if (!architectures.existsSync()) {
    stderr.writeln('${source.path} is not a tek registry repository (no architectures folder).');
    exit(1);
  }

  final problems = <String>[];
  final versions = <_Version>[];
  final manifests = [
    for (final file in architectures.listSync(recursive: true, followLinks: false).whereType<File>())
      if (p.basename(file.path) == 'manifest.yaml' &&
          p.split(p.relative(file.path, from: architectures.path)).length == 4)
        file,
  ]..sort((a, b) => a.path.compareTo(b.path));
  for (final file in manifests) {
    final location = p.relative(file.path, from: source.path);
    final [publisher, name, version, _] = p.split(p.relative(file.path, from: architectures.path));
    final Manifest manifest;
    try {
      manifest = Manifest.parse(file.readAsStringSync(), location: location);
    } on TekException catch (e) {
      problems.add(e.message);
      continue;
    }
    if (manifest.id != '$publisher/$name' || '${manifest.version}' != version) {
      problems.add('$location declares ${manifest.id}@${manifest.version} but lives in $publisher/$name/$version.');
      continue;
    }
    final files = _packageFiles(file.parent);
    if (files.containsKey(installReceiptFile)) problems.add('$location: $installReceiptFile is reserved.');
    versions.add(_Version(publisher, name, version, files, manifest.executable));
  }
  if (problems.isNotEmpty) {
    for (final problem in problems) {
      stderr.writeln('error: $problem');
    }
    exit(1);
  }

  if (out.existsSync()) out.deleteSync(recursive: true);
  final home = Platform.environment['TEK_HOME'];
  final index = <String, Map<String, Object?>>{};
  final cache = Directory('${out.path}.cache');
  for (final version in versions) {
    final assets = Directory(p.join(out.path, version.tag))..createSync(recursive: true);
    version.files['manifest.yaml']!.copySync(p.join(assets.path, 'manifest.yaml'));
    final String checksum;
    final Map<String, Object?> artifact;
    if (version.executable == null) {
      final package = _package(version.files);
      checksum = sha256.convert(package).toString();
      File(p.join(assets.path, '${version.tag}.tek')).writeAsBytesSync(package);
      artifact = {
        'artifact': {'url': '${version.tag}/${version.tag}.tek', 'sha256': checksum},
      };
    } else {
      final name = 'run-$hostPlatform${Platform.isWindows ? '.exe' : ''}';
      final built = _compile(version, name, cache);
      checksum = sha256.convert(built.readAsBytesSync()).toString();
      built.copySync(p.join(assets.path, name));
      artifact = {
        'artifacts': {
          hostPlatform: {'url': '${version.tag}/$name', 'sha256': checksum},
        },
      };
    }
    final architecture = index[version.id] ??= {
      'id': version.id,
      'publisher': version.publisher,
      'name': version.name,
      'versions': <Map<String, Object?>>[],
    };
    (architecture['versions']! as List<Map<String, Object?>>).add({
      'version': version.version,
      'manifest': '${version.tag}/manifest.yaml',
      ...artifact,
    });
    if (home != null) _dropStaleInstall(TekHome(home), version, checksum);
  }
  File(p.join(out.path, 'registry.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'schemaVersion': 2, 'architectures': index.values.toList()})}\n',
  );
  stderr.writeln('Built local registry from ${source.path}: ${versions.map((v) => v.reference).join(', ')}');
}

File _compile(_Version version, String name, Directory cache) {
  final hash = sha256.convert([
    for (final MapEntry(key: path, value: file) in version.files.entries) ...[
      ...utf8.encode(path),
      ...file.readAsBytesSync(),
    ],
  ]);
  final directory = Directory(p.join(cache.path, '${version.tag}-$hash'));
  final built = File(p.join(directory.path, name));
  if (built.existsSync()) return built;
  if (cache.existsSync()) {
    for (final stale in cache.listSync().whereType<Directory>()) {
      if (p.basename(stale.path).startsWith('${version.tag}-')) stale.deleteSync(recursive: true);
    }
  }
  final root = p.dirname(version.files['manifest.yaml']!.path);
  stderr.writeln('Compiling ${version.reference} for $hostPlatform...');
  final result = Process.runSync('sh', [p.join(root, 'compile.sh'), directory.path], workingDirectory: root);
  if (result.exitCode != 0 || !built.existsSync()) {
    stderr
      ..writeln('error: compiling ${version.reference} failed.')
      ..writeln(result.stdout)
      ..writeln(result.stderr);
    exit(1);
  }
  return built;
}

Map<String, File> _packageFiles(Directory directory) {
  final files = <String, File>{};
  for (final entity in directory.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || _ignoredFiles.contains(p.basename(entity.path))) continue;
    final relative = p.posix.joinAll(p.split(p.relative(entity.path, from: directory.path)));
    if (relative.split('/').contains('.dart_tool') || relative == 'src/lib/embedded.dart') continue;
    files[p.posix.joinAll(p.split(p.relative(entity.path, from: directory.path)))] = entity;
  }
  return Map.fromEntries(files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}

Uint8List _package(Map<String, File> files) {
  final archive = Archive();
  for (final MapEntry(key: name, value: file) in files.entries) {
    archive.addFile(
      ArchiveFile.bytes(name, file.readAsBytesSync())
        ..mode = file.statSync().mode & 0x49 != 0 ? 0x1ed : 0x1a4
        ..lastModTime = 0
        ..creationTime = 0
        ..ownerId = 0
        ..groupId = 0,
    );
  }
  return Uint8List.fromList(TarEncoder().encodeBytes(archive));
}

void _dropStaleInstall(TekHome home, _Version version, String checksum) {
  final installed = Directory(home.versionDir(version.id, version.version));
  final receipt = File(p.join(installed.path, installReceiptFile));
  if (!receipt.existsSync()) return;
  try {
    if ((jsonDecode(receipt.readAsStringSync()) as Map)['sha256'] == checksum) return;
  } on FormatException {
    stderr.writeln('Replacing the unreadable install of ${version.reference}.');
  }
  installed.deleteSync(recursive: true);
  stderr.writeln('Removed the outdated install of ${version.reference}; it is reinstalled on next use.');
}
