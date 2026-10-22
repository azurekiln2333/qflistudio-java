import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tools/java_runtime_acceptance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'durable acceptance uses real diagnostics and debugger without claiming a host device pass',
    () async {
      final storage = Directory.systemTemp.createTempSync('java_acceptance_');
      final sentinel = File(p.join(storage.path, 'existing-user-file.txt'));
      sentinel.writeAsStringSync('preserve');
      try {
        final stages = <String>[];
        final report = await runJavaRuntimeAcceptance(
          storage: storage,
          onProgress: stages.add,
        );
        final diagnostics = report['diagnostics']! as Map<String, Object?>;
        final debugger = report['debugger']! as Map<String, Object?>;
        final runtime = report['runtime']! as Map<String, Object?>;
        expect(diagnostics['ok'], isTrue, reason: jsonEncode(diagnostics));
        expect(debugger['ok'], isTrue, reason: jsonEncode(debugger));
        expect((diagnostics['checks']! as Map).values, everyElement(true));
        expect((debugger['checks']! as Map).values, everyElement(true));
        expect(runtime['javaVersion'], isNotEmpty);
        expect(runtime['osArch'], isNotEmpty);
        expect(report['ok'], runtime['ok']);
        expect(
          report['deviceGatePassed'],
          Platform.operatingSystem == 'ohos' && report['ok'] == true,
        );
        expect(report['expectedBundleName'], 'com.azurekiln.qfli.java');
        expect(report['cleanupConfirmed'], isTrue);
        expect(
          Directory(report['workDirectory']! as String).existsSync(),
          isFalse,
        );
        expect(sentinel.readAsStringSync(), 'preserve');
        expect(
          stages,
          containsAllInOrder([
            'runtime',
            'diagnostics',
            'debugger',
            'complete',
          ]),
        );
        final file = File(
          p.join(storage.path, javaRuntimeAcceptanceReportName),
        );
        expect(jsonDecode(file.readAsStringSync()), report);
        expect(storage.listSync().whereType<File>(), hasLength(2));
        final cases = diagnostics['cases']! as Map;
        expect(cases.keys, containsAll(['typeErrors', 'syntaxError', 'clean']));
        final buffers = (cases['typeErrors'] as Map)['buffers'] as Map;
        final main =
            (buffers.entries
                        .singleWhere(
                          (e) => p.basename(e.key as String) == 'Main.java',
                        )
                        .value
                    as Map)['text']
                as String;
        expect(main, contains('\r\n'));
        expect(main, contains('😀中文'));
        final errors = (cases['typeErrors'] as Map)['diagnostics'] as List;
        final error =
            errors.singleWhere(
                  (d) =>
                      p.basename((d as Map)['path'] as String) == 'Main.java',
                )
                as Map;
        expect(error['offset'], main.indexOf('"wrong"'));
        expect(
          main.substring(
            error['offset'] as int,
            (error['offset'] as int) + (error['length'] as int),
          ),
          '"wrong"',
        );
      } finally {
        storage.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
