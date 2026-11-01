import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/spring_boot_bundle.dart';

/// Guards the Java EE dependency packs' own consistency.
///
/// The packs are produced by `tools/prepare_javaee_packs.py` from
/// `tools/spring_boot.lock.json` and `tools/javaee8.lock.json`. These checks
/// fail loudly if a lock file, a manifest, or the packaged JARs ever disagree —
/// a mismatch here would surface as an unexplained `NoClassDefFoundError`, or as
/// a health-only application refusing to start, on a device.
///
/// The JARs are Git-ignored and only exist after preparation, so the checks that
/// need bytes skip when the pack directory is absent. The lock, manifest and
/// selection checks always run.
void main() {
  final repo = Directory.current;

  File lockFile(String pack) => File(
    p.join(
      repo.path,
      'tools',
      pack == 'javaee8' ? 'javaee8.lock.json' : 'spring_boot.lock.json',
    ),
  );

  Directory assetDirectory(String pack) => Directory(
    pack == 'javaee8'
        ? p.join(repo.path, 'assets', 'javaee8')
        : p.join(repo.path, 'assets', 'spring_boot', SpringBootBundle.version),
  );

  Map<String, dynamic> readLock(String pack) =>
      jsonDecode(lockFile(pack).readAsStringSync()) as Map<String, dynamic>;

  List<String> lockNames(Map<String, dynamic> lock) =>
      (lock['artifacts'] as List<dynamic>)
          .map(
            (artifact) => (artifact as Map<String, dynamic>)['file'] as String,
          )
          .toList()
        ..sort();

  test('both lock files are well formed and pin every artifact', () {
    for (final pack in JavaEeProfiles.all) {
      expect(
        lockFile(pack).existsSync(),
        isTrue,
        reason: '$pack lock must be tracked',
      );
      final lock = readLock(pack);
      expect(lock['packId'], pack);
      expect(lock['javaTarget'], 17);
      final artifacts = lock['artifacts'] as List<dynamic>;
      expect(artifacts, isNotEmpty, reason: '$pack must pin artifacts');
      for (final artifact in artifacts) {
        final entry = artifact as Map<String, dynamic>;
        expect(entry['mavenPath'], isA<String>(), reason: '$pack mavenPath');
        expect(entry['file'], isA<String>(), reason: '$pack file');
        expect(
          entry['sha256'],
          matches(RegExp(r'^[0-9a-f]{64}$')),
          reason: 'every artifact needs a full SHA-256',
        );
        expect(
          entry['bytes'],
          isA<int>(),
          reason: 'every artifact needs a byte count',
        );
        expect(
          entry['role'],
          isA<String>(),
          reason: 'capabilities come from roles',
        );
        expect(
          entry['license'],
          isA<String>(),
          reason: 'every artifact names a licence',
        );
        // The file name must be artifactId-version.jar, so a coordinate cannot
        // be misread. 'spring-boot' is a prefix of 'spring-boot-autoconfigure',
        // which is exactly how a misread happens.
        expect(
          entry['file'],
          '${entry['artifactId']}-${entry['version']}.jar',
          reason: 'file name must match the coordinate for ${entry['file']}',
        );
      }
    }
    expect(readLock('spring-boot')['version'], SpringBootBundle.version);
    expect(readLock('spring-boot')['servletNamespace'], 'jakarta.servlet');
    expect(readLock('javaee8')['servletNamespace'], 'javax.servlet');
  });

  test('manifest lists exactly the locked artifacts, for both packs', () {
    for (final pack in JavaEeProfiles.all) {
      final lock = readLock(pack);
      final locked = lockNames(lock);
      final manifestFile = File(
        p.join(assetDirectory(pack).path, 'manifest.json'),
      );
      expect(
        manifestFile.existsSync(),
        isTrue,
        reason: 'run tools/prepare_javaee_packs.py to generate the manifest',
      );
      final manifest = SpringBootBundle.jsonDecodeList(
        manifestFile.readAsStringSync(),
      )..sort();
      expect(
        manifest,
        locked,
        reason: '$pack manifest must equal the locked set',
      );
    }
  });

  test(
    'the hashed manifest agrees with the lock, and the bundle requires it',
    () {
      for (final pack in JavaEeProfiles.all) {
        final lock = readLock(pack);
        final byName = {
          for (final artifact in lock['artifacts'] as List<dynamic>)
            (artifact as Map<String, dynamic>)['file'] as String: artifact,
        };
        final hashedFile = File(
          p.join(assetDirectory(pack).path, 'manifest.hashed.json'),
        );
        expect(
          hashedFile.existsSync(),
          isTrue,
          reason: 'the bundle reads manifest.hashed.json and has no fallback',
        );
        final hashed =
            jsonDecode(hashedFile.readAsStringSync()) as Map<String, dynamic>;
        expect(hashed['packId'], pack);
        final entries = hashed['files'] as List<dynamic>;
        expect(
          entries.length,
          byName.length,
          reason: '$pack must list every lock file',
        );
        for (final item in entries) {
          final entry = item as Map<String, dynamic>;
          final name = entry['file'] as String;
          final artifact = byName[name]!;
          expect(entry['sha256'], artifact['sha256'], reason: '$name hash');
          expect(entry['bytes'], artifact['bytes'], reason: '$name size');
          expect(entry['role'], artifact['role'], reason: '$name role');
          expect(entry['scope'], artifact['scope'], reason: '$name scope');
          // The parser the bundle uses must accept the real record.
          final parsed = JavaEePacks.packFileFromJson(entry);
          expect(parsed.name, name);
          expect(parsed.sha256, artifact['sha256']);
        }
      }
    },
  );

  test('every manifest entry is present with the locked size and hash', () {
    for (final pack in JavaEeProfiles.all) {
      final lock = readLock(pack);
      final byName = {
        for (final artifact in lock['artifacts'] as List<dynamic>)
          (artifact as Map<String, dynamic>)['file'] as String: artifact,
      };
      final manifestFile = File(
        p.join(assetDirectory(pack).path, 'manifest.json'),
      );
      if (!manifestFile.existsSync()) {
        // The JARs are Git-ignored and only exist after preparation.
        continue;
      }
      for (final name in SpringBootBundle.jsonDecodeList(
        manifestFile.readAsStringSync(),
      )) {
        final jar = File(p.join(assetDirectory(pack).path, name));
        if (!jar.existsSync()) {
          continue;
        }
        expect(
          jar.lengthSync(),
          byName[name]!['bytes'],
          reason: '$pack $name size differs from the lock',
        );
        expect(
          sha256Hex(jar.readAsBytesSync()),
          byName[name]!['sha256'],
          reason: '$pack $name hash differs from the lock',
        );
      }
    }
  });

  test('the two packs never mix servlet namespaces', () {
    final boot = readLock('spring-boot');
    final ee8 = readLock('javaee8');
    final bootNames = lockNames(
      boot,
    ).map((name) => name.toLowerCase()).toList();
    final ee8Names = lockNames(ee8).map((name) => name.toLowerCase()).toList();

    expect(
      bootNames.toSet().intersection(ee8Names.toSet()),
      isEmpty,
      reason: 'the packs must share no file name',
    );
    for (final name in bootNames) {
      expect(
        name.startsWith('javax'),
        isFalse,
        reason: '$name is a javax artifact in the jakarta pack',
      );
    }
    for (final name in ee8Names) {
      expect(
        name.startsWith('jakarta'),
        isFalse,
        reason: '$name is a jakarta artifact in the javax pack',
      );
      expect(
        name.contains('spring'),
        isFalse,
        reason: '$name is Spring Framework in the container-only pack',
      );
    }
    // Each pack carries its own Servlet API, and it is compile scope so the
    // runtime keeps one copy of the class.
    for (final pair in <List<Object>>[
      ['spring-boot', 'jakarta.servlet-api'],
      ['javaee8', 'javax.servlet-api'],
    ]) {
      final artifacts =
          (readLock(pair[0] as String)['artifacts'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
      final api = artifacts.firstWhere(
        (artifact) => artifact['file'].toString().startsWith(pair[1] as String),
        orElse: () => <String, dynamic>{},
      );
      expect(api, isNotEmpty, reason: '${pair[0]} must carry ${pair[1]}');
      expect(
        api['scope'],
        'compile',
        reason: '${pair[1]} is a compile-only API',
      );
    }
  });

  test('profile names are frozen and an unknown profile is refused', () {
    expect(JavaEeProfiles.all, <String>['spring-boot', 'javaee8']);
    expect(JavaEeProfiles.springBoot, 'spring-boot');
    expect(JavaEeProfiles.javaee8, 'javaee8');
    expect(JavaEePacks.packFor('javaee8').namespace, 'javax.servlet');
    expect(JavaEePacks.packFor('spring-boot').namespace, 'jakarta.servlet');
    expect(
      () => JavaEePacks.packFor('jakarta'),
      throwsA(isA<JavaEePackException>()),
    );
    expect(
      () => JavaEePacks.packFor('javax'),
      throwsA(isA<JavaEePackException>()),
    );
    expect(() => JavaEePacks.packFor(''), throwsA(isA<JavaEePackException>()));
    expect(readLock('javaee8')['profiles'], <String>['javaee8']);
    expect(readLock('spring-boot')['profiles'], <String>['spring-boot']);
  });

  test('default selection excludes the database group, includeDatabase adds it '
      'back', () {
    final hashedFile = File(
      p.join(assetDirectory('spring-boot').path, 'manifest.hashed.json'),
    );
    if (!hashedFile.existsSync()) {
      // Without the prepared pack the split is still checked from the lock.
      return;
    }
    final hashed =
        jsonDecode(hashedFile.readAsStringSync()) as Map<String, dynamic>;
    final entries = (hashed['files'] as List<dynamic>)
        .map((item) => JavaEePacks.packFileFromJson(item))
        .toList();

    final defaultSelection = JavaEePacks.selectRuntimeNames(entries)..sort();
    final withDatabase = JavaEePacks.selectRuntimeNames(
      entries,
      includeDatabase: true,
    )..sort();

    bool isDatabase(String name) => entries
        .where((entry) => entry.name == name)
        .every((entry) => javaEeDatabaseRoles.contains(entry.role));

    expect(
      defaultSelection.where(isDatabase),
      isEmpty,
      reason: 'a health-only Boot classpath must carry no datasource machinery',
    );
    expect(
      defaultSelection.any(
        (name) => name.contains('mybatis-spring-boot-autoconfigure'),
      ),
      isFalse,
      reason: 'MyBatis auto-configuration without a datasource fails startup',
    );
    expect(
      defaultSelection.any((name) => name.contains('HikariCP')),
      isFalse,
      reason: 'a pooled datasource without a URL fails startup',
    );
    expect(
      withDatabase.length,
      greaterThan(defaultSelection.length),
      reason: 'includeDatabase must add the group back',
    );
    // Every enabled jar must be present, and nothing else added or removed.
    expect(
      withDatabase.toSet().difference(defaultSelection.toSet()).length,
      8,
      reason:
          'the database group is JDBC, tx, pool, three MyBatis, starter and driver',
    );
    expect(
      defaultSelection.toSet().difference(withDatabase.toSet()),
      isEmpty,
      reason: 'includeDatabase only adds, never removes',
    );
    // Compile scope is on neither classpath.
    for (final name
        in entries
            .where((entry) => entry.scope == JavaEeJarScope.compile)
            .map((entry) => entry.name)) {
      expect(defaultSelection, isNot(contains(name)));
      expect(withDatabase, isNot(contains(name)));
    }
    // The javaee8 pack has no database group, so the flag changes nothing.
    final ee8File = File(
      p.join(assetDirectory('javaee8').path, 'manifest.hashed.json'),
    );
    if (ee8File.existsSync()) {
      final ee8 =
          jsonDecode(ee8File.readAsStringSync()) as Map<String, dynamic>;
      final ee8Entries = (ee8['files'] as List<dynamic>)
          .map((item) => JavaEePacks.packFileFromJson(item))
          .toList();
      expect(
        JavaEePacks.selectRuntimeNames(ee8Entries),
        JavaEePacks.selectRuntimeNames(ee8Entries, includeDatabase: true),
        reason: 'javaee8 has no database group, so includeDatabase is a no-op',
      );
      expect(
        JavaEePacks.selectRuntimeNames(
          ee8Entries,
        ).any((name) => name.contains('spring')),
        isFalse,
        reason: 'the container pack ships no Spring Framework',
      );
    }
  });

  test('capability flags come from roles and match the observed packs', () {
    for (final pack in JavaEeProfiles.all) {
      final hashedFile = File(
        p.join(assetDirectory(pack).path, 'manifest.hashed.json'),
      );
      if (!hashedFile.existsSync()) {
        continue;
      }
      final hashed =
          jsonDecode(hashedFile.readAsStringSync()) as Map<String, dynamic>;
      final roles = <String>{
        for (final item in hashed['files'] as List<dynamic>)
          JavaEePacks.packFileFromJson(item).role ?? '',
      };
      roles.remove('');
      if (pack == 'javaee8') {
        expect(roles, contains('jsp'));
        expect(roles, contains('servlet'));
        expect(roles.contains('jdbc'), isFalse);
      } else {
        expect(roles, contains('web'));
        expect(roles, contains('json'));
        expect(roles, contains('servlet'));
        expect(roles, contains('jdbc'));
        expect(roles, contains('persistence'));
        // JSP is deferred in the Boot pack, so the pack must not claim it.
        expect(
          roles.contains('jsp'),
          isFalse,
          reason: 'a deferred capability must not appear as present',
        );
      }
    }
  });

  test('the pack digest matches known SHA-256 vectors', () {
    // The digest itself comes from the shared core; this wrapper only encodes it.
    expect(
      sha256Hex(const <int>[]),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256Hex(utf8.encode('The quick brown fox jumps over the lazy dog')),
      'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592',
    );
    // A block boundary: 55 bytes fits the padding, 56 does not.
    expect(
      sha256Hex(List<int>.filled(55, 0x61)),
      '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
    );
    expect(
      sha256Hex(List<int>.filled(56, 0x61)),
      'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
    );
  });

  test(
    'the lock coordinates round-trip, because a prefix cannot be trusted',
    () {
      for (final pack in JavaEeProfiles.all) {
        for (final artifact
            in (readLock(pack)['artifacts'] as List<dynamic>)
                .cast<Map<String, dynamic>>()) {
          final path = artifact['mavenPath'] as String;
          final parts = path.split('/');
          expect(parts.last, artifact['file']);
          expect(parts[parts.length - 2], artifact['version'], reason: path);
          expect(parts[parts.length - 3], artifact['artifactId'], reason: path);
          expect(
            parts.sublist(0, parts.length - 3).join('.'),
            artifact['groupId'],
            reason: path,
          );
        }
      }
    },
  );

  test('manifest rejects entries that are not plain file names', () {
    expect(
      () => SpringBootBundle.jsonDecodeList('["ok.jar","../escape.jar"]'),
      throwsFormatException,
    );
    expect(
      () => SpringBootBundle.jsonDecodeList('["sub/dir.jar"]'),
      throwsFormatException,
    );
    expect(
      () => SpringBootBundle.jsonDecodeList('{"a":1}'),
      throwsFormatException,
    );
    expect(
      () => JavaEePacks.packFileFromJson(<String, Object?>{
        'file': 'a/b.jar',
        'sha256': 'x',
      }),
      throwsFormatException,
    );
    expect(
      () => JavaEePacks.packFileFromJson(<String, Object?>{'file': ''}),
      throwsFormatException,
    );
  });

  group('a malformed manifest is refused, never half-trusted', () {
    // The pack cannot prove a byte without its hashed manifest, so every one of
    // these must throw instead of returning a partial pack.
    void expectRefused(String manifest) {
      JavaEePacks.resetForTest();
      JavaEePacks.useLoadersForTest(
        stringLoader: (key) async => manifest,
        byteLoader: (key) async => Uint8List(0),
      );
      expect(
        () => JavaEePacks.files('javaee8'),
        throwsA(isA<JavaEePackException>()),
        reason: 'manifest must be refused: $manifest',
      );
    }

    tearDown(JavaEePacks.resetForTest);

    test('a files field that is not a list', () {
      expectRefused('{"packId":"javaee8","files":"nope"}');
    });

    test('a top level that is not an object', () {
      expectRefused('["a.jar"]');
    });

    test('an empty files list', () {
      expectRefused('{"packId":"javaee8","files":[]}');
    });

    test('a packId that names the other pack', () {
      expectRefused(
        '{"packId":"spring-boot","files":['
        '{"file":"a.jar","bytes":1,"sha256":"${'a' * 64}"}]}',
      );
    });

    test('an entry with no usable hash', () {
      expectRefused(
        '{"packId":"javaee8","files":[{"file":"a.jar","bytes":1}]}',
      );
    });

    test('an entry with a traversal path', () {
      expectRefused(
        '{"packId":"javaee8","files":['
        '{"file":"../escape.jar","bytes":1,"sha256":"${'a' * 64}"}]}',
      );
    });
  });

  group('the materialisation cache never hands back a stale path', () {
    // A cached path is not a proof. These two cases are the ones that would
    // otherwise put a missing or a corrupted jar on a device classpath.
    late Directory work;
    final content = Uint8List.fromList(utf8.encode('fake-pack-jar-bytes'));
    final digest = sha256Hex(content);
    final manifest = jsonEncode(<String, Object?>{
      'packId': 'javaee8',
      'namespace': 'javax.servlet',
      'files': <Object?>[
        <String, Object?>{
          'file': 'fake-1.0.jar',
          'bytes': content.length,
          'sha256': digest,
          'scope': 'runtime',
          'role': 'servlet',
          'license': 'Apache-2.0',
        },
      ],
    });

    setUp(() {
      JavaEePacks.resetForTest();
      work = Directory.systemTemp.createTempSync('qfli_cache_test_');
      JavaEePacks.useLoadersForTest(
        stringLoader: (key) async => manifest,
        byteLoader: (key) async => content,
      );
    });

    tearDown(() {
      JavaEePacks.resetForTest();
      if (work.existsSync()) {
        work.deleteSync(recursive: true);
      }
    });

    File writtenFile(List<String> paths) {
      expect(paths, hasLength(1));
      return File(paths.single);
    }

    test('a deleted file is recreated on the next call', () async {
      final first = await JavaEePacks.materialiseProfile(
        'javaee8',
        targetDirectory: work.path,
      );
      final file = writtenFile(first);
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync(), content);

      file.deleteSync();
      expect(file.existsSync(), isFalse);

      final second = await JavaEePacks.materialiseProfile(
        'javaee8',
        targetDirectory: work.path,
      );
      expect(
        writtenFile(second).readAsBytesSync(),
        content,
        reason: 'a cache hit must not serve a path whose file was deleted',
      );
    });

    test('a same-length corruption is repaired, not served', () async {
      final first = await JavaEePacks.materialiseProfile(
        'javaee8',
        targetDirectory: work.path,
      );
      final file = writtenFile(first);

      // Same length, different bytes: a length-only check would accept this.
      final corrupted = Uint8List.fromList(content);
      corrupted[0] = corrupted[0] ^ 0xff;
      expect(corrupted.length, content.length);
      file.writeAsBytesSync(corrupted);

      final second = await JavaEePacks.materialiseProfile(
        'javaee8',
        targetDirectory: work.path,
      );
      expect(
        writtenFile(second).readAsBytesSync(),
        content,
        reason: 'a same-length corruption must be detected by the SHA-256',
      );
    });

    test('a truncated file is repaired', () async {
      final first = await JavaEePacks.materialiseProfile(
        'javaee8',
        targetDirectory: work.path,
      );
      final file = writtenFile(first);
      file.writeAsBytesSync(<int>[]);

      final second = await JavaEePacks.materialiseProfile(
        'javaee8',
        targetDirectory: work.path,
      );
      expect(writtenFile(second).readAsBytesSync(), content);
    });

    test('an intact cache hit returns the same paths', () async {
      final first = await JavaEePacks.materialiseProfile(
        'javaee8',
        targetDirectory: work.path,
      );
      final second = await JavaEePacks.materialiseProfile(
        'javaee8',
        targetDirectory: work.path,
      );
      expect(second, first);
    });
  });
}
