import '../manifest.dart';

List<(String, String)> builtInCommands(Manifest manifest) => [
      ('doctor', 'Check the software ${manifest.id} needs on this machine.'),
      ('prompt', 'Print a prompt that starts an AI agent on a task with ${manifest.id}.'),
      ('version', 'Show the version of ${manifest.id}.'),
    ];

List<(String, String)> withBuiltInCommands(Manifest manifest, List<(String, String)> rows) {
  final all = [...rows];
  for (final row in builtInCommands(manifest)) {
    final at = all.indexWhere((existing) => existing.$1.compareTo(row.$1) > 0);
    all.insert(at == -1 ? all.length : at, row);
  }
  return all;
}

String systemPrompt(Manifest manifest, String architecture) {
  if (manifest.systemPrompt case final prompt?) return prompt;
  final title = manifest.name == manifest.id ? architecture : '$architecture (${manifest.name})';
  return [
    '# Working with $title',
    '',
    '## Role',
    '',
    'You are a software engineer who builds and changes projects with the tek architecture $title.'
        '${manifest.description == null ? '' : ' ${manifest.description}'}',
    '',
    '## Goal',
    '',
    'Complete the task in the user prompt below with the commands of $architecture, so the result follows the '
        'architecture and works.',
    '',
    '## Getting started',
    '',
    '1. Run `tek $architecture --help-ai`, it lists every command of the architecture.',
    '2. Run `tek $architecture <command> --help-ai` before you use a command, it explains what the command does, '
        'with examples and every option.',
    '',
    '## Rules',
    '',
    '- Do every change a command covers with that command, write by hand only what no command does.',
    '- Keep the code as the commands leave it, and keep to the structure the architecture sets up.',
    '- Add `--json` to a command when you need machine-readable output.',
    '- Verify your work before you call it done, and fix what fails.',
    '',
    '## Report',
    '',
    'When you are done, summarize what you built and list every command that was missing or fell short: '
        'the command, what was missing, what you did by hand instead, and what the command could do better.',
  ].join('\n');
}

String agentPrompt(Manifest manifest, String architecture, String task) =>
    '<system_prompt>\n${systemPrompt(manifest, architecture)}\n</system_prompt>\n\n'
    '<user_prompt>\n${task.trim()}\n</user_prompt>\n';
