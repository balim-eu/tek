import 'dart:async';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import '../errors.dart';
import '../manifest.dart';

final _versionPattern = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?');

class RequirementStatus {
  const RequirementStatus(this.requirement, {this.found, this.problem, this.skipped = false});

  final Requirement requirement;
  final String? found;
  final String? problem;
  final bool skipped;

  bool get ok => skipped || problem == null;

  Map<String, Object?> toJson() => {
        ...requirement.toJson(),
        'status': skipped
            ? 'skipped'
            : ok
                ? 'ok'
                : 'missing',
        if (found != null) 'found': found,
        if (problem != null) 'problem': problem,
      };
}

class RequirementChecker {
  final _results = <String, Future<RequirementStatus>>{};

  Future<void> check(String subject, List<Requirement> requirements) async {
    final problems = [
      for (final status in await Future.wait(requirements.map(inspect)))
        if (status.problem case final problem?) problem,
    ];
    if (problems.isEmpty) return;
    throw TekException(
      ErrorCodes.requirementsNotMet,
      '$subject needs:\n${problems.map((problem) => '  - $problem').join('\n')}',
      details: {'problems': problems},
    );
  }

  Future<RequirementStatus> inspect(Requirement requirement) {
    final key = '${requirement.tool}\u0000${requirement.version}\u0000${requirement.command}';
    return _results[key] ??= _inspect(requirement);
  }

  Future<RequirementStatus> _inspect(Requirement requirement) async {
    if (!requirement.appliesHere) return RequirementStatus(requirement, skipped: true);
    final hint = requirement.install == null ? '' : ' (install: ${requirement.install})';
    if (requirement.command == null && !requirement.checksVersion) {
      final path = _which(requirement.tool);
      return path == null
          ? RequirementStatus(requirement,
              problem: '${requirement.display}, but ${requirement.tool} is not installed$hint')
          : RequirementStatus(requirement, found: path);
    }
    final command =
        requirement.command == null ? [requirement.tool, '--version'] : splitCommandLine(requirement.command!);
    final ProcessResult result;
    try {
      result = await Process.run(command.first, command.skip(1).toList(), runInShell: Platform.isWindows)
          .timeout(const Duration(seconds: 60));
    } on ProcessException {
      return RequirementStatus(requirement,
          problem: '${requirement.display}, but ${requirement.tool} is not installed$hint');
    } on TimeoutException {
      return RequirementStatus(requirement,
          problem: '${requirement.display}, but "${command.join(' ')}" did not finish');
    }
    if (result.exitCode != 0) {
      return RequirementStatus(
        requirement,
        problem: '${requirement.display}, but "${command.join(' ')}" failed with exit code ${result.exitCode}$hint',
      );
    }
    final match = _versionPattern.firstMatch('${result.stdout}\n${result.stderr}');
    final found =
        match == null ? null : Version(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3] ?? '0'));
    if (!requirement.checksVersion) return RequirementStatus(requirement, found: found?.toString() ?? 'installed');

    final VersionConstraint constraint;
    try {
      constraint = VersionConstraint.parse(requirement.version!);
    } on FormatException {
      return RequirementStatus(
        requirement,
        problem: '${requirement.display}, but "${requirement.version}" is not a valid version constraint',
      );
    }
    if (found == null) {
      return RequirementStatus(
        requirement,
        problem: '${requirement.display}, but its version could not be read from "${command.join(' ')}"',
      );
    }
    if (constraint.allows(found)) return RequirementStatus(requirement, found: '$found');
    return RequirementStatus(requirement, found: '$found', problem: '${requirement.display}, found $found$hint');
  }

  String? _which(String tool) {
    final extensions = Platform.isWindows ? ['.exe', '.bat', '.cmd', ''] : [''];
    for (final directory in (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
      if (directory.isEmpty) continue;
      for (final extension in extensions) {
        final file = File('$directory${Platform.pathSeparator}$tool$extension');
        if (file.existsSync()) return file.path;
      }
    }
    return null;
  }
}
