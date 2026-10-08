import 'dart:async';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import '../errors.dart';
import '../manifest.dart';

final _versionPattern = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?');

class RequirementChecker {
  final _results = <String, Future<String?>>{};

  Future<void> check(String subject, List<Requirement> requirements) async {
    final problems = <String>[];
    for (final requirement in requirements) {
      final key = '${requirement.tool}\u0000${requirement.version}\u0000${requirement.command}';
      final problem = await (_results[key] ??= _check(requirement));
      if (problem != null) problems.add(problem);
    }
    if (problems.isEmpty) return;
    throw TekException(
      ErrorCodes.requirementsNotMet,
      '$subject needs:\n${problems.map((problem) => '  - $problem').join('\n')}',
      details: {'problems': problems},
    );
  }

  Future<String?> _check(Requirement requirement) async {
    final hint = requirement.install == null ? '' : ' (install: ${requirement.install})';
    final command =
        requirement.command == null ? [requirement.tool, '--version'] : splitCommandLine(requirement.command!);
    final ProcessResult result;
    try {
      result = await Process.run(command.first, command.skip(1).toList(), runInShell: Platform.isWindows)
          .timeout(const Duration(seconds: 60));
    } on ProcessException {
      return '${requirement.display}, but ${requirement.tool} is not installed$hint';
    } on TimeoutException {
      return '${requirement.display}, but "${command.join(' ')}" did not finish';
    }
    if (result.exitCode != 0) {
      return '${requirement.display}, but "${command.join(' ')}" failed with exit code ${result.exitCode}$hint';
    }
    if (!requirement.checksVersion) return null;

    final VersionConstraint constraint;
    try {
      constraint = VersionConstraint.parse(requirement.version!);
    } on FormatException {
      return '${requirement.display}, but "${requirement.version}" is not a valid version constraint';
    }
    final match = _versionPattern.firstMatch('${result.stdout}\n${result.stderr}');
    if (match == null) {
      return '${requirement.display}, but its version could not be read from "${command.join(' ')}"';
    }
    final found = Version(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3] ?? '0'));
    if (constraint.allows(found)) return null;
    return '${requirement.display}, found $found$hint';
  }
}
