import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/services/code_analysis.dart';
import 'package:qfli_studio_core/services/studio_profile.dart'
    show kProgramNotRunExitCode;

import 'java_runner.dart';
import 'mobile_jdk.dart';

enum JavaDiagnosticSeverity { error, warning, information }

/// Positions refer to the exact submitted UTF-16 buffer, never the saved file.
class JavaDiagnostic {
  const JavaDiagnostic({
    required this.path,
    required this.offset,
    required this.length,
    required this.line,
    required this.column,
    required this.severity,
    required this.code,
    required this.message,
  });

  final String path;
  final int offset;
  final int length;
  final int line;
  final int column;
  final JavaDiagnosticSeverity severity;
  final String code;
  final String message;
}

enum JavaAnalysisStatus {
  complete,
  unavailable,
  failed,
  cancelled,
  timedOut,
  limitExceeded,
}

class JavaAnalysisResult {
  const JavaAnalysisResult({
    required this.status,
    this.diagnostics = const [],
    this.message,
  });

  /// A source error is a successful analysis with error diagnostics.
  /// Toolchain and snapshot failures have a separate non-complete status.
  final JavaAnalysisStatus status;
  final List<JavaDiagnostic> diagnostics;
  final String? message;
}

class JavaAnalysisCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}

/// Compiles an isolated Java 17 snapshot without executing user bytecode.
///
/// A fixed, trusted JSR-199 helper reports javac's own source URI and UTF-16
/// positions. Parsing ordinary javac text would lose paths for same-name files
/// and confuse tab-expanded columns with offsets. Annotation processing is
/// disabled in both the helper build and the submitted compilation.
class JavaDiagnosticAnalyzer implements CodeAnalyzer {
  JavaDiagnosticAnalyzer({
    this.runner = const JavaProgramRunner(),
    this.timeout = const Duration(seconds: 30),
    this.maxSources = 2000,
    this.maxSourceBytes = 16 * 1024 * 1024,
    this.maxJarBytes = 128 * 1024 * 1024,
    this.maxOutputBytes = 512 * 1024,
    this.temporaryDirectory,
  });

  final JavaProgramRunner runner;
  final Duration timeout;
  final int maxSources;
  final int maxSourceBytes;
  final int maxJarBytes;
  final int maxOutputBytes;

  /// Test/sandbox override. Normal mobile analysis uses the prepared JDK tmp.
  final String? temporaryDirectory;

  final _activeChecks = <String, JavaAnalysisCancellation>{};

  @override
  Future<CodeAnalysisResult> analyze(CodeAnalysisRequest request) async {
    final project = p.normalize(p.absolute(request.projectPath));
    final projectIdentity = _pathIdentity(project);
    final cancellation = JavaAnalysisCancellation();
    _activeChecks[projectIdentity]?.cancel();
    _activeChecks[projectIdentity] = cancellation;
    try {
      final issue = await _requestIssue(request);
      if (issue != null) return CodeAnalysisResult(unavailableReason: issue);
      final result = await analyzeProject(
        projectPath: project,
        unsavedBuffers: {
          for (final document in request.documents)
            document.path: document.text,
        },
        cancellation: cancellation,
      );
      if (result.status != JavaAnalysisStatus.complete) {
        return CodeAnalysisResult(
          unavailableReason: result.message ?? 'Java 本地检查未完成。',
        );
      }
      return CodeAnalysisResult(
        // Some compiler failures (for example an unreadable JAR) have no
        // source URI. Surface the real message without inventing a file range
        // or falsely returning a clean editor result.
        unavailableReason: result.diagnostics.any((d) => d.path.isEmpty)
            ? result.diagnostics
                  .where((d) => d.path.isEmpty)
                  .map((d) => 'javac: ${d.message}')
                  .join('\n')
            : null,
        diagnostics: [
          for (final diagnostic in result.diagnostics)
            if (diagnostic.path.isNotEmpty)
              CodeDiagnostic(
                filePath: diagnostic.path,
                startOffset: diagnostic.offset,
                endOffset: diagnostic.offset + diagnostic.length,
                message: diagnostic.message,
                source: 'javac',
                code: diagnostic.code,
                severity: switch (diagnostic.severity) {
                  JavaDiagnosticSeverity.error => CodeDiagnosticSeverity.error,
                  JavaDiagnosticSeverity.warning =>
                    CodeDiagnosticSeverity.warning,
                  JavaDiagnosticSeverity.information =>
                    CodeDiagnosticSeverity.information,
                },
              ),
        ],
      );
    } finally {
      if (identical(_activeChecks[projectIdentity], cancellation)) {
        _activeChecks.remove(projectIdentity);
      }
    }
  }

  Future<String?> _requestIssue(CodeAnalysisRequest request) async {
    if (request.language.toLowerCase() != 'java' ||
        p.extension(request.activeFilePath).toLowerCase() != '.java') {
      return 'Java 检查器仅支持活动 Java 源文件（.java）。';
    }
    final root = request.projectPath;
    if (!_canonicalPath(root) ||
        request.revision < 0 ||
        request.documents.length > maxSources) {
      return 'Java 项目快照无效或超过本地检查范围。';
    }
    try {
      if (await FileSystemEntity.type(root, followLinks: false) !=
              FileSystemEntityType.directory ||
          !p.equals(await Directory(root).resolveSymbolicLinks(), root) ||
          !await _ownedSnapshotPath(root, request.activeFilePath)) {
        return '活动 Java 文件必须属于当前项目的规范物理路径。';
      }
      final seen = <String>{};
      CodeDocumentSnapshot? active;
      for (final document in request.documents) {
        if (!await _ownedSnapshotPath(root, document.path) ||
            !seen.add(_pathIdentity(document.path)) ||
            document.revision < 0 ||
            !_validUtf16(document.text)) {
          return 'Java 文档快照包含无效路径、重复别名或无效内容/版本。';
        }
        if (p.equals(document.path, request.activeFilePath)) active = document;
      }
      if (active == null || active.revision != request.revision) {
        return '活动 Java 文件缺少当前版本的编辑器快照，请重新检查。';
      }
    } on FileSystemException {
      return '无法验证 Java 文档快照的项目归属，请重新打开文件。';
    }
    return null;
  }

  Future<JavaAnalysisResult> analyzeProject({
    required String projectPath,
    Map<String, String> unsavedBuffers = const {},
    JavaAnalysisCancellation? cancellation,
  }) async {
    final control = _AnalysisControl(timeout, cancellation);
    Directory? scratch;
    try {
      control.check();
      final capturedBuffers = Map<String, String>.of(unsavedBuffers);
      final project = p.normalize(p.absolute(projectPath));
      if (!await Directory(project).exists() ||
          !p.equals(await Directory(project).resolveSymbolicLinks(), project)) {
        return const JavaAnalysisResult(
          status: JavaAnalysisStatus.failed,
          message: 'Java 项目目录不存在或不是规范物理路径。',
        );
      }
      // Validate every capture, while compiling only Java buffers below.
      final buffers = <String, String>{};
      final seen = <String>{};
      for (final entry in capturedBuffers.entries) {
        final path = p.normalize(
          p.isAbsolute(entry.key) ? entry.key : p.join(project, entry.key),
        );
        if (!await _ownedSnapshotPath(project, path) ||
            !seen.add(_pathIdentity(path)) ||
            !_validUtf16(entry.value)) {
          return const JavaAnalysisResult(
            status: JavaAnalysisStatus.failed,
            message: '未保存的文件不在当前项目内，或包含重复别名/无效文本。',
          );
        }
        if (p.extension(path).toLowerCase() == '.java') {
          buffers[path] = entry.value;
        }
      }
      final bufferTexts = {
        for (final entry in buffers.entries)
          _pathIdentity(entry.key): entry.value,
      };
      final paths = <String, String>{
        for (final path in buffers.keys) _pathIdentity(path): path,
        // Keep the saved filename's case: javac requires Main.java even when
        // Windows accepts an editor capture spelling it MAIN.JAVA.
        for (final path in JavaProgramRunner.collectProjectJavaFiles(
          Directory(project),
        ))
          _pathIdentity(path): path,
      }.values.toList()..sort();
      if (paths.length > maxSources) {
        throw const _AnalysisStopped(JavaAnalysisStatus.limitExceeded);
      }
      control.check();
      if (paths.isEmpty) {
        return const JavaAnalysisResult(
          status: JavaAnalysisStatus.unavailable,
          message: '当前项目没有可检查的 Java 源文件。',
        );
      }
      String? mobileTemporary;
      if (MobileJdk.isMobile && temporaryDirectory == null) {
        mobileTemporary = p.join((await MobileJdk.prepare()).home, 'tmp');
      }
      control.check();
      scratch = await Directory(
        temporaryDirectory ?? mobileTemporary ?? Directory.systemTemp.path,
      ).createTemp('qfli_java_check_');
      final sourcesDirectory = Directory(p.join(scratch.path, 'sources'));
      final classes = Directory(p.join(scratch.path, 'classes'));
      final helper = Directory(p.join(scratch.path, 'helper'));
      await sourcesDirectory.create();
      await classes.create();
      await helper.create();

      final sourceMap = <String, _SnapshotSource>{};
      var totalBytes = 0;
      for (final path in paths) {
        control.check();
        if (!await _ownedSnapshotPath(project, path)) {
          throw const FormatException(
            'Java source is outside physical project',
          );
        }
        final buffer = bufferTexts[_pathIdentity(path)];
        if (buffer == null) {
          // Stat before reading so an oversized saved file is never loaded.
          totalBytes += await File(path).length();
        } else {
          totalBytes += utf8.encode(buffer).length;
        }
        if (totalBytes > maxSourceBytes) {
          throw const _AnalysisStopped(JavaAnalysisStatus.limitExceeded);
        }
        final text = buffer ?? await File(path).readAsString();
        final destination = p.join(
          sourcesDirectory.path,
          p.relative(path, from: project),
        );
        await Directory(p.dirname(destination)).create(recursive: true);
        await File(destination).writeAsString(text);
        sourceMap[p.normalize(destination)] = _SnapshotSource(path, text);
      }
      final jars = [
        ...JavaProgramRunner.collectProjectJars(
          Directory(p.join(project, 'lib')),
        ),
        ...JavaProgramRunner.collectProjectJars(
          Directory(p.join(project, 'libs')),
        ),
      ];
      final snapshotJars = <String>[];
      var jarBytes = 0;
      for (final jar in jars) {
        control.check();
        if (!await _ownedSnapshotPath(project, jar)) {
          throw const FormatException('Java JAR is outside physical project');
        }
        jarBytes += await File(jar).length();
        if (jarBytes > maxJarBytes) {
          throw const _AnalysisStopped(JavaAnalysisStatus.limitExceeded);
        }
        final destination = p.join(
          scratch.path,
          'jars',
          '${snapshotJars.length}.jar',
        );
        await Directory(p.dirname(destination)).create(recursive: true);
        await File(jar).copy(destination);
        snapshotJars.add(destination);
      }

      final helperSource = File(
        p.join(helper.path, 'QfliJavacDiagnostics.java'),
      );
      await helperSource.writeAsString(_compilerHelper);
      final compiledHelper = await _run(control, scratch.path, [
        'javac',
        '-J-Xms16m',
        '-J-Xmx256m',
        '-J-XX:+UseSerialGC',
        '--release',
        '17',
        '-proc:none',
        '-encoding',
        'UTF-8',
        '-classpath',
        helper.path,
        '-d',
        helper.path,
        helperSource.path,
      ]);
      if (compiledHelper.exitCode != 0) {
        return _toolFailure(compiledHelper);
      }
      final request = File(p.join(scratch.path, 'request'));
      await request.writeAsString(
        [
          classes.path,
          snapshotJars.join(Platform.isWindows ? ';' : ':'),
          ...sourceMap.keys,
        ].map((line) => base64.encode(utf8.encode(line))).join('\n'),
      );
      final checked = await _run(control, scratch.path, [
        'java',
        '-Xms16m',
        '-Xmx256m',
        '-XX:+UseSerialGC',
        '-Dfile.encoding=UTF-8',
        '-Duser.language=en',
        '-Duser.country=US',
        '--add-modules',
        'jdk.compiler',
        '-classpath',
        helper.path,
        'QfliJavacDiagnostics',
        request.path,
      ]);
      if (checked.exitCode != 0) return _toolFailure(checked);
      final diagnostics = <JavaDiagnostic>[];
      bool? compileSucceeded;
      for (final line in checked.stdout) {
        if (line == 'QFLI_DONE\ttrue' || line == 'QFLI_DONE\tfalse') {
          compileSucceeded = line == 'QFLI_DONE\ttrue';
        } else if (line.startsWith('QFLI_DIAG\t')) {
          final diagnostic = _decodeDiagnostic(line, sourceMap);
          if (diagnostic != null) diagnostics.add(diagnostic);
        } else if (line.startsWith('QFLI_TOOL\t')) {
          return JavaAnalysisResult(
            status: JavaAnalysisStatus.failed,
            message: _decodeField(line.substring('QFLI_TOOL\t'.length)),
          );
        } else if (line.isNotEmpty) {
          throw const FormatException('Unexpected Java diagnostic protocol');
        }
      }
      if (compileSucceeded == null ||
          !compileSucceeded &&
              !diagnostics.any(
                (d) => d.severity == JavaDiagnosticSeverity.error,
              )) {
        return const JavaAnalysisResult(
          status: JavaAnalysisStatus.failed,
          message: 'Java 编译器未返回完整诊断结果。',
        );
      }
      return JavaAnalysisResult(
        status: JavaAnalysisStatus.complete,
        diagnostics: List.unmodifiable(diagnostics),
      );
    } on _AnalysisStopped catch (stopped) {
      return JavaAnalysisResult(
        status: stopped.status,
        message: switch (stopped.status) {
          JavaAnalysisStatus.cancelled => 'Java 检查已取消。',
          JavaAnalysisStatus.timedOut => 'Java 检查超时。',
          _ => 'Java 检查超过本地资源限制。',
        },
      );
    } on MissingPluginException catch (error) {
      return JavaAnalysisResult(
        status: JavaAnalysisStatus.unavailable,
        message: 'Java 工具链不可用：$error',
      );
    } on PlatformException catch (error) {
      return JavaAnalysisResult(
        status: JavaAnalysisStatus.unavailable,
        message: 'Java 工具链不可用：${error.message}',
      );
    } on IOException catch (error) {
      return JavaAnalysisResult(
        status: JavaAnalysisStatus.failed,
        message: 'Java 检查失败：$error',
      );
    } on FormatException catch (error) {
      return JavaAnalysisResult(
        status: JavaAnalysisStatus.failed,
        message: 'Java 诊断数据无效：${error.message}',
      );
    } finally {
      control.dispose();
      if (scratch != null) {
        try {
          await scratch.delete(recursive: true);
        } on FileSystemException {
          // A cleanup error must not mask source or toolchain diagnostics.
        }
      }
    }
  }

  Future<_ToolOutput> _run(
    _AnalysisControl control,
    String directory,
    List<String> arguments,
  ) async {
    control.check();
    final process = await runner.runToolchainCommand(
      workingDirectory: directory,
      arguments: arguments,
      isolatedEnvironment: true,
    );
    if (process == null) {
      return const _ToolOutput(kProgramNotRunExitCode, [], ['JDK unavailable']);
    }
    var totalBytes = 0;
    Future<List<String>> collect(Stream<String> stream) async {
      final lines = <String>[];
      await for (final line in stream) {
        totalBytes += utf8.encode(line).length + 1;
        if (totalBytes > maxOutputBytes) {
          control.stop(JavaAnalysisStatus.limitExceeded);
        } else {
          lines.add(line);
        }
      }
      return lines;
    }

    // Drain both pipes even after cancellation, then remove the snapshot only
    // after the child has actually exited (including the OHOS native child).
    final stdout = collect(process.stdout);
    final stderr = collect(process.stderr);
    // Transport failures may precede the native exit acknowledgement. Observe
    // them now, while retaining the later awaits that report the real failure.
    stdout.ignore();
    stderr.ignore();
    control.active = process.cancel;
    // A late-started compiler still owns its snapshot even when cancellation
    // fails. The control retries cleanup; only actual exit permits unwinding.
    if (control.stopped != null) control.cancelActive();
    try {
      final code = await process.exitCode;
      // Wait for both pipes even if the first one failed. The default
      // non-eager join preserves its failure while retaining snapshot ownership
      // until the other collector also settles.
      final output = await Future.wait<List<String>>([stdout, stderr]);
      control.check();
      return _ToolOutput(code, output[0], output[1]);
    } finally {
      control.active = null;
    }
  }

  JavaAnalysisResult _toolFailure(_ToolOutput output) => JavaAnalysisResult(
    status: output.exitCode == kProgramNotRunExitCode
        ? JavaAnalysisStatus.unavailable
        : JavaAnalysisStatus.failed,
    message: [...output.stdout, ...output.stderr].join('\n').trim().isEmpty
        ? 'Java 工具链失败（退出码 ${output.exitCode}）。'
        : [...output.stdout, ...output.stderr].join('\n').trim(),
  );

  JavaDiagnostic? _decodeDiagnostic(
    String line,
    Map<String, _SnapshotSource> sources,
  ) {
    final fields = line.split('\t');
    if (fields.length != 10) throw const FormatException('Diagnostic fields');
    final uri = _decodeField(fields[2]);
    // javac can emit a project-level warning without a source location. Keep
    // it as an unlocated diagnostic instead of attaching it to a random file.
    final source = uri.isEmpty
        ? null
        : sources[p.normalize(Uri.parse(uri).toFilePath())];
    if (uri.isNotEmpty && source == null) {
      throw const FormatException('Diagnostic source outside snapshot');
    }
    final position = int.parse(fields[3]);
    final startPosition = int.parse(fields[4]);
    final endPosition = int.parse(fields[5]);
    final textLength = source?.text.length ?? 0;
    final start = (startPosition < 0 ? position : startPosition).clamp(
      0,
      textLength,
    );
    final end = endPosition < start
        ? start
        : endPosition.clamp(start, textLength);
    return JavaDiagnostic(
      path: source?.path ?? '',
      offset: start,
      length: end - start,
      line: int.parse(fields[6]),
      column: int.parse(fields[7]),
      severity: switch (fields[1]) {
        'ERROR' => JavaDiagnosticSeverity.error,
        'WARNING' || 'MANDATORY_WARNING' => JavaDiagnosticSeverity.warning,
        _ => JavaDiagnosticSeverity.information,
      },
      code: _decodeField(fields[8]),
      message: _decodeField(fields[9]),
    );
  }
}

String _decodeField(String value) => utf8.decode(base64.decode(value));

bool _canonicalPath(String path) =>
    path.isNotEmpty &&
    !path.contains('\u0000') &&
    _validUtf16(path) &&
    p.isAbsolute(path) &&
    path == p.normalize(path);

String _pathIdentity(String path) =>
    Platform.isWindows ? path.toLowerCase() : path;

/// New unsaved files are valid only beneath an existing physical owned parent.
/// Resolving the nearest existing ancestor also detects links to missing files.
Future<bool> _ownedSnapshotPath(String root, String path) async {
  if (!_canonicalPath(path) || !p.isWithin(root, path)) return false;
  var current = path;
  while (true) {
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (p.equals(current, root)) return false;
      current = p.dirname(current);
      continue;
    }
    if (type == FileSystemEntityType.link ||
        (p.equals(current, path)
            ? type != FileSystemEntityType.file
            : type != FileSystemEntityType.directory)) {
      return false;
    }
    final resolved = type == FileSystemEntityType.file
        ? await File(current).resolveSymbolicLinks()
        : await Directory(current).resolveSymbolicLinks();
    return p.equals(resolved, current);
  }
}

bool _validUtf16(String text) {
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= text.length) return false;
      final low = text.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

class _SnapshotSource {
  const _SnapshotSource(this.path, this.text);
  final String path;
  final String text;
}

class _ToolOutput {
  const _ToolOutput(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final List<String> stdout;
  final List<String> stderr;
}

class _AnalysisStopped implements Exception {
  const _AnalysisStopped(this.status);
  final JavaAnalysisStatus status;
}

class _AnalysisControl {
  _AnalysisControl(Duration timeout, this.cancellation) {
    cancellation?._listeners.add(_cancel);
    if (cancellation?.isCancelled ?? false) _cancel();
    _timer = Timer(timeout, () => stop(JavaAnalysisStatus.timedOut));
  }

  final JavaAnalysisCancellation? cancellation;
  late final Timer _timer;
  Timer? _cancelRetry;
  bool _cancelling = false;
  bool _disposed = false;
  Future<void> Function()? active;
  JavaAnalysisStatus? stopped;

  void _cancel() => stop(JavaAnalysisStatus.cancelled);

  void stop(JavaAnalysisStatus status) {
    if (stopped != null) return;
    stopped = status;
    cancelActive();
  }

  void cancelActive() {
    final cancel = active;
    if (_disposed || _cancelling || cancel == null || stopped == null) return;
    _cancelling = true;
    // _run retains the actual exit/stream waits and the snapshot. A failed
    // native cleanup attempt must leave a retry owner instead of an orphan.
    unawaited(
      Future<void>.sync(cancel)
          .catchError((Object _) {
            if (!_disposed) {
              _cancelRetry = Timer(
                const Duration(milliseconds: 100),
                cancelActive,
              );
            }
          })
          .whenComplete(() => _cancelling = false),
    );
  }

  void check() {
    if (stopped case final JavaAnalysisStatus status) {
      throw _AnalysisStopped(status);
    }
  }

  void dispose() {
    _disposed = true;
    _timer.cancel();
    _cancelRetry?.cancel();
    cancellation?._listeners.remove(_cancel);
  }
}

// This source is product-owned compiler plumbing, not project code. Its runtime
// classpath contains only its own trusted classes. Project JARs are supplied to
// JavaCompiler as data; -proc:none disables loading processor implementations.
const _compilerHelper = r'''
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import javax.tools.*;

public final class QfliJavacDiagnostics {
  private static String encode(String value) {
    if (value.length() > 8192) value = value.substring(0, 8192) + "...";
    return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8));
  }
  public static void main(String[] args) throws Exception {
    PrintWriter output = new PrintWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8), true);
    JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
    if (compiler == null) {
      output.println("QFLI_TOOL\t" + encode("jdk.compiler is unavailable"));
      return;
    }
    List<String> request = new ArrayList<>();
    for (String line : Files.readAllLines(Path.of(args[0]), StandardCharsets.UTF_8)) {
      request.add(new String(Base64.getDecoder().decode(line), StandardCharsets.UTF_8));
    }
    List<Path> sources = new ArrayList<>();
    for (int i = 2; i < request.size(); i++) sources.add(Path.of(request.get(i)));
    DiagnosticListener<JavaFileObject> listener = diagnostic -> {
      String source = diagnostic.getSource() == null ? "" : diagnostic.getSource().toUri().toString();
      output.println("QFLI_DIAG\t" + diagnostic.getKind() + "\t" + encode(source)
        + "\t" + diagnostic.getPosition() + "\t" + diagnostic.getStartPosition()
        + "\t" + diagnostic.getEndPosition() + "\t" + diagnostic.getLineNumber()
        + "\t" + diagnostic.getColumnNumber() + "\t" + encode(diagnostic.getCode())
        + "\t" + encode(diagnostic.getMessage(Locale.ROOT)));
    };
    try (StandardJavaFileManager files = compiler.getStandardFileManager(listener, Locale.ROOT, StandardCharsets.UTF_8)) {
      List<String> options = List.of("--release", "17", "-proc:none", "-implicit:none", "-encoding", "UTF-8",
        "-Xlint:all", "-Xmaxerrs", "100", "-Xmaxwarns", "100", "-d", request.get(0),
        "-classpath", request.get(1), "-sourcepath", "", "-processorpath", "");
      StringWriter extra = new StringWriter();
      boolean success = compiler.getTask(extra, files, listener, options, null, files.getJavaFileObjectsFromPaths(sources)).call();
      if (extra.getBuffer().length() > 0) output.println("QFLI_TOOL\t" + encode(extra.toString()));
      output.println("QFLI_DONE\t" + success);
    }
  }
}
''';
