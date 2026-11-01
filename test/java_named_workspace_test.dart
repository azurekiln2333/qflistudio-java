import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:qfli_java/main.dart' show javaProfile;
import 'package:qfli_studio_core/app.dart';
import 'package:qfli_studio_core/editor/editor_analysis_controller.dart';
import 'package:qfli_studio_core/editor/editor_controller.dart';
import 'package:qfli_studio_core/editor/editor_page.dart';
import 'package:qfli_studio_core/editor/editor_problems_bar.dart';
import 'package:qfli_studio_core/editor/file_explorer.dart';
import 'package:qfli_studio_core/editor/project_history.dart';
import 'package:qfli_studio_core/models/project.dart';
import 'package:qfli_studio_core/services/app_paths.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';
import 'package:qfli_studio_core/services/task_activity_service.dart';
import 'package:qfli_studio_core/store/auth_store.dart';
import 'package:qfli_studio_core/store/project_store.dart';
import 'package:qfli_studio_core/store/settings_store.dart';
import 'package:qfli_studio_core/workspace/saved_workspace.dart'
    show isMainStudioRelease;
import 'package:qfli_studio_core/workspace/workspace_store.dart';
// Inspect the editor's actual cursor state.
// ignore: depend_on_referenced_packages
import 'package:re_editor/re_editor.dart';

const _workspaceName = 'Java local workbench';
const _firstReadme = '# First Java\nfirst saved text\n';
const _secondReadme = '# Second Java\nsecond saved text\n';
const _javaSource = '''public class Main {
  public static void main(String[] args) {
    int value = 2;
  }
}
''';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late _WorkspaceFixture fixture;
  late PathProviderPlatform previousPaths;
  StudioProfile? previousProfile;

  setUpAll(() async {
    fixture = await _WorkspaceFixture.create();
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TemporaryPaths(fixture.directory.path);
    expect(await AppPaths.storageDirectory(), fixture.directory.path);
    await TaskActivityService.instance.initialize();
    await WorkspaceStore.instance.load();
  });
  setUp(() {
    previousProfile = StudioProfile.current;
    StudioProfile.current = javaProfile;
  });
  tearDown(() => StudioProfile.current = previousProfile);
  tearDownAll(() async {
    PathProviderPlatform.instance = previousPaths;
    fixture.disposeStores();
    await fixture.directory.delete(recursive: true);
  });

  testWidgets(
    'real Java Home saves and reopens a named two-root workspace without losing live buffers',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      binding.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(binding.platformDispatcher.clearLocaleTestValue);
      addTearDown(() => fixture.unmountAndDrain(tester));
      expect(StudioProfile.current, same(javaProfile));
      expect(javaProfile.productKey, StudioProductCatalog.jvmxKey);
      expect(javaProfile.offlineOnly, isTrue);
      expect(javaProfile.supportsSavedWorkspaces, isTrue);
      expect(isMainStudioRelease, isFalse);

      await fixture.mount(tester);
      expect(find.text('云端项目'), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
      await tester.tap(find.text(fixture.first.name).hitTestable());
      await _until(tester, () => fixture.editor(tester)?.files.length == 1);
      await fixture.showTree(tester);
      expect(find.byType(FileExplorer).hitTestable(), findsOneWidget);
      final workspaceAction = find.descendant(
        of: find.byType(FileExplorer),
        matching: find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '工作区项目',
        ),
      );
      await _until(
        tester,
        () => workspaceAction.hitTestable().evaluate().isNotEmpty,
      );
      await tester.tap(workspaceAction.hitTestable());
      final nameField = find.byKey(const ValueKey('workspace-name-field'));
      await _until(tester, () => nameField.hitTestable().evaluate().isNotEmpty);
      final choice = find.byKey(
        ValueKey('workspace-project-${fixture.second.id}'),
      );
      expect(tester.widget<CheckboxListTile>(choice).value, isFalse);
      await tester.tap(choice);
      await tester.enterText(nameField, _workspaceName);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await _until(
        tester,
        () =>
            WorkspaceStore.instance.workspaces.length == 1 &&
            find.byType(AlertDialog).evaluate().isEmpty &&
            fixture.root(fixture.second).evaluate().isNotEmpty,
      );
      final saved = WorkspaceStore.instance.workspaces.single;
      expect(saved.name, _workspaceName);
      expect(saved.memberPaths, [fixture.first.path, fixture.second.path]);
      expect(
        File(
          p.join(fixture.directory.path, 'workspaces', '${saved.id}.json'),
        ).existsSync(),
        isTrue,
      );
      // The tree is rebuilt before its expansion restore completes. Wait for
      // the real retained host promotion callback, not just mounted roots.
      await _until(
        tester,
        () =>
            tester.widget<EditorPage>(find.byType(EditorPage)).workspace?.id ==
            saved.id,
      );
      expect(
        tester.widget<EditorPage>(find.byType(EditorPage)).workspace?.id,
        saved.id,
      );
      await fixture.drain(tester);
      final standaloneHistory = fixture.history.readAsBytesSync();

      for (final project in [fixture.first, fixture.second]) {
        await _until(
          tester,
          () => fixture.entry(project, 'nested').evaluate().isNotEmpty,
        );
        await tester.tap(fixture.entry(project, 'nested'));
        await _until(
          tester,
          () => fixture.entry(project, 'detail.txt').evaluate().isNotEmpty,
        );
      }
      await tester.tap(fixture.entry(fixture.second, 'README.md'));
      await _until(
        tester,
        () =>
            fixture.editor(tester)?.files.length == 2 &&
            fixture.editor(tester)?.current?.projectRootPath ==
                fixture.second.path,
      );
      final editor = fixture.editor(tester)!;
      final first = editor.files.first;
      final second = editor.files.last;
      first.controller.text = 'unsaved first buffer';
      second.controller.text = 'unsaved second buffer';
      await tester.tap(find.byTooltip('收起文件树').hitTestable());
      await tester.pump(const Duration(milliseconds: 300));
      await fixture.showTree(tester);
      expect(fixture.editor(tester), same(editor));
      expect(first.dirty && second.dirty, isTrue);
      expect(first.controller.text, 'unsaved first buffer');
      expect(second.controller.text, 'unsaved second buffer');
      for (final project in [fixture.first, fixture.second]) {
        expect(fixture.entry(project, 'detail.txt'), findsOneWidget);
      }
      // View-session metadata never persists dirty source. Revert in memory
      // before destroying the app, then verify independent cursor restoration.
      first.controller.text = _firstReadme;
      second.controller.text = _secondReadme;
      first.controller.selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 3,
      );
      second.controller.selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 4,
      );
      await fixture.unmountAndDrain(tester);
      final latest = WorkspaceStore.instance.byId(saved.id)!;
      expect(latest.session.documents.map((doc) => doc.projectPath), [
        fixture.first.path,
        fixture.second.path,
      ]);
      expect(latest.session.documents.map((doc) => doc.isActive), [
        false,
        true,
      ]);
      for (final project in [fixture.first, fixture.second]) {
        expect(latest.session.expandedDirs[project.path], contains('nested'));
      }
      expect(
        fixture.history.readAsBytesSync(),
        orderedEquals(standaloneHistory),
      );
      fixture.expectReadmesUnchanged();

      await tester.runAsync(() async {
        await WorkspaceStore.instance.load(force: true);
        await fixture.recreateStores();
      });
      await fixture.mount(tester);
      await tester.tap(find.widgetWithText(Tab, '工作区'));
      await _until(
        tester,
        () => find.text(_workspaceName).hitTestable().evaluate().isNotEmpty,
      );
      await tester.tap(find.text(_workspaceName).hitTestable());
      await _until(tester, () => fixture.editor(tester)?.files.length == 2);
      final restored = fixture.editor(tester)!;
      expect(restored, isNot(same(editor)));
      expect(
        tester.widget<EditorPage>(find.byType(EditorPage)).workspace?.id,
        saved.id,
      );
      expect(restored.files.map((file) => file.ownerProjectName), [
        fixture.first.name,
        fixture.second.name,
      ]);
      expect(
        restored.files.every((file) => file.projectType == 'java'),
        isTrue,
      );
      expect(restored.files.first.controller.text, _firstReadme);
      expect(restored.current!.controller.text, _secondReadme);
      expect(restored.files.first.controller.selection.baseIndex, 1);
      expect(restored.files.first.controller.selection.baseOffset, 3);
      expect(restored.current!.controller.selection.baseIndex, 1);
      expect(restored.current!.controller.selection.baseOffset, 4);
      await fixture.showTree(tester);
      await _until(
        tester,
        () => [fixture.first, fixture.second].every(
          (project) =>
              fixture.entry(project, 'detail.txt').evaluate().isNotEmpty,
        ),
      );
      fixture.expectReadmesUnchanged();
      expect(StudioProfile.current, same(javaProfile));
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'actual Java diagnostics isolate dirty buffers by the active saved-workspace owner',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'java_ws_analysis_',
      );
      final projects = [
        for (final name in ['first', 'second'])
          Project.create(
            name: name,
            path: p.join(directory.path, name),
            type: 'java',
            language: 'Java',
          ),
      ];
      final registry = File(p.join(directory.path, 'projects.json'));
      final store = ProjectStore(storageFile: registry);
      final workspaces = WorkspaceStore(
        root: Directory(p.join(directory.path, 'workspaces')),
      );
      final editor = EditorController(project: projects.first);
      final provider = _ObservedAnalyzer(javaProfile.codeAnalyzer!);
      EditorAnalysisController? analysis;
      try {
        for (final project in projects) {
          await Directory(project.path).create();
          await File(
            p.join(project.path, 'Main.java'),
          ).writeAsString(_javaSource);
        }
        await registry.writeAsString(
          jsonEncode({
            'projects': projects.map((project) => project.toJson()).toList(),
          }),
        );
        await store.load();
        final saved = await workspaces.save(
          name: 'Java diagnostic owners',
          members: projects,
          primary: projects.first,
        );
        expect(saved.error, isNull);
        final resolved = await workspaces.resolve(saved.workspace!, store);
        expect(resolved.projects, hasLength(2));
        for (final project in resolved.projects) {
          expect(
            await editor.openPath(
              p.join(project.path, 'Main.java'),
              ownerProjectName: project.name,
              ownerProjectPath: project.path,
              ownerProjectType: project.type,
            ),
            isNull,
          );
        }
        final malformedFirst = _javaSource.replaceFirst('= 2', '= ;');
        editor.files.first.controller.text = malformedFirst;
        analysis = EditorAnalysisController(
          editor: editor,
          analyzer: provider,
          debounce: Duration.zero,
        );
        await _analysisFinished(analysis);
        expect(analysis.checked, isTrue, reason: analysis.unavailableReason);
        expect(analysis.problems, isEmpty);
        expect(provider.requests.single.projectPath, projects.last.path);
        expect(
          provider.requests.single.documents.map((document) => document.path),
          [editor.files.last.path],
        );

        final dirtySecond = _javaSource.replaceFirst('= 2', '= "wrong"');
        editor.files.last.controller.text = dirtySecond;
        await _analysisFinished(analysis);
        expect(analysis.checked, isTrue, reason: analysis.unavailableReason);
        expect(provider.requests, hasLength(2));
        expect(provider.requests.last.projectPath, projects.last.path);
        expect(provider.requests.last.documents.single.text, dirtySecond);
        final problem = analysis.problems.single;
        expect(problem.filePath, editor.files.last.path);
        expect(problem.severity, CodeDiagnosticSeverity.error);
        expect(problem.source, 'javac');
        expect(problem.startOffset, dirtySecond.indexOf('"wrong"'));
        expect(
          dirtySecond.substring(problem.startOffset, problem.endOffset),
          '"wrong"',
        );
        expect(editor.files.first.controller.text, malformedFirst);
        expect(editor.files.first.dirty && editor.files.last.dirty, isTrue);
        for (final file in editor.files) {
          expect(File(file.path).readAsBytesSync(), utf8.encode(_javaSource));
        }
        expect(StudioProfile.current, same(javaProfile));
      } finally {
        analysis?.dispose();
        // Retain the real provider futures: even a failed assertion must wait for
        // compiler cleanup before removing either owner directory.
        await Future.wait(provider.inFlight);
        editor.dispose();
        workspaces.dispose();
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

class _WorkspaceFixture {
  _WorkspaceFixture(this.directory, this.first, this.second);
  final Directory directory;
  final Project first;
  final Project second;
  late ProjectStore store;
  late AuthStore auth;
  late SettingsStore settings;

  File get registry => File(p.join(directory.path, 'projects.json'));
  File get history => File(p.join(first.path, 'history.json'));
  Finder root(Project project) =>
      find.byKey(ValueKey('workspace-root-${project.path}'));
  Finder entry(Project project, String name) =>
      find.descendant(of: root(project), matching: find.text(name));

  static Future<_WorkspaceFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'java_named_workspace_',
    );
    Project project(String name) => Project.create(
      name: name,
      path: p.join(directory.path, name),
      type: 'java',
      language: 'Java',
    );
    final fixture = _WorkspaceFixture(
      directory,
      project('First Java'),
      project('Second Java'),
    );
    for (final project in [fixture.first, fixture.second]) {
      await Directory(p.join(project.path, 'nested')).create(recursive: true);
      await File(
        p.join(project.path, 'nested', 'detail.txt'),
      ).writeAsString('nested local text');
    }
    await File(
      p.join(fixture.first.path, 'README.md'),
    ).writeAsString(_firstReadme);
    await File(
      p.join(fixture.second.path, 'README.md'),
    ).writeAsString(_secondReadme);
    await fixture.registry.writeAsString(
      jsonEncode({
        'projects': [fixture.first.toJson(), fixture.second.toJson()],
      }),
    );
    await ProjectHistory.save(
      fixture.first.path,
      cursors: const {},
      openFiles: const ['README.md'],
      activeFile: 'README.md',
    );
    await fixture._createStores();
    return fixture;
  }

  Future<void> _createStores() async {
    store = ProjectStore(storageFile: registry);
    auth = AuthStore();
    settings = SettingsStore();
    await store.load();
  }

  Future<void> recreateStores() async {
    disposeStores();
    await _createStores();
  }

  void disposeStores() {
    store.dispose();
    auth.dispose();
    settings.dispose();
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      QfliApp(store: store, auth: auth, settings: settings),
    );
    await _until(
      tester,
      () => find.text(first.name).hitTestable().evaluate().isNotEmpty,
    );
  }

  EditorController? editor(WidgetTester tester) {
    final bar = find.byType(EditorProblemsBar).hitTestable();
    return bar.evaluate().isEmpty
        ? null
        : tester.widget<EditorProblemsBar>(bar).analysis.editor;
  }

  Future<void> showTree(WidgetTester tester) async {
    await _until(
      tester,
      () =>
          find.byTooltip('打开文件树').hitTestable().evaluate().isNotEmpty ||
          find.byTooltip('收起文件树').hitTestable().evaluate().isNotEmpty,
    );
    final closed = find.byTooltip('打开文件树').hitTestable();
    if (closed.evaluate().isNotEmpty) await tester.tap(closed);
    await tester.pump(const Duration(milliseconds: 300));
    await _until(tester, () => root(first).hitTestable().evaluate().isNotEmpty);
  }

  Future<void> drain(WidgetTester tester) async {
    var done = false;
    final pending = Future.wait([
      WorkspaceStore.instance.settle(),
      ProjectHistory.load(first.path),
      store.refresh(),
    ]);
    pending.then((_) => done = true);
    await _until(tester, () => done);
    await pending;
  }

  Future<void> unmountAndDrain(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester);
  }

  void expectReadmesUnchanged() {
    expect(
      File(p.join(first.path, 'README.md')).readAsBytesSync(),
      utf8.encode(_firstReadme),
    );
    expect(
      File(p.join(second.path, 'README.md')).readAsBytesSync(),
      utf8.encode(_secondReadme),
    );
  }
}

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => p.join(path, 'tmp');
}

class _ObservedAnalyzer implements CodeAnalyzer {
  _ObservedAnalyzer(this.delegate);
  final CodeAnalyzer delegate;
  final requests = <CodeAnalysisRequest>[];
  final inFlight = <Future<CodeAnalysisResult>>[];
  @override
  Future<CodeAnalysisResult> analyze(CodeAnalysisRequest request) {
    requests.add(request);
    final result = delegate.analyze(request);
    inFlight.add(result);
    return result;
  }
}

Future<void> _analysisFinished(EditorAnalysisController analysis) async {
  if (!analysis.pending) return;
  final complete = Completer<void>();
  void listener() {
    if (!analysis.pending && !complete.isCompleted) complete.complete();
  }

  analysis.addListener(listener);
  try {
    await complete.future.timeout(const Duration(seconds: 40));
  } finally {
    analysis.removeListener(listener);
  }
}

Future<void> _until(WidgetTester tester, bool Function() complete) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (complete()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(
    complete(),
    isTrue,
    reason: 'The real Java workspace UI did not reach the expected state.',
  );
}
