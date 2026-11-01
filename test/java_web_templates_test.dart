import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_web_templates.dart';
import 'package:qfli_java/spring_boot_bundle.dart';

JavaWebScaffoldPlan _plan({
  String profile = javaWebProfileJavaee8,
  String packageName = 'com.example.demo',
  int port = 8080,
  String contextPath = '/',
  String webRoot = 'src/main/webapp',
  List<String> existingPaths = const [],
}) => buildJavaWebScaffold(
  profile: profile,
  packageName: packageName,
  port: port,
  contextPath: contextPath,
  webRoot: webRoot,
  existingPaths: existingPaths,
  projectRoot: '/tmp/demo',
);

String _content(JavaWebScaffoldPlan plan, String path) =>
    plan.files.firstWhere((file) => file.path == path).content;

void main() {
  test('accepts only the two contract profiles', () {
    expect(isJavaWebProfile('spring-boot'), isTrue);
    expect(isJavaWebProfile('javaee8'), isTrue);
    expect(isJavaWebProfile('servlet'), isFalse);
    expect(isJavaWebProfile('jsp'), isFalse);
    expect(isJavaWebProfile(null), isFalse);
    expect(javaWebProfiles, hasLength(2));
  });

  test('points at the real Java entry file per profile', () {
    expect(
      javaWebEntryRelativePath(
        profile: javaWebProfileSpringBoot,
        packageName: 'com.example.demo',
      ),
      'src/main/java/com/example/demo/WebApplication.java',
    );
    expect(
      javaWebEntryRelativePath(
        profile: javaWebProfileJavaee8,
        packageName: 'com.example.web',
      ),
      'src/main/java/com/example/web/HelloServlet.java',
    );
    // A qualified main class supplies the package, so an empty package is fine.
    expect(
      javaWebEntryRelativePath(
        profile: javaWebProfileSpringBoot,
        packageName: '',
        mainClass: 'com.acme.App',
      ),
      'src/main/java/com/acme/App.java',
    );
  });

  test('normalizes the supported context path shapes', () {
    expect(normalizeContextPath('/'), '/');
    expect(normalizeContextPath(''), isNull);
    expect(normalizeContextPath('demo'), isNull);
    expect(normalizeContextPath('/demo/'), '/demo');
  });

  group('pack listing', () {
    test('lists nothing for an empty pack', () {
      const pack = JavaWebPack.empty();
      expect(pack.any, isFalse);
      expect(pack.canServe(javaWebProfileSpringBoot), isFalse);
      expect(pack.canServe(javaWebProfileJavaee8), isFalse);
      expect(pack.boot3Version, isNull);
      expect(pack.metadataAvailable, isFalse);
    });

    test('takes every flag from p4 role metadata', () {
      final pack = JavaWebPack.fromCapabilities(
        springBoot: const JavaEePackCapabilities(
          web: true,
          json: true,
          servlet: true,
          jsp: false,
          jstl: false,
          jdbc: true,
          persistence: true,
          roles: ['web', 'json', 'servlet', 'jdbc', 'persistence'],
        ),
        javaee8: const JavaEePackCapabilities(
          web: true,
          json: false,
          servlet: true,
          jsp: true,
          jstl: false,
          jdbc: false,
          persistence: false,
          roles: ['servlet', 'jsp'],
        ),
        jars: const ['spring-boot-3.5.16.jar'],
        boot3Version: JavaEePacks.springBoot.version,
      );
      expect(pack.canServe(javaWebProfileSpringBoot), isTrue);
      expect(pack.canServe(javaWebProfileJavaee8), isTrue);
      expect(pack.jsp, isTrue);
      expect(pack.jdbc, isTrue);
      expect(pack.persistence, isTrue);
      expect(pack.json, isTrue);
      expect(pack.boot3Version, '3.5.16');
      expect(pack.metadataAvailable, isTrue);
    });

    test('does not treat a jakarta pack as javax support', () {
      final pack = JavaWebPack.fromCapabilities(
        springBoot: const JavaEePackCapabilities(
          web: true,
          json: true,
          servlet: true,
          jsp: false,
          jstl: false,
          jdbc: false,
          persistence: false,
          roles: ['web', 'servlet'],
        ),
      );
      expect(pack.javaee8, isFalse);
      expect(pack.canServe(javaWebProfileJavaee8), isFalse);
    });

    test('a javax pack serves javaee8 and not spring-boot', () {
      final pack = JavaWebPack.fromCapabilities(
        javaee8: const JavaEePackCapabilities(
          web: true,
          json: false,
          servlet: true,
          jsp: true,
          jstl: false,
          jdbc: false,
          persistence: false,
          roles: ['servlet', 'jsp'],
        ),
      );
      expect(pack.javaee8, isTrue);
      expect(pack.jsp, isTrue);
      expect(pack.jakartaContainer, isFalse);
      expect(pack.canServe(javaWebProfileJavaee8), isTrue);
      expect(pack.canServe(javaWebProfileSpringBoot), isFalse);
    });

    test('unreadable metadata stays unknown, not guessed', () {
      final pack = JavaWebPack.fromCapabilities();
      expect(pack.metadataAvailable, isFalse);
      expect(pack.any, isFalse);
      expect(pack.canServe(javaWebProfileSpringBoot), isFalse);
    });

    test('publishes the pack directories from the p4 lock', () {
      expect(javaWebPackDirectories, contains('assets/javaee8'));
    });
  });

  group('environment report', () {
    test('reports a missing config as not configured', () {
      final report = buildJavaWebReport(
        projectPath: '/tmp/demo',
        config: null,
        configIssues: const [],
        projectPaths: const [],
        pack: const JavaWebPack.empty(),
        hasConfigFile: false,
      );
      expect(report.statusLine, '尚未配置 JavaEE 环境');
      expect(report.reachable, isFalse);
    });

    test('never infers readiness from a jar name', () {
      final report = buildJavaWebReport(
        projectPath: '/tmp/demo',
        config: const JavaWebConfigSnapshot(
          profile: javaWebProfileSpringBoot,
          mainClass: 'com.example.demo.WebApplication',
          port: 8080,
          contextPath: '/',
          webRoot: 'src/main/webapp',
        ),
        configIssues: const [],
        projectPaths: const [],
        pack: JavaWebPack.fromCapabilities(
          springBoot: const JavaEePackCapabilities(
            web: true,
            json: true,
            servlet: true,
            jsp: false,
            jstl: false,
            jdbc: false,
            persistence: false,
            roles: ['web', 'servlet'],
          ),
        ),
        hasConfigFile: true,
      );
      expect(report.statusLine, '配置已就绪，尚未启动服务');
      expect(report.statusLine, isNot(contains('响应')));
      // Reachability only shows that the port answers, never owned readiness.
      expect(report.withReachable(true).statusLine, '本机端口有响应，未确认由本项目提供');
      expect(report.withReachable(true).reachable, isTrue);
    });

    test('reports a pack that cannot serve the profile', () {
      final report = buildJavaWebReport(
        projectPath: '/tmp/demo',
        config: const JavaWebConfigSnapshot(
          profile: javaWebProfileJavaee8,
          mainClass: null,
          port: 8080,
          contextPath: '/',
          webRoot: 'src/main/webapp',
        ),
        configIssues: const [],
        projectPaths: const [],
        pack: const JavaWebPack.empty(),
        hasConfigFile: true,
      );
      expect(report.statusLine, '离线包缺少 javaee8 运行组件');
      expect(report.missingComponents, contains('javax Servlet/JSP 包'));
      expect(report.hasPackConflict, isFalse);
    });

    test('flags a namespace conflict between pack and profile', () {
      final report = buildJavaWebReport(
        projectPath: '/tmp/demo',
        config: const JavaWebConfigSnapshot(
          profile: javaWebProfileSpringBoot,
          mainClass: null,
          port: 8080,
          contextPath: '/',
          webRoot: 'src/main/webapp',
        ),
        configIssues: const [],
        projectPaths: const [],
        pack: JavaWebPack.fromCapabilities(
          javaee8: const JavaEePackCapabilities(
            web: true,
            json: false,
            servlet: true,
            jsp: true,
            jstl: false,
            jdbc: false,
            persistence: false,
            roles: ['servlet', 'jsp'],
          ),
        ),
        hasConfigFile: true,
      );
      expect(report.hasPackConflict, isTrue);
    });
  });

  group('scaffold plan', () {
    test('remembers the project it was planned for', () {
      final plan = _plan(profile: javaWebProfileSpringBoot);
      expect(plan.projectRoot, '/tmp/demo');
      expect(plan.canApply, isTrue);
    });

    test('boot3 emits root routes and a loopback bind', () {
      final plan = _plan(profile: javaWebProfileSpringBoot);
      final paths = plan.files.map((file) => file.path).toList();
      expect(
        paths,
        contains('src/main/java/com/example/demo/WebApplication.java'),
      );
      expect(
        paths,
        contains('src/main/java/com/example/demo/HealthController.java'),
      );
      expect(paths, contains('src/main/resources/application.properties'));
      final properties = _content(
        plan,
        'src/main/resources/application.properties',
      );
      expect(properties, contains('server.address=127.0.0.1'));
      expect(properties, contains('server.port=8080'));
      expect(
        _content(plan, 'src/main/java/com/example/demo/HealthController.java'),
        contains('@GetMapping("/health")'),
      );
      expect(
        _content(
          plan,
          'src/main/java/com/example/demo/FormBindingController.java',
        ),
        contains('@PostMapping("/form")'),
      );
    });

    test(
      'javaee8 emits a real javax HttpServlet and a container descriptor',
      () {
        final plan = _plan();
        final paths = plan.files.map((file) => file.path).toList();
        expect(
          paths,
          contains('src/main/java/com/example/demo/HelloServlet.java'),
        );
        expect(paths, contains('src/main/webapp/index.jsp'));
        expect(paths, contains('src/main/webapp/WEB-INF/web.xml'));
        final servlet = _content(
          plan,
          'src/main/java/com/example/demo/HelloServlet.java',
        );
        expect(servlet, contains('javax.servlet.http.HttpServlet'));
        expect(servlet, contains('javax.servlet.ServletException'));
        expect(servlet, isNot(contains('jakarta.')));
        expect(servlet, isNot(contains('com.sun.net.httpserver')));
        expect(
          _content(plan, 'src/main/webapp/WEB-INF/web.xml'),
          contains(
            '<servlet-class>com.example.demo.HelloServlet</servlet-class>',
          ),
        );
      },
    );

    test('honors the configured webRoot', () {
      final plan = _plan(webRoot: 'web');
      expect(
        plan.files.map((file) => file.path),
        containsAll(<String>['web/index.jsp', 'web/WEB-INF/web.xml']),
      );
      expect(
        plan.files.map((file) => file.path),
        isNot(contains('src/main/webapp/index.jsp')),
      );
    });

    test('writes the config with the chosen profile and webRoot', () {
      final config = jsonDecode(
        _content(_plan(webRoot: 'web'), javaWebConfigFileName),
      );
      expect(config['schemaVersion'], 1);
      expect(config['profile'], 'javaee8');
      expect(config['webRoot'], 'web');
      expect(config['mainClass'], 'com.example.demo.HelloServlet');
    });

    test('never overwrites an existing project file', () {
      final plan = _plan(
        existingPaths: const [
          'src/main/java/com/example/demo/HelloServlet.java',
        ],
      );
      expect(plan.canApply, isFalse);
      expect(plan.blocked, contains('拒绝覆盖'));
      expect(
        plan.skippedExisting,
        contains('src/main/java/com/example/demo/HelloServlet.java'),
      );
      expect(
        plan.files.map((file) => file.path),
        isNot(contains('src/main/java/com/example/demo/HelloServlet.java')),
      );
    });

    test('uses a neutral package instead of emitting package ;', () {
      final plan = _plan(packageName: '');
      expect(
        plan.files.map((file) => file.path),
        contains('src/main/java/com/example/web/HelloServlet.java'),
      );
      final servlet = _content(
        plan,
        'src/main/java/com/example/web/HelloServlet.java',
      );
      expect(servlet, startsWith('package com.example.web;'));
      expect(servlet, isNot(contains('package ;')));
    });

    test('carries no credential and no homework content', () {
      for (final profile in javaWebProfiles) {
        final plan = _plan(profile: profile);
        final all = plan.files.map((file) => file.content).join('\n');
        expect(all.toLowerCase(), isNot(contains('password=')));
        expect(all.toLowerCase(), isNot(contains('jdbc:')));
        expect(all.toLowerCase(), isNot(contains('create table')));
        expect(all, contains('qflisql'));
      }
    });
  });
}
