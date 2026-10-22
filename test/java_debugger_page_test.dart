import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_debugger.dart';
import 'package:qfli_java/java_debugger_page.dart';
import 'package:qfli_studio_core/models/project.dart';
import 'package:qfli_studio_core/store/project_store.dart';

const _location = JavaDebugLocation(
  className: 'Main',
  sourceName: 'Main.java',
  line: 4,
);
const _frames = [
  JavaDebugFrame(index: 0, method: 'work', location: _location),
  JavaDebugFrame(index: 1, method: 'main', location: _location),
];

class _Session implements JavaDebugSession {
  final controller = StreamController<JavaDebugEvent>.broadcast();
  final readyCompleter = Completer<void>();
  final doneCompleter = Completer<int>();
  final commands = <String>[];
  final added = <JavaBreakpoint>[];
  final removed = <String>[];
  final inspectedFrames = <int>[];
  Completer<List<JavaDebugFrame>>? stackReply;
  Completer<void>? stopReply;
  int stopCalls = 0;

  @override
  Stream<JavaDebugEvent> get events => controller.stream;
  @override
  Future<void> get ready => readyCompleter.future;
  @override
  Future<int> get done => doneCompleter.future;
  @override
  JavaDebugVmInfo? get vmInfo => const JavaDebugVmInfo(
    name: 'Test local JVM',
    version: '17',
    description: 'JDI test double',
    canPopFrames: false,
    canForceEarlyReturn: false,
  );

  void attach() {
    readyCompleter.complete();
    emit(const JavaDebugEvent(JavaDebugEventKind.attached));
  }

  void emit(JavaDebugEvent event) => controller.add(event);

  @override
  Future<void> stop() async {
    stopCalls++;
    if (stopReply != null) await stopReply!.future;
    if (!readyCompleter.isCompleted) {
      readyCompleter.completeError(StateError('stopped before attach'));
    }
    if (!doneCompleter.isCompleted) {
      emit(const JavaDebugEvent(JavaDebugEventKind.terminated, exitCode: -1));
      doneCompleter.complete(-1);
    }
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    emit(const JavaDebugEvent(JavaDebugEventKind.paused, location: _location));
  }

  @override
  Future<void> resume() async {
    commands.add('resume');
    emit(const JavaDebugEvent(JavaDebugEventKind.resumed));
  }

  @override
  Future<void> stepInto() async => commands.add('into');
  @override
  Future<void> stepOver() async => commands.add('over');
  @override
  Future<void> stepOut() async => commands.add('out');
  @override
  Future<void> terminate() => stop();
  @override
  Future<void> setBreakpoint(JavaBreakpoint breakpoint) async {
    added.add(breakpoint);
    emit(
      JavaDebugEvent(
        JavaDebugEventKind.breakpoint,
        breakpointId: breakpoint.id,
        verified: true,
      ),
    );
  }

  @override
  Future<void> removeBreakpoint(String id) async => removed.add(id);
  @override
  Future<List<JavaDebugFrame>> stackTrace() async =>
      stackReply == null ? _frames : await stackReply!.future;
  @override
  Future<List<JavaDebugVariable>> variables({int frame = 0}) async {
    inspectedFrames.add(frame);
    return [
      JavaDebugVariable(name: 'answer', type: 'int', value: '${40 + frame}'),
    ];
  }
}

class _Debugger extends JavaDebugger {
  _Debugger(this.session);
  final _Session session;
  String? projectPath;
  String? entryFile;
  List<JavaBreakpoint>? breakpoints;
  List<String>? arguments;
  Map<String, String>? unsavedBuffers;

  @override
  JavaDebugSession launch({
    required String projectPath,
    required String entryFile,
    Map<String, String> unsavedBuffers = const {},
    List<JavaBreakpoint> breakpoints = const [],
    List<String> arguments = const [],
  }) {
    this.projectPath = projectPath;
    this.entryFile = entryFile;
    this.breakpoints = breakpoints;
    this.arguments = arguments;
    this.unsavedBuffers = unsavedBuffers;
    return session;
  }
}

class _Store extends ProjectStore {
  _Store(this.entries);
  final List<Project> entries;
  @override
  List<Project> get projects => entries;
}

void main() {
  late _Session session;
  late _Debugger debugger;
  final projectPath = p.join(
    Directory.systemTemp.path,
    'java-debug-ui-project',
  );
  Finder field(String label) => find.widgetWithText(TextField, label);
  Finder button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );

  tearDown(() async {
    await session.controller.close();
  });

  Future<void> mount(WidgetTester tester, {ProjectStore? store}) async {
    session = _Session();
    debugger = _Debugger(session);
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: JavaDebuggerPage(store: store, debugger: debugger),
      ),
    );
    await tester.pump();
  }

  Future<void> start(WidgetTester tester) async {
    await tester.enterText(field('项目绝对路径'), projectPath);
    await tester.tap(button('启动调试'));
    await tester.pump();
  }

  testWidgets('validates the project and confines the entry before launching', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(button('启动调试'));
    await tester.pump();
    expect(debugger.projectPath, isNull);
    expect(find.text('请填写项目绝对路径和 Java 入口文件。'), findsOneWidget);
    await tester.enterText(field('项目绝对路径'), projectPath);
    await tester.enterText(field('Java 入口文件'), '../Other.java');
    await tester.tap(button('启动调试'));
    await tester.pump();
    expect(debugger.projectPath, isNull);
    expect(find.text('入口必须是当前项目内的 .java 文件。'), findsOneWidget);
  });

  testWidgets(
    'defaults to the last browsed local project and preserves arguments',
    (tester) async {
      final recent = Project.create(
        name: 'Recent',
        path: '$projectPath-recent',
      );
      final selected = Project.create(name: 'Selected', path: projectPath);
      final store = _Store([recent, selected]);
      store.lastBrowsedProjectId = selected.id;
      addTearDown(store.dispose);
      await mount(tester, store: store);
      expect(
        tester.widget<TextField>(field('项目绝对路径')).controller!.text,
        projectPath,
      );
      await tester.enterText(field('程序参数（每行一个）'), ' first arg \n第二项');
      await tester.tap(button('启动调试'));
      await tester.pump();
      expect(debugger.projectPath, projectPath);
      expect(debugger.entryFile, p.join(projectPath, 'Main.java'));
      expect(debugger.arguments, [' first arg ', '第二项']);
      expect(debugger.unsavedBuffers, isEmpty);
      expect(find.textContaining('保存文件'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(session.stopCalls, 1);
    },
  );

  testWidgets(
    'real session actions, verified breakpoints, frames and output are reachable',
    (tester) async {
      await mount(tester);
      await tester.enterText(field('断点行号'), '4');
      await tester.tap(button('添加断点'));
      await tester.pump();
      await start(tester);
      expect(debugger.breakpoints!.single.className, 'Main');
      expect(debugger.breakpoints!.single.line, 4);
      session.attach();
      session.emit(
        JavaDebugEvent(
          JavaDebugEventKind.breakpoint,
          breakpointId: debugger.breakpoints!.single.id,
          verified: true,
        ),
      );
      await tester.pump();
      expect(find.text('Test local JVM 17'), findsOneWidget);
      expect(find.text('已绑定可执行位置'), findsOneWidget);
      await tester.tap(button('暂停'));
      await tester.pump();
      await tester.pump();
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('Main.work'), findsOneWidget);
      expect(find.text('int answer = 40'), findsOneWidget);
      await tester.tap(find.text('Main.main'));
      await tester.pump();
      await tester.pump();
      expect(session.inspectedFrames, [0, 1]);
      expect(find.text('int answer = 41'), findsOneWidget);
      for (final label in ['单步越过', '单步进入', '单步跳出']) {
        await tester.tap(button(label));
        await tester.pump();
      }
      await tester.enterText(field('断点行号'), '7');
      await tester.tap(button('添加断点'));
      await tester.pump();
      expect(session.added.single.line, 7);
      await tester.tap(find.byTooltip('移除 Main:7'));
      await tester.pump();
      expect(session.removed, [session.added.single.id]);
      session.emit(
        const JavaDebugEvent(JavaDebugEventKind.output, message: 'answer=42\n'),
      );
      session.emit(
        const JavaDebugEvent(
          JavaDebugEventKind.output,
          message: 'warning\n',
          isErrorOutput: true,
        ),
      );
      await tester.pump();
      expect(find.textContaining('[stderr] warning'), findsOneWidget);
      await tester.tap(button('继续'));
      await tester.pump();
      expect(session.commands, ['pause', 'over', 'into', 'out', 'resume']);
      expect(find.text('运行中'), findsOneWidget);
      expect(find.text('Main.work'), findsNothing);
      await tester.tap(button('停止'));
      await tester.pump();
      expect(session.stopCalls, 1);
      expect(find.text('已结束'), findsOneWidget);
    },
  );

  testWidgets('stop works while compilation or attach is pending', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    expect(find.text('正在编译并连接调试器…'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(button('停止')).onPressed, isNotNull);
    await tester.tap(button('停止'));
    await tester.pumpAndSettle();
    expect(session.stopCalls, 1);
    expect(find.text('已结束'), findsOneWidget);
    expect(
      tester.widget<ButtonStyleButton>(button('启动调试')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('toolchain failure remains explicit after termination', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    const failure = 'JDWP is not supported by this target VM';
    session.emit(
      const JavaDebugEvent(JavaDebugEventKind.error, message: failure),
    );
    session.readyCompleter.completeError(StateError(failure));
    session.emit(
      const JavaDebugEvent(JavaDebugEventKind.terminated, exitCode: 1),
    );
    session.doneCompleter.complete(1);
    await tester.pump();
    expect(find.text('调试不可用或失败'), findsOneWidget);
    expect(find.text(failure), findsOneWidget);
    expect(find.text('已结束'), findsNothing);
  });

  testWidgets('late attach or pause cannot reopen controls while stopping', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    session.stopReply = Completer<void>();
    await tester.tap(button('停止'));
    await tester.pump();
    session.attach();
    session.emit(
      const JavaDebugEvent(JavaDebugEventKind.paused, location: _location),
    );
    await tester.pump();
    expect(find.text('正在停止…'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(button('继续')).onPressed, isNull);
    expect(session.inspectedFrames, isEmpty);
    session.stopReply!.complete();
    await tester.pumpAndSettle();
    expect(find.text('已结束'), findsOneWidget);
  });

  testWidgets('output retains a bounded tail with actual stdout and stderr', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    session.attach();
    session.emit(
      JavaDebugEvent(JavaDebugEventKind.output, message: 'x' * 100000),
    );
    session.emit(
      const JavaDebugEvent(
        JavaDebugEventKind.output,
        message: 'tail\n',
        isErrorOutput: true,
      ),
    );
    await tester.pump();
    final output = tester
        .widget<SelectableText>(find.byKey(const ValueKey('java-debug-output')))
        .data!;
    expect(output, startsWith('…（仅保留最近输出）'));
    expect(output, endsWith('[stderr] tail\n'));
    expect(output.length, lessThan(65600));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'resuming rejects late stack data and disposal stops the session',
    (tester) async {
      await mount(tester);
      await start(tester);
      session.attach();
      session.stackReply = Completer<List<JavaDebugFrame>>();
      session.emit(
        const JavaDebugEvent(JavaDebugEventKind.paused, location: _location),
      );
      await tester.pump();
      await tester.tap(button('继续'));
      await tester.pump();
      session.stackReply!.complete(_frames);
      await tester.pump();
      expect(session.inspectedFrames, isEmpty);
      expect(find.text('Main.work'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(session.stopCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a narrow dark page keeps controls and errors within the viewport',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      session = _Session();
      debugger = _Debugger(session);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: JavaDebuggerPage(debugger: debugger),
        ),
      );
      final scrollable = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        button('单步跳出'),
        200,
        scrollable: scrollable,
      );
      await tester.pump();
      expect(button('单步跳出').hitTestable(), findsOneWidget);
      await tester.scrollUntilVisible(
        field('断点行号'),
        200,
        scrollable: scrollable,
      );
      await tester.enterText(field('断点行号'), '0');
      await tester.tap(button('添加断点'));
      await tester.pump();
      expect(debugger.projectPath, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
