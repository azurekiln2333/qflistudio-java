import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'mobile_jvm_launch.dart';
import 'ohos_jdk_process.dart';

class MobileJdkLayout {
  const MobileJdkLayout({
    required this.home,
    required this.java,
    required this.javac,
    required this.libraryDirectory,
  });

  final String home;
  final String java;
  final String javac;
  final String libraryDirectory;

  String get temporaryDirectory => MobileJvmLaunch.temporaryDirectory(home);

  factory MobileJdkLayout.fromMap(Map<Object?, Object?> data) {
    String path(String key) {
      final value = data[key];
      if (value is! String || value.isEmpty || !p.isAbsolute(value)) {
        throw FormatException('Invalid JDK path: $key');
      }
      return value;
    }

    return MobileJdkLayout(
      home: path('home'),
      java: path('java'),
      javac: path('javac'),
      libraryDirectory: path('libraryDirectory'),
    );
  }

  Map<String, String> get environment => {
    'JAVA_HOME': home,
    'QFLI_JAVA_HOME': home,
    if (Platform.operatingSystem == 'ohos')
      'QFLI_NATIVE_LIBRARY_DIR': libraryDirectory,
    'TMPDIR': temporaryDirectory,
    'LD_LIBRARY_PATH': [
      libraryDirectory,
      p.join(home, 'lib'),
      p.join(home, 'lib', 'server'),
      if (Platform.environment['LD_LIBRARY_PATH'] case final String existing)
        existing,
    ].join(':'),
  };
}

abstract final class MobileJdk {
  static const _channel = MethodChannel('qfli_jvmx/jdk');
  static MobileJdkLayout? current;
  static Future<MobileJdkLayout>? _preparing;

  static bool get isMobile =>
      Platform.isAndroid || Platform.operatingSystem == 'ohos';

  static Future<MobileJdkLayout> prepare() {
    if (current case final MobileJdkLayout layout) {
      return MobileJvmLaunch.prepareTemporaryDirectory(
        layout.home,
      ).then((_) => layout);
    }
    return _preparing ??= _prepare().whenComplete(() => _preparing = null);
  }

  static Future<MobileJdkLayout> _prepare() async {
    final data = await _channel.invokeMapMethod<Object?, Object?>('prepare');
    if (data == null) throw const FormatException('JDK layout is missing');
    final layout = MobileJdkLayout.fromMap(data);
    if (Platform.operatingSystem == 'ohos') {
      for (final arguments in [
        ['-version'],
        ['-m', 'jdk.compiler/com.sun.tools.javac.Main', '-version'],
      ]) {
        final process = await OhosJdkProcess.start(
          home: layout.home,
          libraryDirectory: layout.libraryDirectory,
          arguments: arguments,
          workingDirectory: layout.home,
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final diagnostic = process.stderr.transform(utf8.decoder).join();
        try {
          final code = await process.exitCode.timeout(
            const Duration(seconds: 30),
          );
          final text = await output;
          final error = await diagnostic;
          if (code != 0) {
            throw ProcessException('JVM', arguments, error.trim(), code);
          }
          _checkVersion('$text\n$error', compiler: arguments.first == '-m');
        } catch (_) {
          await process.cancel();
          await output;
          await diagnostic;
          rethrow;
        }
      }
      current = layout;
      return layout;
    }
    for (final executable in [layout.java, layout.javac]) {
      final process = await Process.start(
        executable,
        await MobileJvmLaunch.arguments(
          home: layout.home,
          arguments: ['-version'],
          javac: executable == layout.javac,
        ),
        environment: layout.environment,
        runInShell: false,
      );
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      try {
        final code = await process.exitCode.timeout(
          const Duration(seconds: 30),
        );
        final output = await stdout;
        final diagnostic = await stderr;
        if (code != 0) {
          throw ProcessException(
            executable,
            ['-version'],
            diagnostic.trim().isEmpty ? 'JDK probe failed' : diagnostic.trim(),
            code,
          );
        }
        _checkVersion(
          '$output\n$diagnostic',
          compiler: executable == layout.javac,
        );
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await stdout;
        await stderr;
        rethrow;
      }
    }
    current = layout;
    return layout;
  }

  static void _checkVersion(String output, {required bool compiler}) {
    final pattern = compiler
        ? r'^javac \d+'
        : r'^(?:openjdk|java) (?:version )?"?\d+';
    if (!RegExp(pattern, multiLine: true).hasMatch(output)) {
      throw FormatException(
        'JDK version probe returned unexpected output: ${output.trim()}',
      );
    }
  }
}
