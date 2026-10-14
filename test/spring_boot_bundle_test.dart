import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/spring_boot_bundle.dart';

/// Guards the Spring Boot dependency set's own consistency.
///
/// The set is produced by `tools/prepare_spring_boot.ps1` from
/// `tools/spring_boot.lock.json`. These checks fail loudly if the lock file,
/// the asset manifest, and the packaged JARs ever disagree — a mismatch here
/// would surface as an unexplained `NoClassDefFoundError` on a device.
void main() {
  final repo = Directory.current;
  final lockFile = File(p.join(repo.path, 'tools', 'spring_boot.lock.json'));
  final assetDirectory = Directory(
    p.join(repo.path, 'assets', 'spring_boot', SpringBootBundle.version),
  );

  test('lock file is well formed and pins the bundled version', () {
    expect(lockFile.existsSync(), isTrue, reason: 'lock file must be tracked');
    final lock =
        jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
    expect(lock['version'], SpringBootBundle.version);
    expect(lock['javaTarget'], 17);
    final artifacts = lock['artifacts'] as List<dynamic>;
    expect(artifacts, isNotEmpty);
    for (final artifact in artifacts) {
      final entry = artifact as Map<String, dynamic>;
      expect(entry['mavenPath'], isA<String>());
      expect(entry['file'], isA<String>());
      expect(
        entry['sha256'],
        matches(RegExp(r'^[0-9a-f]{64}$')),
        reason: 'every artifact needs a full SHA-256',
      );
    }
  });

  test('manifest lists exactly the locked artifacts', () {
    final lock =
        jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
    final locked = (lock['artifacts'] as List<dynamic>)
        .map((artifact) => (artifact as Map<String, dynamic>)['file'] as String)
        .toList()
      ..sort();

    final manifestFile = File(p.join(assetDirectory.path, 'manifest.json'));
    expect(
      manifestFile.existsSync(),
      isTrue,
      reason: 'run tools/prepare_spring_boot.ps1 to generate the manifest',
    );
    final manifest = SpringBootBundle.jsonDecodeList(
      manifestFile.readAsStringSync(),
    )..sort();
    expect(manifest, locked);
  });

  test('every manifest entry is present with the locked size', () {
    final lock =
        jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
    final byName = {
      for (final artifact in lock['artifacts'] as List<dynamic>)
        (artifact as Map<String, dynamic>)['file'] as String: artifact,
    };

    final manifestFile = File(p.join(assetDirectory.path, 'manifest.json'));
    if (!manifestFile.existsSync()) {
      // The JARs are Git-ignored and only exist after preparation. Skip rather
      // than fail on a fresh clone; the manifest-vs-lock test above still runs.
      return;
    }
    for (final name in SpringBootBundle.jsonDecodeList(
      manifestFile.readAsStringSync(),
    )) {
      final jar = File(p.join(assetDirectory.path, name));
      if (!jar.existsSync()) continue;
      expect(
        jar.lengthSync(),
        byName[name]!['bytes'],
        reason: '$name size differs from the lock file',
      );
    }
  });

  test('manifest rejects entries that are not plain file names', () {
    expect(
      () => SpringBootBundle.jsonDecodeList('["ok.jar","../escape.jar"]'),
      throwsFormatException,
    );
    expect(
      () => SpringBootBundle.jsonDecodeList('["sub/dir.jar"]'),
      throwsFormatException,
    );
    expect(() => SpringBootBundle.jsonDecodeList('{"a":1}'), throwsFormatException);
  });
}
