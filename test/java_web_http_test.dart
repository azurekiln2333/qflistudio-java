import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qfli_java/java_runner.dart';
import 'package:qfli_java/java_web_project.dart';
import 'package:qfli_studio_core/services/studio_profile.dart';

/// Real host acceptance. No compiler, JVM, dependency or HTTP response is faked.
///
/// The dedicated source-bound gate enables this file with
/// QFLI_JAVAEE_HTTP_TESTS=1. Normal unit-suite runs skip these external processes.
/// A desktop JDK compiling with --release 17 is not OHOS or Java 17 runtime proof.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['QFLI_JAVAEE_HTTP_TESTS'] == '1';
  final skip = enabled ? false : 'Requires the dedicated JavaEE host gate';

  test(
    'host product runner serves Boot JSON, bound forms and main resources',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final runner = _runner();
      final project = await Directory.systemTemp.createTemp('qfli_boot_http_');
      final owner = _RunOwner(project);
      try {
        final port = await _unusedPort();
        final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
        _write(
          project,
          'src/main/java/acceptance/boot/Application.java',
          _bootSource.replaceAll('__NONCE__', nonce),
        );
        _write(
          project,
          'src/main/resources/runtime-proof.txt',
          'BOOT_RESOURCE',
        );
        // A broken test source must not enter production web compilation.
        _write(project, 'src/test/java/Broken.java', 'this is not Java');
        _config(project, profile: 'spring-boot', port: port);
        final before = _snapshot(project);

        final run = await owner.launch(
          runner,
          'src/main/java/acceptance/boot/Application.java',
        );
        final health = _uri(port, '/', 'health');
        await _waitFor(run, health, (reply) {
          if (reply.status != HttpStatus.ok) return false;
          final value = jsonDecode(reply.body);
          return value is Map && value['instance'] == nonce;
        });
        final json = jsonDecode((await _request('GET', health)).body) as Map;
        expect(json['profile'], 'spring-boot');
        expect(json['resource'], 'BOOT_RESOURCE');
        expect(json['instance'], nonce);

        const title = 'notice + form';
        const author = '作者 A+B';
        final form = await _request(
          'POST',
          _uri(port, '/', 'form'),
          fields: const {'title': title, 'author': author},
        );
        expect(form.status, HttpStatus.ok, reason: form.body);
        expect(jsonDecode(form.body), {
          'title': title,
          'author': author,
          'instance': nonce,
        });

        // Stop and actual terminal ownership are part of acceptance, not cleanup
        // that may fail after the test has already declared success.
        await run.stop();
        await _waitPortFree(port);
        _expectSnapshot(project, before);
      } finally {
        await owner.finish();
      }
    }, _RealHttpOverrides()),
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'host product runner deploys JavaEE8 Servlet, JSP, JSTL and restart',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final runner = _runner();
      final project = await Directory.systemTemp.createTemp('qfli_ee8_http_');
      final owner = _RunOwner(project);
      HttpServer? occupied;
      StreamSubscription<HttpRequest>? occupiedRequests;
      try {
        final port = await _unusedPort();
        final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
        const context = '/classroom';
        const webRoot = 'web-root';
        const entry = 'src/main/java/acceptance/legacy/HealthServlet.java';
        _write(project, entry, _servletSource.replaceAll('__NONCE__', nonce));
        _write(project, 'src/main/resources/runtime-proof.txt', 'EE8_RESOURCE');
        _write(project, 'src/test/java/Broken.java', 'this must not compile');
        _write(project, '$webRoot/WEB-INF/web.xml', _webXml);
        _write(
          project,
          '$webRoot/index.jsp',
          _jspSource.replaceAll('__NONCE__', nonce),
        );
        _write(project, '$webRoot/proof.txt', 'STATIC_REVISION_1');
        _config(
          project,
          profile: 'javaee8',
          port: port,
          context: context,
          webRoot: webRoot,
        );
        final before = _snapshot(project);

        final first = await owner.launch(runner, entry);
        await _waitFor(
          first,
          _uri(port, context, 'health'),
          (reply) =>
              reply.status == 200 && reply.body == 'EE8|EE8_RESOURCE|$nonce',
        );
        final form = await _request(
          'POST',
          _uri(port, context, 'form'),
          fields: const {'title': '表单 + A', 'author': '作者&B'},
        );
        expect(form.status, HttpStatus.ok, reason: form.body);
        expect(form.body, 'FORM|表单 + A|作者&B|$nonce');

        final jsp = await _request(
          'GET',
          _uri(
            port,
            context,
            'index.jsp',
          ).replace(queryParameters: const {'title': '<QFLI>&'}),
        );
        expect(jsp.status, HttpStatus.ok, reason: jsp.body);
        expect(jsp.body.trim(), 'JSP|&lt;QFLI&gt;&amp;|123|$nonce');
        final staticReply = await _request(
          'GET',
          _uri(port, context, 'proof.txt'),
        );
        expect(staticReply.status, HttpStatus.ok);
        expect(staticReply.body, 'STATIC_REVISION_1');

        await first.stop();
        await _waitPortFree(port);
        _expectSnapshot(project, before);
        _expectDeploymentRemoved(first);

        // A real unrelated listener must cause refusal, not a readiness pass.
        var unrelatedRequests = 0;
        occupied = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          port,
          shared: false,
        );
        occupiedRequests = occupied.listen((request) {
          unrelatedRequests++;
          request.response.write('UNRELATED_SERVER');
          unawaited(request.response.close());
        });
        final refused = await owner.launch(runner, entry);
        expect(
          await refused.exit.timeout(const Duration(seconds: 10)),
          kProgramNotRunExitCode,
        );
        await refused.stop();
        expect(refused.stderr.join('\n'), contains('$port'));
        expect(refused.stdout.any((line) => line.contains('HTTP ')), isFalse);
        expect(unrelatedRequests, 0);
        await occupied.close(force: true);
        occupied = null;
        await occupiedRequests.cancel();
        occupiedRequests = null;

        // A fresh deployment must load the new static bytes on the same port.
        _write(project, '$webRoot/proof.txt', 'STATIC_REVISION_2');
        final secondBefore = _snapshot(project);
        final second = await owner.launch(runner, entry);
        await _waitFor(
          second,
          _uri(port, context, 'health'),
          (reply) =>
              reply.status == 200 && reply.body == 'EE8|EE8_RESOURCE|$nonce',
        );
        final revised = await _request('GET', _uri(port, context, 'proof.txt'));
        expect(revised.status, HttpStatus.ok);
        expect(revised.body, 'STATIC_REVISION_2');
        await second.stop();
        await _waitPortFree(port);
        _expectSnapshot(project, secondBefore);
        _expectDeploymentRemoved(second);
      } finally {
        try {
          await occupied?.close(force: true);
          await occupiedRequests?.cancel();
        } finally {
          await owner.finish();
        }
      }
    }, _RealHttpOverrides()),
    skip: skip,
    timeout: const Timeout(Duration(seconds: 80)),
  );
}

JavaProgramRunner _runner() {
  final runner = JavaProgramRunner(
    compileTimeout: const Duration(seconds: 20),
    webReadyTimeout: const Duration(seconds: 15),
  );
  expect(
    Platform.isWindows || Platform.isLinux || Platform.isMacOS,
    isTrue,
    reason: 'This dedicated gate proves desktop behavior only.',
  );
  expect(
    runner.isAvailable,
    isTrue,
    reason: 'An enabled HTTP gate requires a real local JDK.',
  );
  return runner;
}

class _RunOwner {
  _RunOwner(this.project);

  final Directory project;
  final runs = <_ObservedRun>[];
  bool startupPending = false;

  Future<_ObservedRun> launch(JavaProgramRunner runner, String entry) async {
    // Do not abandon an in-flight run Future with Future.timeout: it may later
    // return a JVM that still needs an owner. A thrown startup leaves the
    // project intact, since this test then has no authoritative terminal handle.
    startupPending = true;
    final result = await runner.run(
      projectPath: project.path,
      entryFile: p.join(project.path, entry),
    );
    expect(result, isNotNull);
    final observed = _ObservedRun(result!);
    runs.add(observed);
    startupPending = false;
    return observed;
  }

  Future<void> finish() async {
    for (final run in runs.reversed) {
      await run.stop();
    }
    if (!startupPending &&
        runs.every((run) => run.terminal) &&
        await project.exists()) {
      await project.delete(recursive: true);
    }
  }
}

class _ObservedRun {
  _ObservedRun(this.result) {
    _out = result.stdout.listen(
      stdout.add,
      onError: errors.add,
      onDone: () => _outDone.complete(),
    );
    _err = result.stderr.listen(
      stderr.add,
      onError: errors.add,
      onDone: () => _errDone.complete(),
    );
    exit = result.exitCode.then((value) {
      terminal = true;
      code = value;
      return value;
    });
    // Preserve the original Future for the later await without an early
    // unhandled-error race while HTTP startup is being observed.
    unawaited(exit.then<void>((_) {}, onError: (Object _) {}));
  }

  final ProgramRunResult result;
  final stdout = <String>[];
  final stderr = <String>[];
  final errors = <Object>[];
  final _outDone = Completer<void>();
  final _errDone = Completer<void>();
  late final StreamSubscription<String> _out;
  late final StreamSubscription<String> _err;
  late final Future<int> exit;
  bool terminal = false;
  int? code;

  String get evidence =>
      'exit=$code\n${stdout.join('\n')}\n${stderr.join('\n')}';

  Future<void> stop() async {
    if (!terminal) {
      final cancel = result.cancel;
      if (cancel == null) {
        await exit.timeout(const Duration(seconds: 10));
      } else {
        await cancel().timeout(const Duration(seconds: 12));
      }
    }
    await exit.timeout(const Duration(seconds: 12));
    await Future.wait([
      _outDone.future,
      _errDone.future,
    ]).timeout(const Duration(seconds: 5));
    await _out.cancel();
    await _err.cancel();
    expect(errors, isEmpty, reason: evidence);
  }
}

Future<void> _waitFor(
  _ObservedRun run,
  Uri uri,
  bool Function(_HttpReply) accepted,
) async {
  final elapsed = Stopwatch()..start();
  _HttpReply? last;
  while (elapsed.elapsed < const Duration(seconds: 18)) {
    if (run.terminal) {
      fail('Server exited before its response. ${run.evidence}');
    }
    try {
      last = await _request('GET', uri);
      if (accepted(last)) return;
    } on SocketException {
      // Startup has not bound the socket yet.
    } on HttpException {
      // A listener may be starting while its web context is not ready yet.
    } on TimeoutException {
      // The whole request is bounded and the client was closed.
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  fail(
    'No matching application response at $uri. '
    'last=${last?.status} ${last?.body}\n${run.evidence}',
  );
}

class _HttpReply {
  const _HttpReply(this.status, this.body);
  final int status;
  final String body;
}

Future<_HttpReply> _request(
  String method,
  Uri uri, {
  Map<String, String>? fields,
}) async {
  expect(uri.scheme, 'http');
  expect(uri.host, '127.0.0.1');
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 1)
    ..findProxy = (_) => 'DIRECT';
  try {
    return await (() async {
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      if (fields != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        request.add(utf8.encode(Uri(queryParameters: fields).query));
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return _HttpReply(response.statusCode, body);
    })().timeout(const Duration(seconds: 3));
  } finally {
    client.close(force: true);
  }
}

/// TestWidgetsFlutterBinding normally substitutes HTTP 400 responses. Inherit
/// the real dart:io factory in this zone, including the product runner's probes.
class _RealHttpOverrides extends HttpOverrides {}

Uri _uri(int port, String context, String leaf) => Uri(
  scheme: 'http',
  host: '127.0.0.1',
  port: port,
  path: '${context == '/' ? '' : context}/$leaf',
);

Future<int> _unusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _waitPortFree(int port) async {
  final elapsed = Stopwatch()..start();
  while (true) {
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      await socket.close();
      return;
    } on SocketException {
      if (elapsed.elapsed >= const Duration(seconds: 3)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

void _config(
  Directory project, {
  required String profile,
  required int port,
  String context = '/',
  String webRoot = 'src/main/webapp',
}) {
  _write(
    project,
    JavaWebProject.configFileName,
    jsonEncode({
      'schemaVersion': 1,
      'profile': profile,
      if (profile == 'spring-boot') 'mainClass': 'acceptance.boot.Application',
      'port': port,
      'contextPath': context,
      'webRoot': webRoot,
      'database': false,
    }),
  );
}

void _write(Directory project, String relative, String text) {
  final file = File(p.join(project.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

Map<String, List<int>> _snapshot(Directory project) => {
  for (final file
      in project
          .listSync(recursive: true, followLinks: false)
          .whereType<File>())
    p.relative(file.path, from: project.path): file.readAsBytesSync(),
};

void _expectSnapshot(Directory project, Map<String, List<int>> before) {
  final after = _snapshot(project);
  expect(after.keys.toSet(), before.keys.toSet());
  for (final path in before.keys) {
    expect(after[path], before[path], reason: 'Source changed: $path');
  }
}

void _expectDeploymentRemoved(_ObservedRun run) {
  const prefix = 'qfli-javaee8-docBase=';
  final paths = run.stdout.where((line) => line.startsWith(prefix)).toList();
  expect(paths, hasLength(1), reason: run.evidence);
  expect(
    Directory(paths.single.substring(prefix.length)).existsSync(),
    isFalse,
    reason: 'Deployment must be removed after the exact JVM exit.',
  );
}

const _bootSource = r'''package acceptance.boot;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;

@SpringBootApplication
@RestController
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
    @GetMapping("/health")
    public Map<String, String> health() throws Exception {
        try (InputStream input = Application.class.getResourceAsStream("/runtime-proof.txt")) {
            if (input == null) throw new IllegalStateException("Resource is missing");
            return Map.of("profile", "spring-boot", "instance", "__NONCE__",
                "resource", new String(input.readAllBytes(), StandardCharsets.UTF_8));
        }
    }
    @PostMapping(path = "/form", consumes = MediaType.APPLICATION_FORM_URLENCODED_VALUE)
    public Map<String, String> form(@ModelAttribute FormData form) {
        return Map.of("title", form.getTitle(), "author", form.getAuthor(),
            "instance", "__NONCE__");
    }
    public static class FormData {
        private String title;
        private String author;
        public String getTitle() { return title; }
        public void setTitle(String value) { title = value; }
        public String getAuthor() { return author; }
        public void setAuthor(String value) { author = value; }
    }
}
''';

const _servletSource = r'''package acceptance.legacy;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

public class HealthServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        response.setContentType("text/plain;charset=UTF-8");
        try (InputStream input = getClass().getResourceAsStream("/runtime-proof.txt")) {
            if (input == null) throw new IOException("Resource is missing");
            response.getWriter().print("EE8|"
                + new String(input.readAllBytes(), StandardCharsets.UTF_8) + "|__NONCE__");
        }
    }
    @Override
    protected void doPost(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        request.setCharacterEncoding("UTF-8");
        response.setContentType("text/plain;charset=UTF-8");
        response.getWriter().print("FORM|" + request.getParameter("title")
            + "|" + request.getParameter("author") + "|__NONCE__");
    }
}
''';

const _webXml = r'''<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="http://xmlns.jcp.org/xml/ns/javaee" version="4.0">
  <servlet>
    <servlet-name>health</servlet-name>
    <servlet-class>acceptance.legacy.HealthServlet</servlet-class>
  </servlet>
  <servlet-mapping>
    <servlet-name>health</servlet-name><url-pattern>/health</url-pattern>
  </servlet-mapping>
  <servlet-mapping>
    <servlet-name>health</servlet-name><url-pattern>/form</url-pattern>
  </servlet-mapping>
</web-app>
''';

const _jspSource =
    r'''<%@ page contentType="text/plain;charset=UTF-8" pageEncoding="UTF-8" %><%@ taglib prefix="c" uri="http://java.sun.com/jsp/jstl/core" %>JSP|<c:out value="${param.title}"/>|<c:forEach var="n" begin="1" end="3">${n}</c:forEach>|__NONCE__''';
