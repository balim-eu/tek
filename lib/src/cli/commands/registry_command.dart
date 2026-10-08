import 'dart:io';

import 'package:args/command_runner.dart';

import '../../errors.dart';
import '../../fetcher.dart';
import '../../registry/registry.dart';
import '../../registry/registry_auth.dart';
import '../../registry/registry_config.dart';
import '../../registry/registry_index.dart';
import '../context.dart';
import '../output.dart';
import '../terminal.dart';
import 'tek_command.dart';

class RegistryCommand extends Command<int> {
  RegistryCommand(TekContext context) {
    addSubcommand(RegistryListCommand(context));
    addSubcommand(RegistryAddCommand(context));
    addSubcommand(RegistryLoginCommand(context));
    addSubcommand(RegistryLogoutCommand(context));
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
    final states = {
      for (final registry in registries) registry.name: await _credentialState(context, registry.name),
    };
    output.success({
      'registries': [
        for (final r in registries) {...r.toJson(), 'credentials': states[r.name]?.$1},
      ],
    }, (out) {
      final style = output.style;
      if (registries.isEmpty) {
        out
          ..writeln(style.dim('No registries are configured.'))
          ..writeln(style.dim('Add one with: tek registry add <name> <url>'));
        return;
      }
      for (final (index, registry) in registries.indexed) {
        if (index > 0) out.writeln();
        final state = states[registry.name];
        final type = registry.auth?.type ?? state?.$2;
        final badge = type == null
            ? style.dim('public')
            : style.yellow('private · ${authNoun(type)} ${switch (state?.$1) {
                'environment' => 'from ${state!.$3}',
                'saved' => 'saved',
                _ => 'missing',
              }}');
        out
          ..writeln('${style.id(registry.name)} $badge')
          ..writeln(style.dim('  ${registry.url}'));
      }
    });
    return 0;
  }
}

Future<(String, String, String?)?> _credentialState(TekContext context, String registry) async {
  if (environmentCredential(registry) case final credential?) {
    return ('environment', credential.type, environmentSource(registry, credential));
  }
  if (await context.credentials.saved(registry) case final credential?) return ('saved', credential.type, null);
  return null;
}

abstract class _CredentialCommand extends TekCommand {
  _CredentialCommand(super.context) {
    argParser
      ..addOption(
        'token',
        valueHelp: 'token',
        help: 'Token for a registry that needs one. Use "-" to enter it at a hidden prompt or read it from stdin.',
      )
      ..addOption('username', valueHelp: 'name', help: 'Username for a registry that needs a username and password.')
      ..addOption(
        'password',
        valueHelp: 'password',
        help: 'Password that goes with --username. Use "-" to enter it at a hidden prompt or read it from stdin.',
      )
      ..addFlag('verify', defaultsTo: true, help: 'Fetch and validate the registry index before saving.');
  }

  bool get interactive => !jsonMode && canPrompt();

  bool get verify => argResults!.flag('verify');

  Credential? credentialFromOptions() {
    final token = argResults!.option('token');
    final username = argResults!.option('username')?.trim();
    final password = argResults!.option('password');
    if (token != null && (username != null || password != null)) {
      usageException('Use either --token or --username and --password.');
    }
    if (token != null) {
      final value = token == '-' ? readSecret('Token') : token.trim();
      if (value.isEmpty) usageException('The token must not be empty.');
      return Credential.bearer(value);
    }
    if (username == null) {
      if (password != null) usageException('--password needs --username.');
      return null;
    }
    if (username.isEmpty) usageException('The username must not be empty.');
    if (password == null && !interactive) usageException('--username needs --password.');
    final value = password == null || password == '-' ? readSecret('Password', trim: false) : password;
    if (value.isEmpty) usageException('The password must not be empty.');
    return Credential.basic(username, value);
  }

  Credential askCredential(String name, Uri url, AuthInfo info, {required String reason, required String next}) {
    info.ensureSupported(name);
    if (!interactive) {
      throw TekException(
        ErrorCodes.authenticationRequired,
        reason,
        hint: [...info.details(url), 'Then run: $next ${credentialOptions(info.type)}'].join('\n'),
      );
    }
    final style = output.errorStyle;
    stderr.writeln('${style.question} $reason');
    for (final line in info.details(url)) {
      stderr.writeln(style.dim('  $line'));
    }
    if (info.type == basicAuth) return Credential.basic(readLine('Username'), readSecret('Password', trim: false));
    return Credential.bearer(readSecret('Token'));
  }

  Future<(RegistryIndex, Credential?)> connect(
    String name,
    Uri url,
    Credential? credential, {
    AuthInfo? known,
    required String next,
  }) async {
    var current = credential;
    while (true) {
      final config =
          RegistryConfig(name: name, url: url, auth: known ?? (current == null ? null : AuthInfo(current.type)));
      TekException? failure;
      final index = await output.step(
        'Connecting to $name',
        () async {
          try {
            return await openRegistry(config, context.fetcher, credential: current).index();
          } on TekException catch (e) {
            failure = e;
            return null;
          }
        },
        done: (index) => index == null
            ? null
            : 'Connected to $name (${index.architectures.length} '
                'architecture${index.architectures.length == 1 ? '' : 's'} available)',
      );
      if (index == null) {
        final error = failure!;
        if (error.code == ErrorCodes.accessDenied) {
          throw TekException(
            error.code,
            error.message,
            details: error.details,
            hint: credentialHint(name, url, config.auth ?? AuthInfo(bearerAuth),
                rejected: true, next: 'Then run: $next ${credentialOptions(config.auth?.type ?? bearerAuth)}'),
          );
        }
        final needed = current == null ? _neededAuth(error, url) : null;
        if (needed == null) throw error;
        current = askCredential(
          name,
          url,
          known ?? AuthInfo(needed),
          reason: error.details?['status'] == 404
              ? '$name was not found, or it is private and needs ${authLabel(needed)}.'
              : '$name is private and needs ${authLabel(needed)}.',
          next: next,
        );
        continue;
      }
      final declared = index.auth;
      if (declared != null && current == null) {
        current = askCredential(name, url, declared, reason: '$name needs ${authLabel(declared.type)}.', next: next);
      } else if (declared != null && current != null && declared.type != current.type) {
        throw TekException(
          ErrorCodes.usage,
          '$name needs ${authLabel(declared.type)}, not ${authLabel(current.type)}.',
          hint: [...declared.details(url), 'Then run: $next ${credentialOptions(declared.type)}'].join('\n'),
          exitCode: 64,
        );
      }
      return (index, current);
    }
  }

  String? _neededAuth(TekException error, Uri url) {
    final status = error.details?['status'];
    final challenge = '${error.details?['challenge'] ?? ''}'.trimLeft().toLowerCase();
    if (status == 401 || status == 403) return challenge.startsWith('basic') ? basicAuth : bearerAuth;
    if (status == 404 && isGitHubHost(url)) return bearerAuth;
    return null;
  }
}

class RegistryAddCommand extends _CredentialCommand {
  RegistryAddCommand(super.context);

  @override
  String get name => 'add';

  @override
  String get description => 'Add a registry, or update an existing one and its credentials.';

  @override
  String get invocation => 'tek registry add [name] <url> [--token <token> | --username <name> --password <password>]';

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
    final given = credentialFromOptions();
    final fromEnvironment = given == null ? environmentCredential(name) : null;
    var credential = given ?? fromEnvironment;
    RegistryIndex? index;
    if (verify) (index, credential) = await connect(name, url, credential, next: 'tek registry add $name $url');
    final auth = index?.auth ?? (credential == null ? null : AuthInfo(credential.type));
    final (config, updated) = await context.registryConfig.add(name, url, auth: auth);
    final environment = credential != null && identical(credential, fromEnvironment);
    if (credential == null) {
      await context.credentials.remove(name);
    } else if (!environment) {
      await context.credentials.save(name, credential);
    }
    output.success({
      'registry': config.toJson(),
      'added': !updated,
      'updated': updated,
      'credentials': credential == null ? null : (environment ? 'environment' : 'saved'),
      if (index != null) 'architectures': index.architectures.length,
    }, (out) {
      final style = output.style;
      out.writeln('${style.success} ${updated ? 'Updated' : 'Added'} registry ${style.id(config.name)}');
      if (credential != null) {
        final noun = authNoun(credential.type);
        out.writeln(style.dim(environment
            ? '  Using the $noun from ${environmentSource(name, credential)}'
            : '  ${noun[0].toUpperCase()}${noun.substring(1)} saved to ${displayPath(context.home.credentialsFile)}'));
      }
      out.writeln(style.dim('  Search it with: tek search --registry ${config.name}'));
    });
    return 0;
  }
}

class RegistryLoginCommand extends _CredentialCommand {
  RegistryLoginCommand(super.context);

  @override
  String get name => 'login';

  @override
  String get description => 'Save new credentials for a registry, for example after its token expired.';

  @override
  String get invocation => 'tek registry login <name> [--token <token> | --username <name> --password <password>]';

  @override
  Future<int> run() async {
    final name = argument(0, 'name');
    expectArguments(1);
    final config = await context.registryConfig.get(name);
    final next = 'tek registry login $name';
    var credential = credentialFromOptions();
    if (credential == null && config.auth != null) {
      credential = askCredential(
        name,
        config.url,
        config.auth!,
        reason: '$name needs ${authLabel(config.auth!.type)}.',
        next: next,
      );
    }
    RegistryIndex? index;
    if (verify || credential == null) {
      (index, credential) = await connect(name, config.url, credential, known: config.auth, next: next);
    }
    final output = this.output;
    if (credential == null) {
      output.success({'registry': name, 'saved': false, 'public': true}, (out) {
        out.writeln('${output.style.success} ${output.style.id(name)} is public and needs no credentials');
      });
      return 0;
    }
    await context.registryConfig.add(name, config.url, auth: index?.auth ?? config.auth ?? AuthInfo(credential.type));
    await context.credentials.save(name, credential);
    final saved = credential;
    output.success({'registry': name, 'saved': true, 'type': saved.type}, (out) {
      final style = output.style;
      out
        ..writeln('${style.success} Saved the ${authNoun(saved.type)} of ${style.id(name)}')
        ..writeln(style.dim('  ${displayPath(context.home.credentialsFile)}'));
      if (environmentCredential(name) case final variable?) {
        out.writeln(style.dim('  ${environmentSource(name, variable)} is set and is used instead.'));
      }
    });
    return 0;
  }
}

class RegistryLogoutCommand extends TekCommand {
  RegistryLogoutCommand(super.context);

  @override
  String get name => 'logout';

  @override
  String get description => 'Remove the saved credentials of a registry and keep the registry.';

  @override
  String get invocation => 'tek registry logout <name>';

  @override
  Future<int> run() async {
    final name = argument(0, 'name');
    expectArguments(1);
    await context.registryConfig.get(name);
    final removed = await context.credentials.remove(name);
    output.success({'registry': name, 'removed': removed}, (out) {
      final style = output.style;
      out.writeln(removed
          ? '${style.success} Removed the credentials of ${style.id(name)}'
          : style.dim('No credentials were saved for $name.'));
      if (environmentCredential(name) case final credential?) {
        out.writeln(style.dim('  ${environmentSource(name, credential)} is still set and is used.'));
      }
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
  String get description => 'Remove a registry and its saved credentials.';

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
