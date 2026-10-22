import 'dart:io';

import 'package:path/path.dart' as p;

/// JVM defaults for the app-owned mobile JDK, never the desktop/WSL JDK.
abstract final class MobileJvmLaunch {
  static String temporaryDirectory(String home) => p.join(home, 'tmp');

  static Future<void> prepareTemporaryDirectory(String home) async {
    await Directory(temporaryDirectory(home)).create(recursive: true);
  }

  static Future<List<String>> arguments({
    required String home,
    required List<String> arguments,
    bool javac = false,
  }) async {
    await prepareTemporaryDirectory(home);
    // TMPDIR alone does not initialize java.io.tmpdir on the packaged OHOS
    // JDK. Put this default first so an explicit per-command -D/-J-D retains
    // the launcher's existing last-property-wins behavior.
    return [
      '${javac ? '-J' : ''}-Djava.io.tmpdir=${temporaryDirectory(home)}',
      ...arguments,
    ];
  }
}
