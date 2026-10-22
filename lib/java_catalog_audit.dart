import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/content/java_catalog_audit.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';

import 'java_runner.dart';
import 'mobile_jdk.dart';

export 'package:qfli_studio_core/content/java_catalog_audit.dart';

const _assetPaths = {
  'tutorials': 'assets/content/tutorials.json',
  'examples': 'assets/content/examples.json',
  'legacy': 'assets/tutorials/java.json',
};

/// Runs the actual package assets through the app's normal native Java runner.
/// [expectedTopicCount] is independent of asset contents: a truncated bundle
/// must fail even if all the remaining rows agree with one another.
Future<Map<String, Object?>> auditBundledJavaCatalog({
  required Directory workspace,
  required File reportFile,
  int expectedTopicCount = 280,
  AssetBundle? bundle,
  void Function(String message)? onProgress,
}) async {
  final assetBundle = bundle ?? rootBundle;
  final sources = <String, String>{};
  final identities = <String, Object?>{};
  for (final asset in _assetPaths.entries) {
    Object? lastError;
    for (final key in [
      'packages/qfli_studio_core/${asset.value}',
      asset.value,
    ]) {
      try {
        final data = await assetBundle.load(key);
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final source = utf8.decode(bytes);
        sources[asset.key] = source;
        identities[asset.key] = {
          'assetKey': key,
          'bytes': bytes.length,
          'sha256': javaCatalogBytesSha256(bytes),
        };
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (!sources.containsKey(asset.key)) {
      throw StateError('Cannot read shipped ${asset.value}: $lastError');
    }
  }
  final inventory = JavaCatalogInventory.fromSources(
    tutorialsSource: sources['tutorials']!,
    examplesSource: sources['examples']!,
    legacySource: sources['legacy']!,
    expectedTopicCount: expectedTopicCount,
  );
  await workspace.create(recursive: true);
  if (MobileJdk.isMobile) {
    await MobileJdk.prepare().timeout(const Duration(seconds: 90));
  }
  const runner = JavaProgramRunner();
  final probes = <String, Object?>{};
  for (final (name, arguments) in [
    ('javaVersion', ['java', '-version']),
    ('javacVersion', ['javac', '-version']),
    ('runtimeProperties', ['java', '-XshowSettings:properties', '-version']),
  ]) {
    final result = await runner
        .runToolchainCommand(
          workingDirectory: workspace.path,
          arguments: arguments,
        )
        .timeout(const Duration(seconds: 30));
    if (result == null) throw StateError('JDK probe was not handled: $name');
    final observation = await collectJavaAuditResult(result);
    probes[name] = observation;
    if (observation['ok'] != true) {
      throw StateError('JDK probe failed: $name: $observation');
    }
  }
  final properties = probes['runtimeProperties'] as Map<String, Object?>;
  final propertyText = '${properties['stdout']}\n${properties['stderr']}';
  final version = probes['javaVersion'] as Map<String, Object?>;
  final versionText = '${version['stdout']}\n${version['stderr']}';
  final compiler = probes['javacVersion'] as Map<String, Object?>;
  final compilerText = '${compiler['stdout']}\n${compiler['stderr']}';
  final major = RegExp(
    r'(?:openjdk|java) (?:version )?"?(\d+)',
  ).firstMatch(versionText)?.group(1);
  final compilerMajor = RegExp(
    r'javac (\d+)',
  ).firstMatch(compilerText)?.group(1);
  String? property(String name) => RegExp(
    '^\\s*${RegExp.escape(name)} = (.+)\$',
    multiLine: true,
  ).firstMatch(propertyText)?.group(1)?.trim();
  final runtimeVerified =
      major != null &&
      compilerMajor != null &&
      property('os.arch') != null &&
      property('java.vm.name') != null;
  if (!runtimeVerified) {
    throw StateError('Missing actual JDK version/ABI/VM evidence');
  }
  return runJavaCatalogInventory(
    inventory: inventory,
    runner: runner,
    workspace: workspace,
    reportFile: reportFile,
    assets: identities,
    runtimeEvidence: {
      'kind': MobileJdk.isMobile ? 'in-app-native' : 'host-app',
      'operatingSystem': Platform.operatingSystem,
      'operatingSystemVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version,
      'osArch': property('os.arch'),
      'javaVmName': property('java.vm.name'),
      'javaRuntimeVersion': property('java.runtime.version'),
      'runtimeMajorVersion': int.tryParse(major),
      'isJava17Runtime': major == '17',
      'compilerMajorVersion': int.tryParse(compilerMajor),
      'isJavac17Compiler': compilerMajor == '17',
      'isOhosDeviceEvidence': Platform.operatingSystem == 'ohos',
      'jdkHome': MobileJdk.current?.home,
      'nativeLibraryDirectory': MobileJdk.current?.libraryDirectory,
      'probes': probes,
    },
    onProgress: onProgress,
  );
}

/// Executes every distinct payload, then attaches its observation to every
/// mirrored snippet identity. Mismatching mirrors execute separately and fail
/// inventory parity, so their code can never hide behind a passing example.
Future<Map<String, Object?>> runJavaCatalogInventory({
  required JavaCatalogInventory inventory,
  required ProgramRunner runner,
  required Directory workspace,
  required File reportFile,
  Map<String, Object?> assets = const {},
  Map<String, Object?> runtimeEvidence = const {},
  Duration launchTimeout = const Duration(seconds: 90),
  Duration runTimeout = const Duration(seconds: 60),
  void Function(String message)? onProgress,
}) async {
  final executions = <Map<String, Object?>>[];
  final snippetResults = <Map<String, Object?>>[];
  final groups = inventory.executionGroups.entries.toList();
  final report = <String, Object?>{
    'schemaVersion': 2,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'ok': false,
    'deviceGatePassed': false,
    'executionComplete': false,
    'assets': assets,
    'environment': runtimeEvidence,
    'inventory': inventory.toJson(),
    'executions': executions,
    'snippetResults': snippetResults,
    'runner': runner.runtimeType.toString(),
    'launchTimeoutSeconds': launchTimeout.inSeconds,
    'runTimeoutSeconds': runTimeout.inSeconds,
  };
  var persistence = Future<void>.value();
  Future<void> persist() {
    return persistence = persistence.then((_) async {
      await reportFile.parent.create(recursive: true);
      await reportFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
    });
  }

  await workspace.create(recursive: true);
  await persist();
  var passed = 0;
  var aborted = false;
  var abortStatus = 'not_run_after_launch_timeout';
  for (final (index, group) in groups.indexed) {
    final snippet = group.value.first;
    var project = Directory(
      p.join(workspace.path, 'payload-$index-${group.key.substring(0, 12)}'),
    );
    Map<String, Object?> observation = {};
    var status = abortStatus;
    var pendingLaunch = false;
    var retainProject = false;
    final lateCleanup = <String, Object?>{};
    if (!aborted) {
      project = await workspace.createTemp('payload-$index-');
      final entry = File(p.join(project.path, 'Main.java'));
      await entry.writeAsString(snippet.code, encoding: utf8);
      await File(
        p.join(project.path, 'input.txt'),
      ).writeAsString(snippet.fixtures['stdin'] ?? '', encoding: utf8);
      try {
        final launch = runner.run(
          projectPath: project.path,
          entryFile: entry.path,
        );
        final result = await launch.timeout(
          launchTimeout,
          onTimeout: () {
            pendingLaunch = true;
            // A compiler finishing after the launch deadline must not leave its
            // subsequently started JVM running in the background.
            unawaited(
              launch
                  .then((late) async {
                    if (late != null) {
                      try {
                        await late.cancel?.call().timeout(
                          const Duration(seconds: 5),
                        );
                      } catch (error) {
                        lateCleanup['cancelError'] = error.toString();
                      }
                      final observation = await collectJavaAuditResult(
                        late,
                        timeout: const Duration(seconds: 1),
                      );
                      lateCleanup.addAll(observation);
                      if (observation['processExited'] != true) {
                        await persist();
                        return;
                      }
                    }
                    if (await project.exists()) {
                      await project.delete(recursive: true);
                    }
                    lateCleanup['projectRemoved'] = true;
                    await persist();
                  })
                  .catchError((Object error) {
                    lateCleanup['error'] = error.toString();
                  })
                  .whenComplete(() => lateCleanup['cleanupComplete'] = true),
            );
            throw TimeoutException(
              'Java runner compilation/start exceeded $launchTimeout',
            );
          },
        );
        if (result == null) {
          throw StateError('Java runner did not handle Main.java');
        }
        observation = await collectJavaAuditResult(result, timeout: runTimeout);
        if (observation['processExited'] != true) {
          // Cancellation is a request, not proof of termination. Keep the
          // snapshot while its child might still use it and stop the sweep.
          retainProject = true;
          aborted = true;
          abortStatus = 'not_run_after_unreaped_process';
        }
        final expected = normalizeJavaCatalogOutput(snippet.expectedOutput);
        status = observation['ok'] != true
            ? 'runtime_or_compile_failure'
            : observation['stdout'] != expected
            ? 'output_mismatch'
            : 'ok';
      } on TimeoutException catch (error) {
        observation = {
          'ok': false,
          'timedOut': true,
          'error': error.toString(),
        };
        status = 'launch_timeout';
        // The runner has no compiler cancellation handle before returning a
        // ProgramRunResult. Abort rather than starting overlapping compilers.
        aborted = true;
      } catch (error, stack) {
        observation = {
          'ok': false,
          'error': error.toString(),
          'stack': stack.toString(),
        };
        status = 'launch_failure';
      } finally {
        if (!pendingLaunch && !retainProject && await project.exists()) {
          await project.delete(recursive: true);
        }
      }
    }
    if (status == 'ok') passed++;
    executions.add({
      'payloadSha256': group.key,
      'sourceSha256': snippet.sourceSha256,
      'locations': group.value.map((item) => item.location).toList(),
      'status': status,
      'expected': normalizeJavaCatalogOutput(snippet.expectedOutput),
      'observation': observation,
      if (pendingLaunch || retainProject) 'retainedProjectPath': project.path,
      if (pendingLaunch) 'lateLaunchCleanup': lateCleanup,
    });
    for (final mirror in group.value) {
      snippetResults.add({
        ...mirror.toJson(),
        'executionIndex': index,
        'status': status,
        'exitCode': observation['exitCode'],
        'actual': observation['stdout'],
      });
    }
    report.addAll({
      'passedPayloads': passed,
      'failedPayloads': executions.length - passed,
      'verifiedSnippetCount': snippetResults
          .where((item) => item['status'] == 'ok')
          .length,
      'executionComplete': index == groups.length - 1 && !aborted,
    });
    await persist();
    onProgress?.call(
      '[${index + 1}/${groups.length}] ${snippet.topicId}: $status',
    );
  }
  final ok =
      inventory.ok && !aborted && passed == groups.length && groups.isNotEmpty;
  report.addAll({
    'ok': ok,
    'deviceGatePassed':
        ok &&
        Platform.operatingSystem == 'ohos' &&
        runner is JavaProgramRunner &&
        runtimeEvidence['isOhosDeviceEvidence'] == true &&
        runtimeEvidence['isJava17Runtime'] == true &&
        runtimeEvidence['isJavac17Compiler'] == true,
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
  });
  await persist();
  return report;
}

/// Collects both line streams concurrently and waits for final stream drainage.
/// The line API has already removed one terminal newline; do not trim it again.
Future<Map<String, Object?>> collectJavaAuditResult(
  ProgramRunResult result, {
  Duration timeout = const Duration(seconds: 60),
  int outputLimitBytes = 1024 * 1024,
}) async {
  final stopwatch = Stopwatch()..start();
  final output = <String>[];
  final error = <String>[];
  final tooMuch = Completer<void>();
  final outputDone = Completer<void>();
  final errorDone = Completer<void>();
  final report = <String, Object?>{'title': result.title};
  final streamErrors = <String>[];
  var outBytes = 0;
  var errorBytes = 0;
  var processExited = false;
  final exit = result.exitCode.then((code) {
    processExited = true;
    report['exitCode'] = code;
    return code;
  });
  void append(String line, List<String> target, bool isError) {
    final length = utf8.encode(line).length + 1;
    final total = isError ? errorBytes += length : outBytes += length;
    if (total <= outputLimitBytes) {
      target.add(line);
    } else if (!tooMuch.isCompleted) {
      tooMuch.complete();
    }
  }

  final stdout = result.stdout.listen(
    (line) => append(line, output, false),
    onDone: outputDone.complete,
    onError: (Object error) => streamErrors.add(error.toString()),
  );
  final stderr = result.stderr.listen(
    (line) => append(line, error, true),
    onDone: errorDone.complete,
    onError: (Object error) => streamErrors.add(error.toString()),
  );
  try {
    await Future.any<void>([
      () async {
        await exit;
        await Future.wait([outputDone.future, errorDone.future]);
      }(),
      tooMuch.future.then(
        (_) => throw StateError('Output exceeded $outputLimitBytes bytes'),
      ),
    ]).timeout(timeout);
  } catch (error) {
    report['error'] = error.toString();
    report['timedOut'] = error is TimeoutException;
    try {
      await result.cancel?.call().timeout(const Duration(seconds: 5));
    } catch (cancelError) {
      report['cancelError'] = cancelError.toString();
    }
    try {
      await exit.timeout(const Duration(seconds: 5));
    } catch (exitError) {
      report['exitWaitError'] = exitError.toString();
    }
  } finally {
    await stdout.cancel();
    await stderr.cancel();
  }
  report.addAll({
    'stdout': output.join('\n'),
    'stderr': error.join('\n'),
    'streamErrors': streamErrors,
    'processExited': processExited,
    'outputLimitExceeded': tooMuch.isCompleted,
    'elapsedMilliseconds': stopwatch.elapsedMilliseconds,
    'ok':
        report['exitCode'] == 0 &&
        !report.containsKey('error') &&
        !tooMuch.isCompleted &&
        streamErrors.isEmpty,
  });
  return report;
}
