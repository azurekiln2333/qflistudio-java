import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/services/studio_profile.dart';

import 'mobile_jdk.dart';
import 'mobile_jvm_launch.dart';
import 'ohos_jdk_process.dart';

/// Compiles project sources with javac and runs the resulting main class.
class JavaProgramRunner implements ProgramRunner {
  const JavaProgramRunner({
    this.javaHome,
    this.compileTimeout = const Duration(seconds: 60),
    this.compilerOutputLimit = 512 * 1024,
  });

  /// An explicit JDK location, useful for a bundled distribution or tests.
  final String? javaHome;

  /// A compiler must terminate before Run returns or deletes its class output.
  final Duration compileTimeout;
  final int compilerOutputLimit;

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
      final sources = collectProjectJavaFiles(Directory(project));
      final jars = collectProjectJars(Directory(p.join(project, 'lib')));
      jars.addAll(collectProjectJars(Directory(p.join(project, 'libs'))));
      output = await Directory(
        jdk.tempDirectory ?? Directory.systemTemp.path,
      ).createTemp('qfli_java_');
      final classPath = [
        output.path,
        ...jars,
      ].join(Platform.isWindows ? ';' : ':');
      final compilerArguments = [
        '--release',
        '17',
        '-encoding',
        'UTF-8',
        '-d',
        output.path,
        '-classpath',
        classPath,
        ...sources,
      ];
      final compile = await _compile(jdk, compilerArguments, project);
      if (compile.exitCode != 0) {
        final diagnostic = '${compile.stdout}${compile.stderr}'.trim();
        return _failure(
          'javac ${p.basename(entry)}',
          diagnostic.isEmpty
              ? 'javac failed (exit code ${compile.exitCode})'
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
          title: 'java $mainClass',
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
        await jdk.launchArguments(runtimeArguments),
        workingDirectory: project,
        environment: jdk.environment,
        runInShell: false,
      );
      unawaited(_feedInput(process.stdin, File(p.join(project, 'input.txt'))));
      final runOutput = output;
      final exitCode = process.exitCode.whenComplete(() async {
        await _removeOutput(runOutput);
      });
      final cancel = _desktopCancellation(process);
      output = null;
      return ProgramRunResult(
        title: 'java $mainClass',
        stdout: _drainAfterExit(
          process.stdout,
          process.exitCode,
        ).transform(utf8.decoder).transform(const LineSplitter()),
        stderr: _withDiagnostics(
          compileDiagnostics,
          _drainAfterExit(
            process.stderr,
            process.exitCode,
          ).transform(utf8.decoder).transform(const LineSplitter()),
        ),
        exitCode: exitCode,
        cancel: () async {
          await cancel();
          await exitCode;
        },
      );
    } on _JavaCompileStopped catch (error) {
      return _failure('javac ${p.basename(entry)}', error.message);
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

  Future<ProcessResult> _compile(
    _Jdk jdk,
    List<String> arguments,
    String project,
  ) async {
    final Stream<List<int>> stdout;
    final Stream<List<int>> stderr;
    final Future<int> exitCode;
    final Future<void> Function() terminate;
    if (jdk.mobileLayout case final MobileJdkLayout layout
        when Platform.operatingSystem == 'ohos') {
      final process = await OhosJdkProcess.start(
        home: layout.home,
        libraryDirectory: layout.libraryDirectory,
        arguments: [
          '-Xms16m',
          '-Xmx256m',
          '-XX:+UseSerialGC',
          '-m',
          'jdk.compiler/com.sun.tools.javac.Main',
          ...arguments,
        ],
        workingDirectory: project,
      );
      stdout = process.stdout;
      stderr = process.stderr;
      exitCode = process.exitCode;
      terminate = process.cancel;
    } else {
      final process = await Process.start(
        jdk.javac,
        await jdk.launchArguments([
          '-J-Xms16m',
          '-J-Xmx256m',
          '-J-XX:+UseSerialGC',
          ...arguments,
        ], javac: true),
        workingDirectory: project,
        environment: jdk.environment,
        runInShell: false,
      );
      unawaited(process.stdin.close());
      stdout = process.stdout;
      stderr = process.stderr;
      exitCode = process.exitCode;
      terminate = _desktopCancellation(process);
    }
    Future<void>? terminating;
    String? stopped;
    void stop(String message) {
      if (stopped != null) return;
      stopped = message;
      terminating = terminate();
      // Also awaited below; install a handler before awaiting pipe drainage.
      unawaited(terminating!.catchError((Object _) {}));
    }

    var bytes = 0;
    Future<String> collect(Stream<List<int>> stream) async {
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        final remaining = (compilerOutputLimit - bytes).clamp(0, chunk.length);
        if (remaining > 0) buffer.add(chunk.sublist(0, remaining));
        bytes += chunk.length;
        if (bytes > compilerOutputLimit) stop('javac 编译诊断超过本地输出限制。');
      }
      return utf8.decode(buffer.takeBytes(), allowMalformed: true);
    }

    final timer = Timer(compileTimeout, () => stop('javac 编译超时，已终止编译器。'));
    try {
      // Future.wait subscribes to both pipes and exit errors immediately.
      final values = await Future.wait<Object>([
        exitCode,
        collect(_drainAfterExit(stdout, exitCode)),
        collect(_drainAfterExit(stderr, exitCode)),
      ]);
      if (terminating != null) await terminating;
      if (stopped case final String message) throw _JavaCompileStopped(message);
      return ProcessResult(0, values[0] as int, values[1], values[2]);
    } catch (_) {
      await terminate();
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  /// Compiles and/or executes a raw terminal command (`javac`/`java`) in
  /// [workingDirectory], using the same JDK resolution and mobile bridge as
  /// [run]. Returns null when the command is not a java toolchain command.
  ///
  /// Used by the shared terminal so `javac Main.java` / `java Main` typed by
  /// the user run for real, instead of the terminal falsely reporting that the
  /// platform forbids execution.
  Future<ProgramRunResult?> runToolchainCommand({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
  }) async {
    final process = await startToolchainProcess(
      workingDirectory: workingDirectory,
      arguments: arguments,
      isolatedEnvironment: isolatedEnvironment,
    );
    if (process == null) return null;
    return ProgramRunResult(
      title: process.title,
      stdout: process.stdout
          .transform(_toolchainDecoder)
          .transform(const LineSplitter()),
      stderr: process.stderr
          .transform(_toolchainDecoder)
          .transform(const LineSplitter()),
      exitCode: process.exitCode,
      cancel: process.cancel,
    );
  }

  /// Raw pipes let trusted compiler/debugger clients enforce byte limits before
  /// line decoding, including output which has no newline.
  Future<JavaToolchainProcess?> startToolchainProcess({
    required String workingDirectory,
    required List<String> arguments,
    bool isolatedEnvironment = false,
    String? inputFile,
  }) async {
    if (arguments.isEmpty) return null;
    final tool = arguments.first;
    final isJavac =
        tool == 'javac' || p.basenameWithoutExtension(tool) == 'javac';
    final isJava = tool == 'java' || p.basenameWithoutExtension(tool) == 'java';
    if (!isJavac && !isJava) return null;

    _Jdk? jdk;
    try {
      jdk = MobileJdk.isMobile
          ? _Jdk.fromMobile(await MobileJdk.prepare())
          : _findJdk();
    } on Exception catch (error) {
      return _toolchainFailure('javac', '无法初始化 JDK：$error');
    }
    if (jdk == null) {
      return _toolchainFailure(
        'javac',
        '未找到 JDK。请设置 QFLI_JAVA_HOME 或 JAVA_HOME。',
      );
    }

    final rest = arguments.sublist(1);
    final String title = isJavac
        ? 'javac ${rest.join(' ')}'
        : 'java ${rest.join(' ')}';
    try {
      if (jdk.mobileLayout case final MobileJdkLayout layout
          when Platform.operatingSystem == 'ohos') {
        final process = await OhosJdkProcess.start(
          home: layout.home,
          libraryDirectory: layout.libraryDirectory,
          arguments: isJavac
              ? [
                  for (final argument in rest)
                    if (argument.startsWith('-J') && argument.length > 2)
                      argument.substring(2),
                  '-m',
                  'jdk.compiler/com.sun.tools.javac.Main',
                  for (final argument in rest)
                    if (!(argument.startsWith('-J') && argument.length > 2))
                      argument,
                ]
              : rest,
          workingDirectory: workingDirectory,
          inputFile: inputFile,
        );
        return JavaToolchainProcess(
          title: title,
          stdout: process.stdout,
          stderr: process.stderr,
          exitCode: process.exitCode,
          cancel: process.cancel,
        );
      }
      final executable = isJavac ? jdk.javac : jdk.java;
      final process = await Process.start(
        executable,
        await jdk.launchArguments(rest, javac: isJavac),
        workingDirectory: workingDirectory,
        environment: isolatedEnvironment
            ? ({...Platform.environment, ...?jdk.environment}..removeWhere(
                (name, _) => const {
                  'JAVA_TOOL_OPTIONS',
                  '_JAVA_OPTIONS',
                  'JDK_JAVAC_OPTIONS',
                  'JDK_JAVA_OPTIONS',
                  'CLASSPATH',
                }.contains(name.toUpperCase()),
              ))
            : jdk.environment,
        includeParentEnvironment: !isolatedEnvironment,
        runInShell: false,
      );
      if (inputFile == null) {
        unawaited(process.stdin.close());
      } else {
        unawaited(_feedInput(process.stdin, File(inputFile)));
      }
      return JavaToolchainProcess(
        title: title,
        stdout: _drainAfterExit(process.stdout, process.exitCode),
        stderr: _drainAfterExit(process.stderr, process.exitCode),
        exitCode: process.exitCode,
        cancel: _desktopCancellation(process),
      );
    } on ProcessException catch (error) {
      return _toolchainFailure(title, '无法启动 $tool：${error.message}');
    }
  }

  /// Decoder for a JDK toolchain process' output.
  ///
  /// `javac`/`java` print diagnostics in the host's ANSI code page (GBK on a
  /// Chinese Windows), not UTF-8. A strict decoder throws on those bytes and
  /// the terminal would show `shell: FormatException: ...` instead of the real
  /// compiler diagnostic. Malformed bytes are replaced rather than fatal so the
  /// user always sees the tool's actual message.
  static const Converter<List<int>, String> _toolchainDecoder = Utf8Decoder(
    allowMalformed: true,
  );

  // A descendant can inherit a JVM's output handles. Once the owned JVM has
  // exited, keep draining its final output briefly, then close our pipe handles
  // instead of waiting indefinitely for an unrelated descendant's EOF.
  static Stream<List<int>> _drainAfterExit(
    Stream<List<int>> stream,
    Future<int> exitCode,
  ) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    var closed = false;
    var paused = false;
    var processExited = false;
    final drainElapsed = Stopwatch();
    void close() {
      if (closed) return;
      closed = true;
      timer?.cancel();
      drainElapsed.stop();
      unawaited(subscription?.cancel());
      unawaited(controller.close());
    }

    void drain() {
      if (closed || paused) return;
      drainElapsed.start();
      // Preserve the remaining budget across backpressure, rather than letting
      // each asynchronous chunk reset the deadline for a noisy descendant.
      final remaining = const Duration(seconds: 2) - drainElapsed.elapsed;
      timer = Timer(remaining.isNegative ? Duration.zero : remaining, close);
    }

    void afterExit() {
      processExited = true;
      drain();
    }

    controller = StreamController<List<int>>(
      onListen: () {
        subscription = stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: close,
        );
        unawaited(
          exitCode.then((_) => afterExit(), onError: (Object _) => afterExit()),
        );
      },
      onPause: () {
        paused = true;
        timer?.cancel();
        drainElapsed.stop();
        subscription?.pause();
      },
      onResume: () {
        paused = false;
        subscription?.resume();
        if (processExited) drain();
      },
      onCancel: () {
        closed = true;
        timer?.cancel();
        drainElapsed.stop();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  static Future<void> Function() _desktopCancellation(Process process) {
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    Future<void>? cancelling;
    Future<void> cancel() async {
      if (exited) return;
      if (Platform.isWindows) {
        // Kill only this owned process and its descendants. Killing the root
        // first loses the ancestry information required by taskkill /T.
        Process? taskkill;
        try {
          final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
          taskkill = await Process.start(
            p.join(windows, 'System32', 'taskkill.exe'),
            ['/PID', '${process.pid}', '/T', '/F'],
            runInShell: false,
          );
          unawaited(taskkill.stdin.close());
          unawaited(
            _drainAfterExit(taskkill.stdout, taskkill.exitCode).drain<void>(),
          );
          unawaited(
            _drainAfterExit(taskkill.stderr, taskkill.exitCode).drain<void>(),
          );
          await taskkill.exitCode.timeout(const Duration(seconds: 3));
        } on Exception {
          taskkill?.kill(ProcessSignal.sigkill);
          // Fall back to killing the owned JVM if tree cancellation failed.
        }
      }
      if (!exited) process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5));
    }

    return () => cancelling ??= cancel();
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

  /// Sources compiled by both Run and the offline diagnostic snapshot.
  static List<String> collectProjectJavaFiles(Directory directory) {
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

  /// Local dependencies; no package resolution or downloads take place.
  static List<String> collectProjectJars(Directory directory) {
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
      r'^\s*package\s+([\w$\u0080-\uFFFF]+(?:\.[\w$\u0080-\uFFFF]+)*)\s*;',
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

  JavaToolchainProcess _toolchainFailure(String title, String message) =>
      JavaToolchainProcess(
        title: title,
        stdout: const Stream.empty(),
        stderr: Stream.value(utf8.encode(message)),
        exitCode: Future.value(kProgramNotRunExitCode),
        cancel: () async {},
      );
}

class JavaToolchainProcess {
  const JavaToolchainProcess({
    required this.title,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.cancel,
  });
  final String title;
  final Stream<List<int>> stdout;
  final Stream<List<int>> stderr;
  final Future<int> exitCode;
  final Future<void> Function() cancel;
}

class _JavaCompileStopped implements Exception {
  const _JavaCompileStopped(this.message);
  final String message;
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
    tempDirectory: layout.temporaryDirectory,
    mobileLayout: layout,
  );

  Future<List<String>> launchArguments(
    List<String> arguments, {
    bool javac = false,
  }) async {
    final layout = mobileLayout;
    if (layout == null) return arguments;
    return MobileJvmLaunch.arguments(
      home: layout.home,
      arguments: arguments,
      javac: javac,
    );
  }

  static _Jdk? fromDirectory(String directory) {
    final suffix = Platform.isWindows ? '.exe' : '';
    final java = p.join(directory, 'java$suffix');
    final javac = p.join(directory, 'javac$suffix');
    if (!File(java).existsSync() || !File(javac).existsSync()) return null;
    return _Jdk(java, javac);
  }
}
