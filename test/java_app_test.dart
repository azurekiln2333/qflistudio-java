import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/main.dart' show javaProfile;
import 'package:qfli_studio_core/services/project_templates.dart';
import 'package:qfli_studio_core/services/runner_service.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';

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
      expect(result.title, contains('JDK'));
      expect(await result.stdout!.toList(), ['ready']);
      expect(await result.stderr!.toList(), isEmpty);
      expect(await result.exitCode, 0);
    });
  });
}
