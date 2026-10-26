import 'package:path/path.dart' as p;

import '../architecture_ref.dart';
import '../errors.dart';
import '../fetcher.dart';
import '../install/installed_architecture.dart';
import '../install/installer.dart';
import '../registry/registry.dart';
import '../registry/registry_auth.dart';
import '../registry/registry_config.dart';
import '../run/executor.dart';
import '../runtime/catalog.dart';
import '../runtime/checker.dart';
import '../runtime/shell.dart';
import '../runtime/system.dart';
import '../tek_home.dart';
import 'output.dart';

class TekContext {
  TekContext({TekHome? home, Fetcher? fetcher})
      : _home = home,
        fetcher = fetcher ?? Fetcher();

  final Fetcher fetcher;
  TekHome? _home;
  RegistrySet? _registries;
  HostSystem? _host;
  ToolCatalog? _catalog;

  TekHome get home => _home ??= TekHome.fromEnvironment();

  RegistryConfigStore get registryConfig => RegistryConfigStore(home.configFile);

  CredentialStore get credentials => CredentialStore(home.credentialsFile);

  InstalledStore get installed => InstalledStore(home);

  Installer get installer => Installer(home, installed);

  Executor get executor => Executor(home);

  Future<RegistrySet> registries() async =>
      _registries ??= await RegistrySet.load(registryConfig, credentials, fetcher);

  Future<HostSystem> host() async => _host ??= await HostSystem.detect();

  /// ~/.tek/path.json, the folders and variables tek made visible to shells.
  PathStore get pathStore => PathStore(p.join(home.root, 'path.json'));

  ToolCache get toolCache => ToolCache(toolCachePath(home.root));

  /// The tools of the configured registries: from ~/.tek/tools.json, read from the registries when [refresh] or when
  /// tek has never read them. A registry that can't be reached keeps the tools tek read last.
  Future<ToolCatalog> toolCatalog({bool refresh = false}) async {
    if (_catalog != null && !refresh) return _catalog!;
    final cache = toolCache;
    final cached = {...cache.read()};
    if (refresh || !cache.exists) {
      var changed = false;
      for (final registry in (await registries()).registries) {
        try {
          cached[registry.config.name] = (await registry.index()).tools;
          changed = true;
        } on TekException {
          continue;
        }
      }
      if (changed) cache.write(cached);
    }
    final configs = await registryConfig.load();
    return _catalog = ToolCatalog.fromRegistries([
      for (final config in configs)
        if (cached[config.name] case final tools?) (config.name, tools),
    ]);
  }

  Future<ToolChecker> toolChecker({bool refresh = false}) async => ToolChecker(
        catalog: await toolCatalog(refresh: refresh),
        host: await host(),
        recordedFolders: pathStore.read().folderPaths,
      );

  Future<InstalledArchitecture> ensureInstalled(
    ArchitectureRef ref, {
    required Output output,
    String? registry,
    bool install = true,
  }) async {
    final exact = ref.constraint.exact;
    final local = exact != null ? await installed.find(ref.id, exact) : await installed.select(ref);
    if (local != null && registry == null) return local;
    if (!install) {
      throw TekException(
        ErrorCodes.notInstalled,
        '$ref is not installed. Install it with "tek install $ref".',
      );
    }
    final resolved = await (await registries()).resolve(ref, registry: registry);
    final result = await installer.install(resolved, progress: output);
    if (!result.alreadyInstalled) output.completed('Installed ${resolved.reference}');
    return result.installed;
  }

  void close() => fetcher.close();
}
