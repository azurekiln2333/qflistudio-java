import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_developer_tool_pages.dart';
import 'package:qfli_java/java_tools_page.dart';
import 'package:qfli_studio_core/widgets/tool_widgets.dart';
import 'package:qfli_studio_core/services/picker_service.dart';

/// Widget tests for the four developer-tool pages added to the Java tools tab.
///
/// The transformations themselves are covered by `java_developer_tools_test.dart`.
/// These mount each real page, drive it the way a user does (typing, toggling,
/// picking a file) and assert what is rendered. The `.class`/`.jar` loaders are
/// injected with the committed real fixtures so no native dialog is involved.
void main() {
  Uint8List fixture(String name) => File(
    'test/fixtures/java_developer_tools/${name == 'greeting.class' ? 'greeting.bin' : name}',
  ).readAsBytesSync();

  JavaFileBytesLoader fixedLoader(String name) =>
      () async => JavaFileBytes(name: name, bytes: fixture(name));

  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(420, 900),
    ThemeMode mode = ThemeMode.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        themeMode: mode,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF0B63CE),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF0B63CE),
        ),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Finds the [TextField] whose label is [label].
  Finder fieldWithLabel(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(TextField));

  group('tools tab wiring', () {
    test(
      'the Java section carries the original and inspected developer cards',
      () {
        expect(
          javaTools.map((tool) => tool.title),
          containsAllInOrder([
            '整数与进制',
            '字符串转义',
            'JSON 转 Java 类',
            '关键字速查',
            JavaDescriptorToolPage.title,
            JavaStackTraceToolPage.title,
            JavaClassFileToolPage.title,
            JavaJarToolPage.title,
          ]),
        );
        expect(
          javaTools.map((tool) => tool.title).toSet(),
          hasLength(javaTools.length),
          reason: 'every card title is unique so no card hides another',
        );
        for (final tool in javaTools) {
          expect(
            tool.builder,
            isNotNull,
            reason: '${tool.title} opens directly',
          );
          expect(
            tool.onTap,
            isNull,
            reason: '${tool.title} has no menu indirection',
          );
          expect(tool.description, isNotEmpty);
        }
      },
    );

    testWidgets('the standalone grid renders every Java card directly', (
      tester,
    ) async {
      await mount(
        tester,
        const Scaffold(body: JavaToolsGrid()),
        size: const Size(1100, 2400),
      );
      for (final tool in javaTools) {
        expect(find.text(tool.title), findsOneWidget);
      }
      expect(find.text('Java'), findsOneWidget);
      expect(find.text('通用'), findsOneWidget);
      expect(find.byType(ToolCard), findsNWidgets(javaTools.length + 9));
    });
  });

  group('shared native picker adapter', () {
    const channel = MethodChannel('qflistudio/platform');
    setUp(() => PickerService.forcePlatformChannel = true);
    tearDown(() {
      PickerService.forcePlatformChannel = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('uses the actual OHOS URI picker and readUri contract', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'pickDocument') {
              return {'uri': 'file://docs/local/selected', 'name': '本地.jar'};
            }
            return Uint8List.fromList([1, 2, 3]);
          });
      final file = await pickJavaFileBytes(['jar', 'zip']);
      expect(file!.name, '本地.jar');
      expect(file.bytes, [1, 2, 3]);
      expect(calls.map((call) => call.method), ['pickDocument', 'readUri']);
      expect(calls.first.arguments, {
        'folder': false,
        'extensions': ['jar', 'zip'],
      });
      expect(calls.last.arguments, {'uri': 'file://docs/local/selected'});
    });

    test('rejects a large local file before reading its bytes', () async {
      final directory = await Directory.systemTemp.createTemp(
        'java-tool-limit-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/large.jar');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(kJavaToolMaxBytes + 1);
      await handle.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => {'path': file.path},
          );
      await expectLater(pickJavaFileBytes(['jar']), throwsFormatException);
    });
  });

  group('JavaDescriptorToolPage', () {
    testWidgets('decodes the default method descriptor', (tester) async {
      await mount(tester, const JavaDescriptorToolPage());

      expect(find.text(JavaDescriptorToolPage.title), findsOneWidget);
      expect(find.text('(java.lang.String, int) -> void'), findsOneWidget);
      expect(find.text('参数个数'), findsOneWidget);
      expect(
        find.text('java.lang.String  [Ljava/lang/String;]'),
        findsOneWidget,
      );
      expect(find.text('int  [I]'), findsOneWidget);
      expect(find.text('void  [V]'), findsOneWidget);
    });

    testWidgets(
      'decodes a field descriptor when the input has no parentheses',
      (tester) async {
        await mount(tester, const JavaDescriptorToolPage());
        await tester.enterText(fieldWithLabel('描述符'), '[[Ljava/lang/String;');
        await tester.pump();

        expect(find.text('字段描述符'), findsWidgets);
        expect(find.text('java.lang.String[][]'), findsWidgets);
        expect(find.text('数组维度'), findsOneWidget);
        expect(find.text('2'), findsWidgets);
      },
    );

    testWidgets('reports an invalid descriptor instead of a wrong answer', (
      tester,
    ) async {
      await mount(tester, const JavaDescriptorToolPage());
      await tester.enterText(fieldWithLabel('描述符'), 'Ljava/lang/String');
      await tester.pump();

      expect(find.text('对象描述符缺少结尾的 ;'), findsOneWidget);
      expect(find.text('可读签名'), findsNothing);
      expect(find.text('数组维度'), findsNothing);
    });

    testWidgets('writes field and method descriptors from Java types', (
      tester,
    ) async {
      await mount(
        tester,
        const JavaDescriptorToolPage(),
        size: const Size(420, 1400),
      );

      expect(find.text('[Ljava/lang/String;'), findsOneWidget);
      expect(find.text('(ILjava/util/List;)V'), findsOneWidget);

      await tester.enterText(
        fieldWithLabel('方法参数类型（逗号分隔）'),
        'java.lang.String[]',
      );
      await tester.pump();
      expect(find.text('([Ljava/lang/String;)V'), findsOneWidget);

      await tester.enterText(fieldWithLabel('返回类型'), 'int');
      await tester.pump();
      expect(find.text('([Ljava/lang/String;)I'), findsOneWidget);
    });

    testWidgets('surfaces the reverse-direction error', (tester) async {
      await mount(
        tester,
        const JavaDescriptorToolPage(),
        size: const Size(420, 1400),
      );
      await tester.enterText(fieldWithLabel('字段类型'), 'void[]');
      await tester.pump();
      expect(find.text('void 只能作为方法返回类型'), findsOneWidget);
    });
  });

  group('JavaStackTraceToolPage', () {
    testWidgets('summarises the sample trace and keeps application frames', (
      tester,
    ) async {
      await mount(
        tester,
        const JavaStackTraceToolPage(),
        size: const Size(420, 1600),
      );

      expect(find.text(JavaStackTraceToolPage.title), findsOneWidget);
      expect(find.text('java.lang.IllegalStateException'), findsWidgets);
      expect(find.text('配置缺少 database.url'), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('6 帧，其中 4 帧属于应用代码'), findsOneWidget);
      expect(
        find.text('at app.Config.require(Config.java:42)'),
        findsOneWidget,
      );
      // The default is "application frames only", so JDK frames are hidden in
      // the rendered output (the text field still holds the pasted original).
      final trace = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((text) => text.data ?? '')
          .firstWhere((data) => data.contains('Exception in thread'));
      expect(trace, isNot(contains('java.io.FileInputStream')));
      expect(trace, isNot(contains('... 3 more')));
      expect(trace, contains('at app.Main.main(Main.java:9)'));
    });

    testWidgets('shows runtime frames when the switch is turned off', (
      tester,
    ) async {
      await mount(
        tester,
        const JavaStackTraceToolPage(),
        size: const Size(420, 1600),
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();

      expect(
        find.textContaining('java.io.FileInputStream.open0(Native Method)'),
        findsWidgets,
      );
      expect(find.textContaining('... 3 more'), findsWidgets);
    });

    testWidgets('filters frames by class or file text', (tester) async {
      await mount(
        tester,
        const JavaStackTraceToolPage(),
        size: const Size(420, 1600),
      );
      await tester.enterText(fieldWithLabel('只保留包含（可选）'), 'Config.java');
      await tester.pump();

      final output = tester.widgetList<SelectableText>(
        find.byType(SelectableText),
      );
      final trace = output
          .map((text) => text.data ?? '')
          .firstWhere((data) => data.contains('Exception in thread'));
      expect(trace, contains('app.Config.require(Config.java:42)'));
      expect(trace, isNot(contains('app.Repository.connect')));
      expect(trace, isNot(contains('app.Main.main')));
    });

    testWidgets('says honestly when the input is not a trace', (tester) async {
      await mount(tester, const JavaStackTraceToolPage());
      await tester.enterText(fieldWithLabel('堆栈文本'), 'BUILD SUCCESSFUL');
      await tester.pump();

      expect(find.text('粘贴一段 Java 堆栈以解析异常链和栈帧'), findsOneWidget);
      expect(find.text('概览'), findsNothing);
    });
  });

  group('JavaClassFileToolPage', () {
    testWidgets('inspects the committed Java 17 class fixture', (tester) async {
      await mount(
        tester,
        JavaClassFileToolPage(loader: fixedLoader('greeting.class')),
        size: const Size(420, 2200),
      );
      expect(find.text('选择一个本地 .class 文件以查看其结构'), findsOneWidget);

      await tester.tap(find.text('选择 .class 文件'));
      await tester.pumpAndSettle();

      expect(find.textContaining('greeting.class'), findsOneWidget);
      expect(find.text('Java 17 (major 61, minor 0)'), findsOneWidget);
      expect(
        find.text(
          'public final class fixtures.Greeting extends java.lang.Object',
        ),
        findsOneWidget,
      );
      expect(find.text('java.lang.Object'), findsOneWidget);
      expect(find.text('字段（2）'), findsOneWidget);
      expect(find.text('方法（4）'), findsOneWidget);
      expect(find.textContaining('public static void main'), findsWidgets);
      expect(find.textContaining('([Ljava/lang/String;)V'), findsOneWidget);
    });

    testWidgets('reports bytes that are not a class file', (tester) async {
      await mount(
        tester,
        JavaClassFileToolPage(
          loader: () async => JavaFileBytes(
            name: 'notes.txt',
            bytes: Uint8List.fromList('hello'.codeUnits),
          ),
        ),
      );
      await tester.tap(find.text('选择 .class 文件'));
      await tester.pumpAndSettle();

      expect(find.textContaining('CAFEBABE'), findsOneWidget);
      expect(find.text('版本与修饰符'), findsNothing);
    });

    testWidgets('cancelling the picker leaves the page empty', (tester) async {
      await mount(tester, JavaClassFileToolPage(loader: () async => null));
      await tester.tap(find.text('选择 .class 文件'));
      await tester.pumpAndSettle();

      expect(find.text('选择一个本地 .class 文件以查看其结构'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failing picker is reported instead of thrown', (
      tester,
    ) async {
      await mount(
        tester,
        JavaClassFileToolPage(
          loader: () async => throw const FileSystemException('权限不足'),
        ),
      );
      await tester.tap(find.text('选择 .class 文件'));
      await tester.pumpAndSettle();

      expect(find.text('无法读取文件：权限不足'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('JavaJarToolPage', () {
    testWidgets('inspects the committed JAR fixture', (tester) async {
      await mount(
        tester,
        JavaJarToolPage(loader: fixedLoader('greeting.jar')),
        size: const Size(420, 2200),
      );
      await tester.tap(find.text('选择 .jar 文件'));
      await tester.pumpAndSettle();

      expect(find.textContaining('greeting.jar'), findsOneWidget);
      expect(find.text('MANIFEST 主属性'), findsOneWidget);
      expect(find.text('fixtures.Greeting'), findsOneWidget);
      expect(find.text('Greeting fixture'), findsOneWidget);
      expect(find.text('1.2.3'), findsOneWidget);
      expect(find.text('1 个'), findsOneWidget);
      expect(find.text('fixtures'), findsOneWidget);
      expect(find.textContaining('fixtures/Greeting.class'), findsWidgets);
    });

    testWidgets('reports a non-archive file', (tester) async {
      await mount(
        tester,
        JavaJarToolPage(
          loader: () async => JavaFileBytes(
            name: 'readme.txt',
            bytes: Uint8List.fromList('plain text'.codeUnits),
          ),
        ),
      );
      await tester.tap(find.text('选择 .jar 文件'));
      await tester.pumpAndSettle();

      expect(find.textContaining('ZIP'), findsOneWidget);
      expect(find.text('MANIFEST 主属性'), findsNothing);
    });
  });

  group('layout', () {
    for (final page in <Widget>[
      const JavaDescriptorToolPage(),
      const JavaStackTraceToolPage(),
      JavaClassFileToolPage(loader: fixedLoader('greeting.class')),
      JavaJarToolPage(loader: fixedLoader('greeting.jar')),
    ]) {
      testWidgets('${page.runtimeType} renders in dark mode without overflow', (
        tester,
      ) async {
        await mount(
          tester,
          page,
          size: const Size(360, 640),
          mode: ThemeMode.dark,
        );
        expect(tester.takeException(), isNull);
        expect(
          Theme.of(tester.element(find.byType(ToolScaffold))).brightness,
          Brightness.dark,
        );
      });
    }

    testWidgets('the JAR page lays out its loaded results on a phone', (
      tester,
    ) async {
      await mount(
        tester,
        JavaJarToolPage(loader: fixedLoader('greeting.jar')),
        size: const Size(360, 640),
      );
      await tester.tap(find.text('选择 .jar 文件'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('归档结构'), findsOneWidget);
    });
  });
}
