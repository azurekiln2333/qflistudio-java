import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_catalog_audit.dart';
import 'package:qfli_studio_core/services/app_paths.dart';
import 'package:qfli_studio_core/tools/offline_tools.dart';

/// Temporary app entry for exhaustive packaged-content execution.
/// Build/install/run this entry on the target, pull the reported JSON, then
/// rebuild/install lib/main.dart. Desktop invocation is never OHOS evidence.
/// Override QFLI_JAVA_EXPECTED_TOPICS only when intentionally auditing an older
/// curriculum; the release gate uses 280 and must not infer it from the assets.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.shrink(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => _audit());
}

Future<void> _audit() async {
  File? reportFile;
  try {
    final storage = await AppPaths.storageDirectory();
    if (storage == null) throw StateError('No writable app storage');
    reportFile = File(p.join(storage, 'qfli-java-catalog-audit.json'));
    final workspace = Directory(p.join(storage, 'qfli-java-catalog-projects'));
    final report = await auditBundledJavaCatalog(
      workspace: workspace,
      reportFile: reportFile,
      expectedTopicCount: const int.fromEnvironment(
        'QFLI_JAVA_EXPECTED_TOPICS',
        defaultValue: 280,
      ),
      onProgress: (message) => debugPrint('QFLI_JAVA_CATALOG_ITEM $message'),
    );
    debugPrint(
      'QFLI_JAVA_CATALOG_AUDIT ${jsonEncode({'ok': report['ok'], 'deviceGatePassed': report['deviceGatePassed'], 'operatingSystem': Platform.operatingSystem, 'passedPayloads': report['passedPayloads'], 'failedPayloads': report['failedPayloads'], 'verifiedSnippetCount': report['verifiedSnippetCount'], 'report': reportFile.path, 'reportSha256': OfflineDigest.sha256(await reportFile.readAsString())})}',
    );
  } catch (error, stack) {
    final failure = {
      'ok': false,
      'deviceGatePassed': false,
      'operatingSystem': Platform.operatingSystem,
      'error': error.toString(),
      'stack': stack.toString(),
      'report': reportFile?.path,
    };
    if (reportFile != null) {
      await reportFile.parent.create(recursive: true);
      await reportFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(failure),
        flush: true,
      );
    }
    debugPrint('QFLI_JAVA_CATALOG_AUDIT ${jsonEncode(failure)}');
  }
}
