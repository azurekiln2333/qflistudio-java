import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/mobile_jdk.dart';
import 'package:qfli_java/ohos_jdk_process.dart';
import 'package:qfli_java/spring_boot_bundle.dart';
import 'package:qfli_studio_core/services/app_paths.dart';

/// Stage 2 feasibility probe.
///
/// Answers one question: can a minimal Spring Boot application start and serve
/// HTTP on the HarmonyOS runtime, and how long does it take?
///
/// This deliberately uses [OhosJdkProcess] directly rather than
/// `JavaProgramRunner`. The product runner's `exitCode` future completes only
/// when a program ends, and a server never ends; server mode does not exist yet.
/// Driving the native child here keeps the measurement independent of Stage 3
/// product changes and keeps this gate honest.
///
/// Run on a device with:
///   flutter run -t tools/spring_boot_probe.dart -d DEVICE_ID
///
/// Success is one `QFLI_SPRING_BOOT_PROBE` JSON log with `"ok":true`.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.shrink(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => _check());
}

Future<void> _check() async {
  final checks = <String>[];
  Directory? work;
  OhosJdkProcess? server;
  try {
    // 1. A baseline JDK must exist; without it nothing here is meaningful.
    final layout = await MobileJdk.prepare();
    checks.add('jdk-prepared');

    final storage = await AppPaths.storageDirectory();
    if (storage == null) throw StateError('No writable app storage');
    work = await Directory(storage).createTemp('spring-boot-probe-');
    final root = work.path;

    // 2. Materialise the bundled Spring Boot JARs into a real directory.
    final jars = await SpringBootBundle.materialise(
      targetDirectory: p.join(root, 'jars'),
    );
    checks.add('jars-materialised');
    if (jars.isEmpty) throw StateError('Spring Boot bundle is empty');

    // 3. Compile the probe sources with the app's own JDK, exactly as the
    //    product compiles a project: javac module entry, explicit classpath.
    final sources = <String>[];
    Future<void> write(String relative, String content) async {
      final file = File(p.join(root, relative));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      if (relative.endsWith('.java')) sources.add(file.path);
    }

    await write('src/probe/ProbeApplication.java', _application);
    await write('src/probe/ProbeController.java', _controller);

    final output = Directory(p.join(root, 'classes'));
    await output.create(recursive: true);
    final classPath = [output.path, ...jars].join(
      Platform.isWindows ? ';' : ':',
    );

    final compile = await _runJdk(
      layout: layout,
      workingDirectory: root,
      arguments: [
        '-m',
        'jdk.compiler/com.sun.tools.javac.Main',
        '-encoding',
        'UTF-8',
        '-d',
        output.path,
        '-classpath',
        classPath,
        ...sources,
      ],
    );
    if (compile.code != 0) {
      throw StateError(
        'javac failed (${compile.code}):\n${compile.stderr.join('\n')}',
      );
    }
    checks.add('compiled');

    // 4. Launch the server and time the two milestones we care about.
    final launchStart = DateTime.now();
    var firstOutputMs = -1;
    var readyMs = -1;
    int? port;

    final process = await OhosJdkProcess.start(
      home: layout.home,
      libraryDirectory: layout.libraryDirectory,
      workingDirectory: root,
      arguments: [
        '-Dfile.encoding=UTF-8',
        '-Dstdout.encoding=UTF-8',
        '-Dstderr.encoding=UTF-8',
        '-classpath',
        classPath,
        'probe.ProbeApplication',
      ],
    );
    server = process;

    final ready = Completer<void>();
    final stdoutLines = <String>[];
    final stderrLines = <String>[];

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stdoutLines.add(line);
      if (firstOutputMs < 0) {
        firstOutputMs = DateTime.now().difference(launchStart).inMilliseconds;
      }
      final match = RegExp(r'PROBE_READY port=(\d+)').firstMatch(line);
      if (match != null && !ready.isCompleted) {
        port = int.parse(match.group(1)!);
        readyMs = DateTime.now().difference(launchStart).inMilliseconds;
        ready.complete();
      }
    });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add);

    // The ohos Zero interpreter has no JIT; allow a generous window so a slow
    // start is measured rather than mistaken for a hang.
    try {
      await ready.future.timeout(const Duration(minutes: 5));
    } on TimeoutException {
      throw StateError(
        'Server did not become ready within 5 minutes.\n'
        'stdout tail:\n${stdoutLines.takeLast(40).join('\n')}\n'
        'stderr tail:\n${stderrLines.takeLast(40).join('\n')}',
      );
    }
    checks.add('server-ready');

    // 5. Prove it actually serves, not just logs.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200 || !body.contains('PROBE_OK')) {
        throw StateError('HTTP ${response.statusCode}: $body');
      }
      checks.add('http-served');
    } finally {
      client.close(force: true);
    }

    debugPrint(
      'QFLI_SPRING_BOOT_PROBE ${jsonEncode({
        'ok': true,
        'abi': Platform.version,
        'jdkHome': layout.home,
        'jarCount': jars.length,
        'firstOutputMs': firstOutputMs,
        'serverReadyMs': readyMs,
        'port': port,
        'checks': checks,
      })}',
    );
  } catch (error, stack) {
    debugPrint(
      'QFLI_SPRING_BOOT_PROBE ${jsonEncode({
        'ok': false,
        'checks': checks,
        'error': error.toString(),
        'stack': stack.toString(),
      })}',
    );
  } finally {
    if (server != null) {
      try {
        await server.cancel().timeout(const Duration(seconds: 30));
      } on Exception {
        // The probe result is already reported; cleanup must not mask it.
      }
    }
    if (work != null) {
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // A leftover temp directory must not replace the measurement.
      }
    }
  }
}

/// Runs one JDK tool (javac) through the same mobile bridge and returns its
/// drained output and exit status.
Future<({int code, List<String> stdout, List<String> stderr})> _runJdk({
  required MobileJdkLayout layout,
  required String workingDirectory,
  required List<String> arguments,
}) async {
  final process = await OhosJdkProcess.start(
    home: layout.home,
    libraryDirectory: layout.libraryDirectory,
    workingDirectory: workingDirectory,
    arguments: arguments,
  );
  final stdout = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .toList();
  final stderr = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .toList();
  final code = await process.exitCode;
  return (code: code, stdout: await stdout, stderr: await stderr);
}

extension on List<String> {
  Iterable<String> takeLast(int count) =>
      length <= count ? this : sublist(length - count);
}

const String _application = r'''
package probe;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.ConfigurableApplicationContext;

@SpringBootApplication
public class ProbeApplication {
  public static void main(String[] args) throws Exception {
    SpringApplication application = new SpringApplication(ProbeApplication.class);
    application.setDefaultProperties(java.util.Map.of("server.port", "0"));
    ConfigurableApplicationContext context = application.run(args);
    String port = context.getEnvironment().getProperty("local.server.port");
    System.out.println("PROBE_READY port=" + port);
    System.out.flush();
    Thread.currentThread().join();
  }
}
''';

const String _controller = r'''
package probe;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class ProbeController {
  @GetMapping("/")
  public String hello() {
    return "PROBE_OK";
  }
}
''';
