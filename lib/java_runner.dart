import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/services/studio_profile.dart';

import 'java_web_project.dart';
import 'javaee_container_launcher.dart';
import 'mobile_jdk.dart';
import 'mobile_jvm_launch.dart';
import 'ohos_jdk_process.dart';
import 'spring_boot_bundle.dart';
import 'src/java_process_cancellation.dart';

/// Compiles project sources with javac and runs the resulting main class.
class JavaProgramRunner implements ProgramRunner {
  const JavaProgramRunner({
    this.javaHome,
    this.compileTimeout = const Duration(seconds: 60),
    this.compilerOutputLimit = 512 * 1024,
    this.webProcessFactory,
    this.webDependencyProvider,
    this.webReadinessProbe,
    this.webPortAvailable,
    this.webReadyTimeout = const Duration(seconds: 120),
    this.webStartWait = const Duration(seconds: 60),
    this.webDrainWindow = const Duration(seconds: 2),
    this.webCompiler,
    this.javaeeContainerPackProvider,
  });

  /// An explicit JDK location, useful for a bundled distribution or tests.
  final String? javaHome;

  /// A compiler must terminate before Run returns or deletes its class output.
  final Duration compileTimeout;
  final int compilerOutputLimit;

  /// Test seam: replaces the real JVM launch of an opted-in Web project.
  final JavaWebProcessFactory? webProcessFactory;

  /// Test seam: replaces the bundled Spring Boot dependency set.
  final JavaWebDependencyProvider? webDependencyProvider;

  /// Test seam: replaces the loopback readiness probe.
  final JavaWebReadinessProbe? webReadinessProbe;

  /// Test seam: replaces the pre-launch free-port check.
  final JavaWebPortCheck? webPortAvailable;

  /// How long a Web project may take to answer on its configured address.
  final Duration webReadyTimeout;

  /// How long a start waits for the previous start of the same project.
  ///
  /// A wait that overruns refuses this start; it never takes the root. Injectable
  /// so a regression test can exercise the refusal without a 60 second wait.
  final Duration webStartWait;

  /// How long an owned Web pipe keeps draining after its process exits.
  ///
  /// A descendant can inherit the JVM's handles, so the pipe may never reach
  /// EOF. This window bounds that wait. Injectable so a regression test can drive
  /// the cancellation ordering without a real 2 second wait.
  final Duration webDrainWindow;

  /// Test seam: replaces the real `javac` invocation of an opted-in Web project.
  final JavaWebCompiler? webCompiler;

  /// Supplies the verified `javaee8` container bundle. p4 owns the real one;
  /// without it a `javaee8` run refuses instead of guessing paths.
  final JavaeeContainerPackProvider? javaeeContainerPackProvider;

  /// Separator the running platform uses between the classpath entries we build.
  static String get _classpathSeparator => Platform.isWindows ? ';' : ':';

  /// Bounded JVM budget for a Web server, matching the compile policy.
  ///
  /// A Boot application or an embedded container defaults to a heap derived
  /// from the machine. On a memory-tight device that default can exceed the
  /// headroom, so the server runs on the same fixed budget as the compiler.
  static const List<String> _webMemoryArguments = <String>[
    '-Xms16m',
    '-Xmx256m',
    '-XX:+UseSerialGC',
  ];

  /// The server each project root currently owns, so a restart stops the old JVM.
  static final Map<String, _OwnedJavaWebServer> _ownedWebServers =
      <String, _OwnedJavaWebServer>{};

  /// Starts in flight per project root, so two Runs cannot interleave.
  static final Map<String, Future<void>> _webStarts = <String, Future<void>>{};

  /// Deploy directories a terminal process could not delete.
  ///
  /// Kept rather than dropped, so a leftover tree is reported instead of being
  /// silently presented as a clean deploy. [retryWebCleanup] drains this set.
  static final Set<String> _pendingWebCleanup = <String>{};

  /// Shares one in-flight cleanup so a retry cannot run twice at once.
  static Future<bool>? _cleanupRetry;

  /// Retries every deploy directory a terminal process failed to delete.
  ///
  /// Returns true only when the set is empty afterwards. Successes leave the
  /// set, failures stay in it so a later call can try again. Calls are serialized
  /// so two retries never race the same directory.
  static Future<bool> retryWebCleanup() {
    final pending = _cleanupRetry;
    if (pending != null) return pending;
    final attempt = _retryWebCleanup().whenComplete(() {
      _cleanupRetry = null;
    });
    _cleanupRetry = attempt;
    return attempt;
  }

  static Future<bool> _retryWebCleanup() async {
    for (final path in _pendingWebCleanup.toList()) {
      if (await _removeOutput(Directory(path))) {
        _pendingWebCleanup.remove(path);
      }
    }
    return _pendingWebCleanup.isEmpty;
  }

  /// Deploy directories still on disk after their process ended.
  static Set<String> get pendingWebCleanup =>
      Set<String>.unmodifiable(_pendingWebCleanup);

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

    // An opted-in Web project takes the server path. A project without the
    // config file keeps the console path below unchanged.
    final JavaWebProject? webProject;
    try {
      webProject = await JavaWebProject.load(project);
    } on JavaWebProjectException catch (error) {
      return _failure('Java Web', '${error.code}：${error.message}');
    }
    if (webProject != null) {
      return _runWeb(project: webProject, entry: entry, entryFile: entryFile);
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

  /// Server path for a project that carries a Java Web config file.
  ///
  /// The project keeps its sources untouched: compilation writes into a
  /// temporary deploy directory, and that directory is removed only after the
  /// JVM it belongs to has terminated.
  Future<ProgramRunResult> _runWeb({
    required JavaWebProject project,
    required String entry,
    required String entryFile,
  }) async {
    final blocked = project.launchBlockedReason;
    if (blocked != null) return _failure('Java Web', blocked);

    _Jdk? jdk;
    try {
      jdk = MobileJdk.isMobile
          ? _Jdk.fromMobile(await MobileJdk.prepare())
          : _findJdk();
    } on Exception catch (error) {
      return _failure('Java Web', '无法初始化 JDK：$error');
    }
    if (jdk == null) {
      return _failure('Java Web', '未找到 JDK。请设置 QFLI_JAVA_HOME 或 JAVA_HOME。');
    }

    // The physical guard runs before any collection. A `src/main/java` that is a
    // link out of the project would otherwise compile sources the project does
    // not own, because the directory scan itself follows the tree root.
    final escapedSourceRoot = await _escapedProjectRoot(
      project.projectRoot,
      <String>[project.mainSourceRoot],
    );
    if (escapedSourceRoot != null) {
      return _failure('Java Web', escapedSourceRoot);
    }

    final sources = collectWebMainJavaFiles(Directory(project.projectRoot));
    if (sources.isEmpty) {
      return _failure('javac ${p.basename(entryFile)}', 'Web 项目没有可编译的主源码。');
    }

    if (project.profile == JavaWebProject.profileJavaee8) {
      return _runJavaee8(
        project: project,
        jdk: jdk,
        sources: sources,
        entryFile: entryFile,
      );
    }
    return _runSpringBoot(
      project: project,
      jdk: jdk,
      sources: sources,
      entry: entry,
      entryFile: entryFile,
    );
  }

  /// Spring Boot runs on the bundled jakarta dependency set with server args.
  Future<ProgramRunResult> _runSpringBoot({
    required JavaWebProject project,
    required _Jdk jdk,
    required List<String> sources,
    required String entry,
    required String entryFile,
  }) async {
    // Boot ships no Jasper, so a JSP anywhere it publishes would be readable
    // source. That covers the project web root and the four default static
    // locations under src/main/resources, because Boot serves those too.
    final jspLocation = _bootPublishedJspLocation(project);
    if (jspLocation != null) {
      return _failure(
        'Java Web',
        'Boot 画像不含 JSP 引擎。$jspLocation 中的 JSP 不会被渲染，也不得作为静态文件公开。请改用 javaee8 画像。',
      );
    }
    final escapedRoot = await _escapedProjectRoot(project.projectRoot, <String>[
      project.resourcesRoot,
      project.webRootPath,
    ]);
    if (escapedRoot != null) {
      return _failure('Java Web', escapedRoot);
    }

    final List<String> bundleJars;
    try {
      // The dependency group follows the project's own flag. A health-only app
      // must not receive the JDBC, pool and mapper jars, because their auto
      // configuration would demand a data source at startup.
      final includeDatabase = project.databaseEnabled;
      final packCache = _packCacheRoot(jdk);
      bundleJars =
          await (webDependencyProvider?.call(
                project.profile,
                includeDatabase: includeDatabase,
                targetDirectory: packCache,
              ) ??
              SpringBootBundle.materialiseProfile(
                project.profile,
                targetDirectory: packCache,
                includeDatabase: includeDatabase,
              ));
    } on JavaEePackException catch (error) {
      return _failure('Java Web', 'Boot 依赖包不可用：${error.message}');
    } on Exception catch (error) {
      return _failure('Java Web', 'Boot 依赖包不可用：$error');
    }
    if (bundleJars.isEmpty) {
      return _failure('Java Web', 'Boot 依赖包为空，无法编译 Web 项目。');
    }

    final projectJars = <String>[
      ...collectProjectJars(Directory(p.join(project.projectRoot, 'lib'))),
      ...collectProjectJars(Directory(p.join(project.projectRoot, 'libs'))),
    ];
    final namespaces = detectServletNamespaces(<String>[
      ...projectJars,
      ...bundleJars,
    ]);
    if (namespaces.contains('javax.servlet') &&
        namespaces.contains('jakarta.servlet')) {
      return _failure(
        'Java Web',
        'classpath 同时含 javax 与 jakarta 的 Servlet API，命名空间混用。',
      );
    }

    final deployRoot = await _createDeployRoot(jdk);
    var transferred = false;
    try {
      final classesDir = Directory(p.join(deployRoot.path, 'classes'));
      await classesDir.create(recursive: true);
      await _copyTree(Directory(project.resourcesRoot), classesDir);
      final webappDir = Directory(p.join(deployRoot.path, 'webapp'));
      await _copyTree(Directory(project.webRootPath), webappDir);
      final servesWebRoot = _hasAnyFile(webappDir);

      final classpathEntries = <String>[
        classesDir.path,
        ...projectJars,
        ...bundleJars,
      ];

      final compile = await _compileWeb(jdk, <String>[
        '--release',
        '17',
        '-encoding',
        'UTF-8',
        '-d',
        classesDir.path,
        '-classpath',
        classpathEntries.join(_classpathSeparator),
        ...sources,
      ], project.projectRoot);
      if (compile.exitCode != 0) {
        final diagnostic = '${compile.stdout}${compile.stderr}'.trim();
        return _failure(
          'javac ${p.basename(entryFile)}',
          diagnostic.isEmpty
              ? 'javac failed (exit code ${compile.exitCode})'
              : diagnostic,
        );
      }

      return await _ownedServerResult(
        project: project,
        jdk: jdk,
        deployRoot: deployRoot,
        port: project.port,
        mainClass: project.mainClass ?? _deriveMainClass(entry),
        arguments: <String>[
          '--server.address=127.0.0.1',
          '--server.port=${project.port}',
          // Always sent, including the root case. Omitting it for the root would
          // let a stale server.servlet.context-path in the project's own
          // application.properties win, while the UI reports the root URL.
          // An empty value is Boot's way of asking for the root context.
          '--server.servlet.context-path='
              '${project.contextPath == '/' ? '' : project.contextPath}',
          // Only override the static locations when the project really has a
          // web root with content. Boot replaces its default list rather than
          // extending it, so the four defaults are restated here on purpose.
          if (servesWebRoot)
            '--spring.web.resources.static-locations=${_bootStaticLocations(webappDir)}',
        ],
        classpathEntries: classpathEntries,
        address: project.localAddress,
        compileDiagnostics: '${compile.stdout}${compile.stderr}'.trim(),
        markTransferred: () => transferred = true,
      );
    } finally {
      // Until the process owns the deploy directory, this method owns it.
      if (!transferred) await _removeOutput(deployRoot);
    }
  }

  /// Java EE 8 runs p5's container plan.
  ///
  /// The plan owns the Tomcat 9 launcher source and its argv. This runner owns
  /// the process, the live output, the cancellation and the cleanup.
  Future<ProgramRunResult> _runJavaee8({
    required JavaWebProject project,
    required _Jdk jdk,
    required List<String> sources,
    required String entryFile,
  }) async {
    final escapedRoot = await _escapedProjectRoot(project.projectRoot, <String>[
      project.resourcesRoot,
      project.webRootPath,
    ]);
    if (escapedRoot != null) {
      return _failure('Java Web', escapedRoot);
    }

    JavaeeContainerPack pack;
    try {
      // The real container pack comes from the dependency owner's verified
      // pack. A missing pack is a refusal, never a fabricated empty one.
      final packCache = _packCacheRoot(jdk);
      pack =
          await (javaeeContainerPackProvider?.call(packCache) ??
              _defaultJavaee8Pack(packCache));
    } on JavaEePackException catch (error) {
      return _failure('Java Web', '容器包不可用：${error.message}');
    } on Exception catch (error) {
      return _failure('Java Web', '无法读取容器包：$error');
    }

    final deployRoot = await _createDeployRoot(jdk);
    var transferred = false;
    try {
      final classesDir = Directory(p.join(deployRoot.path, 'classes'));
      await classesDir.create(recursive: true);
      final projectJars = <String>[
        ...collectProjectJars(Directory(p.join(project.projectRoot, 'lib'))),
        ...collectProjectJars(Directory(p.join(project.projectRoot, 'libs'))),
      ];

      // The legacy line is javax only. A classpath that carries both Servlet
      // namespaces cannot run either one, so it is refused here as well.
      final namespaces = detectServletNamespaces(<String>[
        ...projectJars,
        ...pack.classpath,
      ]);
      if (namespaces.contains('javax.servlet') &&
          namespaces.contains('jakarta.servlet')) {
        return _failure(
          'Java Web',
          'classpath 同时含 javax 与 jakarta 的 Servlet API，命名空间混用。',
        );
      }

      final JavaeeContainerLaunchPlan plan;
      try {
        plan = JavaeeContainerLauncher.plan(
          config: project,
          pack: pack,
          workDirectory: deployRoot.path,
          classDirectories: <String>[classesDir.path],
          projectJars: projectJars,
          requiresJsp: _hasJspPages(Directory(project.webRootPath)),
        );
      } on JavaeeContainerException catch (error) {
        return _failure(
          'Java Web',
          error.issues
              .map((issue) => '${issue.code}：${issue.message}')
              .join('\n'),
        );
      }

      // Lay out exactly what the plan declares, then compile into the classes
      // directory the plan already put on its classpath.
      await _copyTree(
        Directory(plan.assembly.webSource),
        Directory(plan.assembly.documentBase),
      );
      await _copyTree(
        Directory(plan.assembly.resourcesSource),
        Directory(plan.assembly.classesDestination),
      );
      await Directory(plan.assembly.libraryDestination).create(recursive: true);
      for (final jar in plan.assembly.libraryJars) {
        final source = File(jar);
        if (await source.exists()) {
          await source.copy(
            p.join(plan.assembly.libraryDestination, p.basename(jar)),
          );
        }
      }
      final launcherFile = File(plan.sourcePath);
      await launcherFile.parent.create(recursive: true);
      await launcherFile.writeAsString(plan.source, flush: true);

      final compile = await _compileWeb(jdk, <String>[
        '--release',
        '17',
        '-encoding',
        'UTF-8',
        '-d',
        classesDir.path,
        '-classpath',
        plan.classpath.join(_classpathSeparator),
        plan.sourcePath,
        ...sources,
      ], project.projectRoot);
      if (compile.exitCode != 0) {
        final diagnostic = '${compile.stdout}${compile.stderr}'.trim();
        return _failure(
          'javac ${p.basename(entryFile)}',
          diagnostic.isEmpty
              ? 'javac failed (exit code ${compile.exitCode})'
              : diagnostic,
        );
      }

      final result = await _ownedServerResult(
        project: project,
        jdk: jdk,
        deployRoot: deployRoot,
        port: plan.port,
        mainClass: plan.mainClass,
        arguments: plan.arguments,
        classpathEntries: plan.classpath,
        address: plan.readinessUrl.toString(),
        compileDiagnostics: '${compile.stdout}${compile.stderr}'.trim(),
        markTransferred: () => transferred = true,
      );
      return result;
    } finally {
      if (!transferred) await _removeOutput(deployRoot);
    }
  }

  /// Starts the server, registers it as the project's owned process, and hands
  /// back a result whose cancel stops it.
  ///
  /// The deploy directory lives as long as the JVM it belongs to: the caller
  /// keeps it until [markTransferred] runs. After the owned process becomes
  /// terminal its output still drains, then this method deletes the directory.
  /// A deletion that fails is recorded in [pendingWebCleanup], never presented
  /// as a clean deploy.
  Future<ProgramRunResult> _ownedServerResult({
    required JavaWebProject project,
    required _Jdk jdk,
    required Directory deployRoot,
    required int port,
    required String mainClass,
    required List<String> arguments,
    required List<String> classpathEntries,
    required String address,
    required String compileDiagnostics,
    required void Function() markTransferred,
  }) async {
    // Starts are serialized per project root with a future chain. Each caller
    // registers its own tail before it waits, so starts for one root cannot
    // interleave. A waiter that overruns the wait refuses, but it must not
    // release its tail while the predecessor is still running: a third caller
    // is queued on that tail, and releasing early would let it start behind a
    // predecessor that has not finished.
    final predecessor = _webStarts[project.projectRoot] ?? Future<void>.value();
    final gate = Completer<void>();
    final tail = gate.future;
    _webStarts[project.projectRoot] = tail;
    // True when this call refused after the wait and gave its queue position back
    // to the predecessor. Such a call no longer owns the tail: releasing it in
    // `finally` would unblock a successor while the predecessor still runs.
    var retired = false;
    try {
      try {
        await predecessor.timeout(webStartWait);
      } on TimeoutException {
        // Refuse, and retire this queue position instead of releasing it.
        retired = true;
        // When this tail is still the published one, hand the position back to
        // the real owner so later callers queue on it rather than on this tail.
        if (identical(_webStarts[project.projectRoot], tail)) {
          _webStarts[project.projectRoot] = predecessor;
        }
        void releaseRetiredTail() {
          if (!gate.isCompleted) gate.complete();
          if (identical(_webStarts[project.projectRoot], tail)) {
            _webStarts.remove(project.projectRoot);
          }
        }

        // The retired tail stays pending until the predecessor really ends, so a
        // successor queued on this tail cannot overtake a running start. The
        // hook, not `finally`, releases this tail.
        unawaited(
          predecessor.then(
            (_) => releaseRetiredTail(),
            onError: (Object _) => releaseRetiredTail(),
          ),
        );
        return _failure('Java Web', '同一项目的上一次启动仍未结束，本次启动已取消。');
      } on Object {
        // A previous start that failed must not block this one.
      }

      // One owned server per project: a second Run replaces the first, so a
      // stale JVM never holds the configured port.
      final owned = _ownedWebServers[project.projectRoot];
      if (owned != null) {
        // A running server is stopped first, then the full teardown is joined. A
        // terminal-but-draining server is joined directly: it still owns its
        // deploy tree, so starting a replacement now would overlap the cleanup.
        if (!owned.terminal) await owned.cancel();
        await owned.done;
      }

      // A port already answering belongs to someone else. Starting anyway would
      // let an unrelated server be mistaken for this project's server.
      final portFree =
          await (webPortAvailable?.call(port) ?? _isPortFree(port));
      if (!portFree) {
        return _failure('Java Web', '端口 $port 已被其他进程占用，本地 Web 服务未启动。');
      }

      final JavaToolchainProcess handle;
      try {
        handle = await _webFactory(jdk)(
          JavaWebProcessRequest(
            arguments: <String>[
              ..._webMemoryArguments,
              '-Dfile.encoding=UTF-8',
              '-Dstdout.encoding=UTF-8',
              '-Dstderr.encoding=UTF-8',
              '-Dsun.stdout.encoding=UTF-8',
              '-Dsun.stderr.encoding=UTF-8',
              '-classpath',
              classpathEntries.join(_classpathSeparator),
              mainClass,
              ...arguments,
            ],
            workingDirectory: project.projectRoot,
          ),
        );
      } on ProcessException catch (error) {
        return _failure('Java Web', '无法启动 JDK：${error.message}');
      } on PlatformException catch (error) {
        return _failure('Java Web', '无法启动 JDK：${error.message}');
      }

      final server = _OwnedJavaWebServer(project.projectRoot, handle.cancel);

      // Both pipes are wrapped exactly once, here, and drained even when no
      // caller ever listens. Settlement covers both pipes and waits for the raw
      // subscriptions to be cancelled.
      final stdoutPipe = _webPipe(
        handle.stdout,
        handle.exitCode,
        webDrainWindow,
      );
      final stderrPipe = _webPipe(
        handle.stderr,
        handle.exitCode,
        webDrainWindow,
      );
      final settled = Future.wait<void>(<Future<void>>[
        stdoutPipe.settled,
        stderrPipe.settled,
      ]);

      // The full teardown: exit, both pipes settled, and the deploy directory
      // deleted. A replacement joins this even when the process is already
      // terminal, because a terminal server still owns its deploy tree while it
      // drains.
      final done = handle.exitCode.whenComplete(() async {
        server.terminal = true;
        await settled;
        if (identical(_ownedWebServers[project.projectRoot], server)) {
          _ownedWebServers.remove(project.projectRoot);
        }
        final removed = await _removeOutput(deployRoot);
        if (!removed) _pendingWebCleanup.add(deployRoot.path);
      });
      server.done = done;
      // Published only after [done] exists, so a concurrent Run can never join an
      // uninitialised teardown.
      _ownedWebServers[project.projectRoot] = server;
      markTransferred();

      final exitCode = done;

      return ProgramRunResult(
        title: 'java $mainClass（Web ${project.profile}）',
        stdout: _webStdout(
          stdoutPipe.stream,
          address: address,
          settled: settled,
          probe: webReadinessProbe ?? _probeLoopback,
          timeout: webReadyTimeout,
          isOwnedAndRunning: () => !server.terminal,
        ),
        stderr: _withDiagnostics(compileDiagnostics, stderrPipe.stream),
        exitCode: exitCode,
        cancel: () async {
          await handle.cancel();
          await exitCode;
        },
      );
    } finally {
      // Only the call that still owns the tail releases it. A retired call left
      // the tail pending on purpose, and its predecessor hook releases it later.
      if (!retired) {
        if (!gate.isCompleted) gate.complete();
        if (identical(_webStarts[project.projectRoot], tail)) {
          _webStarts.remove(project.projectRoot);
        }
      }
    }
  }

  /// True when nothing is listening on [port] on the loopback interface.
  ///
  /// The bind is exclusive, so a socket already in use is reported as taken
  /// rather than silently shared.
  static Future<bool> _isPortFree(int port) async {
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      return true;
    } on SocketException {
      return false;
    } finally {
      await socket?.close();
    }
  }

  Future<Directory> _createDeployRoot(_Jdk jdk) async {
    final tempBase = jdk.tempDirectory;
    return tempBase == null
        ? Directory.systemTemp.createTemp('qfli_java_web_')
        : Directory(tempBase).createTemp('qfli_java_web_');
  }

  /// Writable root for the dependency packs, never the platform temp default.
  ///
  /// On a mobile runtime `Directory.systemTemp` resolves to a path the app
  /// cannot rely on writing, so the JDK layout's own temporary directory is
  /// used when it is known. Both packs materialise under this one root.
  static String _packCacheRoot(_Jdk jdk) => p.join(
    jdk.tempDirectory ?? Directory.systemTemp.path,
    'qfli-javaee-packs',
  );

  /// Boot's static locations, with the deployed web root appended.
  ///
  /// `spring.web.resources.static-locations` replaces the default list, so the
  /// four classpath defaults are restated before the file location. Dropping
  /// them would silently stop `classpath:/static/` from being served.
  static String _bootStaticLocations(Directory webapp) {
    var uri = webapp.absolute.uri.toString();
    if (!uri.endsWith('/')) uri = '$uri/';
    return <String>[
      'classpath:/META-INF/resources/',
      'classpath:/resources/',
      'classpath:/static/',
      'classpath:/public/',
      uri,
    ].join(',');
  }

  /// Refuses a project root that a symbolic link points outside the project.
  ///
  /// `followLinks: false` only guards entries below a copied tree. The tree root
  /// itself can still be a link, which would copy files the project does not own.
  /// Returns a refusal message naming the real target, or null when every
  /// candidate stays inside the project.
  static Future<String?> _escapedProjectRoot(
    String projectRoot,
    List<String> candidates,
  ) async {
    final root = await Directory(projectRoot).resolveSymbolicLinks();
    for (final candidate in candidates) {
      final directory = Directory(candidate);
      if (!await directory.exists()) continue;
      final physical = await directory.resolveSymbolicLinks();
      if (p.equals(physical, root) || p.isWithin(root, physical)) continue;
      return '$candidate 通过链接指向项目外：$physical';
    }
    return null;
  }

  /// Returns the first location under which Boot would publish a JSP, or null.
  ///
  /// Boot serves `src/main/resources/{META-INF/resources,resources,static,public}`
  /// by default and the project web root when the runner adds it to the static
  /// locations. A JSP in any of those is published as plain source, so each is
  /// inspected instead of only the configured web root.
  static String? _bootPublishedJspLocation(JavaWebProject project) {
    final candidates = <String>[
      project.webRootPath,
      p.join(project.resourcesRoot, 'META-INF', 'resources'),
      p.join(project.resourcesRoot, 'resources'),
      p.join(project.resourcesRoot, 'static'),
      p.join(project.resourcesRoot, 'public'),
    ];
    for (final candidate in candidates) {
      if (_hasJspPages(Directory(candidate))) return candidate;
    }
    return null;
  }

  /// True when a tree holds at least one file, so an empty web root is ignored.
  static bool _hasAnyFile(Directory directory) {
    if (!directory.existsSync()) return false;
    try {
      return directory
          .listSync(recursive: true, followLinks: false)
          .any((entity) => entity is File);
    } on FileSystemException {
      return false;
    }
  }

  /// Reads the container pack from the dependency owner's verified pack.
  ///
  /// The classpath and every capability flag come from that pack's hashed
  /// manifest. No flag is inferred from a file name, and no version is invented.
  /// [targetDirectory] is the writable cache root the caller resolved, so the
  /// container JARs never land in an unusable platform temp directory.
  static Future<JavaeeContainerPack> _defaultJavaee8Pack(
    String targetDirectory,
  ) async {
    final classpath = await JavaEePacks.materialiseProfile(
      JavaEeProfiles.javaee8,
      targetDirectory: targetDirectory,
    );
    final capabilities = await JavaEePacks.capabilities(JavaEeProfiles.javaee8);
    return JavaeeContainerPack(
      classpath: classpath,
      jspSupported: capabilities.jsp,
      jstlSupported: capabilities.roles.contains('jstl'),
      annotationScanning: capabilities.servlet,
    );
  }

  /// Runs `javac` through the real toolchain, or through the test seam.
  Future<ProcessResult> _compileWeb(
    _Jdk jdk,
    List<String> arguments,
    String project,
  ) {
    final injected = webCompiler;
    if (injected == null) return _compile(jdk, arguments, project);
    return injected(
      JavaWebCompileRequest(arguments: arguments, workingDirectory: project),
    );
  }

  /// True when the web root really holds a JSP page, so a JSP-less pack refuses.
  static bool _hasJspPages(Directory webRoot) {
    if (!webRoot.existsSync()) return false;
    try {
      for (final entity in webRoot.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final extension = p.extension(entity.path).toLowerCase();
        if (extension == '.jsp' ||
            extension == '.jspx' ||
            extension == '.jspf') {
          return true;
        }
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  JavaWebProcessFactory _webFactory(_Jdk jdk) {
    final injected = webProcessFactory;
    if (injected != null) return injected;
    return (request) => _startWebProcess(jdk, request);
  }

  Future<JavaToolchainProcess> _startWebProcess(
    _Jdk jdk,
    JavaWebProcessRequest request,
  ) async {
    final workingDirectory = request.workingDirectory;
    if (jdk.mobileLayout case final MobileJdkLayout layout
        when Platform.operatingSystem == 'ohos') {
      final process = await OhosJdkProcess.start(
        home: layout.home,
        libraryDirectory: layout.libraryDirectory,
        arguments: request.arguments,
        workingDirectory: workingDirectory,
        inputFile: p.join(workingDirectory, 'input.txt'),
      );
      return JavaToolchainProcess(
        title: 'java',
        // Raw pipes: the Web path wraps each once, in _webPipe, and owns the
        // drain and its cancellation.
        stdout: process.stdout,
        stderr: process.stderr,
        exitCode: process.exitCode,
        cancel: process.cancel,
      );
    }
    final process = await Process.start(
      jdk.java,
      await jdk.launchArguments(request.arguments),
      workingDirectory: workingDirectory,
      environment: jdk.environment,
      runInShell: false,
    );
    unawaited(
      _feedInput(process.stdin, File(p.join(workingDirectory, 'input.txt'))),
    );
    // Raw pipes: the Web path wraps each once, in _webPipe, and owns the drain
    // and its cancellation. The shared console path keeps using _drainAfterExit.
    return JavaToolchainProcess(
      title: 'java',
      stdout: process.stdout,
      stderr: process.stderr,
      exitCode: process.exitCode,
      cancel: _desktopCancellation(process),
    );
  }

  /// Drains one owned Web pipe into a buffered text stream, subscribed at once.
  ///
  /// The Web path owns this drain: the raw process pipe is wrapped exactly once,
  /// here. [settled] completes only after the underlying subscription is really
  /// cancelled, so a deploy directory is never deleted while the pipe stays
  /// attached. A pipe a descendant keeps open is closed after [drainWindow], which
  /// also bounds the teardown.
  static ({Stream<String> stream, Future<void> settled}) _webPipe(
    Stream<List<int>> raw,
    Future<int> exitCode,
    Duration drainWindow,
  ) {
    final controller = StreamController<String>();
    final settled = Completer<void>();
    var discarded = false;
    var drained = false;
    // A listener that never attaches must not let an unread log grow without
    // bound. The pipe keeps draining regardless; only the retained prefix is
    // capped, and it is delivered when a listener finally attaches.
    const maxUnlistenedLines = 2000;
    var buffered = 0;
    Timer? window;
    final drainedElapsed = Stopwatch();

    late final StreamSubscription<String> subscription;

    Future<void> finish() async {
      if (drained) return;
      drained = true;
      window?.cancel();
      drainedElapsed.stop();
      // The pipe is only really free once the raw subscription is cancelled.
      // Settling before that would let the deploy directory be deleted under a
      // still-attached pipe.
      await subscription.cancel();
      if (!controller.isClosed) unawaited(controller.close());
      if (!settled.isCompleted) settled.complete();
    }

    void startWindow() {
      if (drained) return;
      drainedElapsed.start();
      // Preserve the remaining budget across backpressure, rather than letting
      // each asynchronous chunk reset the deadline for a noisy descendant.
      final remaining = drainWindow - drainedElapsed.elapsed;
      window = Timer(remaining.isNegative ? Duration.zero : remaining, () {
        unawaited(finish());
      });
    }

    subscription = raw
        .transform(_toolchainDecoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (discarded || controller.isClosed) return;
            if (controller.hasListener) {
              controller.add(line);
              return;
            }
            if (buffered < maxUnlistenedLines) {
              controller.add(line);
              buffered++;
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!discarded && !controller.isClosed) {
              controller.addError(error, stack);
            }
          },
          onDone: () => unawaited(finish()),
          cancelOnError: false,
        );

    // A consumer that cancels only stops the forwarding. The drain must keep the
    // pipe emptying until the process is gone.
    controller.onCancel = () {
      discarded = true;
    };

    // The drain window opens when the process exits, not when it is cancelled:
    // an exiting process may still have buffered bytes to deliver.
    unawaited(
      exitCode.then<void>(
        (_) => startWindow(),
        onError: (Object _) => startWindow(),
      ),
    );

    return (stream: controller.stream, settled: settled.future);
  }

  /// Announces the configured address, then reports a local response once one
  /// arrives.
  ///
  /// The response is labelled as an answer on that address, not as proof that
  /// this project's own JVM produced it: any process on the port can answer. The
  /// port was verified free before launch, and the line is emitted only while
  /// the owned process is still running, so it degrades honestly instead of
  /// claiming more than it can show.
  ///
  /// Process exit stops readiness reporting only. It must not close the output:
  /// a program can print its last line and exit before the pipe delivers it, and
  /// closing early would drop exactly those lines.
  Stream<String> _webStdout(
    Stream<String> lines, {
    required String address,
    required Future<void> settled,
    required JavaWebReadinessProbe probe,
    required Duration timeout,
    required bool Function() isOwnedAndRunning,
  }) {
    final controller = StreamController<String>();
    StreamSubscription<String>? subscription;
    var closed = false;
    var exited = false;

    void add(String line) {
      if (!closed && !controller.isClosed) controller.add(line);
    }

    Future<void> close() async {
      if (closed) return;
      closed = true;
      // Wait for the subscription to really cancel before reporting closed.
      await subscription?.cancel();
      if (!controller.isClosed) await controller.close();
    }

    controller.onListen = () {
      add('本地地址（配置）：$address');
      subscription = lines.listen(
        add,
        onError: (Object error, StackTrace stack) {
          if (!closed && !controller.isClosed) {
            controller.addError(error, stack);
          }
        },
        onDone: () => unawaited(close()),
      );
      unawaited(() async {
        final deadline = DateTime.now().add(timeout);
        while (!closed && !exited && DateTime.now().isBefore(deadline)) {
          final status = await probe(Uri.parse(address));
          if (closed || exited) return;
          if (status != null && isOwnedAndRunning()) {
            add('本地地址（可响应）：$address（HTTP $status）');
            return;
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }());
      // Exit only stops readiness reporting; the drained pipe closes this stream.
      unawaited(settled.whenComplete(() => exited = true));
    };
    controller.onCancel = close;
    return controller.stream;
  }

  /// Sends one loopback request and returns its status, or null when nothing
  /// answered within [budget].
  ///
  /// Redirects are disabled: a redirect is not a served response, and following
  /// one would report an unrelated host's status as this address's. The budget
  /// covers connect, headers and the whole body, so a server that accepts and
  /// then stalls cannot hold the probe open.
  Future<int?> _probeLoopback(
    Uri uri, {
    Duration budget = const Duration(seconds: 5),
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    Future<int?> attempt() async {
      final request = await client.getUrl(uri);
      // Redirects are a per-request setting, not a client setting. Following one
      // would report an unrelated host's status as this address's answer.
      request.followRedirects = false;
      request.maxRedirects = 0;
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    try {
      return await attempt().timeout(budget);
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String _deriveMainClass(String entry) {
    String source;
    try {
      source = File(entry).readAsStringSync();
    } on FileSystemException {
      source = '';
    }
    final packageName = _packageName(source);
    final simpleName = p.basenameWithoutExtension(entry);
    return packageName == null ? simpleName : '$packageName.$simpleName';
  }

  /// Source files a Web project compiles: `src/main/java` when present, the
  /// project root otherwise. Test, build and tool output never enter the set.
  static List<String> collectWebMainJavaFiles(Directory project) {
    const excluded = <String>{
      'target',
      'build',
      'out',
      '.gradle',
      '.git',
      '.idea',
      'node_modules',
    };
    final mainRoot = Directory(p.join(project.path, 'src', 'main', 'java'));
    final testRoot = p.normalize(p.join(project.path, 'src', 'test'));
    final roots = <Directory>[mainRoot.existsSync() ? mainRoot : project];
    final files = <String>[];

    void visit(Directory directory) {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          if (name.startsWith('.') || excluded.contains(name)) continue;
          if (p.equals(p.normalize(entity.path), testRoot)) continue;
          visit(entity);
        } else if (entity is File &&
            p.extension(entity.path).toLowerCase() == '.java') {
          files.add(entity.path);
        }
      }
    }

    for (final root in roots) {
      if (root.existsSync()) visit(root);
    }
    files.sort();
    return files;
  }

  /// Reads the container API namespaces present in the given JARs.
  ///
  /// A JAR name proves nothing, so the archive entries decide.
  static Set<String> detectServletNamespaces(Iterable<String> jarPaths) {
    final found = <String>{};
    for (final path in jarPaths) {
      Uint8List bytes;
      try {
        bytes = File(path).readAsBytesSync();
      } on FileSystemException {
        continue;
      }
      Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(bytes, verify: false);
      } on Exception {
        continue;
      }
      for (final entry in archive) {
        final name = entry.name;
        if (name.startsWith('javax/servlet/')) found.add('javax.servlet');
        if (name.startsWith('jakarta/servlet/')) found.add('jakarta.servlet');
        if (found.length == 2) return found;
      }
    }
    return found;
  }

  static Future<void> _copyTree(Directory source, Directory target) async {
    if (!await source.exists()) return;
    await target.create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: source.path);
      final destination = p.join(target.path, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await entity.copy(destination);
      }
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
    }

    return javaProcessCancellation(process, cancel);
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

  /// Removes a temporary deploy directory.
  ///
  /// Returns true only when the directory is really gone. A caller that claims
  /// a clean deploy must check this, because a silent failure would turn a
  /// leftover tree into a false statement about the run. Static because it uses
  /// only its argument, and both the static retry path and instance runs call it.
  static Future<bool> _removeOutput(Directory output) async {
    try {
      if (!await output.exists()) return true;
      await output.delete(recursive: true);
      return true;
    } on FileSystemException {
      // A cleanup failure must not replace javac diagnostics or the JVM exit code.
      return false;
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

/// Arguments for one Web server launch. Kept free of JDK details so a test can
/// assert the exact command line without starting a JVM.
class JavaWebProcessRequest {
  const JavaWebProcessRequest({
    required this.arguments,
    required this.workingDirectory,
  });

  final List<String> arguments;
  final String workingDirectory;
}

/// Starts the Web server process. Replaced in tests.
typedef JavaWebProcessFactory =
    Future<JavaToolchainProcess> Function(JavaWebProcessRequest request);

/// Supplies the dependency JARs a Web project runs against. Replaced in tests.
///
/// [targetDirectory] is a writable cache root the caller resolved; it must not be
/// ignored, because the platform temp default is not writable on a mobile runtime.
typedef JavaWebDependencyProvider =
    Future<List<String>> Function(
      String profile, {
      required bool includeDatabase,
      required String targetDirectory,
    });

/// Returns the HTTP status of a local request, or null when nothing answered.
typedef JavaWebReadinessProbe = Future<int?> Function(Uri uri);

/// Reports whether a loopback port is free before launch. Replaced in tests.
typedef JavaWebPortCheck = Future<bool> Function(int port);

/// Arguments for one Web compile. Kept free of JDK details so a test can assert
/// the exact `javac` command line without starting a JVM.
class JavaWebCompileRequest {
  const JavaWebCompileRequest({
    required this.arguments,
    required this.workingDirectory,
  });

  final List<String> arguments;
  final String workingDirectory;
}

/// Compiles an opted-in Web project. Replaced in tests.
typedef JavaWebCompiler =
    Future<ProcessResult> Function(JavaWebCompileRequest request);

/// Supplies the verified `javaee8` container bundle. Replaced in tests.
///
/// The argument is the writable cache root the runner resolved for this launch.
typedef JavaeeContainerPackProvider =
    Future<JavaeeContainerPack> Function(String targetDirectory);

/// One running server per project root, so a restart can stop the previous JVM.
class _OwnedJavaWebServer {
  _OwnedJavaWebServer(this.projectRoot, this.cancel);

  final String projectRoot;
  final Future<void> Function() cancel;
  bool terminal = false;

  /// Resolves when the owned process has exited, both pipes settled, and the
  /// deploy directory is gone or recorded as pending. A replacement joins this
  /// even when [terminal] is set, so a draining server still blocks a restart.
  late Future<void> done;
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
