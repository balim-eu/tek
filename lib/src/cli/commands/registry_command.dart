import 'package:args/command_runner.dart';

import '../../fetcher.dart';
import '../../registry/registry.dart';
import '../../registry/registry_auth.dart';
import '../../registry/registry_config.dart';
import '../context.dart';
import '../output.dart';
import '../terminal.dart';
import 'tek_command.dart';

class RegistryCommand extends Command<int> {
  RegistryCommand(TekContext context) {
    addSubcommand(RegistryListCommand(context));
    addSubcommand(RegistryAddCommand(context));
    addSubcommand(RegistryRemoveCommand(context));
  }

  @override
  String get name => 'registry';

  @override
  String get description => 'Manage configured registries.';

  @override
  void printUsage() => Output(json: globalResults?.flag('json') ?? false).usage(usage);
}

class RegistryListCommand extends TekCommand {
  RegistryListCommand(super.context);

  @override
  String get name => 'list';

  @override
  String get description => 'List configured registries.';

  @override
  Future<int> run() async {
    expectArguments(0);
    final registries = await context.registryConfig.load();
    output.success({
      'registries': [for (final r in registries) r.toJson()],
    }, (out) {
      final style = output.style;
      if (registries.isEmpty) {
        out
          ..writeln(style.dim('No registries are configured.'))
          ..writeln(style.dim('Add one with: tek registry add <name> <url> [--token <token>]'));
        return;
      }
      for (final (index, registry) in registries.indexed) {
        if (index > 0) out.writeln();
        final badge = registry.auth == null ? style.dim('public') : style.yellow('private · ${registry.auth}');
        out
          ..writeln('${style.id(registry.name)} $badge')
          ..writeln(style.dim('  ${registry.url}'));
      }
    });
    return 0;
  }
}

class RegistryAddCommand extends TekCommand {
  RegistryAddCommand(super.context) {
    argParser
      ..addOption(
        'token',
        valueHelp: 'token',
        help: 'Access token for a private registry. Use "-" to enter it at a hidden prompt or read it from stdin.',
      )
      ..addFlag('verify', defaultsTo: true, help: 'Fetch and validate the registry index before adding it.');
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Add a registry, or update an existing one and its token.';

  @override
  String get invocation => 'tek registry add [name] <url> [--token <token>]';

  @override
  Future<int> run() async {
    if (rest.isEmpty) usageException('Missing required argument <url>.');
    expectArguments(2);
    final url = Fetcher.parseLocation(rest.last);
    final name = rest.length == 2 ? rest.first : RegistryConfig.deriveName(url);
    if (!RegistryConfig.isValidName(name)) {
      usageException('Invalid registry name "$name". Use lowercase letters, digits, "-" and "_".');
    }
    Fetcher.ensureSecure(url);
    final output = this.output;
    final tokenOption = argResults!.option('token');
    final token = tokenOption == '-' ? readTokenFromStdin() : tokenOption?.trim();
    if (token != null && token.isEmpty) usageException('The token must not be empty.');
    final auth = token == null ? null : tokenAuth;
    var architectures = 0;
    if (argResults!.flag('verify')) {
      final registry = openRegistry(RegistryConfig(name: name, url: url, auth: auth), context.fetcher, token: token);
      architectures = await output.step(
        'Connecting to $name',
        () async => (await registry.search('')).length,
        done: (count) => 'Connected to $name ($count architecture${count == 1 ? '' : 's'} available)',
      );
    }
    final (config, updated) = await context.registryConfig.add(name, url, auth: auth);
    if (token == null) {
      await context.credentials.remove(name);
    } else {
      await context.credentials.setToken(name, token);
    }
    output.success({
      'registry': config.toJson(),
      'added': !updated,
      'updated': updated,
      if (argResults!.flag('verify')) 'architectures': architectures,
    }, (out) {
      final style = output.style;
      out.writeln('${style.success} ${updated ? 'Updated' : 'Added'} registry ${style.id(config.name)}');
      if (token != null) out.writeln(style.dim('  Token saved to ${displayPath(context.home.credentialsFile)}'));
      out.writeln(style.dim('  Search it with: tek search --registry ${config.name}'));
    });
    return 0;
  }
}

class RegistryRemoveCommand extends TekCommand {
  RegistryRemoveCommand(super.context);

  @override
  String get name => 'remove';

  @override
  List<String> get aliases => const ['rm'];

  @override
  String get description => 'Remove a registry.';

  @override
  String get invocation => 'tek registry remove <name>';

  @override
  Future<int> run() async {
    final name = argument(0, 'name');
    expectArguments(1);
    final removed = await context.registryConfig.remove(name);
    await context.credentials.remove(name);
    output.success({
      'registry': removed.name,
      'removed': true,
    }, (out) {
      out.writeln('${output.style.success} Removed registry ${output.style.id(removed.name)}');
    });
    return 0;
  }
}
