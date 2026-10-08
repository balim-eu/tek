import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../host.dart';
import '../progress.dart';
import '../registry/registry.dart';
import '../registry/registry_index.dart';
import '../tek_home.dart';
import 'installed_architecture.dart';

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
    return progress.step(
      'Installing the executable for $hostPlatform',
      () => _installExecutable(resolved, bytes, actual, artifact),
      done: (_) => 'Installed the executable for $hostPlatform',
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
    final files = {'manifest.yaml': utf8.encode(manifest.source!), executableName: bytes};
    final stage = await home.createTempDir('install-');
    try {
      for (final MapEntry(key: path, value: content) in files.entries) {
        await File(p.join(stage.path, path)).writeAsBytes(content, flush: true);
      }
      await _makeExecutable(p.join(stage.path, executableName));
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

  Future<void> _makeExecutable(String path) async {
    if (Platform.isWindows) return;
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw TekException(ErrorCodes.io, 'Unable to mark the executable as executable: ${result.stderr}');
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
