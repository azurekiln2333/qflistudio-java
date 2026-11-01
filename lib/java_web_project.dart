import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Reported when `.qfli-java-web.json` exists but cannot be used.
///
/// The decoder never repairs a bad document silently. Callers show [code] and
/// [message] and refuse to run.
class JavaWebProjectException implements Exception {
  const JavaWebProjectException(this.code, this.message);

  /// Stable machine code, for example `invalid-port`.
  final String code;

  /// Human-readable reason, safe to show next to [code].
  final String message;

  @override
  String toString() => '$code: $message';
}

/// The one decoder for `.qfli-java-web.json`.
///
/// Authoritative schema (contract
/// `research/javaee-environment-contract-20261026.md`):
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "profile": "spring-boot",
///   "mainClass": "example.Application",
///   "port": 8080,
///   "contextPath": "/",
///   "webRoot": "src/main/webapp"
/// }
/// ```
///
/// An absent file returns null from [load]. A present but invalid document
/// throws [JavaWebProjectException]. Ordinary Java projects are unaffected:
/// they simply have no config file.
@immutable
class JavaWebProject {
  const JavaWebProject._({
    required this.projectRoot,
    required this.schemaVersion,
    required this.profile,
    required this.mainClass,
    required this.port,
    required this.contextPath,
    required this.webRoot,
    required this.database,
  });

  /// Configuration file name inside a project directory.
  static const String configFileName = '.qfli-java-web.json';

  /// Only schema version handled now.
  static const int currentSchemaVersion = 1;

  /// Boot 3 line: jakarta namespace, embedded Tomcat 10.
  static const String profileSpringBoot = 'spring-boot';

  /// Java EE 8 line: legacy javax Servlet/JSP, served by a Tomcat 9 launcher.
  static const String profileJavaee8 = 'javaee8';

  /// Profiles this decoder accepts. Anything else is refused.
  static const List<String> knownProfiles = <String>[
    profileSpringBoot,
    profileJavaee8,
  ];

  static const int defaultPort = 8080;
  static const String defaultContextPath = '/';
  static const String defaultWebRoot = 'src/main/webapp';

  /// A Web project runs without a data source unless it asks for one.
  static const bool defaultDatabase = false;

  /// Absolute, normalized project directory.
  final String projectRoot;

  final int schemaVersion;
  final String profile;

  /// Java binary name of the entry class, or null to derive from the entry
  /// source at run time.
  final String? mainClass;

  final int port;
  final String contextPath;

  /// Project-relative web root, using `/` separators.
  final String webRoot;

  /// True when the project asked for the JDBC, connection-pool and mapper
  /// dependency group. It is false unless the document says otherwise, because
  /// those libraries make Spring Boot build a data source at startup.
  final bool database;

  /// Named form of [database], for callers that read a flag rather than a field.
  bool get databaseEnabled => database;

  /// True when [profile] is one of [knownProfiles].
  static bool isKnownProfile(String? profile) =>
      profile != null && knownProfiles.contains(profile);

  /// Reads the config of [projectPath].
  ///
  /// Returns null when the file is absent. Throws
  /// [JavaWebProjectException] when the file exists but is invalid, or when
  /// [projectPath] is empty.
  static Future<JavaWebProject?> load(String projectPath) async {
    if (projectPath.trim().isEmpty) {
      throw const JavaWebProjectException('invalid-project-path', '项目路径为空。');
    }
    final root = p.normalize(p.absolute(projectPath));
    final configPath = p.join(root, configFileName);
    final type = await FileSystemEntity.type(configPath);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw JavaWebProjectException(
        'invalid-config-entry',
        '$configFileName 不是普通文件。',
      );
    }

    final String text;
    try {
      text = await File(configPath).readAsString();
    } on FileSystemException catch (error) {
      throw JavaWebProjectException(
        'unreadable-config',
        '$configFileName 无法读取：${error.message}',
      );
    }

    final Object? decoded;
    try {
      // A UTF-8 byte order mark must not break jsonDecode.
      decoded = jsonDecode(
        text.startsWith('\uFEFF') ? text.substring(1) : text,
      );
    } on FormatException catch (error) {
      throw JavaWebProjectException(
        'malformed-json',
        '$configFileName 不是合法 JSON：${error.message}',
      );
    }
    return fromJson(decoded, projectRoot: root);
  }

  /// Decodes an already parsed JSON document.
  ///
  /// Kept separate from [load] so tests and callers can validate a document
  /// without touching the file system.
  static JavaWebProject fromJson(Object? json, {required String projectRoot}) {
    final root = p.normalize(p.absolute(projectRoot));
    if (json is! Map) {
      throw const JavaWebProjectException(
        'config-not-object',
        '配置根必须是 JSON 对象。',
      );
    }
    final map = <String, Object?>{
      for (final entry in json.entries) '${entry.key}': entry.value,
    };

    final schemaVersion = map['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != currentSchemaVersion) {
      throw JavaWebProjectException(
        'unsupported-schema-version',
        'schemaVersion 必须是 $currentSchemaVersion，实际为 $schemaVersion。',
      );
    }

    final profile = map['profile'];
    if (profile is! String || !isKnownProfile(profile)) {
      throw JavaWebProjectException(
        'unsupported-profile',
        'profile 必须是 ${knownProfiles.join(' 或 ')}，实际为 $profile。',
      );
    }

    final mainClass = _decodeMainClass(map['mainClass']);
    final port = _decodePort(map['port']);
    final contextPath = _decodeContextPath(map['contextPath']);
    final webRoot = _decodeWebRoot(map['webRoot'], root);
    final database = _decodeDatabase(map['database']);

    return JavaWebProject._(
      projectRoot: root,
      schemaVersion: schemaVersion,
      profile: profile,
      mainClass: mainClass,
      port: port,
      contextPath: contextPath,
      webRoot: webRoot,
      database: database,
    );
  }

  /// Canonical document. Omits [mainClass] when it is null so a reload yields
  /// the same instance.
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'profile': profile,
    if (mainClass != null) 'mainClass': mainClass,
    'port': port,
    'contextPath': contextPath,
    'webRoot': webRoot,
    'database': database,
  };

  /// Configured loopback address. It is not proven until a response arrives.
  String get localAddress => 'http://127.0.0.1:$port$contextPath';

  /// Package part of [mainClass], or empty when there is none.
  String get packageName {
    final value = mainClass;
    if (value == null) return '';
    final index = value.lastIndexOf('.');
    return index <= 0 ? '' : value.substring(0, index);
  }

  /// True when this profile uses the jakarta namespace (Boot 3 line).
  bool get usesJakartaNamespace => profile == profileSpringBoot;

  /// True when this profile uses the legacy javax namespace (Java EE 8 line).
  bool get usesJavaxNamespace => profile == profileJavaee8;

  /// Main source root, the Maven/Gradle `src/main/java` tree.
  String get mainSourceRoot => p.join(projectRoot, 'src', 'main', 'java');

  /// Deployable resources root, the Maven/Gradle `src/main/resources` tree.
  String get resourcesRoot => p.join(projectRoot, 'src', 'main', 'resources');

  /// Absolute web root, resolved under [projectRoot].
  String get webRootPath =>
      p.joinAll(<String>[projectRoot, ...webRoot.split('/')]);

  /// True when this decoded config can be handed to a launcher.
  ///
  /// Both profiles decode into a usable config. Whether the container JARs for
  /// `javaee8` exist is a runtime fact the runner checks, because this module
  /// never inspects files it was not given.
  bool get isLaunchReady => knownProfiles.contains(profile);

  /// Why [isLaunchReady] is false, or null when it is true.
  ///
  /// Always null for an accepted profile: a decoded config is not a promise
  /// that the container pack exists, and the runner reports that separately.
  String? get launchBlockedReason =>
      isLaunchReady ? null : 'profile $profile 不是已知的运行画像。';

  /// Normalizes a context path. Returns null when [raw] is unusable.
  ///
  /// `/` stays `/`. `/demo/` becomes `/demo`. `demo` returns null because a
  /// context path must be slash-prefixed.
  static String? normalizeContextPath(String raw) {
    if (raw.isEmpty) return null;
    if (raw.contains(RegExp(r'[\\?#\s]'))) return null;
    if (!raw.startsWith('/')) return null;
    final segments = <String>[];
    for (final segment in raw.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') return null;
      segments.add(segment);
    }
    return segments.isEmpty ? '/' : '/${segments.join('/')}';
  }

  /// Normalizes a project-relative web root. Returns null when unusable.
  static String? normalizeWebRoot(String raw) {
    if (raw.trim().isEmpty) return null;
    final value = raw.replaceAll('\\', '/').trim();
    if (value.startsWith('/') || value.contains(':')) return null;
    final segments = <String>[];
    for (final segment in value.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') return null;
      segments.add(segment);
    }
    return segments.isEmpty ? null : segments.join('/');
  }

  static String? _decodeMainClass(Object? value) {
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw const JavaWebProjectException(
        'invalid-main-class',
        'mainClass 必须是字符串。',
      );
    }
    if (value != value.trim() || value.contains(RegExp(r'[\\/:;\s]'))) {
      throw const JavaWebProjectException(
        'invalid-main-class',
        'mainClass 含空白或分隔符，名字不明确。',
      );
    }
    final segments = value.split('.');
    for (final segment in segments) {
      if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(segment) ||
          _javaKeywords.contains(segment)) {
        throw JavaWebProjectException(
          'invalid-main-class',
          'mainClass 的片段 $segment 不是合法 Java 类名。',
        );
      }
    }
    return value;
  }

  /// Reads the optional `database` flag.
  ///
  /// Absent means false. A present value must be a JSON boolean: `"true"`, `1`
  /// and `null` are refused, because guessing would silently change which JARs
  /// reach the classpath and whether a data source is built at startup.
  static bool _decodeDatabase(Object? value) {
    if (value == null) return defaultDatabase;
    if (value is! bool) {
      throw JavaWebProjectException(
        'invalid-database',
        'database 必须是 true 或 false，实际为 $value。',
      );
    }
    return value;
  }

  static int _decodePort(Object? value) {
    if (value == null) return defaultPort;
    if (value is! int || value < 1 || value > 65535) {
      throw JavaWebProjectException(
        'invalid-port',
        'port 必须是 1 到 65535 之间的整数，实际为 $value。',
      );
    }
    return value;
  }

  static String _decodeContextPath(Object? value) {
    if (value == null) return defaultContextPath;
    if (value is! String) {
      throw const JavaWebProjectException(
        'invalid-context-path',
        'contextPath 必须是字符串。',
      );
    }
    final normalized = normalizeContextPath(value);
    if (normalized == null) {
      throw JavaWebProjectException(
        'invalid-context-path',
        'contextPath 必须以 / 开头且不含 .. ，实际为 $value。',
      );
    }
    return normalized;
  }

  static String _decodeWebRoot(Object? value, String root) {
    if (value == null) return defaultWebRoot;
    if (value is! String) {
      throw const JavaWebProjectException(
        'invalid-web-root',
        'webRoot 必须是字符串。',
      );
    }
    final normalized = normalizeWebRoot(value);
    if (normalized == null) {
      throw JavaWebProjectException(
        'invalid-web-root',
        'webRoot 必须是项目内相对路径，实际为 $value。',
      );
    }
    final resolved = p.joinAll(<String>[root, ...normalized.split('/')]);
    if (!p.isWithin(root, resolved) && !p.equals(root, resolved)) {
      throw JavaWebProjectException(
        'invalid-web-root',
        'webRoot 越出项目目录，实际为 $value。',
      );
    }
    return normalized;
  }

  /// Java keywords that cannot be a class-name segment.
  static const Set<String> _javaKeywords = <String>{
    'abstract',
    'assert',
    'boolean',
    'break',
    'byte',
    'case',
    'catch',
    'char',
    'class',
    'const',
    'continue',
    'default',
    'do',
    'double',
    'else',
    'enum',
    'extends',
    'false',
    'final',
    'finally',
    'float',
    'for',
    'goto',
    'if',
    'implements',
    'import',
    'instanceof',
    'int',
    'interface',
    'long',
    'native',
    'new',
    'null',
    'package',
    'permits',
    'private',
    'protected',
    'public',
    'record',
    'return',
    'sealed',
    'short',
    'static',
    'strictfp',
    'super',
    'switch',
    'synchronized',
    'this',
    'throw',
    'throws',
    'transient',
    'true',
    'try',
    'var',
    'void',
    'volatile',
    'while',
    'yield',
  };

  @override
  bool operator ==(Object other) =>
      other is JavaWebProject &&
      other.projectRoot == projectRoot &&
      other.schemaVersion == schemaVersion &&
      other.profile == profile &&
      other.mainClass == mainClass &&
      other.port == port &&
      other.contextPath == contextPath &&
      other.webRoot == webRoot &&
      other.database == database;

  @override
  int get hashCode => Object.hash(
    projectRoot,
    schemaVersion,
    profile,
    mainClass,
    port,
    contextPath,
    webRoot,
    database,
  );

  @override
  String toString() =>
      'JavaWebProject(profile: $profile, mainClass: $mainClass, port: $port, '
      'contextPath: $contextPath, webRoot: $webRoot, database: $database)';
}
