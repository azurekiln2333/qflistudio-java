import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_studio_core/models/project.dart';
import 'package:qfli_studio_core/store/project_store.dart';

import 'java_debugger.dart';

/// A local JDI session over an isolated copy of the project's saved sources.
/// The editor's unsaved buffers are deliberately not implied by this route.
class JavaDebuggerPage extends StatefulWidget {
  const JavaDebuggerPage({
    super.key,
    this.store,
    this.debugger = const JavaDebugger(),
  });

  static const title = 'Java 调试器';
  final ProjectStore? store;
  final JavaDebugger debugger;

  @override
  State<JavaDebuggerPage> createState() => _JavaDebuggerPageState();
}

enum _DebugPhase { idle, starting, running, paused, stopping, ended, failed }

class _JavaDebuggerPageState extends State<JavaDebuggerPage> {
  final _project = TextEditingController();
  final _entry = TextEditingController(text: 'Main.java');
  final _arguments = TextEditingController();
  final _class = TextEditingController(text: 'Main');
  final _line = TextEditingController();
  final _breakpoints = <JavaBreakpoint>[];
  final _verified = <String, bool>{};
  JavaDebugSession? _session;
  StreamSubscription<JavaDebugEvent>? _subscription;
  _DebugPhase _phase = _DebugPhase.idle;
  JavaDebugLocation? _location;
  List<JavaDebugFrame> _frames = const [];
  List<JavaDebugVariable> _variables = const [];
  String? _error;
  String? _vm;
  String _output = '';
  bool _commandPending = false;
  bool _stopRequested = false;
  int _nextBreakpoint = 0;
  int _inspection = 0;
  int _selectedFrame = 0;

  @override
  void initState() {
    super.initState();
    _chooseRecentProject();
    widget.store?.addListener(_storeChanged);
  }

  @override
  void didUpdateWidget(JavaDebuggerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store?.removeListener(_storeChanged);
      widget.store?.addListener(_storeChanged);
      _chooseRecentProject();
    }
  }

  List<Project> get _projects {
    final paths = <String>{};
    return widget.store?.projects
            .where((project) => !project.isCloud && paths.add(project.path))
            .toList() ??
        const [];
  }

  void _chooseRecentProject() {
    if (_project.text.isNotEmpty || _projects.isEmpty) return;
    final selected = _projects.where(
      (project) => project.id == widget.store?.lastBrowsedProjectId,
    );
    _project.text = (selected.isEmpty ? _projects.first : selected.first).path;
  }

  void _storeChanged() {
    if (!mounted) return;
    setState(_chooseRecentProject);
  }

  @override
  void dispose() {
    widget.store?.removeListener(_storeChanged);
    final session = _session;
    _session = null;
    _inspection++;
    unawaited(_subscription?.cancel());
    // The backend owns both JVMs and its snapshot. Leaving the page also stops
    // a session that is still compiling/attaching, rather than orphaning it.
    if (session != null) unawaited(session.stop().catchError((Object _) {}));
    for (final controller in [_project, _entry, _arguments, _class, _line]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _current(JavaDebugSession session) =>
      mounted && identical(_session, session);

  void _appendOutput(String text) {
    const limit = 64 * 1024;
    final combined = _output + text;
    if (combined.length <= limit) {
      _output = combined;
      return;
    }
    var start = combined.length - limit;
    if (combined.codeUnitAt(start) >= 0xdc00 &&
        combined.codeUnitAt(start) <= 0xdfff &&
        combined.codeUnitAt(start - 1) >= 0xd800 &&
        combined.codeUnitAt(start - 1) <= 0xdbff) {
      start++;
    }
    _output = '…（仅保留最近输出）\n${combined.substring(start)}';
  }

  void _event(JavaDebugSession session, JavaDebugEvent event) {
    if (!_current(session)) return;
    if (_stopRequested &&
        (event.kind == JavaDebugEventKind.attached ||
            event.kind == JavaDebugEventKind.paused ||
            event.kind == JavaDebugEventKind.resumed)) {
      return;
    }
    setState(() {
      switch (event.kind) {
        case JavaDebugEventKind.attached:
          _phase = _DebugPhase.running;
          final info = session.vmInfo;
          _vm = info == null ? event.message : '${info.name} ${info.version}';
        case JavaDebugEventKind.breakpoint:
          if (event.breakpointId != null) {
            _verified[event.breakpointId!] = event.verified;
          }
        case JavaDebugEventKind.paused:
          _phase = _DebugPhase.paused;
          _location = event.location;
          _frames = const [];
          _variables = const [];
          _selectedFrame = 0;
        case JavaDebugEventKind.resumed:
          _phase = _DebugPhase.running;
          _location = null;
          _frames = const [];
          _variables = const [];
          _inspection++;
        case JavaDebugEventKind.output:
          _appendOutput(
            '${event.isErrorOutput ? '[stderr] ' : ''}${event.message}',
          );
        case JavaDebugEventKind.error:
          _error = event.message;
          _phase = _DebugPhase.failed;
          _inspection++;
        case JavaDebugEventKind.terminated:
          _inspection++;
          if (_phase != _DebugPhase.failed) _phase = _DebugPhase.ended;
          _appendOutput('\n[进程结束：${event.exitCode ?? '?'}]\n');
      }
    });
    if (event.kind == JavaDebugEventKind.paused) {
      unawaited(_inspect(session));
    }
  }

  Future<void> _inspect(JavaDebugSession session, {int frame = 0}) async {
    final revision = ++_inspection;
    try {
      final frames = await session.stackTrace();
      if (!_current(session) ||
          revision != _inspection ||
          _phase != _DebugPhase.paused) {
        return;
      }
      final variables = frames.isEmpty
          ? <JavaDebugVariable>[]
          : await session.variables(frame: frame);
      if (!_current(session) ||
          revision != _inspection ||
          _phase != _DebugPhase.paused) {
        return;
      }
      setState(() {
        _frames = frames;
        _variables = variables;
        _selectedFrame = frame;
      });
    } catch (error) {
      if (_current(session) && revision == _inspection) {
        setState(() => _error = '无法读取暂停现场：$error');
      }
    }
  }

  void _start() {
    if (_session != null) return;
    final project = _project.text.trim();
    final entry = _entry.text.trim();
    if (!p.isAbsolute(project) || entry.isEmpty) {
      setState(() => _error = '请填写项目绝对路径和 Java 入口文件。');
      return;
    }
    final entryPath = p.normalize(
      p.isAbsolute(entry) ? entry : p.join(project, entry),
    );
    if (!p.isWithin(p.normalize(project), entryPath) ||
        p.extension(entryPath).toLowerCase() != '.java') {
      setState(() => _error = '入口必须是当前项目内的 .java 文件。');
      return;
    }
    setState(() {
      _error = null;
      _output = '';
      _vm = null;
      _location = null;
      _frames = const [];
      _variables = const [];
      _verified.clear();
      _stopRequested = false;
      _phase = _DebugPhase.starting;
    });
    try {
      final session = widget.debugger.launch(
        projectPath: project,
        entryFile: entryPath,
        breakpoints: List.of(_breakpoints),
        arguments: _arguments.text.isEmpty
            ? const []
            : _arguments.text.split(RegExp(r'\r?\n')),
      );
      _session = session;
      _subscription = session.events.listen(
        (event) => _event(session, event),
        onError: (Object error) {
          if (_current(session)) setState(() => _error = '$error');
        },
      );
      unawaited(_watch(session));
    } catch (error) {
      setState(() {
        _phase = _DebugPhase.failed;
        _error = '调试器无法启动：$error';
      });
    }
  }

  Future<void> _watch(JavaDebugSession session) async {
    try {
      await session.ready;
    } catch (error) {
      if (_current(session) && !_stopRequested) {
        setState(() {
          _phase = _DebugPhase.failed;
          _error ??= '调试器不可用：$error';
        });
      }
    }
    try {
      await session.done;
    } catch (error) {
      if (_current(session)) setState(() => _error = '$error');
    }
    if (!_current(session)) return;
    unawaited(_subscription?.cancel());
    _subscription = null;
    setState(() {
      _session = null;
      _commandPending = false;
      _inspection++;
      if (_phase != _DebugPhase.failed) _phase = _DebugPhase.ended;
    });
  }

  Future<void> _command(Future<void> Function(JavaDebugSession) action) async {
    final session = _session;
    if (session == null || _commandPending) return;
    setState(() {
      _commandPending = true;
      _error = null;
    });
    try {
      await action(session);
    } catch (error) {
      if (_current(session) && !_stopRequested) {
        setState(() => _error = '调试命令失败：$error');
      }
    } finally {
      if (_current(session)) setState(() => _commandPending = false);
    }
  }

  Future<void> _stop() async {
    final session = _session;
    if (session == null || _phase == _DebugPhase.stopping) return;
    setState(() {
      _stopRequested = true;
      _phase = _DebugPhase.stopping;
      _inspection++;
    });
    try {
      await session.stop();
    } catch (error) {
      if (_current(session)) setState(() => _error = '停止失败：$error');
    }
  }

  Future<void> _addBreakpoint() async {
    final className = _class.text.trim();
    final line = int.tryParse(_line.text.trim());
    if (!RegExp(
          r'^[\w$\u0080-\uFFFF]+(?:\.[\w$\u0080-\uFFFF]+)*$',
        ).hasMatch(className) ||
        line == null ||
        line < 1) {
      setState(() => _error = '填写完整类名和大于 0 的可执行代码行号。');
      return;
    }
    if (_breakpoints.length >= 200) {
      setState(() => _error = '最多添加 200 个断点。');
      return;
    }
    if (_breakpoints.any(
      (bp) => bp.className == className && bp.line == line,
    )) {
      setState(() => _error = '该位置已有断点。');
      return;
    }
    final breakpoint = JavaBreakpoint(
      id: 'ui-${++_nextBreakpoint}',
      className: className,
      line: line,
    );
    final session = _session;
    if (session == null) {
      setState(() {
        _breakpoints.add(breakpoint);
        _error = null;
      });
    } else {
      await _command((session) async {
        await session.setBreakpoint(breakpoint);
        if (_current(session)) setState(() => _breakpoints.add(breakpoint));
      });
    }
  }

  Future<void> _removeBreakpoint(JavaBreakpoint breakpoint) async {
    final session = _session;
    if (session == null) {
      setState(() => _breakpoints.remove(breakpoint));
    } else {
      await _command((session) async {
        await session.removeBreakpoint(breakpoint.id);
        if (_current(session)) {
          setState(() {
            _breakpoints.remove(breakpoint);
            _verified.remove(breakpoint.id);
          });
        }
      });
    }
  }

  String get _status => switch (_phase) {
    _DebugPhase.idle => '尚未启动',
    _DebugPhase.starting => '正在编译并连接调试器…',
    _DebugPhase.running => '运行中',
    _DebugPhase.paused => '已暂停',
    _DebugPhase.stopping => '正在停止…',
    _DebugPhase.ended => '已结束',
    _DebugPhase.failed => '调试不可用或失败',
  };

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    bool enabled = true,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      onChanged: identical(controller, _project)
          ? (_) => setState(() {})
          : null,
      enabled: enabled,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) {
    final active = _session != null;
    final paused = _phase == _DebugPhase.paused && !_commandPending;
    final running = _phase == _DebugPhase.running && !_commandPending;
    final canEditBreakpoints = !active || paused || running;
    final location = _location;
    return Scaffold(
      appBar: AppBar(title: const Text(JavaDebuggerPage.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '使用本机 JDK/JDI 调试项目，不需要网络。启动前请先在编辑器保存文件；'
            '调试器编译已保存源码的隔离快照，项目目录不会被改写。'
            '目标运行时不支持 JDI/JDWP 时会显示实际错误。',
          ),
          _heading('调试目标'),
          if (_projects.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DropdownButtonFormField<String>(
                key: ValueKey(_project.text),
                initialValue: _projects.any((p) => p.path == _project.text)
                    ? _project.text
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '已注册的本地项目'),
                items: [
                  for (final project in _projects)
                    DropdownMenuItem(
                      value: project.path,
                      child: Text(
                        project.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: active
                    ? null
                    : (value) => setState(() => _project.text = value ?? ''),
              ),
            ),
          _field('项目绝对路径', _project, enabled: !active),
          _field('Java 入口文件', _entry, hint: 'src/Main.java', enabled: !active),
          _field('程序参数（每行一个）', _arguments, enabled: !active, maxLines: 2),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: active ? null : _start,
                icon: const Icon(Icons.play_arrow),
                label: const Text('启动调试'),
              ),
              OutlinedButton.icon(
                onPressed: running ? () => _command((s) => s.pause()) : null,
                icon: const Icon(Icons.pause),
                label: const Text('暂停'),
              ),
              OutlinedButton.icon(
                onPressed: paused ? () => _command((s) => s.resume()) : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('继续'),
              ),
              OutlinedButton(
                onPressed: paused ? () => _command((s) => s.stepOver()) : null,
                child: const Text('单步越过'),
              ),
              OutlinedButton(
                onPressed: paused ? () => _command((s) => s.stepInto()) : null,
                child: const Text('单步进入'),
              ),
              OutlinedButton(
                onPressed: paused ? () => _command((s) => s.stepOut()) : null,
                child: const Text('单步跳出'),
              ),
              OutlinedButton.icon(
                onPressed: active && _phase != _DebugPhase.stopping
                    ? _stop
                    : null,
                icon: const Icon(Icons.stop),
                label: const Text('停止'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_status, key: const ValueKey('java-debug-status')),
          ),
          if (_vm != null) SelectableText(_vm!),
          if (location != null)
            SelectableText(
              '${location.className} · ${location.sourceName}:${location.line}',
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          _heading('行断点'),
          const Text(r'完整类名含包名；内部类使用 $。请选择可执行代码行。'),
          const SizedBox(height: 12),
          _field(
            '断点类名',
            _class,
            hint: 'com.example.Main',
            enabled: canEditBreakpoints,
          ),
          _field(
            '断点行号',
            _line,
            enabled: canEditBreakpoints,
            keyboardType: TextInputType.number,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: canEditBreakpoints ? _addBreakpoint : null,
              icon: const Icon(Icons.add),
              label: const Text('添加断点'),
            ),
          ),
          if (_breakpoints.isEmpty) const Text('尚无断点。添加后启动可在对应位置暂停。'),
          for (final breakpoint in _breakpoints)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                _verified[breakpoint.id] == true
                    ? Icons.circle
                    : Icons.radio_button_unchecked,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text('${breakpoint.className}:${breakpoint.line}'),
              subtitle: Text(
                !active
                    ? '下次启动时设置'
                    : _verified[breakpoint.id] == true
                    ? '已绑定可执行位置'
                    : '尚未绑定（等待类加载或行号无可执行位置）',
              ),
              trailing: IconButton(
                onPressed: canEditBreakpoints
                    ? () => _removeBreakpoint(breakpoint)
                    : null,
                tooltip: '移除 ${breakpoint.className}:${breakpoint.line}',
                icon: const Icon(Icons.close),
              ),
            ),
          _heading('调用栈'),
          if (_frames.isEmpty) const Text('暂停后显示实际线程调用栈。'),
          for (final frame in _frames)
            ListTile(
              contentPadding: EdgeInsets.zero,
              selected: frame.index == _selectedFrame,
              title: Text('${frame.location.className}.${frame.method}'),
              subtitle: Text(
                '${frame.location.sourceName}:${frame.location.line}',
              ),
              onTap: paused
                  ? () => _inspect(_session!, frame: frame.index)
                  : null,
            ),
          _heading('局部变量'),
          if (_variables.isEmpty) const Text('当前没有可读取的局部变量。请在暂停后选择调用栈帧。'),
          for (final variable in _variables)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SelectableText(
                '${variable.type} ${variable.name} = ${variable.value}',
              ),
            ),
          _heading('调试输出'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: SelectableText(
              _output.isEmpty ? '程序的 stdout / stderr 将显示在这里。' : _output,
              key: const ValueKey('java-debug-output'),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
