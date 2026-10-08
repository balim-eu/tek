import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';

const installReceiptFile = '.tek-install.json';

class PackageFile {
  const PackageFile(this.path, this.bytes, {required this.executable});

  final String path;
  final Uint8List bytes;
  final bool executable;
}

abstract final class PackageArchive {
  static Map<String, PackageFile> extract(Uint8List bytes) {
    final Archive archive;
    try {
      final tar = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
          ? const GZipDecoder().decodeBytes(bytes, verify: true)
          : bytes;
      archive = TarDecoder().decodeBytes(tar);
    } catch (e) {
      throw TekException(ErrorCodes.invalidPackage, 'Package is not a valid .tek archive: $e');
    }

    final files = <String, PackageFile>{};
    for (final entry in archive) {
      final path = normalizeEntryPath(entry.name);
      if (path == null) {
        throw TekException(ErrorCodes.invalidPackage, 'Package contains an unsafe path "${entry.name}".');
      }
      if (path.isEmpty || entry.isDirectory) continue;
      if (entry.isSymbolicLink) {
        throw TekException(ErrorCodes.invalidPackage, 'Package contains a symbolic link "$path".');
      }
      if (path == installReceiptFile) {
        throw TekException(ErrorCodes.invalidPackage, 'Package contains reserved file "$path".');
      }
      if (files.containsKey(path)) {
        throw TekException(ErrorCodes.invalidPackage, 'Package contains "$path" more than once.');
      }
      files[path] = PackageFile(path, entry.content, executable: entry.mode & 0x49 != 0);
    }
    return files;
  }

  static String? normalizeEntryPath(String name) {
    final normalized = name.replaceAll(r'\', '/');
    if (normalized.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return null;
    final segments = <String>[];
    for (final segment in normalized.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') return null;
      segments.add(segment);
    }
    return p.posix.joinAll(segments);
  }
}
