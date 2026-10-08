import '../manifest.dart';

List<(String, String)> builtInCommands(Manifest manifest) => [
      ('doctor', 'Check the software ${manifest.id} needs on this machine.'),
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
