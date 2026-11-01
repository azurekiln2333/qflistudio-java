import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_web_project.dart';
import 'package:qfli_java/javaee_container_launcher.dart';

/// A full bundle: container, EL, JSP engine and its compiler, JSTL, annotations.
const JavaeeContainerPack _fullPack = JavaeeContainerPack(
  classpath: <String>[
    'C:/bundle/tomcat-embed-core-9.0.107.jar',
    'C:/bundle/tomcat-embed-el-9.0.107.jar',
    'C:/bundle/tomcat-embed-jasper-9.0.107.jar',
    'C:/bundle/ecj-4.6.1.jar',
    'C:/bundle/jstl-1.2.jar',
    'C:/bundle/tomcat-annotations-api-9.0.107.jar',
  ],
  jspSupported: true,
  jstlSupported: true,
  annotationScanning: true,
  containerVersion: '9.0.107',
);

/// Container only: it can start, but it cannot serve JSP.
const JavaeeContainerPack _servletOnlyPack = JavaeeContainerPack(
  classpath: <String>['C:/bundle/tomcat-embed-core-9.0.107.jar'],
  annotationScanning: true,
  containerVersion: '9.0.107',
);

/// Builds a decoded javaee8 project without touching the file system.
JavaWebProject _project({
  String profile = JavaWebProject.profileJavaee8,
  int? port,
  String? contextPath,
  String? webRoot,
}) => JavaWebProject.fromJson(<String, Object?>{
  'schemaVersion': JavaWebProject.currentSchemaVersion,
  'profile': profile,
  'port': ?port,
  'contextPath': ?contextPath,
  'webRoot': ?webRoot,
}, projectRoot: 'C:/proj');

JavaeeContainerLaunchPlan _plan({
  JavaWebProject? config,
  JavaeeContainerPack pack = _fullPack,
  String workDirectory = 'C:/runs/one',
  List<String> classDirectories = const <String>['C:/proj/target/classes'],
  List<String> projectJars = const <String>['C:/proj/lib/demo-1.0.jar'],
  bool requiresJsp = false,
}) => JavaeeContainerLauncher.plan(
  config: config ?? _project(),
  pack: pack,
  workDirectory: workDirectory,
  classDirectories: classDirectories,
  projectJars: projectJars,
  requiresJsp: requiresJsp,
);

/// Matches the thrown exception and its issue codes.
Matcher _throwsWithCode(String code) => throwsA(
  isA<JavaeeContainerException>().having(
    (JavaeeContainerException error) =>
        error.issues.map((JavaeeContainerIssue issue) => issue.code).toList(),
    'issue codes',
    contains(code),
  ),
);

void main() {
  group('JavaeeContainerPack', () {
    test('an absent bundle provides nothing', () {
      expect(JavaeeContainerPack.absent.isPresent, isFalse);
      expect(JavaeeContainerPack.absent.classpath, isEmpty);
      expect(
        JavaeeContainerPack.absent.missingComponents,
        contains('Tomcat 9 容器'),
      );
    });

    test('missing capabilities are stated as facts about the bundle', () {
      expect(_fullPack.missingComponents, isEmpty);
      expect(_servletOnlyPack.missingComponents, <String>['JSP 引擎', 'JSTL 实现']);
    });
  });

  group('launcherSource', () {
    final source = JavaeeContainerLauncher.launcherSource();

    test('deploys with addWebapp and never with addContext', () {
      expect(
        source,
        contains(
          'tomcat.addWebapp(contextPath, documentBase.getAbsolutePath())',
        ),
      );
      expect(source, isNot(contains('addContext(')));
    });

    test('does not disable the default web.xml initialization', () {
      // NO_DEFAULT_XML and a second ContextConfig would remove the default and
      // JSP servlet setup this profile depends on.
      expect(source, isNot(contains('NO_DEFAULT_XML')));
      expect(source, isNot(contains('new ContextConfig')));
    });

    test('binds the loopback address and never a wildcard', () {
      expect(source, contains('String LOOPBACK = "127.0.0.1";'));
      expect(source, contains('connector.setProperty("address", LOOPBACK);'));
      expect(source, isNot(contains('0.0.0.0')));
    });

    test('creates the connector before Tomcat starts', () {
      final connectorIndex = source.indexOf('new Connector("HTTP/1.1")');
      final bindIndex = source.indexOf('connector.setProperty("address"');
      final startIndex = source.indexOf('tomcat.start();');

      expect(connectorIndex, greaterThanOrEqualTo(0));
      expect(bindIndex, greaterThan(connectorIndex));
      expect(startIndex, greaterThan(bindIndex));
    });

    test('uses a unique base directory and mounts extra classes', () {
      expect(source, contains('tomcat.setBaseDir(baseDir);'));
      expect(source, contains('"/WEB-INF/classes"'));
      expect(source, contains('tomcat.getServer().await();'));
    });

    test('guards the port and the missing document base', () {
      expect(source, contains('port out of range'));
      expect(source, contains('docBase is not a directory'));
    });

    test('normalizes the root context to the empty string Tomcat expects', () {
      expect(
        source,
        contains(
          'final String contextPath = "/".equals(rawContextPath) ? "" : rawContextPath;',
        ),
      );
      expect(
        source,
        contains(
          'tomcat.addWebapp(contextPath, documentBase.getAbsolutePath())',
        ),
      );
      expect(source, isNot(contains('addWebapp(rawContextPath')));
    });

    test('refuses to report a context that did not become available', () {
      final startIndex = source.indexOf('tomcat.start();');
      final stateIndex = source.indexOf('context.getState().isAvailable()');

      expect(startIndex, greaterThanOrEqualTo(0));
      expect(stateIndex, greaterThan(startIndex));
      expect(source, contains('context did not become available'));
    });

    test('stops and destroys the container on every exit path', () {
      final awaitIndex = source.indexOf('tomcat.getServer().await();');
      final stopIndex = source.indexOf('tomcat.stop();');
      final destroyIndex = source.indexOf('tomcat.destroy();');

      expect(source, contains('addShutdownHook'));
      expect(awaitIndex, greaterThanOrEqualTo(0));
      expect(stopIndex, greaterThan(awaitIndex));
      expect(destroyIndex, greaterThan(stopIndex));
      expect(source, contains('} finally {'));
    });

    test('does not print a readiness claim of its own', () {
      // Usable state is p3's call, so the source prints context state instead.
      expect(source, contains('qfli-javaee8-contextState='));
      expect(source, isNot(contains('ready=true')));
    });
  });

  group('plan', () {
    test('passes base, docBase, context, port, jsp and classes by argv', () {
      final plan = _plan(config: _project(contextPath: '/shop'));

      expect(plan.mainClass, 'qfli.javaee.QfliTomcat9Main');
      expect(plan.arguments, <String>[
        'C:/runs/one/tomcat',
        'C:/runs/one/webapp',
        '/shop',
        '8080',
        'true',
        'C:/proj/target/classes',
      ]);
      expect(plan.baseDirectory, 'C:/runs/one/tomcat');
      expect(plan.workDirectory, 'C:/runs/one');
      expect(plan.assembly.documentBase, 'C:/runs/one/webapp');
      expect(
        plan.assembly.classesDestination,
        'C:/runs/one/webapp/WEB-INF/classes',
      );
      expect(
        plan.assembly.libraryDestination,
        'C:/runs/one/webapp/WEB-INF/lib',
      );
      expect(plan.assembly.libraryJars, <String>['C:/proj/lib/demo-1.0.jar']);
      expect(plan.assembly.classDirectories, <String>[
        'C:/proj/target/classes',
      ]);
    });

    test('forwards p3 layout paths instead of re-deriving them', () {
      final config = _project();
      final plan = _plan(config: config);

      expect(plan.assembly.webSource, config.webRootPath);
      expect(plan.assembly.resourcesSource, config.resourcesRoot);
    });

    test('writes the source where its package requires it', () {
      final plan = _plan();

      expect(plan.sourceFileName, 'QfliTomcat9Main.java');
      expect(plan.sourcePath, 'C:/runs/one/qfli/javaee/QfliTomcat9Main.java');
      expect(plan.source, contains('package qfli.javaee;'));
      expect(plan.source, JavaeeContainerLauncher.launcherSource());
    });

    test('orders the classpath bundle, then project JARs, then classes', () {
      final plan = _plan();

      expect(plan.classpath, <String>[
        'C:/bundle/tomcat-embed-core-9.0.107.jar',
        'C:/bundle/tomcat-embed-el-9.0.107.jar',
        'C:/bundle/tomcat-embed-jasper-9.0.107.jar',
        'C:/bundle/ecj-4.6.1.jar',
        'C:/bundle/jstl-1.2.jar',
        'C:/bundle/tomcat-annotations-api-9.0.107.jar',
        'C:/proj/lib/demo-1.0.jar',
        'C:/proj/target/classes',
      ]);
    });

    test('keeps the bundle order it was given and drops duplicates', () {
      final plan = _plan(
        pack: const JavaeeContainerPack(
          classpath: <String>['C:/bundle/b.jar', 'C:/bundle/a.jar'],
          jspSupported: true,
        ),
        projectJars: const <String>['C:/bundle/a.jar', 'C:/proj/lib/app.jar'],
      );

      expect(plan.classpath, <String>[
        'C:/bundle/b.jar',
        'C:/bundle/a.jar',
        'C:/proj/lib/app.jar',
      ]);
    });

    test('does not infer capabilities from JAR file names', () {
      // The dependency owner declares capabilities. A name that merely looks
      // like a container API must be passed through untouched, never sniffed.
      final plan = _plan(
        projectJars: const <String>['C:/proj/lib/servlet-api-2.5.jar'],
      );

      expect(plan.classpath, contains('C:/proj/lib/servlet-api-2.5.jar'));
    });

    test('enables JSP only when the bundle declares it', () {
      final withJsp = _plan(pack: _fullPack);
      final withoutJsp = _plan(pack: _servletOnlyPack);

      expect(withJsp.jspEnabled, isTrue);
      expect(withJsp.jstlEnabled, isTrue);
      expect(withoutJsp.jspEnabled, isFalse);
      expect(withoutJsp.jstlEnabled, isFalse);
      expect(withoutJsp.arguments[4], 'false');
    });

    test('does not enable JSTL when JSP itself is unavailable', () {
      final plan = _plan(
        pack: const JavaeeContainerPack(
          classpath: <String>['C:/bundle/tomcat-embed-core-9.0.107.jar'],
          jstlSupported: true,
        ),
      );

      expect(plan.jspEnabled, isFalse);
      expect(plan.jstlEnabled, isFalse);
    });

    test('reports the configured loopback address, not a proven one', () {
      expect(_plan().readinessUrl.toString(), 'http://127.0.0.1:8080/');
      expect(
        _plan(
          config: _project(port: 9090, contextPath: '/shop'),
        ).readinessUrl.toString(),
        'http://127.0.0.1:9090/shop',
      );
    });

    test(
      'passes the configured context path for root and for a named context',
      () {
        expect(_plan(config: _project(contextPath: '/')).arguments[2], '/');
        expect(
          _plan(config: _project(contextPath: '/shop')).arguments[2],
          '/shop',
        );
      },
    );

    test('refuses the spring-boot profile', () {
      expect(
        () =>
            _plan(config: _project(profile: JavaWebProject.profileSpringBoot)),
        _throwsWithCode('profile'),
      );
    });

    test('refuses an absent bundle instead of planning a broken start', () {
      expect(
        () => _plan(pack: JavaeeContainerPack.absent),
        _throwsWithCode('packMissing'),
      );
    });

    test('refuses a JSP project when the bundle cannot serve JSP', () {
      expect(
        () => _plan(pack: _servletOnlyPack, requiresJsp: true),
        _throwsWithCode('jspMissing'),
      );
    });

    test('does not refuse JSP when the bundle declares support', () {
      expect(_plan(pack: _fullPack, requiresJsp: true).jspEnabled, isTrue);
    });

    test('refuses a missing work directory', () {
      expect(
        () => _plan(workDirectory: '   '),
        _throwsWithCode('workDirectory'),
      );
    });

    test('refuses a document base name that is not one plain segment', () {
      for (final bad in <String>['a/b', r'a\b', '..', '.', ' ']) {
        expect(
          () => JavaeeContainerLauncher.plan(
            config: _project(),
            pack: _fullPack,
            workDirectory: 'C:/runs/one',
            documentDirectoryName: bad,
          ),
          _throwsWithCode('documentBase'),
          reason: 'document directory "$bad" must be refused',
        );
      }
    });

    test('collects every refusal instead of stopping at the first', () {
      try {
        JavaeeContainerLauncher.plan(
          config: _project(profile: JavaWebProject.profileSpringBoot),
          pack: JavaeeContainerPack.absent,
          workDirectory: '  ',
          documentDirectoryName: 'a/b',
        );
        fail('expected a JavaeeContainerException');
      } on JavaeeContainerException catch (error) {
        final codes = error.issues
            .map((JavaeeContainerIssue issue) => issue.code)
            .toList();
        expect(
          codes,
          containsAll(<String>[
            'profile',
            'packMissing',
            'workDirectory',
            'documentBase',
          ]),
        );
        expect(error.code, 'profile');
      }
    });
  });
}
