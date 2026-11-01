import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_web_environment_page.dart';
import 'package:qfli_java/java_web_templates.dart';

const _snapshot = JavaWebConfigSnapshot(
  profile: javaWebProfileSpringBoot,
  mainClass: 'com.example.demo.WebApplication',
  port: 8080,
  contextPath: '/demo',
  webRoot: 'src/main/webapp',
);

/// Pack metadata a ready project expects, stated explicitly.
///
/// The page reads capabilities from p4. A fake that returned an empty pack made
/// every ready expectation unsatisfiable, so the ready case states its pack.
const _readyPack = JavaWebPack(
  boot3: true,
  json: true,
  jakartaContainer: true,
  jsp: true,
  jdbc: false,
  persistence: false,
  javaee8: false,
  boot3Version: '3.5.16',
  metadataAvailable: true,
  jars: ['spring-boot-3.5.16.jar', 'jakarta.servlet-api-6.0.0.jar'],
);

class _FakeSource implements JavaWebProjectSource {
  _FakeSource({
    this.hasConfigFile = true,
    this.config = _snapshot,
    this.projectPaths = const [],
    this.pack = _readyPack,
    this.healthy = false,
  });

  final bool hasConfigFile;
  final JavaWebConfigSnapshot? config;
  final List<String> projectPaths;

  /// Pack metadata the page would read from p4. Explicit for each case.
  final JavaWebPack pack;
  final bool healthy;

  final List<String> written = <String>[];
  int probes = 0;
  int reads = 0;

  @override
  Future<JavaWebConfigRead> readConfig(String projectPath) async {
    reads++;
    return JavaWebConfigRead(
      hasConfigFile: hasConfigFile,
      config: config,
      issues: hasConfigFile
          ? const []
          : const [JavaWebIssue('missing', '找不到配置文件')],
    );
  }

  @override
  Future<List<String>> listProjectFiles(String projectPath) async =>
      projectPaths;

  @override
  Future<JavaWebPack> readPack() async => pack;

  @override
  Future<bool> probeHealth(JavaWebConfigSnapshot config) async {
    probes++;
    return healthy;
  }

  @override
  Future<void> writeScaffold(
    String projectPath,
    JavaWebScaffoldPlan plan,
  ) async {
    if (!plan.canApply) {
      throw StateError('blocked');
    }
    written.addAll(plan.files.map((file) => file.path));
  }
}

Future<void> _pump(WidgetTester tester, JavaWebProjectSource source) async {
  await tester.pumpWidget(
    MaterialApp(
      home: JavaWebEnvironmentPage(
        initialProjectPath: '/tmp/demo',
        source: source,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((widget) => widget.data ?? '')
    .join('\n');

/// A source whose async calls stay pending until the test releases them.
class _DelayedSource implements JavaWebProjectSource {
  final List<String> readPaths = <String>[];
  final List<String> writePaths = <String>[];

  Completer<JavaWebConfigRead>? _read;
  Completer<bool>? _probe;
  Completer<void>? _write;

  @override
  Future<JavaWebConfigRead> readConfig(String projectPath) {
    readPaths.add(projectPath);
    final completer = Completer<JavaWebConfigRead>();
    _read = completer;
    return completer.future;
  }

  @override
  Future<List<String>> listProjectFiles(String projectPath) async => const [];

  @override
  Future<JavaWebPack> readPack() async => _readyPack;

  @override
  Future<bool> probeHealth(JavaWebConfigSnapshot config) {
    final completer = Completer<bool>();
    _probe = completer;
    return completer.future;
  }

  @override
  Future<void> writeScaffold(String projectPath, JavaWebScaffoldPlan plan) {
    writePaths.add(projectPath);
    final completer = Completer<void>();
    _write = completer;
    return completer.future;
  }

  void completeRead() => _read!.complete(
    const JavaWebConfigRead(
      hasConfigFile: true,
      config: _snapshot,
      issues: [],
    ),
  );

  void completeProbe() => _probe!.complete(true);

  void completeWrite() => _write!.complete();
}

/// Mounts without settling, so a pending operation is allowed to stay pending.
Future<void> _mount(WidgetTester tester, JavaWebProjectSource source) async {
  await tester.pumpWidget(
    MaterialApp(
      home: JavaWebEnvironmentPage(
        initialProjectPath: '/tmp/demo',
        source: source,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('inspects the project and shows the configured address', (
    tester,
  ) async {
    final source = _FakeSource();
    await _pump(tester, source);

    expect(source.reads, 1);
    expect(find.text('配置已就绪，尚未启动服务'), findsOneWidget);
    expect(find.text('http://127.0.0.1:8080/demo'), findsOneWidget);
    expect(find.text('已找到'), findsOneWidget);
  });

  testWidgets('lists the pack without claiming readiness', (tester) async {
    await _pump(tester, _FakeSource());

    expect(find.text('有包，版本 3.5.16'), findsOneWidget);
    expect(find.text('有包'), findsWidgets);
    expect(find.text('无包'), findsWidgets);
    expect(find.text('未验证'), findsOneWidget);
    expect(_texts(tester), contains('不表示已响应'));
  });

  testWidgets('readiness comes from the response probe only', (tester) async {
    final healthy = _FakeSource(healthy: true);
    await _pump(tester, healthy);

    expect(find.text('未验证'), findsOneWidget);
    await tester.tap(find.text('检查本地响应'));
    await tester.pumpAndSettle();

    expect(healthy.probes, 1);
    expect(find.text('端口有响应'), findsOneWidget);
    expect(find.text('本机端口有响应，未确认由本项目提供'), findsOneWidget);
  });

  testWidgets('a failed probe keeps the address unproven', (tester) async {
    final source = _FakeSource(healthy: false);
    await _pump(tester, source);

    await tester.tap(find.text('检查本地响应'));
    await tester.pumpAndSettle();

    expect(find.text('未验证'), findsOneWidget);
    expect(find.textContaining('未收到本地响应'), findsOneWidget);
  });

  testWidgets('an empty pack is still reported as missing components', (
    tester,
  ) async {
    final source = _FakeSource(pack: const JavaWebPack.empty());
    await _pump(tester, source);

    // The readiness rule stays strict: an empty pack never reads as ready.
    expect(find.text('离线包缺少 spring-boot 运行组件'), findsOneWidget);
    expect(find.text('配置已就绪，尚未启动服务'), findsNothing);
    expect(find.text('无包'), findsWidgets);
    expect(source.reads, 1);
  });

  testWidgets('a path change mid-inspect still releases the busy state', (
    tester,
  ) async {
    final source = _DelayedSource();
    await _mount(tester, source);
    expect(source.readPaths, ['/tmp/demo']);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // The user switches target while the first inspect is still running.
    await tester.enterText(find.byType(TextField).first, '/tmp/other');
    await tester.pump();

    // The stale inspect completes and must release the operation anyway.
    source.completeRead();
    await tester.pump();
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    // Nothing from the abandoned directory is shown.
    expect(find.text('配置地址'), findsNothing);
  });

  testWidgets('a path change mid-probe still releases the busy state', (
    tester,
  ) async {
    final source = _DelayedSource();
    await _mount(tester, source);
    source.completeRead();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('检查本地响应'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '/tmp/other');
    await tester.pump();

    source.completeProbe();
    await tester.pump();
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('applying for one project never reports success for another', (
    tester,
  ) async {
    final source = _DelayedSource();
    await _mount(tester, source);
    source.completeRead();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('生成计划'));
    await tester.pump();
    await tester.tap(find.text('确认创建'));
    await tester.pump();
    expect(source.writePaths, ['/tmp/demo']);

    // Switch target while the write is still in flight.
    await tester.enterText(find.byType(TextField).first, '/tmp/other');
    await tester.pump();

    source.completeWrite();
    await tester.pump();
    await tester.pump();

    // The write stayed on the captured directory, and the notice names it.
    expect(source.writePaths, ['/tmp/demo']);
    expect(find.textContaining('已为 /tmp/demo'), findsOneWidget);
    expect(find.textContaining('已为 /tmp/other'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('points at the editor entry file instead of faking run', (
    tester,
  ) async {
    await _pump(tester, _FakeSource());

    // The editor and terminal own run and stop, so this page has neither.
    expect(find.widgetWithText(FilledButton, '运行'), findsNothing);
    expect(find.widgetWithText(FilledButton, '停止'), findsNothing);
    expect(find.text('入口文件'), findsOneWidget);
    expect(find.textContaining('点击运行'), findsOneWidget);
    expect(find.textContaining('停止由编辑器与终端负责'), findsOneWidget);
  });

  testWidgets('never claims a compile, a run or an OHOS acceptance', (
    tester,
  ) async {
    await _pump(tester, _FakeSource());
    final texts = _texts(tester);
    expect(texts, isNot(contains('运行成功')));
    expect(texts, isNot(contains('编译成功')));
    expect(texts, isNot(contains('OHOS 已验收')));
    expect(texts, contains('qflisql'));
  });

  testWidgets('writes nothing until the user confirms', (tester) async {
    final source = _FakeSource();
    await _pump(tester, source);

    expect(find.text('确认创建'), findsNothing);
    expect(source.written, isEmpty);

    await tester.tap(find.text('生成计划'));
    await tester.pumpAndSettle();
    expect(find.text('确认创建'), findsOneWidget);
    expect(source.written, isEmpty);

    await tester.tap(find.text('确认创建'));
    await tester.pumpAndSettle();

    expect(
      source.written,
      contains('src/main/java/com/example/demo/WebApplication.java'),
    );
    expect(source.written, contains(javaWebConfigFileName));
  });

  testWidgets('keeps an existing file and blocks the plan', (tester) async {
    final source = _FakeSource(
      projectPaths: const [
        'src/main/java/com/example/demo/HealthController.java',
      ],
    );
    await _pump(tester, source);

    await tester.tap(find.text('生成计划'));
    await tester.pumpAndSettle();

    expect(find.textContaining('拒绝覆盖'), findsOneWidget);
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认创建'),
    );
    expect(confirm.onPressed, isNull);
    expect(source.written, isEmpty);
  });

  testWidgets('refuses an out-of-range port before planning', (tester) async {
    final source = _FakeSource();
    await _pump(tester, source);

    await tester.enterText(
      find.widgetWithText(TextField, '8080').first,
      '70000',
    );
    await tester.tap(find.text('生成计划'));
    await tester.pumpAndSettle();

    expect(find.textContaining('端口必须是'), findsOneWidget);
    expect(find.text('确认创建'), findsNothing);
    expect(source.written, isEmpty);
  });

  testWidgets('reports a missing config instead of inventing one', (
    tester,
  ) async {
    await _pump(tester, _FakeSource(hasConfigFile: false, config: null));

    expect(find.text('尚未配置 JavaEE 环境'), findsOneWidget);
    expect(find.text('未找到'), findsOneWidget);
    expect(find.text('确认创建'), findsNothing);
  });
}
