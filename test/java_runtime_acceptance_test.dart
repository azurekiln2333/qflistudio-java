import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../tools/java_runtime_acceptance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('embedded build artifact identifiers', () {
    test('missing or malformed identifiers remain unbound', () {
      for (final (nonce, hash) in [
        ('', ''),
        ('a' * 31, 'b' * 64),
        ('a' * 32, 'b' * 63),
        ('g' * 32, 'b' * 64),
        ('a' * 32, 'B' * 64),
        ('${'a' * 32}\n', 'b' * 64),
        ('a' * 32, '${'b' * 64}\n'),
      ]) {
        final binding = javaRuntimeBuildBinding(
          buildNonce: nonce,
          inputManifestSha256: hash,
        );
        expect(binding['hasEmbeddedBinding'], isFalse);
        expect(binding['installedPackageProven'], isFalse);
        expect(binding['requiresExternalInstallEvidence'], isTrue);
      }
    });

    test('matching identifiers do not claim actual installation', () {
      final binding = javaRuntimeBuildBinding(
        buildNonce: 'a' * 32,
        inputManifestSha256: 'b' * 64,
      );
      expect(binding['hasEmbeddedBinding'], isTrue);
      expect(binding['buildNonce'], 'a' * 32);
      expect(binding['inputManifestSha256'], 'b' * 64);
      expect(binding['installedPackageProven'], isFalse);
      expect(binding['requiresExternalInstallEvidence'], isTrue);
    });
  });

  group('native offline channel evidence', () {
    const platform = MethodChannel('qflistudio/platform');
    const account = MethodChannel('qflistudio/huawei_account');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() {
      messenger.setMockMethodCallHandler(platform, null);
      messenger.setMockMethodCallHandler(account, null);
    });

    for (final method in ['openAgreement', 'openUrl']) {
      test('$method requires the actual OFFLINE_ONLY error envelope', () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(platform, (call) async {
          calls.add(call);
          throw PlatformException(code: 'OFFLINE_ONLY', message: 'Offline');
        });
        final result = await probeJavaNativeOfflineUrl(method);
        expect(result['ok'], isTrue);
        expect(result['status'], 'offline-only');
        expect(result['code'], 'OFFLINE_ONLY');
        expect(result['channel'], platform.name);
        expect(result['method'], method);
        expect(calls, hasLength(1));
        expect(calls.single.method, method);
        expect(calls.single.arguments, {
          'url': '',
          'title': 'Offline acceptance invalid input',
        });
      });
    }

    test('a successful reply never counts as native offline refusal', () async {
      for (final reply in [
        null,
        {'code': 'OFFLINE_ONLY'},
      ]) {
        messenger.setMockMethodCallHandler(platform, (call) async => reply);
        final result = await probeJavaNativeOfflineUrl('openUrl');
        expect(result['ok'], isFalse);
        expect(result['status'], 'unexpected-success');
      }
    });

    test('a missing native method remains a failed probe', () async {
      messenger.setMockMethodCallHandler(platform, (call) async {
        throw MissingPluginException('No native implementation');
      });
      final result = await probeJavaNativeOfflineUrl('openAgreement');
      expect(result['ok'], isFalse);
      expect(result['status'], 'missing-method');
      expect(result['error'], contains('No implementation found'));
    });

    test(
      'invalid URL or other platform errors cannot fabricate a pass',
      () async {
        messenger.setMockMethodCallHandler(platform, (call) async {
          throw PlatformException(code: 'INVALID_URL', message: 'Empty URL');
        });
        final result = await probeJavaNativeOfflineUrl('openUrl');
        expect(result['ok'], isFalse);
        expect(result['status'], 'platform-error');
        expect(result['code'], 'INVALID_URL');
      },
    );

    test('the host test probe cannot dispatch account login', () {
      var calls = 0;
      messenger.setMockMethodCallHandler(account, (call) async {
        calls++;
        throw StateError('Host login must not be invoked');
      });
      expect(() => probeJavaNativeOfflineUrl('login'), throwsArgumentError);
      expect(calls, 0);
    });

    test(
      'a host cannot satisfy the device gate or invoke native login even with a binding',
      () async {
        final calls = <MethodCall>[];
        for (final channel in [platform, account]) {
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            throw StateError('Host native probes must not dispatch');
          });
        }
        final result = await runJavaNativeOfflineProbe(
          sourceBoundNativeHap: true,
          nativeSourceSha256: 'a' * 64,
        );
        expect(result['ok'], isFalse);
        expect(result['unavailableReason'], contains('Actual OHOS'));
        expect((result['methods']! as Map).values, hasLength(3));
        for (final method in (result['methods']! as Map).values) {
          expect((method as Map)['ok'], isFalse);
          expect(method['status'], 'not-run');
        }
        expect(calls, isEmpty);
      },
      skip: Platform.operatingSystem == 'ohos',
    );
  });

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
        final studioDebugger =
            report['studioDebugger']! as Map<String, Object?>;
        final nativeOffline = report['nativeOffline']! as Map<String, Object?>;
        final runtime = report['runtime']! as Map<String, Object?>;
        expect(diagnostics['ok'], isTrue, reason: jsonEncode(diagnostics));
        expect(debugger['ok'], isTrue, reason: jsonEncode(debugger));
        expect(
          studioDebugger['ok'],
          isTrue,
          reason: jsonEncode(studioDebugger),
        );
        expect(studioDebugger['cleanupConfirmed'], isTrue);
        expect((diagnostics['checks']! as Map).values, everyElement(true));
        expect((debugger['checks']! as Map).values, everyElement(true));
        expect((studioDebugger['checks']! as Map).values, everyElement(true));
        expect(
          report['studioDebuggerDeviceGatePassed'],
          Platform.operatingSystem == 'ohos' && runtime['ok'] == true,
        );
        expect(
          report['nativeOfflineDeviceGatePassed'],
          Platform.operatingSystem == 'ohos' && nativeOffline['ok'] == true,
        );
        expect((nativeOffline['methods']! as Map), hasLength(3));
        if (Platform.operatingSystem != 'ohos') {
          expect(nativeOffline['ok'], isFalse);
          expect(nativeOffline['unavailableReason'], contains('Actual OHOS'));
        }
        expect(runtime['javaVersion'], isNotEmpty);
        expect(runtime['osArch'], isNotEmpty);
        expect(
          report['ok'],
          runtime['ok'] == true && nativeOffline['ok'] == true,
        );
        expect(
          report['deviceGatePassed'],
          Platform.operatingSystem == 'ohos' &&
              report['ok'] == true &&
              (report['buildBinding']! as Map)['hasEmbeddedBinding'] == true &&
              report['nativeOfflineDeviceGatePassed'] == true,
        );
        expect(report['expectedBundleName'], 'com.azurekiln.qfli.java');
        expect(
          (report['buildBinding']! as Map)['installedPackageProven'],
          isFalse,
        );
        expect(report['cleanupConfirmed'], isTrue);
        expect(
          Directory(report['workDirectory']! as String).existsSync(),
          isFalse,
        );
        expect(sentinel.readAsStringSync(), 'preserve');
        expect(
          stages,
          containsAllInOrder([
            'native-offline',
            'runtime',
            'diagnostics',
            'debugger',
            'studio-debugger',
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
