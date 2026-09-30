import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/ohos_jdk_process.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qfli_jvmx/jdk');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('qfli_jvm_transport_');
    Directory(p.join(home.path, 'tmp')).createSync();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test(
    'drains final output and preserves UTF-8 across partial writes',
    () async {
      late File output;
      late File error;
      int polls = 0;
      final bytes = utf8.encode('\u4f60\u597d');
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'start') {
          expect(args['args'], ['java', '-version']);
          expect(args['input'], '/dev/null');
          output = File(args['output'] as String)..writeAsBytesSync([]);
          error = File(args['error'] as String)..writeAsBytesSync([]);
          return 100;
        }
        if (++polls == 1) {
          output.writeAsBytesSync(bytes.take(1).toList());
          return null;
        }
        output.writeAsBytesSync(bytes.skip(1).toList(), mode: FileMode.append);
        error.writeAsStringSync('diagnostic\n');
        return 7;
      });
      final process = await OhosJdkProcess.start(
        home: home.path,
        libraryDirectory: home.path,
        arguments: ['-version'],
        workingDirectory: home.path,
      );
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      expect(await process.exitCode, 7);
      expect(await stdout, '\u4f60\u597d');
      expect(await stderr, 'diagnostic\n');
    },
  );

  test('cancel waits for termination while output remains readable', () async {
    bool canceled = false;
    final input = File(p.join(home.path, 'input.txt'))
      ..writeAsStringSync('21\n');
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      switch (call.method) {
        case 'start':
          expect(args['input'], input.path);
          File(args['output'] as String).writeAsStringSync('running\n');
          File(args['error'] as String).writeAsStringSync('');
          return 101;
        case 'cancel':
          canceled = true;
          return null;
        case 'poll':
          return canceled ? 137 : null;
        default:
          throw StateError(call.method);
      }
    });
    final process = await OhosJdkProcess.start(
      home: home.path,
      libraryDirectory: home.path,
      arguments: ['Main'],
      workingDirectory: home.path,
      inputFile: input.path,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    await process.cancel();
    expect(await process.exitCode, 137);
    expect(await stdout, 'running\n');
    expect(await stderr, isEmpty);
  });
}
