import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../errors.dart';

const projectFileName = 'tek.yaml';

final _architectureLine = RegExp(r'^architecture:.*$', multiLine: true);

/// A product of a project's tek.yaml, as smileyface/project lists them.
class ProjectProduct {
  const ProjectProduct(this.path, this.architecture);

  final String path;
  final String? architecture;
}

/// tek.yaml: what a project was made with, `architecture: tek/rust-api@0.1.1`, and for a project of several products
/// the products, each with its path and architecture.
class ProjectFile {
  const ProjectFile(this.directory, {this.architecture, this.products = const []});

  /// Reads the tek.yaml of [directory], null when there is none.
  static ProjectFile? read(String directory) {
    final file = File(p.join(directory, projectFileName));
    if (!file.existsSync()) return null;
    final Object? document;
    try {
      document = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw TekException(ErrorCodes.config, '${file.path} is not valid YAML: ${e.message}');
    }
    if (document == null) return ProjectFile(directory);
    if (document is! YamlMap) throw TekException(ErrorCodes.config, '${file.path} must be a mapping.');
    final architecture = document['architecture'];
    if (architecture != null && architecture is! String) {
      throw TekException(
          ErrorCodes.config, 'architecture: in ${file.path} must be an architecture, e.g. tek/rust-api.');
    }
    final products = document['products'];
    return ProjectFile(
      directory,
      architecture: architecture as String?,
      products: [
        if (products is YamlList)
          for (final product in products)
            if (product is YamlMap && product['path'] is String)
              ProjectProduct(product['path'] as String, product['architecture'] as String?),
      ],
    );
  }

  final String directory;
  final String? architecture;
  final List<ProjectProduct> products;

  /// Writes [reference] as the architecture of the tek.yaml in [directory]: a new file, or the architecture line of an
  /// existing one, put first when it has none.
  static void writeArchitecture(String directory, String reference) {
    final file = File(p.join(directory, projectFileName));
    final line = 'architecture: $reference';
    if (!file.existsSync()) {
      file.writeAsStringSync('# What this project was made with; tek setup sets a clone of it up.\n$line\n');
      return;
    }
    final text = file.readAsStringSync();
    if (_architectureLine.hasMatch(text)) {
      file.writeAsStringSync(text.replaceFirst(_architectureLine, line));
      return;
    }
    // After the comments the file starts with, before its first key.
    final lines = text.split('\n');
    final first = lines.indexWhere((l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'));
    final at = first == -1 ? lines.length : first;
    file.writeAsStringSync([...lines.take(at), line, ...lines.skip(at)].join('\n'));
  }
}
