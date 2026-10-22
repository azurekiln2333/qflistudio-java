import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'java_runner.dart';
import 'mobile_jdk.dart';

class JavaBreakpoint {
  const JavaBreakpoint({
    required this.id,
    required this.className,
    required this.line,
  });
  final String id;

  /// Binary class name, including package and `$` for nested classes.
  final String className;
  final int line;
}

enum JavaDebugEventKind {
  attached,
  breakpoint,
  paused,
  resumed,
  output,
  error,
  terminated,
}

class JavaDebugLocation {
  const JavaDebugLocation({
    required this.className,
    required this.sourceName,
    required this.line,
  });
  final String className;
  final String sourceName;
  final int line;
}

class JavaDebugVariable {
  const JavaDebugVariable({
    required this.name,
    required this.type,
    required this.value,
  });
  final String name;
  final String type;

  /// Primitive/String value or reference identity, never a user toString call.
  final String value;
}

class JavaDebugFrame {
  const JavaDebugFrame({
    required this.index,
    required this.method,
    required this.location,
  });
  final int index;
  final String method;
  final JavaDebugLocation location;
}

class JavaDebugVmInfo {
  const JavaDebugVmInfo({
    required this.name,
    required this.version,
    required this.description,
    required this.canPopFrames,
    required this.canForceEarlyReturn,
  });
  final String name;
  final String version;
  final String description;
  final bool canPopFrames;
  final bool canForceEarlyReturn;
}

class JavaDebugEvent {
  const JavaDebugEvent(
    this.kind, {
    this.message = '',
    this.location,
    this.breakpointId,
    this.verified = false,
    this.isErrorOutput = false,
    this.exitCode,
  });
  final JavaDebugEventKind kind;
  final String message;
  final JavaDebugLocation? location;
  final String? breakpointId;
  final bool verified;
  final bool isErrorOutput;
  final int? exitCode;
}

/// Actual local JDI/JDWP backend. No UI availability claim is made here.
class JavaDebugger {
  const JavaDebugger({
    this.runner = const JavaProgramRunner(),
    this.startupTimeout = const Duration(seconds: 45),
    this.commandTimeout = const Duration(seconds: 10),
    this.sessionTimeout = const Duration(minutes: 20),
    this.maxOutputBytes = 1024 * 1024,
    this.temporaryDirectory,
  });
  final JavaProgramRunner runner;
  final Duration startupTimeout;
  final Duration commandTimeout;
  final Duration sessionTimeout;
  final int maxOutputBytes;
  final String? temporaryDirectory;

  /// Returns immediately so Stop is available during compilation and attach.
  JavaDebugSession launch({
    required String projectPath,
    required String entryFile,
    Map<String, String> unsavedBuffers = const {},
    List<JavaBreakpoint> breakpoints = const [],
    List<String> arguments = const [],
  }) => JavaDebugSession._(
    this,
    projectPath,
    entryFile,
    Map.of(unsavedBuffers),
    List.of(breakpoints),
    List.of(arguments),
  );
}

class JavaDebugSession {
  JavaDebugSession._(
    this._debugger,
    this._projectPath,
    this._entryFile,
    this._buffers,
    this._breakpoints,
    this._arguments,
  ) {
    _ready.future.ignore();
    _port.future.ignore();
    _initializing = Future<void>.microtask(_initialize);
  }

  final JavaDebugger _debugger;
  final String _projectPath;
  final String _entryFile;
  final Map<String, String> _buffers;
  final List<JavaBreakpoint> _breakpoints;
  final List<String> _arguments;
  final _events = StreamController<JavaDebugEvent>.broadcast();
  final _ready = Completer<void>();
  final _port = Completer<int>();
  final _done = Completer<int>();
  final _processes = <JavaToolchainProcess>{};
  final _pending = <int, _DebugReply>{};
  late final Future<void> _initializing;
  Directory? _directory;
  JavaToolchainProcess? _target;
  JavaToolchainProcess? _helper;
  Future<int>? _targetDone;
  Future<int>? _helperDone;
  Future<void>? _stoppingFuture;
  Timer? _lifetime;
  bool _stopping = false;
  bool _helperDisconnected = false;
  int _bytes = 0;
  int _sequence = 0;
  int _targetExit = -1;
  JavaDebugVmInfo? _vmInfo;

  Stream<JavaDebugEvent> get events => _events.stream;
  Future<void> get ready => _ready.future;
  Future<int> get done => _done.future;
  JavaDebugVmInfo? get vmInfo => _vmInfo;

  void _check() {
    if (_stopping) throw StateError('Debug session has stopped');
  }

  void _emit(JavaDebugEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _error(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    if (!_port.isCompleted) _port.completeError(error);
    _emit(JavaDebugEvent(JavaDebugEventKind.error, message: '$error'));
  }

  Stream<List<int>> _bounded(Stream<List<int>> stream) async* {
    await for (final bytes in stream) {
      final remaining = (_debugger.maxOutputBytes - _bytes).clamp(
        0,
        bytes.length,
      );
      _bytes += bytes.length;
      if (remaining > 0) yield bytes.sublist(0, remaining);
      if (_bytes > _debugger.maxOutputBytes && !_stopping) {
        _error(StateError('Java debug output exceeded the byte limit'));
        unawaited(stop());
      }
    }
  }

  Future<JavaToolchainProcess> _start(
    String directory,
    List<String> arguments, {
    String? inputFile,
  }) async {
    _check();
    final process = await _debugger.runner.startToolchainProcess(
      workingDirectory: directory,
      arguments: arguments,
      isolatedEnvironment: true,
      inputFile: inputFile,
    );
    if (process == null) throw StateError('Java toolchain is unavailable');
    _processes.add(process);
    if (_stopping) {
      // A Stop may arrive while the native bridge is starting this child.
      final stdout = process.stdout.drain<void>();
      final stderr = process.stderr.drain<void>();
      await process.cancel();
      await Future.wait([stdout, stderr]);
      _processes.remove(process);
      _check();
    }
    return process;
  }

  Future<void> _compile(String directory, List<String> arguments) async {
    final process = await _start(directory, arguments);
    final output = _bounded(
      process.stdout,
    ).transform(const Utf8Decoder(allowMalformed: true)).join();
    final error = _bounded(
      process.stderr,
    ).transform(const Utf8Decoder(allowMalformed: true)).join();
    final timer = Timer(_debugger.startupTimeout, () {
      _error(TimeoutException('Java debug compilation timed out'));
      unawaited(stop());
    });
    try {
      final code = await process.exitCode;
      final text = '${await output}${await error}';
      _check();
      if (code != 0) throw StateError('javac failed ($code): $text');
    } finally {
      timer.cancel();
      _processes.remove(process);
    }
  }

  Future<void> _initialize() async {
    try {
      _check();
      final project = p.normalize(p.absolute(_projectPath));
      final entry = p.normalize(
        p.isAbsolute(_entryFile) ? _entryFile : p.join(project, _entryFile),
      );
      if (!p.isWithin(project, entry) ||
          p.extension(entry).toLowerCase() != '.java') {
        throw ArgumentError('Java entry must belong to the project');
      }
      final buffers = <String, String>{};
      for (final buffer in _buffers.entries) {
        final path = p.normalize(
          p.isAbsolute(buffer.key) ? buffer.key : p.join(project, buffer.key),
        );
        if (!p.isWithin(project, path)) {
          throw ArgumentError('Unsaved file outside project');
        }
        if (p.extension(path).toLowerCase() == '.java') {
          buffers[path] = buffer.value;
        }
      }
      final sources = {
        ...JavaProgramRunner.collectProjectJavaFiles(Directory(project)),
        ...buffers.keys,
      }.toList()..sort();
      if (!sources.contains(entry) || sources.length > 2000) {
        throw ArgumentError('Missing entry or too many Java sources');
      }
      for (final breakpoint in _breakpoints) {
        _validateBreakpoint(breakpoint);
      }
      if (_breakpoints.length > 200) {
        throw ArgumentError('Too many breakpoints');
      }
      final mobile = MobileJdk.isMobile
          ? p.join((await MobileJdk.prepare()).home, 'tmp')
          : null;
      _check();
      _directory = await Directory(
        _debugger.temporaryDirectory ?? mobile ?? Directory.systemTemp.path,
      ).createTemp('qfli_java_debug_');
      final root = _directory!.path;
      final classes = Directory(p.join(root, 'classes'));
      final helper = Directory(p.join(root, 'helper'));
      await classes.create();
      await helper.create();
      final copied = <String>[];
      var sourceBytes = 0;
      String? entryText;
      for (final path in sources) {
        _check();
        final buffer = buffers[path];
        sourceBytes += buffer == null
            ? await File(path).length()
            : utf8.encode(buffer).length;
        if (sourceBytes > 16 * 1024 * 1024) {
          throw StateError('Java source snapshot exceeded 16 MiB');
        }
        final text = buffer ?? await File(path).readAsString();
        if (p.equals(path, entry)) entryText = text;
        final destination = File(
          p.join(root, 'sources', p.relative(path, from: project)),
        );
        await destination.parent.create(recursive: true);
        await destination.writeAsString(text);
        copied.add(destination.path);
      }
      final jars = <String>[];
      var jarBytes = 0;
      for (final jar in [
        ...JavaProgramRunner.collectProjectJars(
          Directory(p.join(project, 'lib')),
        ),
        ...JavaProgramRunner.collectProjectJars(
          Directory(p.join(project, 'libs')),
        ),
      ]) {
        _check();
        jarBytes += await File(jar).length();
        if (jarBytes > 128 * 1024 * 1024) {
          throw StateError('Java JAR snapshot exceeded 128 MiB');
        }
        final destination = p.join(root, 'jars', '${jars.length}.jar');
        await Directory(p.dirname(destination)).create(recursive: true);
        await File(jar).copy(destination);
        jars.add(destination);
      }
      final classpath = [
        classes.path,
        ...jars,
      ].join(Platform.isWindows ? ';' : ':');
      // An argsfile avoids the Windows command line limit for real projects.
      final argsFile = File(p.join(root, 'sources.args'));
      await argsFile.writeAsString(
        copied
            .map(
              (s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"',
            )
            .join('\n'),
      );
      await _compile(root, [
        'javac',
        '-J-Xms16m',
        '-J-Xmx256m',
        '-J-XX:+UseSerialGC',
        '--release',
        '17',
        '-g',
        '-proc:none',
        '-encoding',
        'UTF-8',
        '-classpath',
        classpath,
        '-d',
        classes.path,
        '@${argsFile.path}',
      ]);
      final helperSource = File(p.join(helper.path, 'QfliJavaDebugger.java'));
      await helperSource.writeAsString(_jdiHelper);
      await _compile(root, [
        'javac',
        '-J-Xms16m',
        '-J-Xmx256m',
        '-J-XX:+UseSerialGC',
        '--release',
        '17',
        '--add-modules',
        'jdk.jdi',
        '-proc:none',
        '-encoding',
        'UTF-8',
        '-classpath',
        helper.path,
        '-d',
        helper.path,
        helperSource.path,
      ]);
      await File(p.join(root, 'breakpoints')).writeAsString(
        _breakpoints
            .map((b) => '${_encode(b.id)}\t${_encode(b.className)}\t${b.line}')
            .join('\n'),
      );
      _helper = await _start(root, [
        'java',
        '-Xms16m',
        '-Xmx256m',
        '-XX:+UseSerialGC',
        '--add-modules',
        'jdk.jdi',
        '-classpath',
        helper.path,
        'QfliJavaDebugger',
        root,
      ]);
      _helperDone = _watch(_helper!, helper: true);
      _helperDone!.then(
        (code) {
          if (!_stopping && !_helperDisconnected) {
            _error(StateError('JDI helper exited ($code)'));
            unawaited(stop());
          }
        },
        onError: (Object e) {
          if (!_stopping) {
            _error(e);
            unawaited(stop());
          }
        },
      );
      final port = await _port.future.timeout(_debugger.startupTimeout);
      _check();
      final withoutComments = entryText!.replaceAll(
        RegExp(r'/\*[\s\S]*?\*/|//[^\r\n]*'),
        '',
      );
      final package = RegExp(
        r'^\s*package\s+([\w$\u0080-\uFFFF]+(?:\.[\w$\u0080-\uFFFF]+)*)\s*;',
        multiLine: true,
      ).firstMatch(withoutComments)?.group(1);
      final mainClass = [?package, p.basenameWithoutExtension(entry)].join('.');
      _target = await _start(project, [
        'java',
        '-Xms16m',
        '-Xmx256m',
        '-XX:+UseSerialGC',
        '-Dfile.encoding=UTF-8',
        '-agentlib:jdwp=transport=dt_socket,server=n,suspend=y,address=127.0.0.1:$port,timeout=${_debugger.startupTimeout.inMilliseconds.clamp(1, 120000)}',
        '-classpath',
        classpath,
        mainClass,
        ..._arguments,
      ], inputFile: p.join(project, 'input.txt'));
      _targetDone = _watch(_target!, helper: false);
      _targetDone!.then(
        (code) {
          _targetExit = code;
          if (!_stopping) unawaited(stop());
        },
        onError: (Object e) {
          if (!_stopping) {
            _error(e);
            unawaited(stop());
          }
        },
      );
      await ready.timeout(_debugger.startupTimeout);
      _check();
      _lifetime = Timer(_debugger.sessionTimeout, () {
        _error(TimeoutException('Java debug session timed out'));
        unawaited(stop());
      });
    } catch (error) {
      if (!_stopping) _error(error);
      unawaited(stop());
    }
  }

  Future<int> _watch(
    JavaToolchainProcess process, {
    required bool helper,
  }) async {
    final stdout = helper
        ? _bounded(process.stdout)
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .forEach(_decode)
        : _bounded(process.stdout)
              .transform(const Utf8Decoder(allowMalformed: true))
              .forEach(
                (text) => _emit(
                  JavaDebugEvent(JavaDebugEventKind.output, message: text),
                ),
              );
    final stderr = _bounded(process.stderr)
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(
          (text) => _emit(
            JavaDebugEvent(
              JavaDebugEventKind.output,
              message: text,
              isErrorOutput: true,
            ),
          ),
        );
    final values = await Future.wait<Object?>([
      process.exitCode,
      stdout,
      stderr,
    ]);
    _processes.remove(process);
    return values[0] as int;
  }

  void _decode(String line) {
    try {
      final fields = line.split('\t');
      if (fields.length < 2 || fields[0] != 'DBG') {
        throw const FormatException('Unexpected JDI helper output');
      }
      switch (fields[1]) {
        case 'READY':
          final port = int.parse(fields[2]);
          if (port < 1 || port > 65535 || _port.isCompleted) {
            throw const FormatException('Invalid debug listener');
          }
          _port.complete(port);
        case 'ATTACHED':
          if (!_ready.isCompleted) _ready.complete();
          _emit(const JavaDebugEvent(JavaDebugEventKind.attached));
        case 'VM':
          _vmInfo = JavaDebugVmInfo(
            name: _decodeField(fields[2]),
            version: _decodeField(fields[3]),
            description: _decodeField(fields[4]),
            canPopFrames: fields[5] == 'true',
            canForceEarlyReturn: fields[6] == 'true',
          );
        case 'BREAKPOINT':
          _emit(
            JavaDebugEvent(
              JavaDebugEventKind.breakpoint,
              breakpointId: _decodeField(fields[2]),
              verified: fields[3] == 'verified',
              message: fields[3],
            ),
          );
        case 'PAUSED':
          _emit(
            JavaDebugEvent(
              JavaDebugEventKind.paused,
              message: fields[2],
              location: JavaDebugLocation(
                className: _decodeField(fields[3]),
                sourceName: _decodeField(fields[4]),
                line: int.parse(fields[5]),
              ),
            ),
          );
        case 'RESUMED':
          _emit(const JavaDebugEvent(JavaDebugEventKind.resumed));
        case 'VAR':
          _pending[int.parse(fields[2])]?.variables.add(
            JavaDebugVariable(
              name: _decodeField(fields[3]),
              type: _decodeField(fields[4]),
              value: _decodeField(fields[5]),
            ),
          );
        case 'FRAME':
          _pending[int.parse(fields[2])]?.frames.add(
            JavaDebugFrame(
              index: int.parse(fields[3]),
              method: _decodeField(fields[5]),
              location: JavaDebugLocation(
                className: _decodeField(fields[4]),
                sourceName: _decodeField(fields[6]),
                line: int.parse(fields[7]),
              ),
            ),
          );
        case 'DONE':
          final reply = _pending.remove(int.parse(fields[2]));
          if (reply != null && !reply.done.isCompleted) {
            reply.done.complete(reply);
          }
        case 'ERROR':
          final reply = _pending.remove(int.parse(fields[2]));
          final error = StateError(_decodeField(fields[3]));
          if (reply != null) {
            reply.done.completeError(error);
          } else {
            _error(error);
          }
        case 'DISCONNECTED':
          _helperDisconnected = true;
          break; // Target process exit, rather than a protocol guess, closes it.
        default:
          throw const FormatException('Unknown JDI helper event');
      }
    } catch (error) {
      _error(error);
      unawaited(stop());
    }
  }

  static void _validateBreakpoint(JavaBreakpoint breakpoint) {
    if (breakpoint.id.isEmpty ||
        breakpoint.id.length > 200 ||
        breakpoint.line < 1 ||
        !RegExp(
          r'^[\w$\u0080-\uFFFF]+(?:\.[\w$\u0080-\uFFFF]+)*$',
        ).hasMatch(breakpoint.className)) {
      throw ArgumentError('Invalid Java breakpoint');
    }
  }

  Future<_DebugReply> _command(
    String operation, [
    List<String> fields = const [],
  ]) async {
    await ready;
    _check();
    final id = ++_sequence;
    final reply = _DebugReply();
    _pending[id] = reply;
    try {
      final command = File(p.join(_directory!.path, '$id.cmd.part'));
      await command.writeAsString(
        [id.toString(), operation, ...fields].join('\t'),
      );
      await command.rename(p.join(_directory!.path, '$id.cmd'));
      return await reply.done.future.timeout(
        _debugger.commandTimeout,
        onTimeout: () {
          unawaited(stop());
          throw TimeoutException('JDI command $operation timed out');
        },
      );
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> setBreakpoint(JavaBreakpoint breakpoint) async {
    _validateBreakpoint(breakpoint);
    await _command('breakpoint', [
      _encode(breakpoint.id),
      _encode(breakpoint.className),
      '${breakpoint.line}',
    ]);
  }

  Future<void> removeBreakpoint(String id) async {
    await _command('remove', [_encode(id)]);
  }

  Future<void> resume() async {
    await _command('resume');
  }

  Future<void> pause() async {
    await _command('pause');
  }

  Future<void> stepOver() async {
    await _command('over');
  }

  Future<void> stepInto() async {
    await _command('into');
  }

  Future<void> stepOut() async {
    await _command('out');
  }

  Future<List<JavaDebugVariable>> variables({int frame = 0}) async {
    if (frame < 0 || frame > 31) throw ArgumentError('Invalid frame');
    return List.unmodifiable(
      (await _command('variables', ['$frame'])).variables,
    );
  }

  Future<List<JavaDebugFrame>> stackTrace() async =>
      List.unmodifiable((await _command('stack')).frames);
  Future<void> terminate() async {
    await _command('terminate');
    await done.timeout(_debugger.commandTimeout);
  }

  Future<void> stop() => _stoppingFuture ??= _stop();
  Future<void> _stop() async {
    _stopping = true;
    _lifetime?.cancel();
    if (!_ready.isCompleted) {
      _ready.completeError(
        StateError('Java debug session stopped before attach'),
      );
    }
    if (!_port.isCompleted) {
      _port.completeError(
        StateError('Java debug session stopped before listening'),
      );
    }
    for (final reply in _pending.values) {
      if (!reply.done.isCompleted) {
        reply.done.completeError(StateError('Java debug session stopped'));
      }
    }
    _pending.clear();
    Future<void> cancel(JavaToolchainProcess? process) async {
      try {
        await process?.cancel();
      } catch (_) {
        /* Preserve the real failure event. */
      }
    }

    await cancel(_target);
    for (final process in _processes.toList()) {
      if (!identical(process, _helper)) await cancel(process);
    }
    await cancel(_helper);
    await _initializing;
    // Native starts may have completed while the first cancellation ran.
    await cancel(_target);
    for (final process in _processes.toList()) {
      await cancel(process);
    }
    try {
      if (_targetDone != null) _targetExit = await _targetDone!;
    } catch (_) {
      /* Already reported. */
    }
    try {
      await _helperDone;
    } catch (_) {
      /* Already reported. */
    }
    if (_directory != null) {
      try {
        await _directory!.delete(recursive: true);
      } on FileSystemException {
        /* Do not replace debugger result. */
      }
    }
    _emit(JavaDebugEvent(JavaDebugEventKind.terminated, exitCode: _targetExit));
    if (!_done.isCompleted) _done.complete(_targetExit);
    unawaited(_events.close());
  }
}

class _DebugReply {
  _DebugReply() {
    done.future.ignore();
  }
  final done = Completer<_DebugReply>();
  final variables = <JavaDebugVariable>[];
  final frames = <JavaDebugFrame>[];
}

String _encode(String text) => base64.encode(utf8.encode(text));
String _decodeField(String text) => utf8.decode(base64.decode(text));

const _jdiHelper = r'''
import com.sun.jdi.*;
import com.sun.jdi.connect.*;
import com.sun.jdi.event.*;
import com.sun.jdi.request.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.io.*;
import java.util.*;

public final class QfliJavaDebugger {
  final Path root;
  final PrintWriter out = new PrintWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8), true);
  final Map<String, Spec> specs = new LinkedHashMap<>();
  VirtualMachine vm;
  ThreadReference paused;
  EventSet held;
  int next = 1;
  static final class Spec {
    final String id, type; final int line;
    final List<BreakpointRequest> requests = new ArrayList<>();
    final Set<ReferenceType> installed = new HashSet<>();
    ClassPrepareRequest prepare;
    Spec(String id, String type, int line) { this.id=id; this.type=type; this.line=line; }
  }
  QfliJavaDebugger(Path root) { this.root=root; }
  static String enc(String s) {
    if (s.length()>4096) s=s.substring(0,4096)+"...";
    return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
  }
  static String dec(String s) { return new String(Base64.getDecoder().decode(s), StandardCharsets.UTF_8); }
  void emit(String text) { out.println("DBG\t"+text); }
  void breakpointState(Spec spec, String state) { emit("BREAKPOINT\t"+enc(spec.id)+"\t"+state); }
  void install(Spec spec, ReferenceType type) throws Exception {
    if (!type.name().equals(spec.type) || !spec.installed.add(type)) return;
    List<Location> locations=type.locationsOfLine(spec.line);
    if (locations.isEmpty()) { breakpointState(spec,"no-executable-code"); return; }
    for (Location location: locations) {
      BreakpointRequest r=vm.eventRequestManager().createBreakpointRequest(location);
      r.setSuspendPolicy(EventRequest.SUSPEND_ALL); r.enable(); spec.requests.add(r);
    }
    breakpointState(spec,"verified");
  }
  void add(Spec spec) throws Exception {
    remove(spec.id); specs.put(spec.id,spec);
    spec.prepare=vm.eventRequestManager().createClassPrepareRequest();
    spec.prepare.addClassFilter(spec.type);
    spec.prepare.setSuspendPolicy(EventRequest.SUSPEND_ALL); spec.prepare.enable();
    boolean prepared=false;
    for (ReferenceType type: vm.classesByName(spec.type)) {
      if (type.isPrepared()) { install(spec,type); prepared=true; }
    }
    if (!prepared) breakpointState(spec,"pending-class");
  }
  void remove(String id) {
    Spec previous=specs.remove(id);
    if (previous!=null) {
      vm.eventRequestManager().deleteEventRequests(previous.requests);
      if (previous.prepare!=null) vm.eventRequestManager().deleteEventRequest(previous.prepare);
    }
  }
  String source(Location l) { try { return l.sourceName(); } catch (AbsentInformationException e) { return ""; } }
  void pauseAt(ThreadReference thread, EventSet set, String reason) throws Exception {
    paused=thread; held=set;
    Location location=thread.frame(0).location();
    emit("PAUSED\t"+reason+"\t"+enc(location.declaringType().name())+"\t"+enc(source(location))+"\t"+location.lineNumber());
  }
  void clearSteps() {
    List<StepRequest> steps=new ArrayList<>(vm.eventRequestManager().stepRequests());
    vm.eventRequestManager().deleteEventRequests(steps);
  }
  void resume() {
    if (paused==null) throw new IllegalStateException("Target is not paused");
    clearSteps();
    resumeHeld();
  }
  void resumeHeld() {
    EventSet set=held; held=null; paused=null;
    if (set!=null) set.resume(); else vm.resume();
    emit("RESUMED");
  }
  void step(int depth) {
    if (paused==null) throw new IllegalStateException("Target is not paused");
    clearSteps();
    StepRequest request=vm.eventRequestManager().createStepRequest(paused,StepRequest.STEP_LINE,depth);
    request.addCountFilter(1);
    for (String filter: List.of("java.*","javax.*","jdk.*","sun.*","com.sun.*")) request.addClassExclusionFilter(filter);
    request.setSuspendPolicy(EventRequest.SUSPEND_ALL); request.enable();
    resumeHeld();
  }
  String value(Value v) {
    if (v==null) return "null";
    if (v instanceof StringReference) return ((StringReference)v).value();
    if (v instanceof ArrayReference) return v.type().name()+"[length="+((ArrayReference)v).length()+"]";
    if (v instanceof ObjectReference) return v.type().name()+"@"+Long.toHexString(((ObjectReference)v).uniqueID());
    return v.toString();
  }
  void command(String[] f) throws Exception {
    String id=f[0], operation=f[1];
    try {
      switch (operation) {
        case "breakpoint":
          if (specs.size()>=200 && !specs.containsKey(dec(f[2]))) throw new IllegalStateException("Too many breakpoints");
          add(new Spec(dec(f[2]),dec(f[3]),Integer.parseInt(f[4]))); break;
        case "remove": remove(dec(f[2])); break;
        case "resume": resume(); break;
        case "over": step(StepRequest.STEP_OVER); break;
        case "into": step(StepRequest.STEP_INTO); break;
        case "out": step(StepRequest.STEP_OUT); break;
        case "pause":
          if (paused!=null) throw new IllegalStateException("Target is already paused");
          vm.suspend();
          ThreadReference selected=null;
          for (ThreadReference t: vm.allThreads()) if (t.name().equals("main") && t.frameCount()>0) { selected=t; break; }
          if (selected==null) { vm.resume(); throw new IllegalStateException("No suspendable main thread"); }
          pauseAt(selected,null,"pause"); break;
        case "variables":
          if (paused==null) throw new IllegalStateException("Target is not paused");
          StackFrame frame=paused.frame(Integer.parseInt(f[2]));
          List<LocalVariable> variables=frame.visibleVariables();
          Map<LocalVariable,Value> values=frame.getValues(variables);
          int count=0;
          for (LocalVariable variable: variables) { if (++count>200) break; emit("VAR\t"+id+"\t"+enc(variable.name())+"\t"+enc(variable.typeName())+"\t"+enc(value(values.get(variable)))); }
          if (frame.thisObject()!=null) emit("VAR\t"+id+"\t"+enc("this")+"\t"+enc(frame.thisObject().type().name())+"\t"+enc(value(frame.thisObject())));
          break;
        case "stack":
          if (paused==null) throw new IllegalStateException("Target is not paused");
          int index=0;
          for (StackFrame sf: paused.frames(0,Math.min(32,paused.frameCount()))) {
            Location l=sf.location(); emit("FRAME\t"+id+"\t"+(index++)+"\t"+enc(l.declaringType().name())+"\t"+enc(l.method().name())+"\t"+enc(source(l))+"\t"+l.lineNumber());
          }
          break;
        case "terminate": emit("DONE\t"+id); vm.exit(0); return;
        default: throw new IllegalArgumentException("Unknown debug command");
      }
      emit("DONE\t"+id);
    } catch (VMDisconnectedException e) { throw e; }
    catch (Exception e) { emit("ERROR\t"+id+"\t"+enc(e.toString())); }
  }
  void run() throws Exception {
    ListeningConnector connector=null;
    for (ListeningConnector c: Bootstrap.virtualMachineManager().listeningConnectors()) if (c.name().equals("com.sun.jdi.SocketListen")) connector=c;
    if (connector==null) throw new IllegalStateException("JDI SocketListen is unavailable");
    Map<String,Connector.Argument> args=connector.defaultArguments();
    args.get("localAddress").setValue("127.0.0.1"); args.get("port").setValue("0"); args.get("timeout").setValue("30000");
    String address=connector.startListening(args);
    int port=Integer.parseInt(address.substring(address.lastIndexOf(':')+1));
    emit("READY\t"+port);
    try { vm=connector.accept(args); } finally { connector.stopListening(args); }
    try {
      for (String line: Files.readAllLines(root.resolve("breakpoints"),StandardCharsets.UTF_8)) {
        if (line.isEmpty()) continue;
        String[] fields=line.split("\t",-1); add(new Spec(dec(fields[0]),dec(fields[1]),Integer.parseInt(fields[2])));
      }
      emit("VM\t"+enc(vm.name())+"\t"+enc(vm.version())+"\t"+enc(vm.description())+"\t"+vm.canPopFrames()+"\t"+vm.canForceEarlyReturn());
      emit("ATTACHED");
      while (true) {
        for (int count=0;count<32;count++) {
          Path command=root.resolve(next+".cmd");
          if (!Files.exists(command)) break;
          String text=Files.readString(command,StandardCharsets.UTF_8);
          Files.delete(command); next++;
          command(text.split("\t",-1));
        }
        EventSet set=vm.eventQueue().remove(40);
        if (set==null) continue;
        boolean stopped=false;
        for (Event event: set) {
          if (event instanceof VMDeathEvent || event instanceof VMDisconnectEvent) return;
          if (event instanceof ClassPrepareEvent) {
            ReferenceType type=((ClassPrepareEvent)event).referenceType();
            for (Spec spec: specs.values()) install(spec,type);
          } else if (event instanceof BreakpointEvent) {
            pauseAt(((BreakpointEvent)event).thread(),set,"breakpoint"); stopped=true;
          } else if (event instanceof StepEvent) {
            clearSteps(); pauseAt(((StepEvent)event).thread(),set,"step"); stopped=true;
          }
        }
        if (!stopped) set.resume();
      }
    } catch (VMDisconnectedException expected) {
      // The owned target's actual process exit is reported separately by Dart.
    } finally {
      emit("DISCONNECTED");
      try { vm.dispose(); } catch (VMDisconnectedException ignored) {}
    }
  }
  public static void main(String[] args) throws Exception { new QfliJavaDebugger(Path.of(args[0])).run(); }
}
''';
