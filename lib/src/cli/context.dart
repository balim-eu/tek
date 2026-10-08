import '../architecture_ref.dart';
import '../errors.dart';
import '../fetcher.dart';
import '../install/installed_architecture.dart';
import '../install/installer.dart';
import '../registry/registry.dart';
import '../registry/registry_auth.dart';
import '../registry/registry_config.dart';
import '../run/executor.dart';
import '../tek_home.dart';
import 'output.dart';

class TekContext {
  TekContext({TekHome? home, Fetcher? fetcher})
      : _home = home,
        fetcher = fetcher ?? Fetcher();

  final Fetcher fetcher;
  TekHome? _home;
  RegistrySet? _registries;

  TekHome get home => _home ??= TekHome.fromEnvironment();

  RegistryConfigStore get registryConfig => RegistryConfigStore(home.configFile);

  CredentialStore get credentials => CredentialStore(home.credentialsFile);

  InstalledStore get installed => InstalledStore(home);

  Installer get installer => Installer(home, installed);

  Executor get executor => Executor(home);

  Future<RegistrySet> registries() async =>
      _registries ??= await RegistrySet.load(registryConfig, credentials, fetcher);

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
