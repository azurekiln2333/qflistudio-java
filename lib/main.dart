import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:qfli_studio_core/app.dart';
import 'package:qfli_studio_core/services/project_templates.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';
import 'package:qfli_studio_core/splash_screen.dart';
import 'package:qfli_studio_core/store/auth_store.dart';
import 'package:qfli_studio_core/store/project_store.dart';
import 'package:qfli_studio_core/store/settings_store.dart';
import 'package:qfli_studio_core/terminal/shell/command_parser.dart';
import 'package:qfli_studio_core/terminal/shell/sandbox_shell_backend.dart';

import 'java_runner.dart';

/// 本 App 的产品名。窗口标题、任务切换器和应用内顶栏都读它。
const String _appTitle = StudioProductCatalog.jvmx;

/// Java 版档位：同一套内核 UI，收窄成只服务 Java。
///
/// 单独提出来是为了让测试能直接断言档位，而不必为了一个常量去跑 `main()`。
StudioProfile javaProfile = _createJavaProfile();

StudioProfile _createJavaProfile() => StudioProfile(
  id: 'java',
  appTitle: _appTitle,
  templates: [ProjectTemplate.empty, ProjectTemplate.java],
  runner: JavaProgramRunner(),
  isOffline: true,
  productKey: StudioProductCatalog.jvmxKey,
  showHomeTabs: false,
  runtimeKind: 'JDK (javac + java)',
  runtimeStatus: const JavaProgramRunner().isAvailable
      ? 'available'
      : 'unavailable',
  supportedFileExtensions: ['.java'],
  // Main.java 排在默认入口表前面，保证本版一定先命中它。
  entryFileNames: ['Main.java', 'src/Main.java'],
  // 终端命令挂钩：让内置终端能手动跑 javac/java（复用运行按钮同一条 JDK 路径）。
  terminalCommandDelegate: _javaTerminalDelegate,
);

/// Terminal hook for the Java toolchain.
///
/// Claims `javac <...>` / `java <...>` and routes them through
/// [JavaProgramRunner.runToolchainCommand] (real JDK on desktop, native bridge
/// on mobile), streaming stdout/stderr and the exit status into the sandbox
/// backend. Returns false for anything else so the sandbox reports honestly.
///
/// The command is tokenized with [CommandParser] rather than a whitespace split
/// so a quoted operand survives (`javac "src/Hello World.java"` must reach
/// javac as one argument, without its quotes). Compound lines (pipes,
/// redirection, chaining, globs) are deliberately **not** claimed: the sandbox
/// cannot evaluate them, so they fall through to the sandbox's honest
/// "construct unavailable" message instead of being misread as javac arguments.
Future<bool> _javaTerminalDelegate(
  SandboxShellBackend backend,
  String command,
) async {
  // The sandbox always classifies with a literal backslash (Windows path
  // separator), so tokenize the same way; otherwise `C:\dir` would be mangled.
  const policy = EscapePolicy.backslashLiteral;
  if (CommandParser.classify(command, escapePolicy: policy) !=
      CommandSyntax.simple) {
    return false;
  }
  final parsed = CommandParser.tokenize(command, escapePolicy: policy);
  if (!parsed.ok || parsed.tokens.isEmpty) return false;
  final tokens = parsed.tokens.map((token) => token.text).toList();
  final tool = tokens.first;
  if (tool != 'javac' && tool != 'java') return false;
  final runner = const JavaProgramRunner();
  final result = await runner.runToolchainCommand(
    workingDirectory: backend.cwd,
    arguments: tokens,
  );
  if (result == null) return false;
  await backend.runStreams(
    title: result.title,
    stdout: result.stdout,
    stderr: result.stderr,
    exitCode: result.exitCode,
    cancel: result.cancel,
  );
  return true;
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final nativeStartup = !kIsWeb && defaultTargetPlatform == TargetPlatform.ohos;
  if (nativeStartup) binding.deferFirstFrame();

  // 在 runApp 之前定档。
  StudioProfile.current = javaProfile;

  final store = ProjectStore();
  final auth = AuthStore();
  final settings = SettingsStore();
  final ready = ValueNotifier<bool>(false);
  runApp(QfliApp(store: store, auth: auth, settings: settings, ready: ready));

  const platformChannel = MethodChannel('qflistudio/platform');
  Future<void> reportProgress(double progress) async {
    try {
      await platformChannel.invokeMethod<void>('startupProgress', {
        'progress': progress,
      });
    } on PlatformException catch (error) {
      debugPrint('Startup progress unavailable: ${error.code}');
    } on MissingPluginException {
      // Other entry shells use the Flutter startup screen.
    }
  }

  Future<void> completeStartup() async {
    try {
      final minimumDisplay = nativeStartup
          ? Future<void>.delayed(const Duration(milliseconds: 1100))
          : Future<void>.value();
      if (nativeStartup) {
        // Let the native splash subscribe before sending initialization progress.
        await Future<void>.delayed(const Duration(milliseconds: 160));
        unawaited(reportProgress(0.05));
      }
      await JavaProgramRunner.prepare();
      javaProfile = _createJavaProfile();
      StudioProfile.current = javaProfile;
      if (nativeStartup) unawaited(reportProgress(0.25));
      await AppBootstrap.run(
        store: store,
        auth: auth,
        settings: settings,
        ready: ready,
        onProgress: nativeStartup
            ? (progress) => unawaited(reportProgress(0.25 + progress * 0.75))
            : null,
      );
      await Future.wait([
        minimumDisplay,
        if (nativeStartup)
          Future<void>.delayed(const Duration(milliseconds: 320)),
      ]);
      // Keep the native splash until the home page has completed build and layout.
      if (nativeStartup) await binding.endOfFrame;
    } finally {
      if (nativeStartup) binding.allowFirstFrame();
    }
  }

  binding.addPostFrameCallback((_) {
    unawaited(completeStartup());
  });
}
