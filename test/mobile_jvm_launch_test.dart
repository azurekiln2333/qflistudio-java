import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_java/mobile_jdk.dart';
import 'package:qfli_java/mobile_jvm_launch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late String home;
  late MobileJdkLayout? previousLayout;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('mobile jvm temp ');
    home = p.join(fixture.path, 'sandbox', 'usr');
    previousLayout = MobileJdk.current;
  });

  tearDown(() async {
    MobileJdk.current = previousLayout;
    await fixture.delete(recursive: true);
  });

  test(
    'creates the actual sandbox directory and preserves argument tokens',
    () async {
      final original = ['-classpath', 'path with spaces', 'Main'];
      final arguments = await MobileJvmLaunch.arguments(
        home: home,
        arguments: original,
      );
      expect(Directory(p.join(home, 'tmp')).existsSync(), isTrue);
      expect(arguments, [
        '-Djava.io.tmpdir=${p.join(home, 'tmp')}',
        ...original,
      ]);
      expect(original, ['-classpath', 'path with spaces', 'Main']);
    },
  );

  test('explicit per-call Java property follows the mobile default', () async {
    const override = '-Djava.io.tmpdir=/caller/selected/path';
    expect(
      await MobileJvmLaunch.arguments(
        home: home,
        arguments: [override, 'Main'],
      ),
      ['-Djava.io.tmpdir=${p.join(home, 'tmp')}', override, 'Main'],
    );
  });

  test(
    'Android javac uses JVM forwarding and retains explicit override',
    () async {
      const override = '-J-Djava.io.tmpdir=/caller/compiler/path';
      expect(
        await MobileJvmLaunch.arguments(
          home: home,
          arguments: [override, '-version'],
          javac: true,
        ),
        ['-J-Djava.io.tmpdir=${p.join(home, 'tmp')}', override, '-version'],
      );
    },
  );

  test(
    'cached mobile preparation recreates a missing sandbox temp root',
    () async {
      final layout = MobileJdkLayout(
        home: home,
        java: p.join(home, 'bin', 'java'),
        javac: p.join(home, 'bin', 'javac'),
        libraryDirectory: p.join(home, 'lib'),
      );
      MobileJdk.current = layout;
      expect(await MobileJdk.prepare(), same(layout));
      expect(Directory(layout.temporaryDirectory).existsSync(), isTrue);
      await Directory(layout.temporaryDirectory).delete();
      expect(await MobileJdk.prepare(), same(layout));
      expect(Directory(layout.temporaryDirectory).existsSync(), isTrue);
      expect(layout.environment['TMPDIR'], layout.temporaryDirectory);
    },
  );

  test(
    'desktop toolchain does not inherit a cached mobile sandbox path',
    () async {
      MobileJdk.current = MobileJdkLayout(
        home: home,
        java: p.join(home, 'bin', 'java'),
        javac: p.join(home, 'bin', 'javac'),
        libraryDirectory: p.join(home, 'lib'),
      );
      final process = (await const JavaProgramRunner().runToolchainCommand(
        workingDirectory: fixture.path,
        arguments: ['java', '-XshowSettings:properties', '-version'],
        isolatedEnvironment: true,
      ))!;
      final output = process.stdout.toList();
      final error = process.stderr.toList();
      expect(await process.exitCode, 0);
      expect(await output, isEmpty);
      expect((await error).join('\n'), isNot(contains(home)));
      expect(Directory(home).existsSync(), isFalse);
    },
    skip: MobileJdk.isMobile,
  );

  test(
    'real JVM default Files temp APIs use the supplied mobile sandbox',
    () async {
      final source = File(p.join(fixture.path, 'TempDefaults.java'));
      await source.writeAsString('''
import java.nio.file.*;
public class TempDefaults {
  public static void main(String[] args) throws Exception {
    Path expected = Path.of(args[0]);
    Path file = Files.createTempFile("qfli-", ".txt");
    Path directory = Files.createTempDirectory("qfli-");
    try {
      System.out.println(Files.isSameFile(file.getParent(), expected));
      System.out.println(Files.isSameFile(directory.getParent(), expected));
    } finally {
      Files.delete(file);
      Files.delete(directory);
    }
  }
}
''');
      const runner = JavaProgramRunner();
      final compile = (await runner.runToolchainCommand(
        workingDirectory: fixture.path,
        arguments: ['javac', '--release', '17', source.path],
        isolatedEnvironment: true,
      ))!;
      final compileOutput = compile.stdout.toList();
      final compileError = compile.stderr.toList();
      expect(
        await compile.exitCode,
        0,
        reason: (await compileError).join('\n'),
      );
      expect(await compileOutput, isEmpty);
      final run = (await runner.runToolchainCommand(
        workingDirectory: fixture.path,
        arguments: [
          'java',
          ...await MobileJvmLaunch.arguments(
            home: home,
            arguments: [
              '-Xms16m',
              '-Xmx64m',
              '-XX:+UseSerialGC',
              '-classpath',
              fixture.path,
              'TempDefaults',
              p.join(home, 'tmp'),
            ],
          ),
        ],
        isolatedEnvironment: true,
      ))!;
      final output = run.stdout.toList();
      final error = run.stderr.toList();
      expect(await run.exitCode, 0, reason: (await error).join('\n'));
      expect(await output, ['true', 'true']);
      expect(Directory(p.join(home, 'tmp')).listSync(), isEmpty);
    },
  );
}
