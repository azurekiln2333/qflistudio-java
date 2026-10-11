import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/main.dart' show javaProfile;
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_studio_core/models/tutorial.dart';
import 'package:qfli_studio_core/services/code_import_service.dart';
import 'package:qfli_studio_core/services/demo_run_service.dart';
import 'package:qfli_studio_core/services/project_templates.dart';
import 'package:qfli_studio_core/services/runner_service.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';
import 'package:qfli_studio_core/terminal/shell/sandbox_shell_backend.dart';

/// Java 版 App 的接线测试。
///
/// 覆盖的正是「一个语言一个 App」的全部接缝：内核怎么知道该显示哪个模板、
/// 该跑哪个入口文件、以及运行后端有没有正确接管/交回。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory project;
  late StudioProfile? previousProfile;

  setUp(() {
    previousProfile = StudioProfile.current;
    StudioProfile.current = javaProfile;
    project = Directory.systemTemp.createTempSync('qfli_java_app_test');
  });

  tearDown(() {
    StudioProfile.current = previousProfile;
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  void write(String relative, String content) {
    final file = File(p.join(project.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  group('档位收窄', () {
    test('新建项目只放行「空项目」和 Java', () {
      expect(javaProfile.filterTemplates(ProjectTemplate.values), [
        ProjectTemplate.empty,
        ProjectTemplate.java,
      ]);
    });

    test('默认模板是 Java 而不是空项目', () {
      expect(javaProfile.defaultTemplate, ProjectTemplate.java);
    });

    test('语言筛选芯片只剩 Java', () {
      // 首页传给档位的候选本来就不含「空项目」——它不是一门语言。
      const all = ['Web', 'Python', 'Java', 'Dart'];
      expect(javaProfile.filterLanguages(all), ['Java']);
    });

    test('产品名使用 QFLIJVMX', () {
      expect(javaProfile.appTitle, 'QFLIJVMX');
      expect(javaProfile.runtimeStatus, 'available');
    });
  });

  group('入口文件识别', () {
    test('优先命中 Main.java', () {
      write('Main.java', '// .java');
      write('other.txt', 'x');
      expect(
        RunnerService.findEntry(project.path),
        p.join(project.path, 'Main.java'),
      );
    });

    test('入口表覆盖了模板自带的入口文件', () {
      // 这是「一个语言一个 App」最容易出错的地方：模板统一把源码放在 src/ 下，
      // 而入口表要是只写了根目录的文件名，新建项目后点运行就会找不到入口。
      final mainFile = ProjectTemplate.java.mainFile;
      expect(mainFile, isNotNull, reason: '模板里没有文件');
      expect(javaProfile.entryFileNames, contains(mainFile));
    });

    test('模板把源码放在 src/ 下时也能找到入口', () {
      final mainFile = ProjectTemplate.java.mainFile!;
      write(mainFile, '// 示例');
      expect(
        RunnerService.findEntry(project.path),
        p.join(project.path, mainFile),
      );
    });
  });

  group('运行后端', () {
    test('使用 JDK 编译并运行多个 Java 源文件', () async {
      write('src/Main.java', '''
package demo;
public class Main {
    public static void main(String[] args) {
        System.out.println(Greeting.message());
    }
}
''');
      write('src/Greeting.java', '''
package demo;
class Greeting {
    static String message() { return "Hello from javac"; }
}
''');
      final result = await javaProfile.runner!.run(
        projectPath: project.path,
        entryFile: p.join(project.path, 'src/Main.java'),
      );
      expect(result, isNotNull);
      final output = await result!.stdout.toList();
      expect(result.title, 'java demo.Main');
      expect(output, ['Hello from javac']);
      expect(await result.stderr.toList(), isEmpty);
      expect(await result.exitCode, 0);
    });

    test('编译错误返回 javac 诊断且程序未运行', () async {
      write('Main.java', 'public class Main { BROKEN }');
      final result = (await javaProfile.runner!.run(
        projectPath: project.path,
        entryFile: p.join(project.path, 'Main.java'),
      ))!;
      final diagnostic = (await result.stderr.toList()).join('\n');
      expect(result.title, 'javac Main.java');
      expect(diagnostic, contains('Main.java:1'));
      expect(diagnostic, contains('BROKEN'));
      expect(await result.exitCode, kProgramNotRunExitCode);
    });

    test('保留 Java 程序自己的退出码', () async {
      write('Main.java', '''
public class Main {
    public static void main(String[] args) { System.exit(7); }
}
''');
      final result = (await javaProfile.runner!.run(
        projectPath: project.path,
        entryFile: p.join(project.path, 'Main.java'),
      ))!;
      expect(await result.stdout.toList(), isEmpty);
      expect(await result.stderr.toList(), isEmpty);
      expect(await result.exitCode, 7);
    });

    test('从 input.txt 提供标准输入', () async {
      write('Main.java', '''
import java.util.Scanner;
public class Main {
    public static void main(String[] args) {
        System.out.println(new Scanner(System.in).nextInt() * 2);
    }
}
''');
      write('input.txt', '21\n');
      final result = (await javaProfile.runner!.run(
        projectPath: project.path,
        entryFile: p.join(project.path, 'Main.java'),
      ))!;
      expect(await result.stdout.toList(), ['42']);
      expect(await result.stderr.toList(), isEmpty);
      expect(await result.exitCode, 0);
    });

    test('中文源码与输出保持 UTF-8', () async {
      write('Main.java', '''
public class Main {
    public static void main(String[] args) { System.out.println("你好，Java"); }
}
''');
      final result = (await javaProfile.runner!.run(
        projectPath: project.path,
        entryFile: p.join(project.path, 'Main.java'),
      ))!;
      expect(await result.stdout.toList(), ['你好，Java']);
      expect(await result.stderr.toList(), isEmpty);
      expect(await result.exitCode, 0);
    });

    test('别的语言文件交回内核', () async {
      write('main.py', 'x');
      final result = await javaProfile.runner!.run(
        projectPath: project.path,
        entryFile: p.join(project.path, 'main.py'),
      );
      expect(result, isNull);
    });
  });

  group('运行按钮分流', () {
    test('运行按钮拿到真实 JDK 执行结果', () async {
      write('Main.java', '''
public class Main {
    public static void main(String[] args) { System.out.println("ready"); }
}
''');
      final result = await RunnerService.runProject(
        projectPath: project.path,
        entryFile: p.join(project.path, 'Main.java'),
      );
      expect(result, isNotNull);
      expect(result!.hint, isNull, reason: '后端接管了就不该走兜底提示');
      expect(result.title, 'java Main');
      expect(await result.stdout!.toList(), ['ready']);
      expect(await result.stderr!.toList(), isEmpty);
      expect(await result.exitCode, 0);
    });

    test('显式运行 Main2 后默认入口仍然运行 Main', () async {
      for (final mainClass in ['Main', 'Main2']) {
        write('$mainClass.java', '''
public class $mainClass {
    public static void main(String[] args) {
        System.out.println(Greeting.message("$mainClass"));
    }
}
''');
      }
      write('Greeting.java', '''
class Greeting {
    static String message(String name) { return "Hello " + name; }
}
''');

      for (final (explicitEntry, expectedClass) in [
        (null, 'Main'),
        ('Main2.java', 'Main2'),
        (null, 'Main'),
      ]) {
        final defaultEntry = RunnerService.findEntry(project.path);
        expect(defaultEntry, p.join(project.path, 'Main.java'));
        final result = await RunnerService.runProject(
          projectPath: project.path,
          entryFile: explicitEntry == null
              ? defaultEntry!
              : p.join(project.path, explicitEntry),
        );
        expect(result, isNotNull);
        expect(result!.hint, isNull);
        expect(result.title, 'java $expectedClass');
        expect(await result.stdout!.toList(), ['Hello $expectedClass']);
        expect(await result.stderr!.toList(), isEmpty);
        expect(await result.exitCode, 0);
      }
    });
  });

  group('直接运行与重命名导入', () {
    test('DemoRunService 用真实 JDK 运行示例并观察到真实退出', () async {
      final previousScratch = DemoRunService.scratchRootOverride;
      DemoRunService.scratchRootOverride = project.path;
      addTearDown(() => DemoRunService.scratchRootOverride = previousScratch);
      const example = ExampleCode(
        id: 'java-example-direct',
        type: 'java',
        title: '中文标题示例',
        summary: '',
        code: '''
public class Main {
    public static void main(String[] args) {
        System.out.println("direct-run-ok");
    }
}
''',
        output: 'direct-run-ok',
      );
      final session = await DemoRunService.start(example);
      addTearDown(session.dispose);
      final output = await session.result.stdout!.toList();
      final code = await session.result.exitCode!;
      expect(output, ['direct-run-ok']);
      expect(code, 0);
    });

    test('重命名导入后的示例用真实 JDK 编译运行', () async {
      const example = ExampleCode(
        id: 'java-example-rename',
        type: 'java',
        title: '重命名示例',
        summary: '',
        code: '''
public class Main {
    int value;

    Main(int value) {
        this.value = value;
    }

    public static void main(String[] args) {
        Main m = new Main(7);
        System.out.println("renamed=" + m.value);
    }
}
''',
        output: 'renamed=7',
      );
      final imported = await CodeImportService.openInEditor(
        example: example,
        fileName: 'Demo',
        location: project.path,
      );
      expect(p.basename(imported.path), 'Demo.java');
      final source = File(imported.path).readAsStringSync();
      expect(source, contains('public class Demo {'));
      expect(source, contains('Demo(int value) {'));
      expect(source, contains('Demo m = new Demo(7);'));
      final result = await javaProfile.runner!.run(
        projectPath: imported.project.path,
        entryFile: imported.path,
      );
      expect(result, isNotNull);
      final run = result!;
      expect(await run.stdout.toList(), ['renamed=7']);
      expect(await run.exitCode, 0);
    });
  });

  group('内置终端可以手动跑 JDK 命令', () {
    test('javac 与 java 经终端委托真实编译运行', () async {
      // The Java profile injects the terminal command delegate; drive it the way
      // the shared sandbox backend does.
      final delegate = javaProfile.terminalCommandDelegate;
      expect(delegate, isNotNull);

      write('src/Main.java', '''
public class Main {
    public static void main(String[] args) {
        System.out.println("terminal-jdk-ok");
    }
}
''');

      // Compile: `javac -d out src/Main.java` in the project directory.
      final compileBackend = _CapturingBackend(project.path);
      final compiled = await delegate!(
        compileBackend,
        'javac -d out ${p.join('src', 'Main.java')}',
      );
      expect(compiled, isTrue);
      expect(compileBackend.exitCode, 0);
      expect(
        File(p.join(project.path, 'out', 'Main.class')).existsSync(),
        isTrue,
      );

      // Run: `java -cp out Main`.
      final runBackend = _CapturingBackend(project.path);
      final ran = await delegate(runBackend, 'java -cp out Main');
      expect(ran, isTrue);
      expect(runBackend.lines, contains('terminal-jdk-ok'));
      expect(runBackend.exitCode, 0);
    });

    test('非 java 命令不由 Java 委托接管', () async {
      final delegate = javaProfile.terminalCommandDelegate;
      final backend = _CapturingBackend(project.path);
      expect(await delegate!(backend, 'ls'), isFalse);
    });

    test('委托收到的运行目录等于用户 cd 后的沙盒目录', () async {
      // The sandbox tracks `cd` itself; the toolchain must run in the directory
      // the prompt shows. Pin the contract at the delegate boundary: read
      // `backend.cwd` at call time and compile a cwd-relative operand with no
      // `-d`, so a stale project directory would put the class file elsewhere.
      write('nested/Main.java', '''
public class Main {
    public static void main(String[] args) {
        System.out.println("nested-cwd-ok");
    }
}
''');
      final delegate = javaProfile.terminalCommandDelegate;
      expect(delegate, isNotNull);
      final backend = _CapturingBackend(project.path);
      addTearDown(backend.shutdown);

      await backend.execute('cd nested');
      final nested = p.join(project.path, 'nested');
      expect(
        p.equals(backend.cwd, nested),
        isTrue,
        reason: 'sandbox cwd must follow cd',
      );

      // `javac Main.java` with no `-d`: the class file lands next to the source
      // only when the process ran in the nested directory.
      expect(await delegate!(backend, 'javac Main.java'), isTrue);
      expect(backend.exitCode, 0);
      expect(
        File(p.join(nested, 'Main.class')).existsSync(),
        isTrue,
        reason: 'javac must compile in the sandbox cwd, not a stale dir',
      );
      expect(
        File(p.join(project.path, 'Main.class')).existsSync(),
        isFalse,
        reason: 'a stale project cwd would produce the class file here',
      );

      final runBackend = _CapturingBackend(project.path);
      addTearDown(runBackend.shutdown);
      await runBackend.execute('cd nested');
      expect(await delegate(runBackend, 'java Main'), isTrue);
      expect(runBackend.lines, contains('nested-cwd-ok'));
      expect(runBackend.exitCode, 0);
    });

    test('工具链参数按原样透传，不重写也不重排', () async {
      // `-encoding`, `-d` and a quoted operand containing a space must reach
      // javac verbatim, and `-cp` must reach java verbatim.
      write('src/Hello World.java', '''
class Main {
    public static void main(String[] args) {
        System.out.println("passthrough-ok");
    }
}
''');
      final runner = const JavaProgramRunner();
      final spacedOut = p.join(project.path, 'out dir');

      final compile = await runner.runToolchainCommand(
        workingDirectory: project.path,
        arguments: [
          'javac',
          '-encoding',
          'UTF-8',
          '-d',
          spacedOut,
          p.join('src', 'Hello World.java'),
        ],
      );
      expect(compile, isNotNull);
      expect(
        await compile!.exitCode,
        0,
        reason: 'quoted operand/-d/-encoding must pass through unchanged',
      );
      expect(File(p.join(spacedOut, 'Main.class')).existsSync(), isTrue);

      final run = await runner.runToolchainCommand(
        workingDirectory: project.path,
        arguments: ['java', '-cp', spacedOut, 'Main'],
      );
      expect(run, isNotNull);
      expect(await run!.stdout.toList(), contains('passthrough-ok'));
      expect(await run.exitCode, 0);
      expect(run.title, 'java -cp $spacedOut Main');
    });

    test('委托不再以空格切割,引号操作数作为单个参数送达', () async {
      // `javac "src/Hello World.java"` must reach javac as ONE operand with
      // the quotes stripped. A whitespace split would hand javac the literal
      // `"src/Hello` and `World.java"` tokens and fail. Drive the real delegate
      // (not `runToolchainCommand`) so the tokenization boundary is covered.
      write('src/Hello World.java', '''
class HelloWorld {
    public static void main(String[] args) {
        System.out.println("quoted-ok");
    }
}
''');
      final delegate = javaProfile.terminalCommandDelegate;
      expect(delegate, isNotNull);
      final backend = _CapturingBackend(project.path);
      addTearDown(backend.shutdown);

      expect(
        await delegate!(backend, 'javac -d out "src/Hello World.java"'),
        isTrue,
      );
      expect(backend.exitCode, 0);
      expect(
        File(p.join(project.path, 'out', 'HelloWorld.class')).existsSync(),
        isTrue,
        reason: 'a quoted spaced operand must compile as a single file',
      );
    });

    test('复合行不被 Java 委托接管,交回沙盒给出诚实提示', () async {
      // Pipes/redirection/chaining cannot be evaluated in the sandbox. The
      // delegate must refuse them (return false) so the sandbox names the
      // unavailable construct instead of feeding `|`/`&&` to javac as operands.
      final delegate = javaProfile.terminalCommandDelegate;
      expect(delegate, isNotNull);
      final toolchain = delegate!;
      final backend = _CapturingBackend(project.path);
      addTearDown(backend.shutdown);

      for (final command in <String>[
        'javac Main.java | head -3',
        'javac Main.java && echo done',
        'ls > listing.txt',
        'java -cp lib/* Main',
        'echo \$(pwd)',
      ]) {
        expect(
          await toolchain(backend, command),
          isFalse,
          reason: 'compound line must not be claimed: $command',
        );
        expect(backend.lines, isEmpty, reason: 'nothing ran for: $command');
      }

      // A plain unknown command is also not the Java toolchain's job.
      expect(await toolchain(backend, 'git status'), isFalse);
      expect(await toolchain(backend, 'ls'), isFalse);
    });
  });
}

/// Minimal [SandboxShellBackend] used to capture delegate output in tests.
class _CapturingBackend extends SandboxShellBackend {
  _CapturingBackend(String root) : super(sandboxRoot: root);

  final lines = <String>[];
  int? exitCode;

  @override
  Future<void> runStreams({
    required String title,
    required Stream<String> stdout,
    required Stream<String> stderr,
    required Future<int> exitCode,
    Future<void> Function()? cancel,
  }) async {
    lines.addAll(await stdout.toList());
    lines.addAll(await stderr.toList());
    this.exitCode = await exitCode;
  }
}
