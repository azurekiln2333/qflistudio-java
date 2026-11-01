import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_web_project.dart';

/// Unit tests for the Java Web config decoder.
///
/// Every case here is a pure function over text and paths, so it runs without a
/// JDK. The decoder is the single place that turns `.qfli-java-web.json` into a
/// typed config; the runner and the environment page both consume it.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('qfli_java_web_config_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File writeConfig(Object? content) {
    final file = File(p.join(root.path, JavaWebProject.configFileName));
    file.writeAsStringSync(content is String ? content : jsonEncode(content));
    return file;
  }

  JavaWebProject decode(Map<String, Object?> json) =>
      JavaWebProject.fromJson(json, projectRoot: root.path);

  Map<String, Object?> minimal([Map<String, Object?> overrides = const {}]) => {
    'schemaVersion': 1,
    'profile': 'spring-boot',
    ...overrides,
  };

  JavaWebProjectException failureFrom(Object? json) {
    expect(
      () => JavaWebProject.fromJson(json, projectRoot: root.path),
      throwsA(isA<JavaWebProjectException>()),
    );
    try {
      JavaWebProject.fromJson(json, projectRoot: root.path);
    } on JavaWebProjectException catch (error) {
      return error;
    }
    throw StateError('decoder accepted a document it should have refused');
  }

  group('load', () {
    test('returns null when the project carries no config file', () async {
      expect(await JavaWebProject.load(root.path), isNull);
    });

    test(
      'returns null when the config file is absent after a nested root',
      () async {
        final nested = Directory(p.join(root.path, 'nested'))..createSync();
        expect(await JavaWebProject.load(nested.path), isNull);
      },
    );

    test('refuses an empty project path', () async {
      await expectLater(
        JavaWebProject.load('   '),
        throwsA(
          isA<JavaWebProjectException>().having(
            (error) => error.code,
            'code',
            'invalid-project-path',
          ),
        ),
      );
    });

    test('refuses a config path that is not a regular file', () async {
      Directory(p.join(root.path, JavaWebProject.configFileName)).createSync();
      await expectLater(
        JavaWebProject.load(root.path),
        throwsA(
          isA<JavaWebProjectException>().having(
            (error) => error.code,
            'code',
            'invalid-config-entry',
          ),
        ),
      );
    });

    test('reports malformed JSON instead of guessing defaults', () async {
      writeConfig('{ not json ');
      await expectLater(
        JavaWebProject.load(root.path),
        throwsA(
          isA<JavaWebProjectException>().having(
            (error) => error.code,
            'code',
            'malformed-json',
          ),
        ),
      );
    });

    test('accepts a leading UTF-8 byte order mark', () async {
      writeConfig('\uFEFF${jsonEncode(minimal())}');
      final project = await JavaWebProject.load(root.path);
      expect(project, isNotNull);
      expect(project!.profile, 'spring-boot');
    });

    test('keeps the decoded values of a complete document', () async {
      writeConfig(
        minimal({
          'mainClass': 'example.Application',
          'port': 9090,
          'contextPath': '/demo/',
          'webRoot': 'src/main/webapp',
        }),
      );
      final project = await JavaWebProject.load(root.path);
      expect(project!.mainClass, 'example.Application');
      expect(project.port, 9090);
      expect(project.contextPath, '/demo');
      expect(project.webRoot, 'src/main/webapp');
    });

    test('accepts an explicit javaee8 profile', () async {
      writeConfig(minimal({'profile': 'javaee8'}));
      final project = await JavaWebProject.load(root.path);
      expect(project!.profile, JavaWebProject.profileJavaee8);
      expect(project.usesJavaxNamespace, isTrue);
    });
  });

  group('defaults', () {
    test('fills port, context path and web root when omitted', () {
      final project = decode(minimal());
      expect(project.port, JavaWebProject.defaultPort);
      expect(project.contextPath, JavaWebProject.defaultContextPath);
      expect(project.webRoot, JavaWebProject.defaultWebRoot);
      expect(project.mainClass, isNull);
      expect(project.schemaVersion, JavaWebProject.currentSchemaVersion);
    });

    test('derives the addresses and roots a runner needs', () {
      final project = decode(
        minimal({
          'mainClass': 'example.web.Application',
          'port': 8081,
          'contextPath': '/demo',
        }),
      );
      expect(project.localAddress, 'http://127.0.0.1:8081/demo');
      expect(project.packageName, 'example.web');
      expect(project.mainSourceRoot, p.join(root.path, 'src', 'main', 'java'));
      expect(
        project.resourcesRoot,
        p.join(root.path, 'src', 'main', 'resources'),
      );
      expect(project.webRootPath, p.join(root.path, 'src', 'main', 'webapp'));
    });

    test('reports no package when the main class has none', () {
      expect(decode(minimal({'mainClass': 'Application'})).packageName, '');
      expect(decode(minimal()).packageName, '');
    });

    test('assigns each profile its servlet namespace', () {
      expect(decode(minimal()).usesJakartaNamespace, isTrue);
      expect(decode(minimal()).usesJavaxNamespace, isFalse);
      expect(
        decode(minimal({'profile': 'javaee8'})).usesJakartaNamespace,
        isFalse,
      );
      expect(
        decode(minimal({'profile': 'javaee8'})).usesJavaxNamespace,
        isTrue,
      );
    });

    test('a known profile is launch ready and states no blocker', () {
      for (final profile in JavaWebProject.knownProfiles) {
        final project = decode(minimal({'profile': profile}));
        expect(project.isLaunchReady, isTrue, reason: profile);
        expect(project.launchBlockedReason, isNull, reason: profile);
      }
    });

    test('toJson round-trips through the decoder', () {
      final original = decode(
        minimal({
          'mainClass': 'example.Application',
          'port': 9090,
          'contextPath': '/demo',
          'webRoot': 'docs',
        }),
      );
      final reloaded = JavaWebProject.fromJson(
        original.toJson(),
        projectRoot: root.path,
      );
      expect(reloaded, original);
      expect(reloaded.hashCode, original.hashCode);
      expect(reloaded.toJson(), original.toJson());
    });

    test('toJson omits an absent main class', () {
      expect(decode(minimal()).toJson().containsKey('mainClass'), isFalse);
    });
  });

  group('schema', () {
    test('refuses a non-object root', () {
      expect(failureFrom(<Object>[]).code, 'config-not-object');
      expect(failureFrom('text').code, 'config-not-object');
      expect(failureFrom(null).code, 'config-not-object');
    });

    test('refuses an unsupported schema version', () {
      expect(
        failureFrom(minimal({'schemaVersion': 2})).code,
        'unsupported-schema-version',
      );
      expect(
        failureFrom(minimal({'schemaVersion': '1'})).code,
        'unsupported-schema-version',
      );
      expect(
        failureFrom(<String, Object?>{'profile': 'spring-boot'}).code,
        'unsupported-schema-version',
      );
    });

    test('refuses an unknown profile', () {
      expect(
        failureFrom(minimal({'profile': 'jakarta'})).code,
        'unsupported-profile',
      );
      expect(
        failureFrom(minimal({'profile': 'SPRING-BOOT'})).code,
        'unsupported-profile',
      );
      expect(failureFrom(minimal({'profile': 3})).code, 'unsupported-profile');
      expect(
        failureFrom(minimal({'profile': null})).code,
        'unsupported-profile',
      );
    });
  });

  group('mainClass', () {
    test('accepts plain and packaged class names', () {
      expect(
        decode(minimal({'mainClass': 'Application'})).mainClass,
        'Application',
      );
      expect(decode(minimal({'mainClass': 'a.b.C'})).mainClass, 'a.b.C');
      expect(
        decode(minimal({'mainClass': r'a.b.$C_D1'})).mainClass,
        r'a.b.$C_D1',
      );
    });

    test('refuses whitespace, separators and empty text', () {
      for (final value in <Object?>[
        '',
        ' example.Application',
        'example.Application ',
        'example/Application',
        'example\\Application',
        'example:Application',
        'example;Application',
        'example. application',
        42,
      ]) {
        expect(
          failureFrom(minimal({'mainClass': value})).code,
          'invalid-main-class',
          reason: '$value',
        );
      }
    });

    test('refuses malformed segments and Java keywords', () {
      for (final value in <String>[
        '.Application',
        'Application.',
        'example..Application',
        'example.9Application',
        'example.class',
        'example.package.Application',
        'example.int',
        'example.-bad',
      ]) {
        expect(
          failureFrom(minimal({'mainClass': value})).code,
          'invalid-main-class',
          reason: value,
        );
      }
    });

    test('leaves an absent main class to the entry file', () {
      expect(decode(minimal({'mainClass': null})).mainClass, isNull);
    });
  });

  group('port', () {
    test('accepts the full TCP range', () {
      expect(decode(minimal({'port': 1})).port, 1);
      expect(decode(minimal({'port': 65535})).port, 65535);
    });

    test('refuses zero, out-of-range and non-integer values', () {
      for (final value in <Object?>[
        0,
        -1,
        65536,
        70000,
        '8080',
        8080.5,
        true,
        null,
      ]) {
        final code = value == null
            ? decode(minimal({'port': null})).port
            : failureFrom(minimal({'port': value})).code;
        if (value == null) {
          expect(code, JavaWebProject.defaultPort);
        } else {
          expect(code, 'invalid-port', reason: '$value');
        }
      }
    });
  });

  group('contextPath', () {
    test('normalizes the accepted forms', () {
      expect(decode(minimal({'contextPath': '/'})).contextPath, '/');
      expect(decode(minimal({'contextPath': '/demo'})).contextPath, '/demo');
      expect(decode(minimal({'contextPath': '/demo/'})).contextPath, '/demo');
      expect(decode(minimal({'contextPath': '/a//b/'})).contextPath, '/a/b');
      expect(decode(minimal({'contextPath': '/a/./b'})).contextPath, '/a/b');
      expect(decode(minimal({'contextPath': '//'})).contextPath, '/');
    });

    test('refuses values that cannot mount a context', () {
      for (final value in <Object?>[
        '',
        'demo',
        '/a/../b',
        '/a b',
        '/a?b',
        '/a#b',
        r'/a\b',
        7,
        null,
      ]) {
        final normalized = value == null
            ? decode(minimal({'contextPath': null})).contextPath
            : failureFrom(minimal({'contextPath': value})).code;
        if (value == null) {
          expect(normalized, JavaWebProject.defaultContextPath);
        } else {
          expect(normalized, 'invalid-context-path', reason: '$value');
        }
      }
    });

    test('normalizeContextPath is usable on its own', () {
      expect(JavaWebProject.normalizeContextPath('/demo/'), '/demo');
      expect(JavaWebProject.normalizeContextPath('demo'), isNull);
      expect(JavaWebProject.normalizeContextPath('/'), '/');
      expect(JavaWebProject.normalizeContextPath('/a/../b'), isNull);
    });
  });

  group('webRoot', () {
    test('accepts and normalizes project-relative paths', () {
      expect(
        decode(minimal({'webRoot': 'src/main/webapp'})).webRoot,
        'src/main/webapp',
      );
      expect(decode(minimal({'webRoot': 'docs'})).webRoot, 'docs');
      expect(decode(minimal({'webRoot': 'a\\b'})).webRoot, 'a/b');
      expect(decode(minimal({'webRoot': 'a//b/'})).webRoot, 'a/b');
      expect(decode(minimal({'webRoot': './docs'})).webRoot, 'docs');
    });

    test('refuses absolute, escaping and empty paths', () {
      for (final value in <Object?>[
        '',
        '   ',
        '/docs',
        'C:/docs',
        '../docs',
        'a/../b',
        '.',
        '..',
        9,
      ]) {
        expect(
          failureFrom(minimal({'webRoot': value})).code,
          'invalid-web-root',
          reason: '$value',
        );
      }
    });

    test('refuses a path that resolves outside the project', () {
      final outer = Directory(
        p.join(root.parent.path, 'outside_web_${root.path.hashCode}'),
      )..createSync();
      addTearDown(() => outer.deleteSync(recursive: true));
      expect(
        failureFrom(<String, Object?>{
          'schemaVersion': 1,
          'profile': 'spring-boot',
          'webRoot': '../${p.basename(outer.path)}',
        }).code,
        'invalid-web-root',
      );
    });

    test('resolveWebRoot keeps the value inside the project', () {
      final project = decode(minimal({'webRoot': 'docs'}));
      expect(project.webRootPath, p.join(root.path, 'docs'));
    });
  });

  group('database', () {
    test('defaults to false so a health-only app gets no data source', () {
      final project = decode(minimal());
      expect(project.database, isFalse);
      expect(project.databaseEnabled, isFalse);
      expect(project.toJson()['database'], isFalse);
    });

    test('accepts an explicit true and an explicit false', () {
      final enabled = decode(minimal({'database': true}));
      expect(enabled.database, isTrue);
      expect(enabled.databaseEnabled, isTrue);
      expect(enabled.toJson()['database'], isTrue);

      final disabled = decode(minimal({'database': false}));
      expect(disabled.database, isFalse);
      expect(disabled.databaseEnabled, isFalse);
    });

    test('refuses a non-boolean instead of coercing it', () {
      for (final value in <Object?>[
        'true',
        'false',
        'TRUE',
        1,
        0,
        <String>[],
        <String, Object?>{},
      ]) {
        expect(
          failureFrom(minimal({'database': value})).code,
          'invalid-database',
          reason: '$value',
        );
      }
    });

    test('treats an absent key and an explicit null as the default', () {
      expect(decode(minimal()).database, JavaWebProject.defaultDatabase);
      expect(
        decode(minimal({'database': null})).database,
        JavaWebProject.defaultDatabase,
      );
    });

    test('a changed flag changes identity and survives a round trip', () {
      final off = decode(minimal({'database': false}));
      final on = decode(minimal({'database': true}));
      expect(on, isNot(off));
      expect(on.hashCode, isNot(off.hashCode));
      expect(off.toString(), contains('database: false'));
      expect(JavaWebProject.fromJson(on.toJson(), projectRoot: root.path), on);
    });

    test('the flag is independent of the profile', () {
      for (final profile in JavaWebProject.knownProfiles) {
        expect(
          decode(
            minimal({'profile': profile, 'database': true}),
          ).databaseEnabled,
          isTrue,
          reason: profile,
        );
        expect(
          decode(minimal({'profile': profile})).databaseEnabled,
          isFalse,
          reason: profile,
        );
      }
    });
  });

  group('contract constants', () {
    test('the config file name is fixed and documented once', () {
      expect(JavaWebProject.configFileName, '.qfli-java-web.json');
      expect(JavaWebProject.currentSchemaVersion, 1);
      expect(JavaWebProject.knownProfiles, <String>['spring-boot', 'javaee8']);
      expect(JavaWebProject.isKnownProfile('spring-boot'), isTrue);
      expect(JavaWebProject.isKnownProfile('javaee8'), isTrue);
      expect(JavaWebProject.isKnownProfile('servlet'), isFalse);
      expect(JavaWebProject.isKnownProfile(null), isFalse);
    });

    test('the exception carries a stable code and a message', () {
      const failure = JavaWebProjectException('invalid-port', '端口不合法。');
      expect(failure.code, 'invalid-port');
      expect(failure.message, '端口不合法。');
      expect(failure.toString(), 'invalid-port: 端口不合法。');
    });
  });
}
