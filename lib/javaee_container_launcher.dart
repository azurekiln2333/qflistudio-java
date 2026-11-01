/// Java EE 8 container launch planning: embedded Tomcat 9 on the javax line.
///
/// This module never starts a process, never writes a file and never opens a
/// socket. It turns one decoded [JavaWebProject] plus the container bundle the
/// caller verified into a launch plan for the shared runner, which owns process
/// creation, live output and cancellation.
///
/// Everything here is a plan. A plan is not proof that the container starts,
/// that a request is served, or that JSP renders. Only an actual run with a
/// fresh grant can show that.
///
/// The bundle arrives as verified paths plus explicit profile metadata. This
/// module never inspects JAR file names to guess capabilities, and it never
/// depends on presentation or template vocabulary.
library;

import 'java_web_project.dart';

/// One reason the container cannot be planned, reported instead of guessed.
class JavaeeContainerIssue {
  const JavaeeContainerIssue(this.code, this.message);

  /// Stable machine-readable code, for tests and for the caller's UI.
  final String code;

  /// Human-readable explanation, stated as a fact rather than a promise.
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Thrown when a plan cannot be produced. Carries every issue, not just one.
class JavaeeContainerException implements Exception {
  const JavaeeContainerException(this.issues);

  final List<JavaeeContainerIssue> issues;

  /// Code of the first issue, or `unknown` when the list is empty.
  String get code => issues.isEmpty ? 'unknown' : issues.first.code;

  @override
  String toString() =>
      'JavaeeContainerException(${issues.map((issue) => issue.toString()).join(', ')})';
}

/// The container bundle for this profile, supplied by the dependency owner.
///
/// [classpath] holds paths that were verified to exist, in the order they must
/// appear on the classpath. The capability flags are explicit declarations, so
/// no file name is ever parsed to infer them.
class JavaeeContainerPack {
  const JavaeeContainerPack({
    required this.classpath,
    this.jspSupported = false,
    this.jstlSupported = false,
    this.annotationScanning = false,
    this.containerVersion,
  });

  /// A bundle with no container at all. Nothing can be launched from it.
  static const JavaeeContainerPack absent = JavaeeContainerPack(
    classpath: <String>[],
  );

  /// Verified JAR paths, container first. Never reordered by this module.
  final List<String> classpath;

  /// The bundle really provides a JSP engine, its compiler and EL.
  final bool jspSupported;

  /// The bundle really provides a javax JSTL implementation.
  final bool jstlSupported;

  /// The bundle provides the annotations API, so annotation scanning can run.
  final bool annotationScanning;

  /// Container version as declared by the pack, when it publishes one.
  final String? containerVersion;

  /// True when at least one container path is present.
  bool get isPresent => classpath.isNotEmpty;

  /// Capabilities the bundle does not provide, phrased as facts about the pack.
  List<String> get missingComponents => <String>[
    if (!isPresent) 'Tomcat 9 容器',
    if (!jspSupported) 'JSP 引擎',
    if (!jstlSupported) 'JSTL 实现',
    if (!annotationScanning) '注解扫描包',
  ];
}

/// What the caller must lay out on disk before the runner starts Tomcat.
///
/// Returned as data so this module stays free of file-system side effects.
class JavaeeContainerAssembly {
  const JavaeeContainerAssembly({
    required this.documentBase,
    required this.webSource,
    required this.resourcesSource,
    required this.classesDestination,
    required this.libraryDestination,
    required this.classDirectories,
    required this.libraryJars,
  });

  /// Exploded document base handed to `addWebapp`.
  final String documentBase;

  /// Project web root whose resources are copied into [documentBase].
  final String webSource;

  /// Project resources tree that belongs under `WEB-INF/classes`.
  final String resourcesSource;

  /// `<documentBase>/WEB-INF/classes`, the compiled output target.
  final String classesDestination;

  /// `<documentBase>/WEB-INF/lib`, the application JAR target.
  final String libraryDestination;

  /// Compiled class directories to expose as `WEB-INF/classes`.
  final List<String> classDirectories;

  /// Application JARs to place in `WEB-INF/lib`.
  final List<String> libraryJars;
}

/// Everything the shared runner needs to start one owned container.
class JavaeeContainerLaunchPlan {
  const JavaeeContainerLaunchPlan({
    required this.mainClass,
    required this.sourceFileName,
    required this.sourcePath,
    required this.source,
    required this.arguments,
    required this.classpath,
    required this.workDirectory,
    required this.baseDirectory,
    required this.contextPath,
    required this.port,
    required this.jspEnabled,
    required this.jstlEnabled,
    required this.assembly,
  });

  final String mainClass;
  final String sourceFileName;

  /// Absolute path the caller writes [source] to, matching the package.
  final String sourcePath;

  /// Embedded Tomcat 9 launcher source, javax only.
  final String source;

  /// Positional arguments for [mainClass].
  final List<String> arguments;

  /// Classpath in a stable order: container, project JARs, then classes.
  final List<String> classpath;

  /// Unique, writable directory owned by this launch.
  final String workDirectory;

  /// Passed to `Tomcat.setBaseDir`, unique per launch.
  final String baseDirectory;

  /// Normalized context path, `/` or slash-prefixed.
  final String contextPath;

  final int port;

  /// The bundle declares JSP support, so the JSP servlet can initialize.
  final bool jspEnabled;

  /// The bundle declares JSTL support on top of JSP.
  final bool jstlEnabled;

  final JavaeeContainerAssembly assembly;

  /// Configured address. Not a proven one until a response arrives.
  Uri get readinessUrl => Uri(
    scheme: 'http',
    host: JavaeeContainerLauncher.loopbackAddress,
    port: port,
    path: contextPath,
  );
}

/// Plans an embedded Tomcat 9 (javax Servlet/JSP) deployment.
///
/// The recipe is fixed: `addWebapp` with an exploded document base, so
/// `WEB-INF/web.xml`, annotation scanning and the default plus JSP servlet
/// initialization all run. A bare `addContext` skips all three and is never
/// generated.
abstract final class JavaeeContainerLauncher {
  /// Wire name of the profile this launcher serves.
  static const String profileWireName = JavaWebProject.profileJavaee8;

  /// Entry point of the generated launcher.
  static const String mainClass = 'qfli.javaee.QfliTomcat9Main';

  /// Source file name, which must match [mainClass]'s package layout.
  static const String sourceFileName = 'QfliTomcat9Main.java';

  /// Directory the source goes in, relative to the work directory.
  static const String sourceRelativeDirectory = 'qfli/javaee';

  /// Loopback address the connector binds. Never a wildcard address.
  static const String loopbackAddress = '127.0.0.1';

  /// Servlet spec mount point for compiled classes.
  static const String classesMountPoint = '/WEB-INF/classes';

  /// Servlet spec mount point for application JARs.
  static const String libraryMountPoint = '/WEB-INF/lib';

  /// Builds a launch plan, or throws [JavaeeContainerException] listing why not.
  ///
  /// [requiresJsp] is the caller's statement that the project really has JSP
  /// pages. When it is true and the bundle cannot serve JSP, this refuses
  /// instead of deploying pages that cannot render.
  static JavaeeContainerLaunchPlan plan({
    required JavaWebProject config,
    required JavaeeContainerPack pack,
    required String workDirectory,
    List<String> classDirectories = const <String>[],
    List<String> projectJars = const <String>[],
    bool requiresJsp = false,
    String documentDirectoryName = 'webapp',
  }) {
    final issues = <JavaeeContainerIssue>[];

    if (config.profile != profileWireName) {
      issues.add(
        JavaeeContainerIssue(
          'profile',
          'This launcher serves only $profileWireName, not ${config.profile}',
        ),
      );
    }
    if (!pack.isPresent) {
      issues.add(
        const JavaeeContainerIssue(
          'packMissing',
          'The javaee8 container bundle has no verified classpath path',
        ),
      );
    }
    if (requiresJsp && !pack.jspSupported) {
      issues.add(
        JavaeeContainerIssue(
          'jspMissing',
          'The project has JSP pages, but the bundle declares no JSP support'
              '${pack.missingComponents.isEmpty ? '' : ': ${pack.missingComponents.join('、')}'}',
        ),
      );
    }
    if (workDirectory.trim().isEmpty) {
      issues.add(
        const JavaeeContainerIssue(
          'workDirectory',
          'A work directory is required',
        ),
      );
    }
    if (documentDirectoryName.contains('/') ||
        documentDirectoryName.contains('\\') ||
        documentDirectoryName == '.' ||
        documentDirectoryName == '..' ||
        documentDirectoryName.trim().isEmpty) {
      issues.add(
        JavaeeContainerIssue(
          'documentBase',
          'Document base name must be one plain path segment, not $documentDirectoryName',
        ),
      );
    }
    if (issues.isNotEmpty) {
      throw JavaeeContainerException(
        List<JavaeeContainerIssue>.unmodifiable(issues),
      );
    }

    final work = _trimTrailingSeparator(workDirectory);
    final baseDirectory = '$work/tomcat';
    final documentBase = '$work/$documentDirectoryName';
    final jspEnabled = pack.jspSupported;
    final assembly = JavaeeContainerAssembly(
      documentBase: documentBase,
      webSource: config.webRootPath,
      resourcesSource: config.resourcesRoot,
      classesDestination: '$documentBase$classesMountPoint',
      libraryDestination: '$documentBase$libraryMountPoint',
      classDirectories: List<String>.unmodifiable(classDirectories),
      libraryJars: List<String>.unmodifiable(projectJars),
    );

    final classpath = <String>[];
    void add(String value) {
      if (value.trim().isNotEmpty && !classpath.contains(value)) {
        classpath.add(value);
      }
    }

    for (final entry in pack.classpath) {
      add(entry);
    }
    for (final jar in projectJars) {
      add(jar);
    }
    for (final directory in classDirectories) {
      add(directory);
    }

    final arguments = <String>[
      baseDirectory,
      documentBase,
      config.contextPath,
      '${config.port}',
      '$jspEnabled',
      ...classDirectories,
    ];

    return JavaeeContainerLaunchPlan(
      mainClass: mainClass,
      sourceFileName: sourceFileName,
      sourcePath: '$work/$sourceRelativeDirectory/$sourceFileName',
      source: launcherSource(),
      arguments: List<String>.unmodifiable(arguments),
      classpath: List<String>.unmodifiable(classpath),
      workDirectory: work,
      baseDirectory: baseDirectory,
      contextPath: config.contextPath,
      port: config.port,
      jspEnabled: jspEnabled,
      jstlEnabled: jspEnabled && pack.jstlSupported,
      assembly: assembly,
    );
  }

  /// The embedded Tomcat 9 launcher source.
  ///
  /// Fixed text: every value arrives by argv, so no user path is ever
  /// interpolated into Java and no quoting rule can break. The loopback
  /// address is a literal here so it cannot drift.
  static String launcherSource() => _source;

  static String _trimTrailingSeparator(String value) {
    var result = value.trim().replaceAll('\\', '/');
    while (result.length > 1 && result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static const String _source = r'''package qfli.javaee;

import java.io.File;

import org.apache.catalina.Context;
import org.apache.catalina.LifecycleException;
import org.apache.catalina.WebResourceRoot;
import org.apache.catalina.connector.Connector;
import org.apache.catalina.startup.Tomcat;
import org.apache.catalina.webresources.DirResourceSet;
import org.apache.catalina.webresources.StandardRoot;

/**
 * Embedded Tomcat 9 (javax Servlet/JSP) launcher for one QFLI Java EE 8 project.
 *
 * Deployment uses addWebapp on an exploded document base, so WEB-INF/web.xml,
 * annotation scanning and the default plus JSP servlet initialization all run.
 * A bare addContext would skip all three and is deliberately never used.
 */
public final class QfliTomcat9Main {

    /** Loopback only. The connector must never listen on every interface. */
    private static final String LOOPBACK = "127.0.0.1";

    private QfliTomcat9Main() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 5) {
            throw new IllegalArgumentException(
                "usage: <baseDir> <docBase> <contextPath> <port> <jsp> [classesDir...]");
        }
        final String baseDir = args[0];
        final String docBase = args[1];
        // Tomcat names the root context with the empty string. A literal "/"
        // would ask for a context named "/", which Tomcat refuses, so the root
        // case is normalized here instead of at every caller.
        final String rawContextPath = args[2];
        final String contextPath = "/".equals(rawContextPath) ? "" : rawContextPath;
        final int port = Integer.parseInt(args[3]);
        final boolean jsp = Boolean.parseBoolean(args[4]);
        if (port < 1 || port > 65535) {
            throw new IllegalArgumentException("port out of range: " + port);
        }
        final File documentBase = new File(docBase);
        if (!documentBase.isDirectory()) {
            throw new IllegalArgumentException("docBase is not a directory: " + documentBase);
        }

        final Tomcat tomcat = new Tomcat();
        tomcat.setBaseDir(baseDir);

        // Create the connector before start(). Otherwise Tomcat builds a default
        // connector that listens on every interface.
        final Connector connector = new Connector("HTTP/1.1");
        connector.setPort(port);
        connector.setProperty("address", LOOPBACK);
        tomcat.setConnector(connector);

        // The normalized path is what addWebapp receives. `tomcat.addWebapp("", ...)`
        // is the root deployment.
        final Context context = tomcat.addWebapp(contextPath, documentBase.getAbsolutePath());

        // Compiled classes and resources stay where the build put them and are
        // mounted as WEB-INF/classes, so the deployment keeps one source of truth.
        final WebResourceRoot resources = new StandardRoot(context);
        for (int index = 5; index < args.length; index++) {
            final File classes = new File(args[index]);
            if (!classes.isDirectory()) {
                throw new IllegalArgumentException("classes directory missing: " + classes);
            }
            resources.addPreResources(new DirResourceSet(
                resources, "/WEB-INF/classes", classes.getAbsolutePath(), "/"));
        }
        context.setResources(resources);

        // Stop and destroy on a normal exit, and on a signal, so a finished run
        // never leaves a live listener behind. Stop and destroy are owned by p3
        // in the product. This source never leaves an invalid context alive.
        Runtime.getRuntime().addShutdownHook(
            new Thread(() -> shutdown(tomcat), "qfli-javaee8-shutdown"));

        try {
            tomcat.start();
            // The port can be listening while the web application failed to
            // start. A started server is therefore not reported as usable until
            // its own context is actually available.
            if (!context.getState().isAvailable()) {
                throw new IllegalStateException(
                    "context did not become available: " + context.getStateName());
            }
            System.out.println("qfli-javaee8-loopback=" + LOOPBACK);
            System.out.println("qfli-javaee8-port=" + port);
            System.out.println("qfli-javaee8-context=" + contextPath);
            System.out.println("qfli-javaee8-root=" + contextPath.isEmpty());
            System.out.println("qfli-javaee8-jsp=" + jsp);
            System.out.println("qfli-javaee8-contextState=" + context.getStateName());
            System.out.println("qfli-javaee8-docBase=" + documentBase.getAbsolutePath());
            tomcat.getServer().await();
        } finally {
            shutdown(tomcat);
        }
    }

    private static void shutdown(Tomcat tomcat) {
        try {
            tomcat.stop();
        } catch (LifecycleException ignored) {
            // Already stopped, or never started. Nothing to report.
        }
        try {
            tomcat.destroy();
        } catch (LifecycleException ignored) {
            // Teardown must not mask the failure that triggered it.
        }
    }
}
''';
}
