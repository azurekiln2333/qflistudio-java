import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/services/studio_profile.dart';

import 'mobile_jdk.dart';
import 'ohos_jdk_process.dart';

/// Compiles project sources with javac and runs the resulting main class.
class JavaProgramRunner implements ProgramRunner {
  const JavaProgramRunner({this.javaHome});

  /// An explicit JDK location, useful for a bundled distribution or tests.
  final String? javaHome;

  bool get isAvailable =>
      MobileJdk.current != null ||
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
          _findJdk() != null;

  static Future<void> prepare() async {
    if (!MobileJdk.isMobile) return;
    try {
      await MobileJdk.prepare();
    } on Exception {
      // run() returns the platform error when a user starts a program.
    }
  }

  @override
  Future<ProgramRunResult?> run({
    required String projectPath,
    required String entryFile,
  }) async {
    if (p.extension(entryFile).toLowerCase() != '.java') return null;
    final project = p.normalize(p.absolute(projectPath));
    final entry = p.normalize(p.absolute(entryFile));
    if (!p.isWithin(project, entry) || !File(entry).existsSync()) {
      return _failure('Java', '入口文件不在项目内或无法读取：$entryFile');
    }
    if (!(MobileJdk.isMobile ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isMacOS)) {
      return _failure('Java', '当前设备未安装可用的 Java 工具链。');
    }

    _Jdk? jdk;
    try {
      jdk = MobileJdk.isMobile
          ? _Jdk.fromMobile(await MobileJdk.prepare())
          : _findJdk();
    } on Exception catch (error) {
      return _failure('Java', '无法初始化 JDK：$error');
    }
    if (jdk == null) {
      return _failure('Java', '未找到 JDK。请设置 QFLI_JAVA_HOME 或 JAVA_HOME。');
    }

    Directory? output;
    try {
      final sources = _collectJavaFiles(Directory(project));
      final jars = _collectJars(Directory(p.join(project, 'lib')));
      jars.addAll(_collectJars(Directory(p.join(project, 'libs'))));
      output = await Directory(
        jdk.tempDirectory ?? Directory.systemTemp.path,
      ).createTemp('qfli_java_');
      final classPath = [
        output.path,
        ...jars,
      ].join(Platform.isWindows ? ';' : ':');
      final compilerArguments = [
        '-encoding',
        'UTF-8',
        '-d',
        output.path,
        '-classpath',
        classPath,
        ...sources,
      ];
      final ProcessResult compile;
      if (jdk.mobileLayout case final MobileJdkLayout layout
          when Platform.operatingSystem == 'ohos') {
        final process = await OhosJdkProcess.start(
          home: layout.home,
          libraryDirectory: layout.libraryDirectory,
          arguments: [
            '-m',
            'jdk.compiler/com.sun.tools.javac.Main',
            ...compilerArguments,
          ],
          workingDirectory: project,
        );
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        compile = ProcessResult(
          0,
          await process.exitCode,
          await stdout,
          await stderr,
        );
      } else {
        compile = await Process.run(
          jdk.javac,
          compilerArguments,
          workingDirectory: project,
          environment: jdk.environment,
          runInShell: false,
        );
      }
      if (compile.exitCode != 0) {
        final diagnostic = '${compile.stdout}${compile.stderr}'.trim();
        return _failure(
          '编译 ${p.basename(entry)}',
          diagnostic.isEmpty
              ? 'javac 编译失败（退出码 ${compile.exitCode}）。'
              : diagnostic,
        );
      }

      final compileDiagnostics = '${compile.stdout}${compile.stderr}'.trim();

      final source = await File(entry).readAsString();
      final packageName = _packageName(source);
      final mainClass = [
        ?packageName,
        p.basenameWithoutExtension(entry),
      ].join('.');
      final runtimeArguments = [
        '-Dfile.encoding=UTF-8',
        '-Dstdout.encoding=UTF-8',
        '-Dstderr.encoding=UTF-8',
        '-Dsun.stdout.encoding=UTF-8',
        '-Dsun.stderr.encoding=UTF-8',
        '-classpath',
        classPath,
        mainClass,
      ];
      if (jdk.mobileLayout case final MobileJdkLayout layout
          when Platform.operatingSystem == 'ohos') {
        final process = await OhosJdkProcess.start(
          home: layout.home,
          libraryDirectory: layout.libraryDirectory,
          arguments: runtimeArguments,
          workingDirectory: project,
          inputFile: p.join(project, 'input.txt'),
        );
        final runOutput = output;
        final exitCode = process.exitCode.whenComplete(
          () => _removeOutput(runOutput),
        );
        output = null;
        return ProgramRunResult(
          title: '运行 ${p.basename(entry)}（JDK）',
          stdout: process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
          stderr: _withDiagnostics(
            compileDiagnostics,
            process.stderr
                .transform(utf8.decoder)
                .transform(const LineSplitter()),
          ),
          exitCode: exitCode,
          cancel: process.cancel,
        );
      }
      final process = await Process.start(
        jdk.java,
        runtimeArguments,
        workingDirectory: project,
        environment: jdk.environment,
        runInShell: false,
      );
      unawaited(_feedInput(process.stdin, File(p.join(project, 'input.txt'))));
      final runOutput = output;
      final exitCode = process.exitCode.whenComplete(() async {
        await _removeOutput(runOutput);
      });
      output = null;
      return ProgramRunResult(
        title: '运行 ${p.basename(entry)}（JDK）',
        stdout: process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
        stderr: _withDiagnostics(
          compileDiagnostics,
          process.stderr
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        ),
        exitCode: exitCode,
        cancel: () async {
          process.kill();
          await exitCode;
        },
      );
    } on FileSystemException catch (error) {
      return _failure('Java', '无法读取项目文件：${error.message}');
    } on ProcessException catch (error) {
      return _failure('Java', '无法启动 JDK：${error.message}');
    } on PlatformException catch (error) {
      return _failure('Java', '无法启动 JDK：${error.message}');
    } finally {
      if (output != null) await _removeOutput(output);
    }
  }

  _Jdk? _findJdk() {
    final homes = [
      javaHome,
      Platform.environment['QFLI_JAVA_HOME'],
      Platform.environment['JAVA_HOME'],
    ];
    for (final home in homes) {
      if (home == null || home.isEmpty) continue;
      final jdk = _Jdk.fromDirectory(p.join(home, 'bin'));
      if (jdk != null) return jdk;
    }
    final path = Platform.environment['PATH'] ?? '';
    for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
      if (directory.isEmpty) continue;
      final jdk = _Jdk.fromDirectory(directory);
      if (jdk != null) return jdk;
    }
    return null;
  }

  List<String> _collectJavaFiles(Directory directory) {
    final files = <String>[];
    void visit(Directory current) {
      for (final entity in current.listSync(followLinks: false)) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          if (name.startsWith('.') || name == 'build') continue;
          visit(entity);
        } else if (entity is File &&
            p.extension(entity.path).toLowerCase() == '.java') {
          files.add(entity.path);
        }
      }
    }

    visit(directory);
    files.sort();
    return files;
  }

  List<String> _collectJars(Directory directory) {
    if (!directory.existsSync()) return [];
    final jars =
        directory
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => p.extension(file.path).toLowerCase() == '.jar')
            .map((file) => file.path)
            .toList()
          ..sort();
    return jars;
  }

  String? _packageName(String source) {
    final withoutComments = source.replaceAll(
      RegExp(r'/\*[\s\S]*?\*/|//[^\r\n]*'),
      '',
    );
    return RegExp(
      r'^\s*package\s+([\w$]+(?:\.[\w$]+)*)\s*;',
      multiLine: true,
    ).firstMatch(withoutComments)?.group(1);
  }

  Stream<String> _withDiagnostics(
    String diagnostics,
    Stream<String> runtime,
  ) async* {
    if (diagnostics.isNotEmpty) {
      yield* Stream<String>.fromIterable(diagnostics.split(RegExp(r'\r?\n')));
    }
    yield* runtime;
  }

  Future<void> _feedInput(IOSink sink, File input) async {
    try {
      if (await input.exists()) await sink.addStream(input.openRead());
    } on IOException {
      // The program may close stdin or exit before all input is consumed.
    }
    try {
      await sink.close();
    } on IOException {
      // A terminated process has already closed its pipe.
    }
  }

  Future<void> _removeOutput(Directory output) async {
    try {
      if (await output.exists()) await output.delete(recursive: true);
    } on FileSystemException {
      // A cleanup failure must not replace javac diagnostics or the JVM exit code.
    }
  }

  ProgramRunResult _failure(String title, String message) => ProgramRunResult(
    title: title,
    stdout: const Stream<String>.empty(),
    stderr: Stream<String>.fromIterable(message.split(RegExp(r'\r?\n'))),
    exitCode: Future<int>.value(kProgramNotRunExitCode),
  );
}

class _Jdk {
  const _Jdk(
    this.java,
    this.javac, {
    this.environment,
    this.tempDirectory,
    this.mobileLayout,
  });

  final String java;
  final String javac;
  final Map<String, String>? environment;
  final String? tempDirectory;
  final MobileJdkLayout? mobileLayout;

  factory _Jdk.fromMobile(MobileJdkLayout layout) => _Jdk(
    layout.java,
    layout.javac,
    environment: layout.environment,
    tempDirectory: p.join(layout.home, 'tmp'),
    mobileLayout: layout,
  );

  static _Jdk? fromDirectory(String directory) {
    final suffix = Platform.isWindows ? '.exe' : '';
    final java = p.join(directory, 'java$suffix');
    final javac = p.join(directory, 'javac$suffix');
    if (!File(java).existsSync() || !File(javac).existsSync()) return null;
    return _Jdk(java, javac);
  }
}
