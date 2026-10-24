import 'package:pub_semver/pub_semver.dart';

import '../errors.dart';
import '../install/installed_architecture.dart';
import 'registry.dart';
import 'registry_index.dart';

class UpdateCheck {
  const UpdateCheck(this.latest, this.failures);

  final Map<String, ResolvedArchitecture> latest;
  final List<RegistryFailure> failures;

  ResolvedArchitecture? update(InstalledArchitecture installed) {
    final candidate = latest[installed.id];
    return candidate != null && candidate.versionNumber > installed.version ? candidate : null;
  }
}

Future<UpdateCheck> checkUpdates(
  RegistrySet registries,
  Iterable<InstalledArchitecture> installed, {
  bool preRelease = false,
}) async {
  final latest = <String, ResolvedArchitecture>{};
  final failures = <String, RegistryFailure>{};
  final checked = <String>{};
  for (final architecture in installed) {
    if (!checked.add(architecture.id)) continue;
    final origin = [
      for (final registry in registries.registries)
        if (registry.config.name == architecture.receipt.registry) registry,
    ];
    for (final registry in origin.isEmpty ? registries.registries : origin) {
      if (failures.containsKey(registry.config.name)) continue;
      final RegistryArchitecture? found;
      try {
        found = await registry.find(architecture.id);
      } on TekException catch (e) {
        failures[registry.config.name] = RegistryFailure(registry, e);
        continue;
      }
      if (found == null) continue;
      final newest = _newest(found.versionNumbers, preRelease: preRelease);
      if (newest != null) latest[architecture.id] = ResolvedArchitecture(registry, found, found.version(newest)!);
      break;
    }
  }
  return UpdateCheck(latest, failures.values.toList());
}

Version? _newest(Iterable<Version> versions, {required bool preRelease}) {
  final candidates = preRelease ? versions : versions.where((version) => !version.isPreRelease);
  return candidates.isEmpty ? null : candidates.reduce((a, b) => a > b ? a : b);
}
