import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../host.dart';
import '../manifest.dart';
import '../progress.dart';
import '../registry/registry.dart';
import '../registry/registry_index.dart';
import '../tek_home.dart';
import 'installed_architecture.dart';
import 'package_archive.dart';

const _entrypointExtensions = ['', '.sh', '.exe', '.cmd', '.bat', '.ps1'];

class InstallResult {
  const InstallResult(this.installed, {required this.alreadyInstalled});

  final InstalledArchitecture installed;
  final bool alreadyInstalled;
}

class Installer {
  Installer(this.home, this.store);

  final TekHome home;
  final InstalledStore store;

  Future<InstallResult> install(
    ResolvedArchitecture resolved, {
    bool force = false,
    Progress progress = const SilentProgress(),
  }) async {
    final artifact = resolved.version.artifactFor(hostPlatform) ??
        (throw TekException(
          ErrorCodes.unsupportedPlatform,
          '${resolved.reference} has no build for $hostPlatform, only for '
          '${resolved.version.artifacts.keys.join(', ')}.',
        ));
    final expected = artifact.sha256;
    InstalledArchitecture? existing;
    try {
      existing = await store.find(resolved.id, resolved.versionNumber);
    } on TekException {
      if (!force) rethrow;
    }
    if (existing != null && !force) {
      if (existing.receipt.sha256 == expected) {
        return InstallResult(existing, alreadyInstalled: true);
      }
      throw TekException(
        ErrorCodes.installConflict,
        '${resolved.reference} is already installed with a different checksum '
        '(${existing.receipt.sha256}) than registry "${resolved.registry.config.name}" ($expected). '
        'Use --force to replace it.',
      );
    }

    final bytes = await progress.step(
      'Downloading ${resolved.reference}',
      () => resolved.registry.download(artifact),
      done: (bytes) => 'Downloaded ${resolved.reference} (${formatBytes(bytes.length)})',
    );
    final actual = await progress.step(
      'Verifying checksum',
      () {
        final actual = sha256.convert(bytes).toString();
        if (actual != expected) {
          throw TekException(
            ErrorCodes.checksumMismatch,
            'Checksum verification failed for ${resolved.reference}: expected $expected, got $actual.',
            details: {'expected': expected, 'actual': actual},
          );
        }
        return actual;
      },
      done: (actual) => 'Verified checksum (sha256:${shortSha(actual)})',
    );
    if (resolved.version.artifacts.isNotEmpty) {
      return progress.step(
        'Installing the executable for $hostPlatform',
        () => _installExecutable(resolved, bytes, actual, artifact),
        done: (_) => 'Installed the executable for $hostPlatform',
      );
    }
    return progress.step(
      'Unpacking ${resolved.reference}',
      () => _unpack(resolved, bytes, actual, artifact),
      done: (result) => 'Unpacked ${result.installed.receipt.files.length} files',
    );
  }

  Future<InstallResult> _installExecutable(
    ResolvedArchitecture resolved,
    List<int> bytes,
    String actual,
    RegistryArtifact artifact,
  ) async {
    final manifest = await resolved.registry.manifest(resolved.architecture, resolved.version) ??
        (throw TekException(
          ErrorCodes.invalidManifest,
          'Registry "${resolved.registry.config.name}" does not provide a manifest for ${resolved.reference}.',
        ));
    final executable = manifest.executable ??
        (throw TekException(
          ErrorCodes.invalidPackage,
          '${resolved.reference} has builds per platform, but its manifest declares no executable.',
        ));
    final name = Platform.isWindows ? '$executable.exe' : executable;
    final files = {'manifest.yaml': utf8.encode(manifest.source!), name: bytes};
    final stage = await home.createTempDir('install-');
    try {
      for (final MapEntry(key: path, value: content) in files.entries) {
        await File(p.join(stage.path, path)).writeAsBytes(content, flush: true);
      }
      await _makeExecutable(stage.path, {name});
      return await _finish(resolved, stage, actual, artifact, {
        for (final MapEntry(key: path, value: content) in files.entries) path: sha256.convert(content).toString(),
      });
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  Future<InstallResult> _finish(
    ResolvedArchitecture resolved,
    Directory stage,
    String actual,
    RegistryArtifact artifact,
    Map<String, String> hashes,
  ) async {
    final receipt = InstallReceipt(
      id: resolved.id,
      version: '${resolved.versionNumber}',
      sha256: actual,
      installedAt: DateTime.now().toUtc(),
      files: Map.fromEntries(hashes.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      registry: resolved.registry.config.name,
      registryUrl: '${resolved.registry.config.url}',
      artifactUrl: '${artifact.url}',
    );
    await File(p.join(stage.path, installReceiptFile))
        .writeAsString('${const JsonEncoder.withIndent('  ').convert(receipt.toJson())}\n', flush: true);
    final target = home.versionDir(resolved.id, '${resolved.versionNumber}');
    await _replace(stage, target);
    return InstallResult(await store.load(target), alreadyInstalled: false);
  }

  Future<InstallResult> _unpack(
    ResolvedArchitecture resolved,
    List<int> bytes,
    String actual,
    RegistryArtifact artifact,
  ) async {
    final files = PackageArchive.extract(Uint8List.fromList(bytes));
    final manifest = _readManifest(files);
    if (manifest.id != resolved.id || manifest.version != resolved.versionNumber) {
      throw TekException(
        ErrorCodes.invalidPackage,
        'Package manifest describes ${manifest.id}@${manifest.version}, expected ${resolved.reference}.',
      );
    }
    final executables = _entrypoints(manifest, files);

    final stage = await home.createTempDir('install-');
    try {
      final hashes = <String, String>{};
      for (final file in files.values) {
        final target = File(p.joinAll([stage.path, ...p.posix.split(file.path)]));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(file.bytes, flush: true);
        hashes[file.path] = sha256.convert(file.bytes).toString();
        if (file.executable) executables.add(file.path);
      }
      await _makeExecutable(stage.path, executables);
      return await _finish(resolved, stage, actual, artifact, hashes);
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }

  Manifest _readManifest(Map<String, PackageFile> files) {
    final file = files['manifest.yaml'];
    if (file == null) {
      throw TekException(ErrorCodes.invalidPackage, 'Package does not contain manifest.yaml at its root.');
    }
    final String source;
    try {
      source = utf8.decode(file.bytes);
    } on FormatException {
      throw TekException(ErrorCodes.invalidPackage, 'Package manifest.yaml is not valid UTF-8.');
    }
    return Manifest.parse(source, location: 'package manifest.yaml');
  }

  Set<String> _entrypoints(Manifest manifest, Map<String, PackageFile> files) {
    final entrypoints = <String>{};
    for (final command in manifest.commands.values) {
      if (command.run != null && manifest.runIsRelativeToCommands) {
        entrypoints.addAll(_runEntrypoints(command.name, command.run!, files));
        continue;
      }
      final candidates = command.run != null
          ? [command.run!.replaceAll(r'\', '/')]
          : [for (final ext in _entrypointExtensions) 'commands/${command.name}$ext'];
      final present = candidates.where(files.containsKey).toList();
      if (present.isEmpty) {
        throw TekException(
          ErrorCodes.invalidPackage,
          'Package does not provide an entrypoint for command "${command.name}" (expected ${candidates.first}).',
        );
      }
      entrypoints.addAll(present);
    }
    return entrypoints;
  }

  Set<String> _runEntrypoints(String command, String run, Map<String, PackageFile> files) {
    final executables = <String>{};
    var referencesPackage = false;
    for (final (index, token) in splitCommandLine(run).indexed) {
      final path = 'commands/${token.replaceAll(r'\', '/')}';
      final isFile = files.containsKey(path);
      final exists = isFile || files.keys.any((f) => f.startsWith('$path/'));
      if (token.contains('/') && !exists) {
        throw TekException(
          ErrorCodes.invalidPackage,
          'Command "$command" runs "$run", but the package does not contain $path.',
        );
      }
      if (exists) referencesPackage = true;
      if (index == 0 && isFile) executables.add(path);
    }
    if (!referencesPackage) {
      throw TekException(
        ErrorCodes.invalidPackage,
        'Command "$command" runs "$run", which does not reference anything in the commands folder.',
      );
    }
    return executables;
  }

  Future<void> _makeExecutable(String root, Set<String> paths) async {
    if (Platform.isWindows || paths.isEmpty) return;
    final result = await Process.run('chmod', [
      '755',
      for (final path in paths) p.joinAll([root, ...p.posix.split(path)]),
    ]);
    if (result.exitCode != 0) {
      throw TekException(ErrorCodes.io, 'Unable to mark commands as executable: ${result.stderr}');
    }
  }

  Future<void> _replace(Directory stage, String target) async {
    await Directory(p.dirname(target)).create(recursive: true);
    final existing = Directory(target);
    Directory? backup;
    if (await existing.exists()) {
      backup = await existing.rename('$target.old-${DateTime.now().microsecondsSinceEpoch}');
    }
    try {
      await stage.rename(target);
    } catch (_) {
      if (backup != null) await backup.rename(target);
      rethrow;
    }
    if (backup != null) await backup.delete(recursive: true);
  }
}
