import 'dart:convert';

import 'java_web_project.dart';
import 'spring_boot_bundle.dart';

/// Configuration file name for a Java web project.
///
/// Re-exported from the one decoder, `java_web_project.dart`. This module never
/// parses the config document.
const String javaWebConfigFileName = JavaWebProject.configFileName;

/// Wire profile names, taken from the one decoder.
const String javaWebProfileSpringBoot = JavaWebProject.profileSpringBoot;
const String javaWebProfileJavaee8 = JavaWebProject.profileJavaee8;
final List<String> javaWebProfiles = JavaWebProject.knownProfiles;

/// Pack directories, from p4's lock files. `assets/javaee8` is the javaee8
/// pack declared by `tools/javaee8.lock.json`. Boot 3 lives under
/// `assets/spring_boot` and is read through `SpringBootBundle`.
const List<String> javaWebPackDirectories = <String>[
  'assets/javaee8',
  'assets/javaee',
  'native/javaee8/libs',
];

/// True when [profile] is one of the two contract profiles.
bool isJavaWebProfile(String? profile) =>
    JavaWebProject.isKnownProfile(profile);

/// A refused or suspicious input, reported instead of silently repaired.
class JavaWebIssue {
  const JavaWebIssue(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Delegates to the one decoder. Kept as a thin alias so callers have one name.
///
/// Empty returns null because the decoder owns the default, not this module.
String? normalizeContextPath(String raw) =>
    JavaWebProject.normalizeContextPath(raw.trim());

/// What the actual offline pack contains, by file name.
///
/// This is a listing. It says which jars exist. It does not say that a server
/// can start, and it never decides readiness.
class JavaWebPack {
  const JavaWebPack({
    this.boot3 = false,
    this.jakartaContainer = false,
    this.json = false,
    this.jsp = false,
    this.jdbc = false,
    this.persistence = false,
    this.javaee8 = false,
    this.jars = const <String>[],
    this.boot3Version,
    this.metadataAvailable = false,
  });

  const JavaWebPack.empty()
    : boot3 = false,
      jakartaContainer = false,
      json = false,
      jsp = false,
      jdbc = false,
      persistence = false,
      javaee8 = false,
      jars = const <String>[],
      boot3Version = null,
      metadataAvailable = false;

  final bool boot3;

  /// A jakarta Servlet container: the Boot pack's servlet role.
  final bool jakartaContainer;

  /// The Boot pack carries the JSON stack.
  final bool json;
  final bool jsp;

  /// A JDBC driver or Spring JDBC is present. Discovery is not a connection.
  final bool jdbc;

  /// A MyBatis mapper runtime is present.
  final bool persistence;

  /// A legacy javax Servlet container: the javaee8 pack's servlet role.
  final bool javaee8;
  final List<String> jars;

  /// Pack version from p4 metadata. Never parsed from a file name.
  final String? boot3Version;

  /// True when p4 metadata was read. False means unknown, not absent.
  final bool metadataAvailable;

  bool get any => boot3 || jakartaContainer || jsp || jdbc || javaee8;

  /// Which profile the available jars could serve. Listing only.
  ///
  /// A true value is a packaging statement, not an operational one.
  bool canServe(String? profile) => switch (profile) {
    javaWebProfileSpringBoot => boot3 && jakartaContainer,
    javaWebProfileJavaee8 => javaee8,
    _ => false,
  };

  /// Adapter over p4's role metadata, the only capability source.
  ///
  /// A null capability means the pack metadata could not be read, so the flag
  /// stays unknown instead of becoming a guess about the file names.
  factory JavaWebPack.fromCapabilities({
    JavaEePackCapabilities? springBoot,
    JavaEePackCapabilities? javaee8,
    Iterable<String> jars = const <String>[],
    String? boot3Version,
  }) {
    final boot = springBoot;
    final ee = javaee8;
    return JavaWebPack(
      boot3: boot?.web ?? false,
      jakartaContainer: boot?.servlet ?? false,
      json: boot?.json ?? false,
      jsp: ee?.jsp ?? false,
      jdbc: (boot?.jdbc ?? false) || (ee?.jdbc ?? false),
      persistence: boot?.persistence ?? false,
      javaee8: ee?.servlet ?? false,
      jars: List<String>.unmodifiable(jars),
      boot3Version: boot3Version,
      metadataAvailable: boot != null || ee != null,
    );
  }

  /// Reads p4's verified hashed manifest when a caller already holds it.
  ///
  /// Roles come from the manifest, never from a file name.
  static JavaWebPack fromManifest(Object? json) {
    if (json is! Map || json['files'] is! List) {
      return const JavaWebPack.empty();
    }
    final files = (json['files'] as List).whereType<Map>().toList(
      growable: false,
    );
    final names = <String>[
      for (final file in files)
        if (file['file'] is String) file['file'] as String,
    ];
    final roles = <String>{
      for (final file in files)
        if (file['role'] is String) file['role'] as String,
    };
    final namespace = json['namespace'] is String
        ? json['namespace'] as String
        : '';
    final packId = json['packId'] is String ? json['packId'] as String : '';
    final javax = namespace.contains('javax.servlet');
    final jakarta = namespace.contains('jakarta.servlet');
    return JavaWebPack(
      boot3: packId == 'spring-boot',
      jakartaContainer: jakarta || roles.contains('jakarta-container'),
      jsp: roles.contains('jsp'),
      jdbc: roles.contains('jdbc'),
      javaee8: javax || roles.contains('servlet'),
      jars: List<String>.unmodifiable(names..sort()),
    );
  }
}

/// The configured shape of one project, supplied by the p3 decoder.
///
/// Plain primitives so this module needs no project type and no decoder.
class JavaWebConfigSnapshot {
  const JavaWebConfigSnapshot({
    required this.profile,
    required this.mainClass,
    required this.port,
    required this.contextPath,
    required this.webRoot,
    this.isLaunchReady = false,
    this.launchBlockedReason,
    this.databaseEnabled = false,
  });

  /// Adapter from the one decoder, for consumers such as the p5 launcher.
  ///
  /// This is not a decoder. It copies already validated fields.
  factory JavaWebConfigSnapshot.fromProject(JavaWebProject project) =>
      JavaWebConfigSnapshot(
        profile: project.profile,
        mainClass: project.mainClass,
        port: project.port,
        contextPath: project.contextPath,
        webRoot: project.webRoot,
        isLaunchReady: project.isLaunchReady,
        launchBlockedReason: project.launchBlockedReason,
        databaseEnabled: project.databaseEnabled,
      );

  /// Mirrors the decoder's optional `database` flag (schemaVersion 1 additive).
  ///
  /// False by default. A Boot project without a qflisql endpoint must stay
  /// false, or JDBC/Hikari auto-configuration fails on a missing URL.
  final bool databaseEnabled;

  final String profile;
  final String? mainClass;
  final int port;
  final String contextPath;
  final String webRoot;

  /// Mirrors the decoder's answer about the run path.
  final bool isLaunchReady;
  final String? launchBlockedReason;

  /// Normalized context prefix: empty for the root context, else `/name`.
  String get contextPrefix => contextPath == '/' ? '' : contextPath;

  /// Configured address. Not a proven one until a response arrives.
  String get localAddress => 'http://127.0.0.1:$port$contextPath';

  /// Configured health path, joined without a double slash.
  String get healthPath => '$contextPrefix/health';

  String get packageName {
    final value = mainClass;
    if (value == null) {
      return '';
    }
    final index = value.lastIndexOf('.');
    return index <= 0 ? '' : value.substring(0, index);
  }
}

/// Relative path of the Java entry file a user opens before pressing Run.
///
/// Boot uses its `main` class. JavaEE8 uses the deployed servlet source, which
/// the Tomcat 9 launcher loads; neither is started from this page.
String javaWebEntryRelativePath({
  required String profile,
  required String packageName,
  String? mainClass,
}) {
  final declared = mainClass?.trim();
  final parts = (declared == null || declared.isEmpty)
      ? const <String>[]
      : declared.split('.');
  final simple = parts.isEmpty
      ? (profile == javaWebProfileJavaee8 ? 'HelloServlet' : 'WebApplication')
      : parts.last;
  // A qualified main class already carries its package, so prefer it.
  final fromMain = parts.length > 1
      ? parts.sublist(0, parts.length - 1).join('.')
      : '';
  final pkg = fromMain.isNotEmpty ? fromMain : packageName.trim();
  final directory = pkg.isEmpty
      ? 'src/main/java'
      : 'src/main/java/${pkg.replaceAll('.', '/')}';
  return '$directory/$simple.java';
}

/// Configured loopback health URI for [snapshot].
///
/// Built from host/port/path parts, so the root context yields `/health` and
/// `/demo` yields `/demo/health`. Never `//health`.
Uri javaWebHealthUri(JavaWebConfigSnapshot snapshot) => Uri(
  scheme: 'http',
  host: '127.0.0.1',
  port: snapshot.port,
  path: snapshot.healthPath,
);

/// True when [uri] is a plain-http loopback address, the only probe target.
bool isLoopbackHttp(Uri uri) {
  if (uri.scheme != 'http') {
    return false;
  }
  const loopbackHosts = <String>{'127.0.0.1', 'localhost', '::1', '[::1]'};
  return loopbackHosts.contains(uri.host.toLowerCase());
}

/// One full inspection: config from p3, pack from p4, reachability from a probe.
class JavaWebEnvironmentReport {
  const JavaWebEnvironmentReport({
    required this.projectPath,
    required this.config,
    required this.configIssues,
    required this.pack,
    required this.existingPaths,
    required this.hasConfigFile,
    this.reachable = false,
  });

  final String projectPath;
  final JavaWebConfigSnapshot? config;
  final List<JavaWebIssue> configIssues;
  final JavaWebPack pack;
  final Set<String> existingPaths;
  final bool hasConfigFile;

  /// True only when a bounded HTTP response arrived from the loopback target.
  ///
  /// This is reachability, not readiness. Another process on the port also
  /// answers. It is never derived from a jar name, a log line or a process.
  final bool reachable;

  JavaWebEnvironmentReport withReachable(bool value) =>
      JavaWebEnvironmentReport(
        projectPath: projectPath,
        config: config,
        configIssues: configIssues,
        pack: pack,
        existingPaths: existingPaths,
        hasConfigFile: hasConfigFile,
        reachable: value,
      );

  /// Honest one-line status.
  String get statusLine {
    final value = config;
    if (value == null && !hasConfigFile) {
      return '尚未配置 JavaEE 环境';
    }
    if (value == null) {
      return '配置无法解码，共 ${configIssues.length} 个问题';
    }
    if (reachable) {
      return '本机端口有响应，未确认由本项目提供';
    }
    if (!pack.canServe(value.profile)) {
      return '离线包缺少 ${value.profile} 运行组件';
    }
    return '配置已就绪，尚未启动服务';
  }

  /// Missing pieces stated as facts about the pack.
  List<String> get missingComponents {
    final missing = <String>[];
    final profile = config?.profile;
    if (profile == javaWebProfileSpringBoot) {
      if (!pack.boot3) {
        missing.add('Spring Boot 3');
      }
      if (!pack.jakartaContainer) {
        missing.add('jakarta Servlet');
      }
    }
    if (profile == javaWebProfileJavaee8 && !pack.javaee8) {
      missing.add('javax Servlet/JSP 包');
    }
    if (!pack.jsp) {
      missing.add('JSP 引擎');
    }
    if (!pack.jdbc) {
      missing.add('JDBC 驱动');
    }
    return missing;
  }

  bool get hasPackConflict {
    final profile = config?.profile;
    if (profile == javaWebProfileJavaee8) {
      return pack.jakartaContainer && !pack.javaee8;
    }
    if (profile == javaWebProfileSpringBoot) {
      return pack.javaee8 && !pack.jakartaContainer;
    }
    return false;
  }
}

/// Builds a report from primitives. Pure: no file access happens here.
JavaWebEnvironmentReport buildJavaWebReport({
  required String projectPath,
  required JavaWebConfigSnapshot? config,
  required List<JavaWebIssue> configIssues,
  required Iterable<String> projectPaths,
  required JavaWebPack pack,
  required bool hasConfigFile,
  bool reachable = false,
}) => JavaWebEnvironmentReport(
  projectPath: projectPath,
  config: config,
  configIssues: configIssues,
  pack: pack,
  existingPaths: projectPaths.map((path) => path.replaceAll('\\', '/')).toSet(),
  hasConfigFile: hasConfigFile,
  reachable: reachable,
);

/// Returns the planned paths that must not be written.
///
/// Pure. It rejects an absolute path, a drive or UNC prefix, a `..` segment,
/// and any path that resolves outside [projectRoot]. Symlink escapes are the
/// writer's job, because they need real file-system state.
List<String> javaWebScaffoldViolations({
  required String projectRoot,
  required Iterable<String> plannedPaths,
}) {
  final violations = <String>[];
  final root = projectRoot.replaceAll('\\', '/');
  for (final raw in plannedPaths) {
    final path = raw.replaceAll('\\', '/');
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains(':') ||
        path.startsWith('//')) {
      violations.add(raw);
      continue;
    }
    final segments = path.split('/');
    if (segments.any((segment) => segment == '..' || segment.isEmpty)) {
      violations.add(raw);
      continue;
    }
    if (!('$root/$path').startsWith('$root/')) {
      violations.add(raw);
    }
  }
  return violations;
}

/// One file a scaffold would write.
class JavaWebScaffoldFile {
  const JavaWebScaffoldFile(this.path, this.content);

  final String path;
  final String content;
}

/// Result of planning a scaffold. Existing project files are never overwritten.
class JavaWebScaffoldPlan {
  const JavaWebScaffoldPlan({
    required this.projectRoot,
    required this.files,
    required this.directories,
    required this.skippedExisting,
    required this.blocked,
  });

  /// The directory this plan was built for, captured when it was built.
  ///
  /// A writer must refuse the plan when this no longer matches its destination,
  /// so a plan built for one project can never land in another.
  final String projectRoot;

  final List<JavaWebScaffoldFile> files;
  final List<String> directories;
  final List<String> skippedExisting;
  final String? blocked;

  bool get canApply => blocked == null && files.isNotEmpty;
}

/// Builds an environment scaffold for [profile].
///
/// Boot3 emits a main entry, a root `/health` route and a root `/form` route on
/// the jakarta line. JavaEE8 emits a real `javax.servlet.http.HttpServlet` plus
/// a JSP form and `web.xml`, to be deployed by the Tomcat 9 launcher. Neither
/// carries exercise content, a homework table or a baked credential, and
/// [webRoot] is honoured rather than assumed.
JavaWebScaffoldPlan buildJavaWebScaffold({
  required String profile,
  required String packageName,
  required int port,
  required String contextPath,
  required String webRoot,
  required Iterable<String> existingPaths,
  required String projectRoot,
  bool includeDatabase = false,
}) {
  final existing = existingPaths
      .map((path) => path.replaceAll('\\', '/'))
      .toSet();
  final root = webRoot.trim().isEmpty ? 'src/main/webapp' : webRoot.trim();
  final boot = profile == javaWebProfileSpringBoot;

  // An empty package would emit `package ;`. A neutral default keeps the
  // generated Java valid, and the plan shows the path before any write.
  final pkg = packageName.isEmpty ? 'com.example.web' : packageName;
  final base = 'src/main/java/${pkg.replaceAll('.', '/')}';

  String apply(String template) => template
      .replaceAll('__PKG__', pkg)
      .replaceAll('__PORT__', '$port')
      .replaceAll('__CONTEXT__', contextPath)
      .replaceAll('__WEBROOT__', root)
      .replaceAll(
        '__DB_BLOCK__',
        includeDatabase ? _databaseEnabledBlock : _databaseDisabledBlock,
      );

  final configContent = const JsonEncoder.withIndent('  ').convert(
    <String, Object?>{
      'schemaVersion': 1,
      'profile': profile,
      'mainClass': boot ? '$pkg.WebApplication' : '$pkg.HelloServlet',
      'port': port,
      'contextPath': contextPath,
      'webRoot': root,
      // Additive schemaVersion 1 key. Omitted when false so a reload
      // yields the same document.
      if (includeDatabase) 'database': true,
    },
  );

  final planned = <JavaWebScaffoldFile>[
    if (boot) ...[
      JavaWebScaffoldFile(
        '$base/WebApplication.java',
        apply(_bootMainTemplate),
      ),
      JavaWebScaffoldFile(
        '$base/HealthController.java',
        apply(_bootHealthTemplate),
      ),
      JavaWebScaffoldFile(
        '$base/FormBindingController.java',
        apply(_bootFormTemplate),
      ),
      JavaWebScaffoldFile(
        'src/main/resources/application.properties',
        apply(_applicationPropertiesTemplate),
      ),
    ] else ...[
      JavaWebScaffoldFile('$base/HelloServlet.java', apply(_javaee8Servlet)),
      JavaWebScaffoldFile('$root/index.jsp', apply(_javaee8Jsp)),
      JavaWebScaffoldFile('$root/WEB-INF/web.xml', apply(_javaee8WebXml)),
    ],
    JavaWebScaffoldFile(
      javaWebConfigFileName,
      '$configContent\n',
    ),
  ];

  final skipped = <String>[];
  final writable = <JavaWebScaffoldFile>[];
  for (final file in planned) {
    if (existing.contains(file.path)) {
      skipped.add(file.path);
    } else {
      writable.add(file);
    }
  }

  return JavaWebScaffoldPlan(
    projectRoot: projectRoot,
    files: List<JavaWebScaffoldFile>.unmodifiable(writable),
    directories: List<String>.unmodifiable(<String>[
      if (!existing.contains(base)) base,
      if (boot) ...[
        if (!existing.contains('src/main/resources')) 'src/main/resources',
      ] else ...[
        '$base/controller',
        '$base/service',
        '$base/mapper',
        '$base/entity',
        if (!existing.contains('$root/WEB-INF')) '$root/WEB-INF',
      ],
    ]),
    skippedExisting: List<String>.unmodifiable(skipped),
    blocked: skipped.isEmpty ? null : '目标文件已存在，拒绝覆盖。请另建目录或先移走旧文件。',
  );
}

// Boot3 line: jakarta namespace only. Routes sit at the root.
const String _bootMainTemplate = r'''package __PKG__;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Environment entry point. Generated by qfli studio, not exercise content.
 */
@SpringBootApplication
public class WebApplication {

    public static void main(String[] args) {
        SpringApplication.run(WebApplication.class, args);
    }
}
''';

const String _bootHealthTemplate = r'''package __PKG__;

import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Health route at /health. Reports process liveness only.
 * It does not touch a database.
 */
@RestController
public class HealthController {

    @GetMapping("/health")
    public Map<String, Object> health() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", "ok");
        return body;
    }
}
''';

const String _bootFormTemplate = r'''package __PKG__;

import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Form binding route at /form. Echoes submitted fields so binding is visible.
 * No table, no entity and no credential belongs here.
 */
@RestController
public class FormBindingController {

    @PostMapping("/form")
    public Map<String, String> submit(@RequestParam Map<String, String> fields) {
        return new LinkedHashMap<>(fields);
    }
}
''';

const String _applicationPropertiesTemplate = r'''server.address=127.0.0.1
server.port=__PORT__
server.servlet.context-path=__CONTEXT__
spring.main.banner-mode=off
# 数据库由 qflisql 外部提供，本脚手架不含真实地址与口令。
__DB_BLOCK__
''';

/// Default Boot scaffold: web and JSON only, so no DataSource auto-config runs.
/// A datasource without a URL fails at startup.
const String _databaseDisabledBlock =
    r'''# 本环境只加载 Web 与 JSON，不启用 JDBC 与 MyBatis。
# 需要数据库时打开“加载 JDBC 与 MyBatis”，再填写 qflisql 端点。
''';

/// Opt-in database block. Every value stays a comment, so no credential, host
/// or port is invented. The owner of qflisql supplies the real endpoint.
const String _databaseEnabledBlock = r'''# 已选择加载 JDBC 与 MyBatis。
# 下列键需要填入真实 qflisql 端点后再取消注释。
# spring.datasource.url=jdbc:mysql://<qflisql-host>:<port>/<schema>
# spring.datasource.username=<user>
# spring.datasource.password=<password>
# 未填写前，应用不连接任何数据库。
''';

// JavaEE8 line: javax namespace only. Deployed by the Tomcat 9 launcher.
const String _javaee8Servlet = r'''package __PKG__;

import java.io.IOException;
import java.io.PrintWriter;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

/**
 * Generic environment servlet. Generated by qfli studio, not exercise content.
 * Deployed by a real container. Database stays external, owned by qflisql.
 */
public class HelloServlet extends HttpServlet {

    private static final long serialVersionUID = 1L;

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws ServletException, IOException {
        response.setContentType("text/html; charset=UTF-8");
        try (PrintWriter out = response.getWriter()) {
            out.println("<!DOCTYPE html>");
            out.println("<html lang=\"zh\"><head><meta charset=\"UTF-8\">");
            out.println("<title>JavaEE 环境</title></head><body>");
            out.println("<h1>JavaEE 环境</h1>");
            out.println("<p>Servlet 已部署。</p>");
            out.println("</body></html>");
        }
    }

    @Override
    protected void doPost(HttpServletRequest request, HttpServletResponse response)
            throws ServletException, IOException {
        request.setCharacterEncoding("UTF-8");
        response.setContentType("text/plain; charset=UTF-8");
        try (PrintWriter out = response.getWriter()) {
            request.getParameterMap().forEach((key, values) -> {
                out.println(key + "=" + String.join(",", values));
            });
        }
    }
}
''';

const String _javaee8Jsp =
    r'''<%@ page contentType="text/html; charset=UTF-8" pageEncoding="UTF-8" %>
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <title>JavaEE 环境</title>
</head>
<body>
<!-- Database stays external and is owned by qflisql. -->
<h1>JavaEE 环境</h1>
<p>Servlet 入口：<a href="${pageContext.request.contextPath}/hello">/hello</a></p>
<form method="post" action="${pageContext.request.contextPath}/hello">
    <label>字段名 <input name="name"></label>
    <label>字段值 <input name="value"></label>
    <button type="submit">提交</button>
</form>
</body>
</html>
''';

const String _javaee8WebXml = r'''<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="http://xmlns.jcp.org/xml/ns/javaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://xmlns.jcp.org/xml/ns/javaee
                             http://xmlns.jcp.org/xml/ns/javaee/web-app_4_0.xsd"
         version="4.0">

    <display-name>JavaEE 环境</display-name>

    <servlet>
        <servlet-name>hello</servlet-name>
        <servlet-class>__PKG__.HelloServlet</servlet-class>
    </servlet>

    <servlet-mapping>
        <servlet-name>hello</servlet-name>
        <url-pattern>/hello</url-pattern>
    </servlet-mapping>

    <welcome-file-list>
        <welcome-file>index.jsp</welcome-file>
    </welcome-file-list>
</web-app>
''';
