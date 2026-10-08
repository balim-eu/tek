import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';

class TekHome {
  TekHome(this.root);

  factory TekHome.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final override = env['TEK_HOME'];
    if (override != null && override.isNotEmpty) return TekHome(p.absolute(override));
    final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
    if (home == null || home.isEmpty) {
      throw TekException(ErrorCodes.config, 'Unable to determine the home directory. Set TEK_HOME.');
    }
    return TekHome(p.join(home, '.tek'));
  }

  final String root;

  String get architecturesDir => p.join(root, 'architectures');

  String get tmpDir => p.join(root, 'tmp');

  String get configFile => p.join(root, 'config.json');

  String get credentialsFile => p.join(root, 'credentials.json');

  String architectureDir(String id) => p.joinAll([architecturesDir, ...id.split('/')]);

  String versionDir(String id, String version) => p.join(architectureDir(id), version);

  Future<Directory> createTempDir(String prefix) async {
    final dir = Directory(tmpDir);
    await dir.create(recursive: true);
    return dir.createTemp(prefix);
  }
}
