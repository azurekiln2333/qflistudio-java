import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qfli_studio_core/models/project.dart';
import 'package:qfli_studio_core/store/project_store.dart';
import 'package:qfli_studio_core/widgets/tool_widgets.dart';

import 'java_web_project.dart';
import 'java_web_templates.dart';
import 'spring_boot_bundle.dart';

/// JavaEE environment page.
///
/// Inspects the actual project directory and the actual offline pack. Writes a
/// scaffold only after an explicit user action. Never claims a compile, a run,
/// a device result or an OHOS acceptance.
///
/// Config decoding belongs to `java_web_project.dart` (p3). Pack listing belongs
/// to `spring_boot_bundle.dart` (p4). Deployment belongs to the Tomcat 9
/// launcher (p5). This page owns presentation and the scaffold.
class JavaWebEnvironmentPage extends StatefulWidget {
  const JavaWebEnvironmentPage({
    super.key,
    this.store,
    this.initialProjectPath,
    this.source,
  });

  static const String title = 'JavaEE 环境';

  final ProjectStore? store;
  final String? initialProjectPath;
  final JavaWebProjectSource? source;

  @override
  State<JavaWebEnvironmentPage> createState() => _JavaWebEnvironmentPageState();
}

/// Config as read by the p3 decoder, plus decoder issues.
class JavaWebConfigRead {
  const JavaWebConfigRead({
    required this.hasConfigFile,
    required this.config,
    required this.issues,
  });

  final bool hasConfigFile;
  final JavaWebConfigSnapshot? config;
  final List<JavaWebIssue> issues;
}

/// Seam to the p3 decoder, the p4 pack and the p5 launcher.
abstract interface class JavaWebProjectSource {
  Future<JavaWebConfigRead> readConfig(String projectPath);

  Future<List<String>> listProjectFiles(String projectPath);

  /// Capability metadata for the offline packs, read from p4.
  ///
  /// Flags come from p4's recorded roles, never from a jar name.
  Future<JavaWebPack> readPack();

  /// True only when a bounded HTTP response arrived from the loopback target.
  Future<bool> probeHealth(JavaWebConfigSnapshot config);

  /// Creates directories and files. Never overwrites an existing file.
  Future<void> writeScaffold(String projectPath, JavaWebScaffoldPlan plan);
}

/// Default source: real files, real pack, real loopback probe.
class FileSystemJavaWebProjectSource implements JavaWebProjectSource {
  const FileSystemJavaWebProjectSource({
    this.packRoot,
    this.timeout = const Duration(seconds: 2),
    this.maxResponseBytes = 8192,
  });

  /// Injectable pack directory. Null uses the p4 bundled pack.
  final String? packRoot;
  final Duration timeout;
  final int maxResponseBytes;

  @override
  Future<JavaWebConfigRead> readConfig(String projectPath) async {
    try {
      final project = await JavaWebProject.load(projectPath);
      if (project == null) {
        return const JavaWebConfigRead(
          hasConfigFile: false,
          config: null,
          issues: [JavaWebIssue('missing', '找不到配置文件')],
        );
      }
      return JavaWebConfigRead(
        hasConfigFile: true,
        config: JavaWebConfigSnapshot.fromProject(project),
        issues: const [],
      );
    } on JavaWebProjectException catch (error) {
      return JavaWebConfigRead(
        hasConfigFile: true,
        config: null,
        issues: [JavaWebIssue(error.code, error.message)],
      );
    }
  }

  @override
  Future<List<String>> listProjectFiles(String projectPath) async {
    final directory = Directory(projectPath);
    if (!await directory.exists()) {
      return const [];
    }
    final paths = <String>[];
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        paths.add(
          entity.path
              .substring(projectPath.length)
              .replaceAll('\\', '/')
              .replaceAll(RegExp('^/+'), ''),
        );
      }
    }
    paths.sort();
    return paths;
  }

  @override
  Future<JavaWebPack> readPack() async {
    JavaEePackCapabilities? springBoot;
    JavaEePackCapabilities? javaee8;
    final names = <String>[];
    // p4 owns every capability flag. A pack whose metadata cannot be read
    // stays unknown, so no flag is guessed from a jar name.
    try {
      springBoot = await SpringBootBundle.capabilities(
        javaWebProfileSpringBoot,
      );
      names.addAll(await JavaEePacks.jarNames(javaWebProfileSpringBoot));
    } on Object {
      springBoot = null;
    }
    try {
      javaee8 = await SpringBootBundle.capabilities(javaWebProfileJavaee8);
      names.addAll(await JavaEePacks.jarNames(javaWebProfileJavaee8));
    } on Object {
      javaee8 = null;
    }
    // An injected pack directory replaces only the displayed file list.
    final root = packRoot;
    if (root != null) {
      final directory = Directory(root);
      if (await directory.exists()) {
        names.clear();
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && entity.path.toLowerCase().endsWith('.jar')) {
            names.add(entity.uri.pathSegments.last);
          }
        }
      }
    }
    names.sort();
    return JavaWebPack.fromCapabilities(
      springBoot: springBoot,
      javaee8: javaee8,
      jars: names,
      boot3Version: JavaEePacks.springBoot.version,
    );
  }

  @override
  Future<bool> probeHealth(JavaWebConfigSnapshot config) async {
    final uri = javaWebHealthUri(config);
    if (!isLoopbackHttp(uri)) {
      return false;
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      // One elapsed budget covers connect, headers and the whole body.
      return await () async {
        final request = await client.getUrl(uri);
        // A redirect could leave loopback, so it is never followed.
        request.followRedirects = false;
        final response = await request.close();
        var bytes = 0;
        await for (final chunk in response) {
          bytes += chunk.length;
          if (bytes > maxResponseBytes) {
            return false;
          }
        }
        // A 2xx..3xx reply only shows that something answers on the port.
        // Another process can own it, so this is reachability, not readiness.
        return response.statusCode >= 200 && response.statusCode < 400;
      }().timeout(timeout);
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> writeScaffold(
    String projectPath,
    JavaWebScaffoldPlan plan,
  ) async {
    if (!plan.canApply) {
      throw StateError('scaffold plan is blocked');
    }
    // The plan carries its own destination, so no caller can land project A's
    // plan inside project B even if the page state was stale.
    final destination = Directory(
      plan.projectRoot,
    ).absolute.path.replaceAll('\\', '/');
    final target = Directory(projectPath).absolute.path.replaceAll('\\', '/');
    if (destination != target) {
      throw StateError('scaffold plan belongs to another project');
    }
    final root = Directory(projectPath).absolute.path.replaceAll('\\', '/');
    final violations = javaWebScaffoldViolations(
      projectRoot: root,
      plannedPaths: <String>[
        ...plan.directories,
        ...plan.files.map((file) => file.path),
      ],
    );
    if (violations.isNotEmpty) {
      throw StateError('unsafe scaffold path: ${violations.first}');
    }
    final createdFiles = <File>[];
    final createdDirs = <Directory>[];
    try {
      for (final directory in plan.directories) {
        final target = Directory('$root/$directory');
        await _rejectLinkEscape(root, target.path);
        if (!await target.exists()) {
          await target.create(recursive: true);
          createdDirs.add(target);
        }
      }
      for (final file in plan.files) {
        final target = File('$root/${file.path}');
        await _rejectLinkEscape(root, target.path);
        await target.parent.create(recursive: true);
        // Exclusive creation is the overwrite guard. exists() then write is a
        // race: a file created after the check would be truncated.
        await target.create(exclusive: true);
        createdFiles.add(target);
        await target.writeAsString(file.content, flush: true);
      }
    } on Object {
      // Roll back only the files and directories this call created.
      for (final file in createdFiles.reversed) {
        try {
          await file.delete();
        } on Object {
          // Keep the original failure; a leftover file is reported by the UI.
        }
      }
      for (final directory in createdDirs.reversed) {
        try {
          await directory.delete();
        } on Object {
          // Non-empty means content predates this call, so it stays.
        }
      }
      rethrow;
    }
  }

  /// Refuses a target whose existing ancestor is a link out of [root].
  Future<void> _rejectLinkEscape(String root, String target) async {
    var current = target.replaceAll('\\', '/');
    final rootPrefix = root.endsWith('/') ? root : '$root/';
    while (current.length > rootPrefix.length) {
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('链接目标不可写入：$current');
      }
      final index = current.lastIndexOf('/');
      if (index <= 0) {
        break;
      }
      current = current.substring(0, index);
    }
  }
}

class _JavaWebEnvironmentPageState extends State<JavaWebEnvironmentPage> {
  final _project = TextEditingController();
  final _port = TextEditingController(text: '8080');
  final _context = TextEditingController(text: '/');
  final _webRoot = TextEditingController(text: 'src/main/webapp');

  String _profile = javaWebProfileSpringBoot;
  bool _includeDatabase = false;
  JavaWebEnvironmentReport? _report;
  JavaWebScaffoldPlan? _plan;
  String? _error;

  /// Number of operations in flight. Busy is derived, so a revision change can
  /// never strand it: whoever increments must decrement on completion.
  int _pending = 0;

  bool get _busy => _pending > 0;

  /// Bumped whenever the target project changes.
  ///
  /// A late async result carries the revision it started with, so a result for
  /// a previous directory is rejected instead of shown or applied.
  int _revision = 0;

  JavaWebProjectSource get _source =>
      widget.source ?? const FileSystemJavaWebProjectSource();

  @override
  void initState() {
    super.initState();
    _project.text = widget.initialProjectPath ?? '';
    _chooseRecentProject();
    _project.addListener(_onProjectEdited);
    widget.store?.addListener(_onStore);
    // No setState here: assigning the initial error avoids calling setState
    // during initState, which Flutter refuses.
    if (_project.text.trim().isEmpty) {
      _error = '请选择一个本地项目';
    } else {
      _inspect();
    }
  }

  @override
  void dispose() {
    widget.store?.removeListener(_onStore);
    _project.removeListener(_onProjectEdited);
    for (final controller in [_project, _port, _context, _webRoot]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onStore() => _chooseRecentProject();

  List<Project> get _localProjects {
    final store = widget.store;
    if (store == null) {
      return const [];
    }
    final seen = <String>{};
    return store.projects
        .where(
          (project) =>
              !project.isCloud &&
              project.path.isNotEmpty &&
              seen.add(project.path),
        )
        .toList(growable: false);
  }

  void _chooseRecentProject() {
    if (_project.text.isNotEmpty) {
      return;
    }
    final projects = _localProjects;
    if (projects.isEmpty) {
      return;
    }
    final selected = projects.where(
      (project) => project.id == widget.store?.lastBrowsedProjectId,
    );
    _project.text = (selected.isEmpty ? projects.first : selected.first).path;
  }

  /// Drops everything derived from the previous directory.
  ///
  /// A report or a plan for project A must never be shown or written for B.
  void _onProjectEdited() {
    _revision++;
    if (_report == null && _plan == null) {
      return;
    }
    setState(() {
      _report = null;
      _plan = null;
      _error = null;
    });
  }

  Future<void> _inspect() async {
    final path = _project.text.trim();
    final revision = ++_revision;
    if (path.isEmpty) {
      setState(() {
        _report = null;
        _plan = null;
        _error = '请选择一个本地项目';
      });
      return;
    }
    setState(() {
      _pending++;
      _error = null;
      _plan = null;
    });
    try {
      final config = await _source.readConfig(path);
      final projectPaths = await _source.listProjectFiles(path);
      final pack = await _source.readPack();
      final report = buildJavaWebReport(
        projectPath: path,
        config: config.config,
        configIssues: config.issues,
        projectPaths: projectPaths,
        pack: pack,
        hasConfigFile: config.hasConfigFile,
      );
      // Reject a result that belongs to a previous target.
      if (!mounted || revision != _revision || path != _project.text.trim()) {
        return;
      }
      setState(() {
        _report = report;
        final snapshot = report.config;
        if (snapshot != null) {
          _port.text = '${snapshot.port}';
          _context.text = snapshot.contextPath;
          _webRoot.text = snapshot.webRoot;
          _profile = snapshot.profile;
        }
      });
    } on Object catch (error) {
      if (mounted && revision == _revision && path == _project.text.trim()) {
        setState(() => _error = '检查失败：$error');
      }
    } finally {
      // Completion always releases the operation, even for a stale target.
      // The presentation guard above must not own the busy flag.
      if (mounted) {
        setState(() {
          if (_pending > 0) {
            _pending--;
          }
        });
      }
    }
  }

  Future<void> _checkResponse() async {
    final report = _report;
    final snapshot = report?.config;
    if (report == null || snapshot == null) {
      setState(() => _error = '请先检查项目并接入配置解码');
      return;
    }
    final revision = _revision;
    setState(() {
      _pending++;
      _error = null;
    });
    try {
      final proven = await _source.probeHealth(snapshot);
      if (!mounted || revision != _revision || _report != report) {
        return;
      }
      setState(() {
        _report = report.withReachable(proven);
        if (!proven) {
          _error = '未收到本地响应。地址只是配置值。';
        }
      });
    } on Object catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _error = '检查失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          if (_pending > 0) {
            _pending--;
          }
        });
      }
    }
  }

  void _planScaffold() {
    final report = _report;
    final path = _project.text.trim();
    if (report == null || path.isEmpty) {
      setState(() => _error = '请先检查项目');
      return;
    }
    // A report for another directory cannot describe this one.
    if (report.projectPath != path) {
      setState(() {
        _report = null;
        _plan = null;
        _error = '项目已更换，请重新检查';
      });
      return;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = '端口必须是 1 到 65535 的整数');
      return;
    }
    final context = normalizeContextPath(_context.text);
    if (context == null) {
      setState(() => _error = '上下文路径必须以 / 开头');
      return;
    }
    final plan = buildJavaWebScaffold(
      profile: _profile,
      packageName: report.config?.packageName ?? '',
      port: port,
      contextPath: context,
      webRoot: _webRoot.text.trim(),
      existingPaths: report.existingPaths,
      // The plan remembers its own destination, so a later write can refuse it.
      projectRoot: path,
      // Only the Boot line has auto-config. A javaee8 project manages its own
      // pool, so the switch does not silently add Spring keys there.
      includeDatabase: _includeDatabase && _profile == javaWebProfileSpringBoot,
    );
    setState(() {
      _error = null;
      _plan = plan;
    });
  }

  Future<void> _applyScaffold() async {
    final plan = _plan;
    final path = _project.text.trim();
    if (plan == null || !plan.canApply || path.isEmpty) {
      return;
    }
    // The destination must be the directory the plan was built for.
    if (plan.projectRoot != path) {
      setState(() {
        _plan = null;
        _report = null;
        _error = '计划与当前项目不一致，请重新生成计划';
      });
      return;
    }
    final revision = _revision;
    final target = plan.projectRoot;
    setState(() {
      _pending++;
      _error = null;
    });
    try {
      // The write is bound to the captured directory, never to the current one.
      await _source.writeScaffold(target, plan);
      if (!mounted) {
        return;
      }
      // The notice names the captured directory, so it can never read as a
      // success for a project the user has since switched to.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已为 $target 创建 ${plan.files.length} 个环境文件')),
      );
      // Only touch the view when that directory is still the one on screen.
      if (revision == _revision && target == _project.text.trim()) {
        setState(() => _plan = null);
        await _inspect();
      }
    } on Object catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _error = '创建失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          if (_pending > 0) {
            _pending--;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return ToolScaffold(
      title: JavaWebEnvironmentPage.title,
      description: '检查离线包与项目配置，按需创建环境脚手架',
      children: [
        _projectField(),
        if (_error != null) ToolError(_error),
        if (_busy) const LinearProgressIndicator(),
        if (report == null)
          const ToolResultCard(children: [Text('尚未检查项目。请选择本地项目后点击检查。')])
        else ...[
          _environmentCard(report),
          _packCard(report),
          _runPathCard(report),
          _scaffoldCard(),
        ],
      ],
    );
  }

  Widget _projectField() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: ToolField(
              controller: _project,
              label: '项目目录',
              hint: '/path/to/project',
              monospace: true,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _busy ? null : _inspect,
            child: const Text('检查'),
          ),
        ],
      ),
      if (_localProjects.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final project in _localProjects)
                ActionChip(
                  label: Text(project.name),
                  onPressed: _busy
                      ? null
                      : () {
                          _project.text = project.path;
                          _inspect();
                        },
                ),
            ],
          ),
        ),
    ],
  );

  Widget _environmentCard(JavaWebEnvironmentReport report) {
    final snapshot = report.config;
    return ToolResultCard(
      title: '环境状态',
      children: [
        ResultRow(label: '状态', value: report.statusLine),
        ResultRow(label: '配置文件', value: report.hasConfigFile ? '已找到' : '未找到'),
        if (snapshot != null) ...[
          ResultRow(label: 'profile', value: snapshot.profile),
          ResultRow(label: '主类', value: snapshot.mainClass ?? '按 profile 默认'),
          ResultRow(
            label: '配置地址',
            value: snapshot.localAddress,
            allowCopy: true,
          ),
        ],
        if (report.configIssues.isNotEmpty) ...[
          const Divider(),
          for (final issue in report.configIssues)
            ResultRow(label: issue.code, value: issue.message),
        ],
      ],
    );
  }

  Widget _packCard(JavaWebEnvironmentReport report) {
    final pack = report.pack;
    final version = pack.boot3Version;
    return ToolResultCard(
      title: '离线包清单',
      children: [
        ResultRow(
          label: 'Spring Boot 3',
          value: pack.boot3
              ? (version == null ? '有包' : '有包，版本 $version')
              : '无包',
        ),
        ResultRow(
          label: 'jakarta Servlet',
          value: pack.jakartaContainer ? '有包' : '无包',
        ),
        ResultRow(
          label: 'javax Servlet（JavaEE8）',
          value: pack.javaee8 ? '有包' : '无包',
        ),
        ResultRow(label: 'JSP', value: pack.jsp ? '有包' : '无包'),
        ResultRow(label: 'JDBC 依赖（随包提供）', value: pack.jdbc ? '有包' : '无包'),
        ResultRow(
          label: '本项目已启用数据库',
          value: report.config?.databaseEnabled == true ? '是' : '否',
        ),
        if (report.missingComponents.isNotEmpty)
          ResultRow(label: '缺口', value: report.missingComponents.join('、')),
        if (report.hasPackConflict)
          const ResultRow(label: '命名空间', value: '包与 profile 的命名空间不一致'),
        const Divider(),
        Text(
          '以上只是包清单。它不表示服务能启动，也不表示已响应。'
          '数据库由 qflisql 外部提供，此处不含地址与口令。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// Shows the real entry file and the editor action that starts the service.
  ///
  /// This page never carries its own Run/Stop, and the editor owns Stop.
  Widget _runPathCard(JavaWebEnvironmentReport report) {
    final snapshot = report.config;
    final entry = snapshot == null
        ? null
        : javaWebEntryRelativePath(
            profile: snapshot.profile,
            packageName: snapshot.packageName,
            mainClass: snapshot.mainClass,
          );
    return ToolResultCard(
      title: '运行入口',
      children: [
        if (entry != null) ...[
          ResultRow(label: '入口文件', value: entry, allowCopy: true),
          Text(
            '在编辑器中打开该入口文件。点击运行。\n'
            '停止由编辑器与终端负责。本页不重复提供运行或停止。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (snapshot?.profile == javaWebProfileJavaee8)
            Text(
              'JavaEE8 由 Tomcat 9 容器启动器部署。编辑器运行会加载该容器。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ] else
          const Text('配置解码后会显示 Java 入口文件。'),
        const Divider(),
        ResultRow(label: '本地响应', value: report.reachable ? '端口有响应' : '未验证'),
        Text(
          '本地响应只说明端口有应答。它不代表本项目已就绪。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: _busy ? null : _checkResponse,
            child: const Text('检查本地响应'),
          ),
        ),
      ],
    );
  }

  Widget _scaffoldCard() {
    final plan = _plan;
    return ToolResultCard(
      title: '创建环境脚手架',
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey(_profile),
          initialValue: _profile,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'profile'),
          items: [
            for (final profile in javaWebProfiles)
              DropdownMenuItem(value: profile, child: Text(profile)),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) {
                    setState(() => _profile = value);
                  }
                },
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('include-database'),
          value: _includeDatabase,
          contentPadding: EdgeInsets.zero,
          title: const Text('加载 JDBC 与 MyBatis'),
          subtitle: const Text('需要真实的 qflisql 端点，本页不填地址与口令'),
          onChanged: _busy
              ? null
              : (value) => setState(() => _includeDatabase = value),
        ),
        ToolField(controller: _port, label: '端口', hint: '8080'),
        ToolField(controller: _context, label: '上下文路径', hint: '/'),
        ToolField(
          controller: _webRoot,
          label: 'webRoot',
          hint: 'src/main/webapp',
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: _busy ? null : _planScaffold,
            child: const Text('生成计划'),
          ),
        ),
        if (plan != null) ...[
          const Divider(),
          if (plan.blocked != null) ToolError(plan.blocked),
          if (plan.files.isNotEmpty)
            ResultRow(
              label: '将新建',
              value: '${plan.files.length} 个文件、${plan.directories.length} 个目录',
            ),
          for (final file in plan.files)
            ResultRow(label: '新建', value: file.path),
          for (final directory in plan.directories)
            ResultRow(label: '目录', value: directory),
          for (final skipped in plan.skippedExisting)
            ResultRow(label: '保留', value: skipped),
          const Divider(),
          Text(
            '脚手架是环境结构，不是作业内容。已有文件一律保留。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: plan.canApply && !_busy ? _applyScaffold : null,
            child: const Text('确认创建'),
          ),
        ],
      ],
    );
  }
}
