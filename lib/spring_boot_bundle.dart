import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Locates the bundled Spring Boot dependency set and materialises it as real
/// JAR files on disk.
///
/// The set is prepared by `tools/prepare_spring_boot.ps1` from the pinned
/// `tools/spring_boot.lock.json` and declared in `pubspec.yaml`, so Flutter
/// packages it as an asset on every platform. Java toolchains cannot read a
/// Flutter asset directly, so the JARs are copied into a real directory before
/// `javac`/`java` are invoked.
///
/// Materialisation is cached per process: the copy happens once and later calls
/// reuse the same directory. On desktop the checked-in asset directory is used
/// in place, because `rootBundle` works there too but copying 17 MB into a temp
/// directory every launch would be wasteful.
abstract final class SpringBootBundle {
  /// Bundled version directory, matching the lock file's `version`.
  ///
  /// Kept in sync with `tools/spring_boot.lock.json` by
  /// `test/spring_boot_bundle_test.dart`.
  static const String version = '3.5.16';

  static const String _assetRoot = 'assets/spring_boot/$version';

  /// The manifest listing the bundled JAR file names.
  ///
  /// A manifest is used instead of scanning the asset directory because
  /// Flutter's asset API cannot enumerate a directory on all platforms, and
  /// because the lock file already defines the authoritative set.
  static const String _manifestAsset = '$_assetRoot/manifest.json';

  static Future<List<String>>? _materialising;
  static List<String>? _cached;

  /// JAR paths ready to be placed on a classpath, in a stable order.
  ///
  /// [targetDirectory] is required on mobile, where the assets must be written
  /// to a real directory. When null, a temporary directory under the system temp
  /// path is used.
  static Future<List<String>> materialise({String? targetDirectory}) {
    final existing = _cached;
    if (existing != null) return Future.value(existing);
    return _materialising ??= _materialise(targetDirectory).whenComplete(
      () => _materialising = null,
    );
  }

  static Future<List<String>> _materialise(String? targetDirectory) async {
    final manifest = await _readManifest();
    final directory = targetDirectory == null
        ? await Directory.systemTemp.createTemp('qfli_spring_boot_')
        : (Directory(targetDirectory)..createSync(recursive: true));

    final paths = <String>[];
    for (final name in manifest) {
      final file = File(p.join(directory.path, name));
      if (!await file.exists() || await file.length() == 0) {
        final bytes = await _readAsset('$_assetRoot/$name');
        await file.writeAsBytes(bytes, flush: true);
      }
      paths.add(file.path);
    }
    return _cached = paths;
  }

  static Future<List<String>> _readManifest() async {
    try {
      final raw = await rootBundle.loadString(_manifestAsset);
      final decoded = jsonDecodeList(raw);
      if (decoded.isEmpty) {
        throw const FormatException('Spring Boot asset manifest is empty');
      }
      return decoded;
    } on FlutterError catch (error) {
      throw StateError(
        'Spring Boot assets are missing. Run tools/prepare_spring_boot.ps1 '
        'and rebuild. ($error)',
      );
    }
  }

  static Future<Uint8List> _readAsset(String key) async {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Parses the manifest, which is a plain JSON array of file names.
  ///
  /// Kept separate so the test can exercise it without a bundle.
  @visibleForTesting
  static List<String> jsonDecodeList(String raw) {
    final value = jsonDecode(raw);
    if (value is! List) {
      throw const FormatException('Spring Boot asset manifest must be a list');
    }
    return value.map((entry) {
      if (entry is! String || entry.isEmpty || entry.contains('/')) {
        throw FormatException('Invalid Spring Boot asset entry: $entry');
      }
      return entry;
    }).toList();
  }
}
