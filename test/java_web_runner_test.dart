import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_java/java_web_project.dart';
import 'package:qfli_java/javaee_container_launcher.dart';
import 'package:qfli_java/spring_boot_bundle.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';

/// Runner tests for the opted-in Web path.
///
/// Every external effect is injected, so the whole path runs without a JDK, a
/// JVM or a socket. The real JDK and real HTTP are the acceptance test's job.
void main() {
  late Directory root;
  late Directory project;
  late Directory jdkHome;

  setUp(() {
    root = Directory.systemTemp.createTempSync('qfli_web_runner_');
    project = Directory(p.join(root.path, 'project'))..createSync();
    // _findJdk() looks for <home>/bin/java and <home>/bin/javac.
    jdkHome = Directory(p.join(root.path, 'jdk'))..createSync();
    final bin = Directory(p.join(jdkHome.path, 'bin'))..createSync();
    for (final tool in <String>['java', 'javac']) {
      File(
        p.join(bin.path, Platform.isWindows ? '$tool.exe' : tool),
      ).writeAsStringSync('');
    }
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void write(String relative, String content) {
    final file = File(p.join(project.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void writeConfig(Map<String, Object?> config) {
    write(
      JavaWebProject.configFileName,
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'profile': 'spring-boot',
        ...config,
      }),
    );
  }

  /// A real ZIP so the namespace scan reads actual archive entries.
  String writeJar(String name, List<String> entries) {
    final file = File(p.join(project.path, name));
    file.parent.createSync(recursive: true);
    final archive = Archive();
    for (final entry in entries) {
      archive.add(ArchiveFile.string(entry, 'x'));
    }
    file.writeAsBytesSync(ZipEncoder().encode(archive));
    return file.path;
  }

  void writeBootSources() {
    write('src/main/java/example/Application.java', 'package example;\n');
    write('src/main/resources/static/probe.txt', 'static');
  }

  JavaProgramRunner runner({
    JavaWebCompiler? compiler,
    JavaWebDependencyProvider? dependencies,
    JavaWebProcessFactory? processFactory,
    JavaWebReadinessProbe? probe,
    JavaWebPortCheck? portCheck,
    JavaeeContainerPackProvider? pack,
    Duration readyTimeout = const Duration(seconds: 2),
    Duration startWait = const Duration(seconds: 2),
    Duration drainWindow = const Duration(seconds: 2),
  }) => JavaProgramRunner(
    javaHome: jdkHome.path,
    webCompiler: compiler,
    webDependencyProvider: dependencies,
    webProcessFactory: processFactory,
    webReadinessProbe: probe,
    webPortAvailable: portCheck,
    javaeeContainerPackProvider: pack,
    webReadyTimeout: readyTimeout,
    webStartWait: startWait,
    webDrainWindow: drainWindow,
  );

  Future<ProgramRunResult?> run(JavaProgramRunner instance) => instance.run(
    projectPath: project.path,
    entryFile: p.join(project.path, 'src/main/java/example/Application.java'),
  );

  Future<List<String>> readUntil(
    Stream<String> stream, {
    required bool Function(List<String>) until,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final lines = <String>[];
    final reached = Completer<void>();
    final subscription = stream.listen((line) {
      lines.add(line);
      if (!reached.isCompleted && until(lines)) reached.complete();
    });
    try {
      await reached.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
    return lines;
  }

  group('spring-boot launch', () {
    test(
      'compiles the main tree and passes loopback server arguments',
      () async {
        writeBootSources();
        writeConfig(<String, Object?>{'mainClass': 'example.Application'});

        final compiled = <JavaWebCompileRequest>[];
        final launches = <JavaWebProcessRequest>[];
        final fake = _FakeServer();

        final result = await run(
          runner(
            compiler: (request) async {
              compiled.add(request);
              return ProcessResult(1, 0, '', '');
            },
            dependencies:
                (
                  profile, {
                  required includeDatabase,
                  required targetDirectory,
                }) async => <String>[
                  writeJar('jars/boot.zip', <String>[
                    'jakarta/servlet/x.class',
                  ]),
                ],
            processFactory: (request) async {
              launches.add(request);
              return fake.handle;
            },
            probe: (uri) async => 200,
            portCheck: (_) async => true,
          ),
        );

        expect(result, isNotNull);
        expect(launches, hasLength(1));
        final launch = launches.single;
        expect(launch.workingDirectory, p.normalize(p.absolute(project.path)));

        final args = launch.arguments;
        final classpathIndex = args.indexOf('-classpath');
        expect(classpathIndex, greaterThanOrEqualTo(0));
        expect(args[classpathIndex + 1], contains('classes'));
        final mainIndex = args.indexOf('example.Application');
        expect(mainIndex, greaterThan(classpathIndex));
        expect(args.sublist(mainIndex + 1), <String>[
          '--server.address=127.0.0.1',
          '--server.port=8080',
        ]);
        final compileArgs = compiled.single.arguments;
        expect(
          compileArgs,
          containsAll(<String>['--release', '17', '-classpath']),
        );
        expect(compileArgs.last, contains('Application.java'));
        expect(
          compiled.single.workingDirectory,
          p.normalize(p.absolute(project.path)),
        );

        // The configured address is announced before any response.
        final lines = await readUntil(
          result!.stdout,
          until: (seen) => seen.any((line) => line.contains('可响应')),
        );
        expect(lines.first, contains('本地地址（配置）'));
        expect(lines.first, contains('http://127.0.0.1:8080/'));
        expect(lines.any((line) => line.contains('可响应')), isTrue);

        await result.cancel!();
        expect(await result.exitCode, 0);
      },
    );

    test('sends the configured context path for a non-root context', () async {
      writeBootSources();
      writeConfig(<String, Object?>{'contextPath': '/demo', 'port': 9091});

      final launches = <JavaWebProcessRequest>[];
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[],
          processFactory: (request) async {
            launches.add(request);
            return _FakeServer().handle;
          },
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 300),
        ),
      );

      expect(result, isNotNull);
      expect(
        launches.single.arguments,
        containsAll(<String>[
          '--server.address=127.0.0.1',
          '--server.port=9091',
          '--server.servlet.context-path=/demo',
        ]),
      );
      expect(
        launches.single.arguments.where((a) => a.contains('server.port')),
        hasLength(1),
      );
      await result!.cancel!();
    });

    test('always overrides the context path, even for the root', () async {
      writeBootSources();
      // A stale value in the project's own properties must not survive.
      write(
        'src/main/resources/application.properties',
        'server.servlet.context-path=/old\nserver.port=1\n',
      );
      writeConfig(<String, Object?>{'contextPath': '/', 'port': 9092});

      final launches = <JavaWebProcessRequest>[];
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async {
            launches.add(request);
            return _FakeServer().handle;
          },
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 300),
        ),
      );

      final args = launches.single.arguments;
      // Empty is Boot's explicit request for the root context.
      expect(args, contains('--server.servlet.context-path='));
      // Exactly one context-path argument, and exactly one port argument.
      expect(
        args.where((a) => a.startsWith('--server.servlet.context-path=')),
        hasLength(1),
      );
      expect(args, contains('--server.port=9092'));
      // The address the UI reports matches the argument that was sent.
      await result!.cancel!();
    });

    test(
      'an empty dependency set is refused instead of running blind',
      () async {
        writeBootSources();
        writeConfig(<String, Object?>{});

        var launched = false;
        final result = await run(
          runner(
            compiler: (request) async => ProcessResult(1, 0, '', ''),
            dependencies:
                (
                  profile, {
                  required includeDatabase,
                  required targetDirectory,
                }) async => <String>[],
            processFactory: (request) async {
              launched = true;
              return _FakeServer().handle;
            },
            portCheck: (_) async => true,
          ),
        );

        expect(result, isNotNull);
        expect(await result!.exitCode, kProgramNotRunExitCode);
        expect(launched, isFalse);
      },
    );
  });

  group('database flag', () {
    test('defaults to false and reaches the dependency provider', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      final seen = <bool>[];
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async {
                seen.add(includeDatabase);
                return <String>[];
              },
          portCheck: (_) async => true,
        ),
      );
      expect(result, isNotNull);
      expect(seen, <bool>[false]);
      expect(await result!.exitCode, kProgramNotRunExitCode);
    });

    test('true opts into the database group for the same profile', () async {
      writeBootSources();
      writeConfig(<String, Object?>{'database': true});

      final profiles = <String>[];
      final seen = <bool>[];
      await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async {
                profiles.add(profile);
                seen.add(includeDatabase);
                return <String>[];
              },
          portCheck: (_) async => true,
        ),
      );
      expect(profiles, <String>['spring-boot']);
      expect(seen, <bool>[true]);
    });

    test('a project with its own JARs keeps them on the classpath', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});
      final own = writeJar('libs/own.zip', <String>['com/example/Lib.class']);

      final launches = <JavaWebProcessRequest>[];
      await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async {
            launches.add(request);
            return _FakeServer().handle;
          },
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 300),
        ),
      );

      expect(launches, hasLength(1));
      final classpath = launches
          .single
          .arguments[launches.single.arguments.indexOf('-classpath') + 1];
      expect(classpath, contains(own));
    });
  });

  group('port guard', () {
    test('an occupied port refuses and starts nothing', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      var launched = false;
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[],
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
          portCheck: (_) async => false,
        ),
      );

      expect(result, isNotNull);
      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
      expect(await result.stderr.join('\n'), contains('端口 8080'));
    });

    test('the real check reports a bound loopback port as taken', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => socket.close());
      final occupied = socket.port;

      var launched = false;
      writeBootSources();
      writeConfig(<String, Object?>{'port': occupied});
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[],
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
          // No portCheck seam: the real bind must refuse.
          probe: (uri) async => 200,
        ),
      );

      expect(result, isNotNull);
      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
    });
  });

  group('readiness reporting', () {
    test('a response while the process is terminal is not reported', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      final fake = _FakeServer();
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async => fake.handle,
          // Something answers, but the owned process is already gone.
          probe: (uri) async {
            await fake.finish(1);
            return 200;
          },
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 600),
        ),
      );

      final lines = await readUntil(
        result!.stdout,
        until: (seen) => seen.isNotEmpty,
        timeout: const Duration(seconds: 3),
      ).timeout(const Duration(seconds: 3), onTimeout: () => <String>[]);
      // Give the probe loop a moment to run and be rejected.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(lines.any((line) => line.contains('可响应')), isFalse);
    });

    test('an unreachable address never yields a success line', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async => _FakeServer().handle,
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 500),
        ),
      );

      final lines = await readUntil(
        result!.stdout,
        until: (seen) => seen.isNotEmpty,
        timeout: const Duration(seconds: 3),
      );
      expect(lines.first, contains('本地地址（配置）'));
      expect(lines.any((line) => line.contains('可响应')), isFalse);
      await result.cancel!();
    });
  });

  group('stdout after exit', () {
    Future<({ProgramRunResult result, _FakeServer fake})> startFake() async {
      writeBootSources();
      writeConfig(<String, Object?>{});
      final fake = _FakeServer();
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async => fake.handle,
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 300),
        ),
      );
      expect(result, isNotNull);
      return (result: result!, fake: fake);
    }

    test('lines printed just before exit are still delivered', () async {
      final started = await startFake();
      final collected = <String>[];
      var done = false;
      final subscription = started.result.stdout.listen(
        collected.add,
        onDone: () => done = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Exit is reported first, then the final line arrives, then EOF.
      await started.fake.exitFirst(0);
      await started.fake.emitLine('server stopped cleanly');
      await started.fake.finish(0);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        collected.any((line) => line.contains('server stopped cleanly')),
        isTrue,
        reason: 'the tail line must survive process exit',
      );
      expect(done, isTrue, reason: 'the stream still completes at real EOF');
      await subscription.cancel();
    });

    test('a response is not reported once the process has exited', () async {
      final started = await startFake();
      final collected = <String>[];
      final subscription = started.result.stdout.listen(collected.add);

      await started.fake.exitFirst(0);
      // The address answers, but our process is gone, so nothing is claimed.
      started.fake.emitLine('late');
      await Future<void>.delayed(const Duration(seconds: 2));
      await started.fake.finish(0);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(collected.any((line) => line.contains('可响应')), isFalse);
      await subscription.cancel();
    });
  });

  group('bounded JVM budget', () {
    test('a web server never runs on an unbounded default heap', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      final launches = <JavaWebProcessRequest>[];
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async {
            launches.add(request);
            return _FakeServer().handle;
          },
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 300),
        ),
      );

      final args = launches.single.arguments;
      // Same policy as the compiler: a fixed, finite budget.
      expect(args.take(3), <String>['-Xms16m', '-Xmx256m', '-XX:+UseSerialGC']);
      expect(
        args.where((arg) => arg.startsWith('-Xmx')),
        <String>['-Xmx256m'],
        reason: 'exactly one heap ceiling, and it is finite',
      );
      expect(args.where((arg) => arg.startsWith('-Xms')), <String>['-Xms16m']);
      // The budget precedes the classpath so the JVM reads it as an option.
      expect(args.indexOf('-Xmx256m'), lessThan(args.indexOf('-classpath')));

      await result!.cancel!();
    });

    test('a javaee8 container launch is bounded the same way', () async {
      writeBootSources();
      writeConfig(<String, Object?>{'profile': 'javaee8'});

      final launches = <JavaWebProcessRequest>[];
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          processFactory: (request) async {
            launches.add(request);
            return _FakeServer().handle;
          },
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 300),
          pack: (targetDirectory) async => JavaeeContainerPack(
            classpath: <String>[
              writeJar('container/tomcat.zip', <String>[
                'javax/servlet/A.class',
              ]),
            ],
          ),
        ),
      );

      final args = launches.single.arguments;
      expect(args.take(3), <String>['-Xms16m', '-Xmx256m', '-XX:+UseSerialGC']);
      expect(args.where((arg) => arg.startsWith('-Xmx')), <String>['-Xmx256m']);

      await result!.cancel!();
    });
  });

  group('owned process lifecycle', () {
    test('cancel stops the server and completes the exit code', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      final fake = _FakeServer();
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async => fake.handle,
          probe: (uri) async => null,
          portCheck: (_) async => true,
        ),
      );

      expect(fake.cancelled, isFalse);
      await result!.cancel!();
      expect(fake.cancelled, isTrue);
      expect(await result.exitCode, 0);
    });

    test('a second run stops the server the first run started', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      final first = _FakeServer();
      final second = _FakeServer();
      final created = <_FakeServer>[first, second];
      var index = 0;

      final instance = runner(
        compiler: (request) async => ProcessResult(1, 0, '', ''),
        dependencies:
            (
              profile, {
              required includeDatabase,
              required targetDirectory,
            }) async => <String>[
              writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
            ],
        processFactory: (request) async => created[index++].handle,
        probe: (uri) async => null,
        portCheck: (_) async => true,
      );

      final firstRun = await run(instance);
      expect(first.cancelled, isFalse);
      final secondRun = await run(instance);

      expect(first.cancelled, isTrue, reason: 'the previous server is stopped');
      expect(second.cancelled, isFalse);

      await secondRun!.cancel!();
      await firstRun!.cancel!();
    });

    test('an unowned leftover process is not the project server', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      // A port that something else owns, with no runner process at all.
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => socket.close());

      var launched = false;
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[],
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
          probe: (uri) async => 200,
          portCheck: (_) async => false,
        ),
      );

      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
      expect(result.stdout, isNotNull);
    });
  });

  group('compile failure', () {
    test('javac diagnostics are reported and no server starts', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      var launched = false;
      final result = await run(
        runner(
          compiler: (request) async =>
              ProcessResult(1, 1, '', 'error: cannot find symbol'),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[],
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
          portCheck: (_) async => true,
        ),
      );

      expect(result, isNotNull);
      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
      expect(await result.stderr.join('\n'), contains('cannot find symbol'));
      expect(
        Directory(p.join(project.path, 'classes')).existsSync(),
        isFalse,
        reason: 'compilation output never lands inside the project',
      );
    });

    test('a project with no main sources is refused', () async {
      writeConfig(<String, Object?>{});
      var launched = false;
      final result = await run(
        runner(
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
        ),
      );
      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
    });
  });

  group('namespace isolation', () {
    test('a classpath with both servlet namespaces is refused', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});
      writeJar('libs/mixed.zip', <String>[
        'javax/servlet/Servlet.class',
        'jakarta/servlet/Servlet.class',
      ]);

      var launched = false;
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
          portCheck: (_) async => true,
        ),
      );

      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
      expect(await result.stderr.join('\n'), contains('javax'));
    });
  });

  group('static web root', () {
    Future<List<String>> launchArgsFor({required bool withWebRoot}) async {
      writeBootSources();
      if (withWebRoot) write('src/main/webapp/index.html', '<html/>');
      writeConfig(<String, Object?>{});
      final launches = <JavaWebProcessRequest>[];
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async {
            launches.add(request);
            return _FakeServer().handle;
          },
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 300),
        ),
      );
      await result!.cancel!();
      return launches.single.arguments;
    }

    test(
      'a web root with content is added to the Boot static locations',
      () async {
        final args = await launchArgsFor(withWebRoot: true);
        final location = args.firstWhere(
          (arg) => arg.startsWith('--spring.web.resources.static-locations='),
        );
        // The defaults are restated, because Boot replaces rather than extends.
        expect(location, contains('classpath:/META-INF/resources/'));
        expect(location, contains('classpath:/resources/'));
        expect(location, contains('classpath:/static/'));
        expect(location, contains('classpath:/public/'));
        // And the deployed web root really becomes a served location.
        expect(location, contains('webapp'));
        expect(location, contains('file:'));
      },
    );

    test('an empty web root leaves the Boot defaults untouched', () async {
      final args = await launchArgsFor(withWebRoot: false);
      expect(
        args.any((arg) => arg.contains('static-locations')),
        isFalse,
        reason: 'an empty directory must not override the defaults',
      );
    });
  });

  group('start lock with three callers', () {
    test(
      'a third caller cannot overtake a pending start after a refusal',
      () async {
        writeBootSources();
        writeConfig(<String, Object?>{});

        // A parks inside its start sequence until released. B and C both queue
        // behind it before B gives up, which is the interleaving that matters: C
        // publishes its tail on top of B's, so B can no longer hand its queue
        // position back. The waits differ per runner because the lock is shared
        // but the wait is a property of the call.
        final firstHolds = Completer<void>();
        var starts = 0;
        Future<JavaToolchainProcess> factory(
          JavaWebProcessRequest request,
        ) async {
          starts++;
          if (starts == 1) await firstHolds.future;
          return _FakeServer().handle;
        }

        JavaProgramRunner build(Duration startWait) => runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: factory,
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 200),
          startWait: startWait,
        );

        // B is given a short wait so it refuses while A still runs. C gets a long
        // one so it is still waiting at that moment rather than timing out too.
        final instanceA = build(const Duration(seconds: 10));
        final instanceB = build(const Duration(milliseconds: 400));
        final instanceC = build(const Duration(seconds: 10));

        // 1. A takes the lock and parks in the process factory.
        final a = run(instanceA);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(starts, 1, reason: 'A is inside its start sequence');

        // 2. B queues. The gap lets B publish its tail before C starts, so C
        //    reliably lands on top of B rather than beside it.
        final bFuture = run(instanceB);
        await Future<void>.delayed(const Duration(milliseconds: 25));

        // 3. C queues on B's tail while B is still waiting. This must happen
        //    before B's 400 ms wait overruns.
        final cFuture = run(instanceC);

        // 4. B overruns and is refused, with A still parked.
        final b = await bFuture;
        expect(await b!.exitCode, kProgramNotRunExitCode);
        expect(
          starts,
          1,
          reason: 'a refusal must not start a process of its own',
        );

        // 5. C must still be blocked. Its queue position sits behind a retired
        //    tail, and the predecessor is still running, so no JVM may start.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          starts,
          1,
          reason: 'C must not launch while A is still pending after B refused',
        );

        // 6. Release A. The chain drains and only then may C start.
        firstHolds.complete();
        final startedA = await a;
        final startedC = await cFuture;
        expect(startedA, isNotNull);
        expect(startedC, isNotNull);
        expect(starts, 2, reason: 'C starts only after A finished');

        await startedC!.cancel!();
        await startedA!.cancel!();
      },
    );
  });

  group('physical guards', () {
    test('a JSP in a default Boot static location is refused', () async {
      writeBootSources();
      // Boot serves src/main/resources/static even without a custom web root.
      write('src/main/resources/static/page.jsp', '<html/>');
      writeConfig(<String, Object?>{});

      var launched = false;
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
          portCheck: (_) async => true,
        ),
      );

      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
      expect(await result.stderr.join('\n'), contains('JSP'));
    });

    test('a JSP under a custom web root is still refused', () async {
      writeBootSources();
      write('src/main/webapp/index.jsp', '<html/>');
      writeConfig(<String, Object?>{});

      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          portCheck: (_) async => true,
        ),
      );

      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(await result.stderr.join('\n'), contains('JSP'));
    });

    // The guard needs a real directory link. Windows grants that only with
    // developer mode or elevation, so an unavailable fixture is recorded as a
    // skip with a precise reason instead of passing through an early return.
    test(
      'a main source root that links outside the project is refused',
      () async {
        writeBootSources();
        writeConfig(<String, Object?>{});

        // Build a real tree outside the project and point src/main/java at it.
        final outside = Directory(p.join(root.path, 'outside_src'))
          ..createSync();
        File(
          p.join(outside.path, 'Foreign.java'),
        ).writeAsStringSync('class F {}');
        final sourceRoot = Directory(p.join(project.path, 'src/main/java'));
        if (sourceRoot.existsSync()) sourceRoot.deleteSync(recursive: true);
        final link = Link(sourceRoot.path);
        try {
          link.createSync(outside.path, recursive: true);
        } on FileSystemException catch (error) {
          // The fixture itself is unavailable, so the guard is NOT verified here.
          markTestSkipped('本机未授予目录链接权限，物理包含守卫未验证：${error.message}');
          return;
        }

        // The fixture must really be a link to a real tree outside the project,
        // or the guard below would be exercised against nothing.
        expect(link.existsSync(), isTrue, reason: '链接必须真实创建');
        final resolvedOutside = outside.resolveSymbolicLinksSync();
        final resolvedProject = project.resolveSymbolicLinksSync();
        expect(link.resolveSymbolicLinksSync(), resolvedOutside);
        expect(p.isWithin(resolvedProject, resolvedOutside), isFalse);

        var launched = false;
        final result = await run(
          runner(
            compiler: (request) async => ProcessResult(1, 0, '', ''),
            dependencies:
                (
                  profile, {
                  required includeDatabase,
                  required targetDirectory,
                }) async => <String>[
                  writeJar('jars/boot.zip', <String>[
                    'jakarta/servlet/x.class',
                  ]),
                ],
            processFactory: (request) async {
              launched = true;
              return _FakeServer().handle;
            },
            portCheck: (_) async => true,
          ),
        );

        expect(await result!.exitCode, kProgramNotRunExitCode);
        expect(launched, isFalse);
        expect(await result.stderr.join('\n'), contains('项目外'));
      },
    );
  });

  group('pipe settlement', () {
    test('exitCode completes only after the pipes settle', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      final fake = _FakeServer();
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async => fake.handle,
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 200),
        ),
      );

      var exited = false;
      unawaited(result!.exitCode.then((_) => exited = true));

      // The process reports exit while its stdout is still open.
      await fake.exitFirst(0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        exited,
        isFalse,
        reason: 'exit alone must not be reported as fully settled',
      );

      // Closing the pipe settles it.
      await fake.finish(0);
      expect(await result.exitCode, 0);
      expect(exited, isTrue);
    });

    test('stderr is drained and joined into settlement', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      final fake = _FakeServer();
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async => fake.handle,
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 200),
        ),
      );

      final errors = <String>[];
      final sub = result!.stderr.listen(errors.add);
      await fake.emitError('boom');
      await fake.finish(1);

      expect(await result.exitCode, 1);
      expect(errors.any((line) => line.contains('boom')), isTrue);
      await sub.cancel();
    });

    test('a held raw cancellation keeps the teardown pending', () async {
      writeBootSources();
      writeConfig(<String, Object?>{});

      // The raw pipe never reaches EOF, so the drain window forces a cancel. That
      // cancel is held, and the teardown must not complete until it resolves:
      // otherwise the deploy directory could be deleted under a live pipe.
      final rawCancelHeld = Completer<void>();
      final fake = _FakeServer(holdRawCancel: rawCancelHeld.future);

      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          dependencies:
              (
                profile, {
                required includeDatabase,
                required targetDirectory,
              }) async => <String>[
                writeJar('jars/boot.zip', <String>['jakarta/servlet/x.class']),
              ],
          processFactory: (request) async => fake.handle,
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 200),
          drainWindow: const Duration(milliseconds: 60),
        ),
      );

      var finished = false;
      unawaited(result!.exitCode.then((_) => finished = true));

      // Exit without EOF. The window elapses and the cancel is attempted, but it
      // cannot resolve yet.
      await fake.exitFirst(0);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        finished,
        isFalse,
        reason: 'teardown must wait for the raw cancellation to resolve',
      );

      // Only now may the teardown complete.
      rawCancelHeld.complete();
      expect(await result.exitCode, 0);
    });
  });

  group('javaee8 profile', () {
    test('an absent container pack is reported, not guessed', () async {
      writeBootSources();
      writeConfig(<String, Object?>{'profile': 'javaee8'});

      var launched = false;
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
          portCheck: (_) async => true,
          pack: (targetDirectory) async => JavaeeContainerPack.absent,
        ),
      );

      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
      // p5's plan names the missing bundle; nothing was fabricated.
      expect(await result.stderr.join('\n'), contains('packMissing'));
    });

    test('a verified pack runs the launcher class from the plan', () async {
      writeBootSources();
      write('src/main/webapp/index.jsp', '<html/>');
      writeConfig(<String, Object?>{'profile': 'javaee8'});
      final container = writeJar('container/tomcat.zip', <String>[
        'javax/servlet/Servlet.class',
      ]);

      final compiled = <List<String>>[];
      final launches = <JavaWebProcessRequest>[];
      final result = await run(
        runner(
          compiler: (request) async {
            compiled.add(request.arguments);
            return ProcessResult(1, 0, '', '');
          },
          processFactory: (request) async {
            launches.add(request);
            return _FakeServer().handle;
          },
          probe: (uri) async => null,
          portCheck: (_) async => true,
          readyTimeout: const Duration(milliseconds: 300),
          pack: (targetDirectory) async => JavaeeContainerPack(
            classpath: <String>[container],
            jspSupported: true,
            jstlSupported: true,
            annotationScanning: true,
            containerVersion: '9.0',
          ),
        ),
      );

      expect(launches, hasLength(1));
      final args = launches.single.arguments;
      expect(args, contains('qfli.javaee.QfliTomcat9Main'));
      // The plan's argv starts with the Tomcat base directory.
      expect(
        args.sublist(args.indexOf('qfli.javaee.QfliTomcat9Main') + 1).first,
        contains('tomcat'),
      );

      expect(
        compiled.single.any((a) => a.endsWith('QfliTomcat9Main.java')),
        isTrue,
      );
      expect(
        compiled.single.any(
          (a) => a.contains('javax/servlet') || a.contains('tomcat'),
        ),
        isTrue,
      );

      await result!.cancel!();
    });

    test('a jakarta jar in a javaee8 classpath is refused as mixed', () async {
      writeBootSources();
      writeConfig(<String, Object?>{'profile': 'javaee8'});
      final container = writeJar('container/tomcat.zip', <String>[
        'javax/servlet/Servlet.class',
      ]);
      writeJar('libs/jakarta.zip', <String>['jakarta/servlet/Servlet.class']);

      var launched = false;
      final result = await run(
        runner(
          compiler: (request) async => ProcessResult(1, 0, '', ''),
          processFactory: (request) async {
            launched = true;
            return _FakeServer().handle;
          },
          portCheck: (_) async => true,
          pack: (targetDirectory) async =>
              JavaeeContainerPack(classpath: <String>[container]),
        ),
      );

      expect(await result!.exitCode, kProgramNotRunExitCode);
      expect(launched, isFalse);
    });

    test(
      'a pack without JSP support refuses a project that has pages',
      () async {
        writeBootSources();
        write('src/main/webapp/index.jsp', '<html/>');
        writeConfig(<String, Object?>{'profile': 'javaee8'});
        final container = writeJar('container/tomcat.zip', <String>[
          'javax/servlet/Servlet.class',
        ]);

        var launched = false;
        final result = await run(
          runner(
            compiler: (request) async => ProcessResult(1, 0, '', ''),
            processFactory: (request) async {
              launched = true;
              return _FakeServer().handle;
            },
            portCheck: (_) async => true,
            pack: (targetDirectory) async =>
                JavaeeContainerPack(classpath: <String>[container]),
          ),
        );

        expect(await result!.exitCode, kProgramNotRunExitCode);
        expect(launched, isFalse);
        expect(await result.stderr.join('\n'), contains('jspMissing'));
      },
    );

    test(
      'a failing dependency pack is reported with its own message',
      () async {
        writeBootSources();
        writeConfig(<String, Object?>{'profile': 'javaee8'});

        final result = await run(
          runner(
            compiler: (request) async => ProcessResult(1, 0, '', ''),
            portCheck: (_) async => true,
            pack: (targetDirectory) async =>
                throw const JavaEePackException('pack assets missing'),
          ),
        );

        expect(await result!.exitCode, kProgramNotRunExitCode);
        expect(await result.stderr.join('\n'), contains('pack assets missing'));
      },
    );
  });

  group('dispatch', () {
    test('a project without a config file is not a Web project', () async {
      writeBootSources();
      expect(await JavaWebProject.load(project.path), isNull);
    });

    test('a non-Java entry never reaches the Web path', () async {
      writeConfig(<String, Object?>{});
      final result = await run(
        runner(processFactory: (request) async => _FakeServer().handle),
      );
      expect(result, isNull);
    });
  });

  group('source collection', () {
    test('keeps main sources and excludes build output', () {
      write('src/main/java/a/A.java', 'class A {}');
      write('src/main/java/b/B.java', 'class B {}');
      write('src/test/java/c/C.java', 'class C {}');
      write('build/generated/D.java', 'class D {}');
      File(p.join(project.path, 'src/main/java/E.txt')).writeAsStringSync('x');

      final files = JavaProgramRunner.collectWebMainJavaFiles(project);
      expect(files.map(p.basename), <String>['A.java', 'B.java']);
    });

    test('falls back to the project root when there is no main tree', () {
      write('src/App.java', 'class App {}');
      write('build/Skip.java', 'class Skip {}');

      final files = JavaProgramRunner.collectWebMainJavaFiles(project);
      expect(files.any((f) => f.endsWith('App.java')), isTrue);
      expect(files.any((f) => f.endsWith('Skip.java')), isFalse);
    });
  });

  group('namespace detection', () {
    test('reads archive entries and ignores file names', () {
      final jakarta = writeJar('x/jakarta.zip', <String>[
        'jakarta/servlet/A.class',
      ]);
      final javax = writeJar('x/javax.zip', <String>['javax/servlet/B.class']);
      final neither = writeJar('x/plain.zip', <String>['org/example/C.class']);

      expect(
        JavaProgramRunner.detectServletNamespaces(<String>[jakarta]),
        <String>{'jakarta.servlet'},
      );
      expect(
        JavaProgramRunner.detectServletNamespaces(<String>[javax]),
        <String>{'javax.servlet'},
      );
      expect(
        JavaProgramRunner.detectServletNamespaces(<String>[neither]),
        isEmpty,
      );
      expect(
        JavaProgramRunner.detectServletNamespaces(<String>[javax, jakarta]),
        <String>{'javax.servlet', 'jakarta.servlet'},
      );
    });

    test('a file that is not a ZIP is skipped, not fatal', () {
      final broken = File(p.join(project.path, 'broken.jar'))
        ..writeAsStringSync('not a zip');
      expect(
        JavaProgramRunner.detectServletNamespaces(<String>[broken.path]),
        isEmpty,
      );
    });
  });
}

/// A server process a test fully controls.
class _FakeServer {
  _FakeServer({Future<void>? holdRawCancel})
    // A held cancellation needs a single-subscription controller: its onCancel is
    // FutureOr<void> and the returned Future is awaited by cancel(). A broadcast
    // controller's onCancel is void, so a returned Future is silently dropped and
    // the hold could never be observed. Ordinary fakes stay broadcast so tests can
    // attach extra listeners.
    : _stdout = holdRawCancel == null
          ? StreamController<List<int>>.broadcast()
          : StreamController<List<int>>(onCancel: () => holdRawCancel),
      _stderr = StreamController<List<int>>.broadcast();

  final StreamController<List<int>> _stdout;
  final StreamController<List<int>> _stderr;
  final Completer<int> _exit = Completer<int>();
  bool cancelled = false;

  JavaToolchainProcess get handle => JavaToolchainProcess(
    title: 'java',
    stdout: _stdout.stream,
    stderr: _stderr.stream,
    exitCode: _exit.future,
    cancel: cancel,
  );

  Future<void> cancel() async {
    cancelled = true;
    await finish(0);
  }

  /// Completes the exit code while stdout stays open, the way a program that
  /// printed its last line and exited before the pipe closed behaves.
  Future<void> exitFirst(int code) async {
    if (!_exit.isCompleted) _exit.complete(code);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> emitLine(String line) async {
    if (!_stdout.isClosed) _stdout.add(utf8.encode('$line\n'));
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> emitError(String line) async {
    if (!_stderr.isClosed) _stderr.add(utf8.encode('$line\n'));
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> finish(int code) async {
    if (!_exit.isCompleted) _exit.complete(code);
    if (!_stdout.isClosed) await _stdout.close();
    if (!_stderr.isClosed) await _stderr.close();
  }
}
