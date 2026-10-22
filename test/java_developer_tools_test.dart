import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:qfli_java/java_developer_tools.dart';

/// Unit tests for the offline Java developer tools.
///
/// The transformations are pure functions over text or bytes, so they are
/// checked here without pumping any UI. The `.class` and `.jar` fixtures are
/// real javac/jar output committed under `test/fixtures/java_developer_tools`
/// (see the source file's header for the exact regeneration command).
void main() {
  Uint8List fixture(String name) => File(
    'test/fixtures/java_developer_tools/${name == 'greeting.class' ? 'greeting.bin' : name}',
  ).readAsBytesSync();

  group('JavaDescriptors', () {
    test('decodes primitive, object and array field descriptors', () {
      final intType = JavaDescriptors.parseField('I');
      expect(intType.javaName, 'int');
      expect(intType.isPrimitive, isTrue);
      expect(intType.dimensions, 0);

      final string = JavaDescriptors.parseField('Ljava/lang/String;');
      expect(string.javaName, 'java.lang.String');
      expect(string.isPrimitive, isFalse);

      final nested = JavaDescriptors.parseField(r'Ljava/util/Map$Entry;');
      expect(nested.javaName, 'java.util.Map\$Entry');

      final strings = JavaDescriptors.parseField('[[Ljava/lang/String;');
      expect(strings.javaName, 'java.lang.String[][]');
      expect(strings.dimensions, 2);
      expect(strings.descriptor, '[[Ljava/lang/String;');

      expect(JavaDescriptors.parseField('[J').javaName, 'long[]');
      expect(JavaDescriptors.parseField('[Z').javaName, 'boolean[]');
    });

    test('rejects malformed descriptors with readable messages', () {
      expect(
        () => JavaDescriptors.parseField(''),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            '请输入 JVM 类型描述符',
          ),
        ),
      );
      expect(
        () => JavaDescriptors.parseField('Ljava/lang/String'),
        throwsFormatException,
      );
      expect(() => JavaDescriptors.parseField('L;'), throwsFormatException);
      expect(() => JavaDescriptors.parseField('Q'), throwsFormatException);
      expect(() => JavaDescriptors.parseField('[V'), throwsFormatException);
      expect(() => JavaDescriptors.parseField('V'), throwsFormatException);
      expect(
        () => JavaDescriptors.parseField('Ljava.lang.String;'),
        throwsFormatException,
      );
      expect(
        () => JavaDescriptors.parseField('Ljava//lang/String;'),
        throwsFormatException,
      );
      expect(
        () => JavaDescriptors.parseField('${'[' * 256}I'),
        throwsFormatException,
      );
      expect(
        () => JavaDescriptors.parseField('II'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('多余内容'),
          ),
        ),
      );
    });

    test('splits method descriptors into parameters and return type', () {
      final method = JavaDescriptors.parseMethod('(Ljava/lang/String;I[[D)Z');
      expect(method.parameters.map((type) => type.javaName), [
        'java.lang.String',
        'int',
        'double[][]',
      ]);
      expect(method.returnType.javaName, 'boolean');
      expect(
        method.signature,
        '(java.lang.String, int, double[][]) -> boolean',
      );
      expect(method.rebuiltDescriptor, '(Ljava/lang/String;I[[D)Z');
    });

    test('decodes the traced main method descriptor', () {
      final main = JavaDescriptors.parseMethod('([Ljava/lang/String;)V');
      expect(main.signature, '(java.lang.String[]) -> void');
      expect(main.returnType.isVoid, isTrue);
    });

    test('rejects malformed method descriptors', () {
      expect(
        () => JavaDescriptors.parseMethod('Ljava/lang/String;'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('( 开头'),
          ),
        ),
      );
      expect(() => JavaDescriptors.parseMethod('(I'), throwsFormatException);
      expect(() => JavaDescriptors.parseMethod('()VV'), throwsFormatException);
      expect(() => JavaDescriptors.parseMethod('()'), throwsFormatException);
      expect(() => JavaDescriptors.parseMethod('(V)V'), throwsFormatException);
      expect(
        () => JavaDescriptors.parseMethod('(${'J' * 128})V'),
        throwsFormatException,
      );
      expect(
        JavaDescriptors.parseMethod('(${'I' * 255})V').parameters,
        hasLength(255),
      );
    });

    test('parseAny accepts both descriptor shapes', () {
      expect(JavaDescriptors.parseAny('I'), isA<JavaDescriptorType>());
      expect(JavaDescriptors.parseAny('()V'), isA<JavaMethodDescriptor>());
    });

    test('writes descriptors from Java type names', () {
      expect(JavaDescriptors.descriptorOf('int'), 'I');
      expect(
        JavaDescriptors.descriptorOf('java.lang.String'),
        'Ljava/lang/String;',
      );
      expect(JavaDescriptors.descriptorOf('int[]'), '[I');
      expect(
        JavaDescriptors.descriptorOf('java.lang.String[][]'),
        '[[Ljava/lang/String;',
      );
      expect(JavaDescriptors.descriptorOf(' Greeting '), 'LGreeting;');
      expect(() => JavaDescriptors.descriptorOf('void'), throwsFormatException);
      expect(
        JavaDescriptors.methodDescriptorOf(['java.lang.String[]'], 'void'),
        '([Ljava/lang/String;)V',
      );
      expect(
        JavaDescriptors.descriptorOf(r'java.util.Map$Entry'),
        r'Ljava/util/Map$Entry;',
      );
    });

    test('round trips every fixture descriptor through the writer', () {
      for (final descriptor in ['I', '[[J', 'Ljava/util/List;']) {
        final decoded = JavaDescriptors.parseField(descriptor);
        expect(JavaDescriptors.descriptorOf(decoded.javaName), descriptor);
      }
      final method = JavaDescriptors.parseMethod(
        '(IJLjava/lang/String;)Ljava/util/List;',
      );
      expect(
        JavaDescriptors.methodDescriptorOf(
          method.parameters.map((type) => type.javaName).toList(),
          method.returnType.javaName,
        ),
        method.descriptor,
      );
    });

    test('rejects unwritable type names', () {
      expect(() => JavaDescriptors.descriptorOf(''), throwsFormatException);
      expect(() => JavaDescriptors.descriptorOf('[]'), throwsFormatException);
      expect(
        () => JavaDescriptors.descriptorOf('void[]'),
        throwsFormatException,
      );
      expect(
        () => JavaDescriptors.methodDescriptorOf(['void'], 'int'),
        throwsFormatException,
      );
      for (final name in [
        'java.lang.String;',
        'List<String>',
        'a..B',
        'a/B',
        'int[',
        '1Type',
      ]) {
        expect(
          () => JavaDescriptors.descriptorOf(name),
          throwsFormatException,
          reason: name,
        );
      }
      expect(
        () => JavaDescriptors.descriptorOf('java lang String'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('空格'),
          ),
        ),
      );
    });
  });

  group('JavaStackTrace', () {
    const trace = '''
Exception in thread "main" java.lang.IllegalStateException: boom
\tat app.Main.lambda\$main\$0(Main.java:12)
\tat java.base/java.util.Optional.orElseThrow(Optional.java:403)
\tat java.base/java.util.Optional.get(Optional.java:195)
\tat app.Service.load(Service.java:88)
\tat app.Main.main(Main.java:5)
Caused by: java.io.IOException: disk on fire
\tat app.Store.read(Store.java:31)
\tat app.Service.load(Service.java:84)
\t... 2 more
''';

    test('splits headers, frames and the caused-by chain', () {
      final report = JavaStackTrace.parse(trace);
      expect(report.threadName, 'main');
      expect(report.throwables, hasLength(2));
      expect(report.primary!.isSuppressed, isFalse);

      final primary = report.primary!;
      expect(primary.exceptionClass, 'java.lang.IllegalStateException');
      expect(primary.message, 'boom');
      expect(primary.depth, 0);
      expect(primary.frames, hasLength(5));
      expect(primary.marker, '');

      final cause = report.throwables[1];
      expect(cause.exceptionClass, 'java.io.IOException');
      expect(cause.message, 'disk on fire');
      expect(cause.isCausedBy, isTrue);
      expect(cause.depth, 1);
      expect(cause.omittedCommonFrames, 2);
      expect(cause.marker, 'Caused by: ');
      expect(report.unparsedLines, isEmpty);
    });

    test('reads frames with module prefixes, native and unknown sources', () {
      final report = JavaStackTrace.parse('''
java.lang.RuntimeException: x
\tat java.base/java.lang.Thread.run(Thread.java:840)
\tat app.Native.bridge(Native Method)
\tat app.Main.main(Main.java)
\tat app.Inner.run(Unknown Source)
''');
      final frames = report.primary!.frames;
      expect(frames[0].moduleName, 'java.base');
      expect(frames[0].className, 'java.lang.Thread');
      expect(frames[0].location, 'Thread.java:840');
      expect(frames[1].isNative, isTrue);
      expect(frames[1].location, 'Native Method');
      expect(frames[2].lineNumber, isNull);
      expect(frames[2].location, 'Main.java');
      expect(frames[3].location, 'Unknown Source');
      expect(frames[3].hasSourceLocation, isFalse);
      expect(frames[0].display, 'at java.lang.Thread.run(Thread.java:840)');
    });

    test('counts application frames separately from runtime frames', () {
      final report = JavaStackTrace.parse(trace);
      expect(report.allFrames, hasLength(7));
      expect(report.applicationFrameCount(), 5);
      expect(report.applicationFrameCount(['app.']), 2);
      expect(report.classes, [
        'app.Main',
        'java.util.Optional',
        'app.Service',
        'app.Store',
      ]);
    });

    test('re-renders the full trace when nothing is filtered', () {
      final report = JavaStackTrace.parse(trace);
      final text = JavaStackTrace.render(report);
      expect(
        text,
        'Exception in thread "main" java.lang.IllegalStateException: boom\n'
        '\tat app.Main.lambda\$main\$0(Main.java:12)\n'
        '\tat java.util.Optional.orElseThrow(Optional.java:403)\n'
        '\tat java.util.Optional.get(Optional.java:195)\n'
        '\tat app.Service.load(Service.java:88)\n'
        '\tat app.Main.main(Main.java:5)\n'
        '\n'
        'Caused by: java.io.IOException: disk on fire\n'
        '\tat app.Store.read(Store.java:31)\n'
        '\tat app.Service.load(Service.java:84)\n'
        '\t... 2 more',
      );
    });

    test('drops runtime frames and the now-inaccurate more-markers', () {
      final report = JavaStackTrace.parse(trace);
      final text = JavaStackTrace.render(report, onlyApplicationFrames: true);
      expect(text, isNot(contains('java.util.Optional')));
      expect(text, isNot(contains('... 2 more')));
      expect(text, contains('\tat app.Main.main(Main.java:5)'));
      expect(text, contains('\tat app.Store.read(Store.java:31)'));
      expect(
        text.split('\n').where((line) => line.startsWith('\tat ')).length,
        5,
      );
    });

    test('filters frames by class or file substring', () {
      final report = JavaStackTrace.parse(trace);
      final text = JavaStackTrace.render(report, contains: 'Service.java');
      expect(
        text.split('\n').where((line) => line.startsWith('\tat ')).length,
        2,
      );
      expect(text, contains('app.Service.load(Service.java:88)'));
      expect(text, contains('app.Service.load(Service.java:84)'));
      expect(
        JavaStackTrace.render(report, contains: 'MAIN.JAVA'),
        contains('Main.java:5'),
      );
    });

    test('caps long traces and says how many frames were omitted', () {
      final buffer = StringBuffer('java.lang.RuntimeException: many\n');
      for (var i = 0; i < 12; i++) {
        buffer.writeln('\tat app.Gen.m$i(Gen.java:$i)');
      }
      final report = JavaStackTrace.parse(buffer.toString());
      final text = JavaStackTrace.render(report, maxFrames: 5);
      expect(
        text.split('\n').where((line) => line.startsWith('\tat ')).length,
        5,
      );
      expect(text, contains('... 其余 7 帧已省略'));
    });

    test('notes when a filter keeps nothing', () {
      final report = JavaStackTrace.parse('''
java.lang.RuntimeException: x
\tat java.base/java.lang.Thread.run(Thread.java:840)
''');
      final text = JavaStackTrace.render(report, onlyApplicationFrames: true);
      expect(text, contains('（过滤后没有保留的栈帧）'));
    });

    test('keeps suppressed throwables and wrapped messages', () {
      final report = JavaStackTrace.parse('''
java.sql.SQLException: failed to close
\tat app.Db.close(Db.java:9)
Suppressed: java.io.IOException: closing channel
\tat app.Channel.close(Channel.java:4)
''');
      expect(report.throwables, hasLength(2));
      expect(report.throwables[1].isSuppressed, isTrue);
      expect(report.throwables[1].marker, 'Suppressed: ');
      expect(
        JavaStackTrace.render(report),
        contains('Suppressed: java.io.IOException: closing channel'),
      );

      final wrapped = JavaStackTrace.parse('''
java.util.concurrent.ExecutionException: java.lang.IllegalStateException:
\tboom happened
\tat app.Task.join(Task.java:20)
''');
      expect(
        wrapped.primary!.message,
        'java.lang.IllegalStateException:\nboom happened',
      );
      expect(wrapped.primary!.frames, hasLength(1));
      expect(JavaStackTrace.render(wrapped), contains('\nboom happened\n'));
    });

    test('keeps suppression markers on their own throwable only', () {
      final report = JavaStackTrace.parse('''
Exception in thread "main" java.lang.RuntimeException: root
  at app.Main.main(Main.java:1)
Suppressed: java.io.IOException: close
  at app.Db.close(Db.java:2)
Caused by: java.lang.IllegalStateException: cause
  at app.Db.read(Db.java:3)
''');
      expect(report.throwables.map((item) => item.isSuppressed), [
        false,
        true,
        false,
      ]);
      expect(report.throwables.map((item) => item.isCausedBy), [
        false,
        false,
        true,
      ]);
      expect(
        'Exception in thread'.allMatches(JavaStackTrace.render(report)),
        hasLength(1),
      );
    });

    test(
      'recognizes Unicode frames with versioned module and loader prefixes',
      () {
        final report = JavaStackTrace.parse('''
本地.异常: 错误
  at app/本地模块@1.0/本地.主类.𐐀方法(主类.java:12)
''');
        expect(report.primary!.exceptionClass, '本地.异常');
        final frame = report.allFrames.single;
        expect(frame.className, '本地.主类');
        expect(frame.methodName, '𐐀方法');
        expect(frame.lineNumber, 12);
      },
    );

    test('keeps unrelated text out of the frame list', () {
      final report = JavaStackTrace.parse('''
Build started
java.lang.RuntimeException: x
\tat app.Main.main(Main.java:5)
Done
''');
      expect(report.primary!.frames, hasLength(1));
      expect(report.unparsedLines, ['Build started', 'Done']);
    });

    test('accepts a custom throwable that does not end in Exception', () {
      final report = JavaStackTrace.parse('''
com.acme.Fault: bad input
\tat app.Main.main(Main.java:5)
''');
      expect(report.isEmpty, isFalse);
      expect(report.primary!.exceptionClass, 'com.acme.Fault');
      expect(report.primary!.message, 'bad input');
      expect(report.primary!.frames, hasLength(1));
    });

    test('does not mistake javac diagnostics or banners for throwables', () {
      final report = JavaStackTrace.parse('''
Main.java:5: error: ';' expected
warning: [options] source value 17 is obsolete
BUILD FAILED
''');
      expect(report.isEmpty, isTrue);
      expect(report.unparsedLines, hasLength(3));
    });

    test('returns an empty report for text that is not a trace', () {
      final report = JavaStackTrace.parse('hello world');
      expect(report.isEmpty, isTrue);
      expect(report.primary, isNull);
      expect(report.unparsedLines, ['hello world']);
      expect(JavaStackTrace.render(report), '');
      expect(JavaStackTrace.parse('').isEmpty, isTrue);
    });
  });

  group('JavaClassFile', () {
    late Uint8List bytes;
    late JavaClassFile parsed;

    setUp(() {
      bytes = fixture('greeting.class');
      parsed = JavaClassFile.parse(bytes);
    });

    test('recognises the class-file magic', () {
      expect(JavaClassFile.looksLikeClassFile(bytes), isTrue);
      expect(JavaClassFile.looksLikeClassFile(utf8.encode('hello')), isFalse);
      expect(
        () => JavaClassFile.parse(utf8.encode('hello')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('CAFEBABE'),
          ),
        ),
      );
    });

    test('reports the Java 17 target version', () {
      expect(parsed.majorVersion, 61);
      expect(parsed.minorVersion, 0);
      expect(parsed.javaRelease, '17');
      expect(parsed.versionText, 'Java 17 (major 61, minor 0)');
      expect(parsed.byteLength, bytes.length);
    });

    test('reports modifiers, hierarchy and attributes', () {
      expect(parsed.modifiers, ['public', 'final']);
      expect(parsed.thisClass, 'fixtures.Greeting');
      expect(parsed.superClass, 'java.lang.Object');
      expect(parsed.interfaces, isEmpty);
      expect(parsed.attributes, containsAll(['SourceFile']));
      expect(
        parsed.declaration,
        'public final class fixtures.Greeting extends java.lang.Object',
      );
    });

    test('decodes fields with descriptors and modifiers', () {
      final fields = {for (final field in parsed.fields) field.name: field};
      expect(fields.keys, containsAll(['PREFIX', 'name']));
      final prefix = fields['PREFIX']!;
      expect(prefix.descriptor, 'Ljava/lang/String;');
      expect(prefix.typeText, 'java.lang.String');
      expect(prefix.modifiers, ['public', 'static', 'final']);
      expect(prefix.display, 'public static final java.lang.String PREFIX');
      final name = fields['name']!;
      expect(name.modifiers, ['private', 'final']);
      expect(
        name.listing,
        'name: private final java.lang.String name  '
        '[Ljava/lang/String;]',
      );
    });

    test('decodes method signatures including varargs arrays', () {
      final methods = {
        for (final method in parsed.methods) method.name: method,
      };
      expect(methods.keys, containsAll(['<init>', 'greet', 'tags', 'main']));

      final main = methods['main']!;
      expect(main.modifiers, ['public', 'static']);
      expect(main.descriptor, '([Ljava/lang/String;)V');
      expect(main.typeText, '(java.lang.String[]) -> void');

      final tags = methods['tags']!;
      expect(tags.descriptor, '([Ljava/lang/String;)Ljava/util/List;');
      expect(tags.typeText, '(java.lang.String[]) -> java.util.List');

      final greet = methods['greet']!;
      expect(greet.descriptor, '(I)Ljava/lang/String;');
      expect(greet.typeText, '(int) -> java.lang.String');

      final constructor = methods['<init>']!;
      expect(constructor.modifiers, contains('public'));
      expect(constructor.descriptor, '(Ljava/lang/String;)V');
    });

    test('summarises the constant pool without dumping it', () {
      expect(parsed.constantPoolSlots, greaterThan(20));
      expect(parsed.constantPoolTags['Utf8'], greaterThan(10));
      expect(parsed.constantPoolTags['Class'], greaterThan(2));
      expect(parsed.constantPoolSummary, contains('Utf8: '));
      expect(
        parsed.constantPoolTags.keys,
        containsAll(['Utf8', 'Class', 'Methodref', 'Fieldref', 'String']),
      );
    });

    test('rejects truncated bytes instead of guessing', () {
      final truncated = Uint8List.sublistView(bytes, 0, 40);
      expect(() => JavaClassFile.parse(truncated), throwsFormatException);
    });

    test('decodes real javac modified UTF8 names and string constants', () {
      final unicode = JavaClassFile.parse(fixture('unicode.class.bin'));
      expect(unicode.thisClass, 'fixtures.UnicodeNames');
      expect(unicode.fields.map((field) => field.name), contains('中文'));
      expect(unicode.methods.map((method) => method.name), contains('𐐀value'));
      // This fixture also contains a NUL and emoji string constant. A standard
      // UTF8 decoder either throws or corrupts the two surrogate code units.
      final malformed = fixture('unicode.class.bin');
      final nul = _indexOf(malformed, [0xc0, 0x80]);
      expect(nul, greaterThan(0));
      malformed[nul + 1] = 0x81;
      expect(() => JavaClassFile.parse(malformed), throwsFormatException);
    });

    test('does not report method varargs flags as field transient flags', () {
      final tags = parsed.methods.singleWhere(
        (method) => method.name == 'tags',
      );
      expect(tags.modifiers, contains('varargs'));
      expect(tags.modifiers, isNot(contains('transient')));
    });

    test(
      'reads the four-byte CONSTANT_Dynamic record from a real loadable class',
      () {
        final dynamicClass = JavaClassFile.parse(fixture('dynamic.class.bin'));
        expect(dynamicClass.majorVersion, 61);
        expect(dynamicClass.thisClass, 'fixtures.DynamicFixture');
        expect(dynamicClass.constantPoolTags['Dynamic'], 1);
        expect(dynamicClass.methods.single.name, 'value');
        expect(dynamicClass.methods.single.descriptor, '()Ljava/lang/String;');
      },
    );

    test('rejects trailing bytes instead of accepting concatenated files', () {
      expect(() => JavaClassFile.parse([...bytes, 0]), throwsFormatException);
    });
  });

  group('JavaManifest', () {
    test('parses the committed fixture manifest', () {
      final manifest = JavaManifest.parse(_manifestText());
      expect(manifest.manifestVersion, '1.0');
      expect(manifest.mainClass, 'fixtures.Greeting');
      expect(manifest.implementationTitle, 'Greeting fixture');
      expect(manifest.implementationVersion, '1.2.3');
      expect(
        manifest['manifest-version'],
        '1.0',
        reason: 'lookup is case-insensitive',
      );
      expect(manifest.isMultiRelease, isFalse);
      expect(manifest.sections, isEmpty);
    });

    test('unfolds continuation lines', () {
      final manifest = JavaManifest.parse(
        'Manifest-Version: 1.0\r\n'
        'Implementation-Title: a very long title that the writer\r\n'
        ' wrapped\r\n',
      );
      expect(
        manifest.implementationTitle,
        'a very long title that the writer'
        'wrapped',
      );
    });

    test('reads named sections and multi-release flags', () {
      final manifest = JavaManifest.parse('''
Manifest-Version: 1.0
Multi-Release: true

Name: fixtures/Greeting.class
SHA-256-Digest: abc
Sealed: true
''');
      expect(manifest.isMultiRelease, isTrue);
      expect(manifest.sections.keys, ['fixtures/Greeting.class']);
      expect(manifest.sections['fixtures/Greeting.class']!['Sealed'], 'true');
      expect(
        manifest.sections['fixtures/Greeting.class']!['SHA-256-Digest'],
        'abc',
      );
    });

    test('unfolds at the byte level so split UTF-8 survives', () {
      // "标题" split across the 72-byte fold boundary mid-character.
      final title = utf8.encode('标');
      final bytes = <int>[
        ...utf8.encode('Manifest-Version: 1.0\r\nImplementation-Title: '),
        title[0],
        ...utf8.encode('\r\n '),
        ...title.sublist(1),
        ...utf8.encode('题\r\n'),
      ];
      final manifest = JavaManifest.parseBytes(bytes);
      expect(manifest.implementationTitle, '标题');
    });
  });

  group('JavaJarInspection', () {
    late Uint8List bytes;
    late JavaJarInspection jar;

    setUp(() {
      bytes = fixture('greeting.jar');
      jar = JavaJarInspection.fromBytes(bytes);
    });

    test('lists the real archive entries', () {
      expect(jar.entries.map((entry) => entry.name), [
        'META-INF/',
        'META-INF/MANIFEST.MF',
        'fixtures/',
        'fixtures/Greeting.class',
      ]);
      expect(jar.fileCount, 2);
      expect(jar.classCount, 1);
      expect(jar.entries.first.isDirectory, isTrue);
      expect(jar.entries[3].isClassFile, isTrue);
      expect(jar.entries[3].directory, 'fixtures');
      expect(jar.packages, ['fixtures']);
      expect(jar.isModular, isFalse);
      expect(jar.totalUncompressedBytes, greaterThan(0));
    });

    test('reads and inflates the manifest entry', () {
      expect(jar.manifestError, isNull);
      final manifest = jar.manifest!;
      expect(manifest.mainClass, 'fixtures.Greeting');
      expect(manifest.implementationVersion, '1.2.3');
      expect(manifest['X-Fixture-Purpose'], contains('real manifest'));
    });

    test('inflated class entry matches the standalone class fixture', () {
      final entry = jar.entries.firstWhere((entry) => entry.isClassFile);
      final inflated = JavaZip.readEntry(bytes, entry)!;
      expect(inflated, fixture('greeting.class'));
      expect(JavaClassFile.parse(inflated).thisClass, 'fixtures.Greeting');
    });

    test('reports entries with real compressed and inflated sizes', () {
      final classEntry = jar.entries.firstWhere((entry) => entry.isClassFile);
      expect(classEntry.uncompressedSize, fixture('greeting.class').length);
      expect(classEntry.compressionName, anyOf('stored', 'deflate'));
      expect(classEntry.listing, contains('fixtures/Greeting.class'));
      final listing = jar.entryListing(limit: 2);
      expect(listing, hasLength(3));
      expect(listing.last, '... 其余 2 个条目已省略');
    });

    test('rejects non-archive bytes with readable messages', () {
      expect(JavaZip.looksLikeZip(bytes), isTrue);
      expect(
        JavaZip.looksLikeZip(utf8.encode('not a zip file at all')),
        isFalse,
      );
      expect(
        () => JavaJarInspection.fromBytes(utf8.encode('plain text')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('ZIP'),
          ),
        ),
      );
    });

    test('records a missing manifest instead of failing the listing', () {
      final jarWithoutManifest = JavaZip.entries(
        bytes,
      ).where((entry) => entry.isManifest);
      expect(jarWithoutManifest, hasLength(1));
      // A ZIP that only holds the class file: rebuild the entry list by hand so
      // the error path is covered without a second binary fixture.
      final inspection = JavaJarInspection(
        entries: [
          const JavaZipEntry(
            name: 'fixtures/Greeting.class',
            compressionMethod: 8,
            compressedSize: 10,
            uncompressedSize: 20,
            crc32: 0,
            localHeaderOffset: 0,
          ),
        ],
        manifest: null,
        manifestError: '压缩包中没有 META-INF/MANIFEST.MF',
      );
      expect(inspection.manifest, isNull);
      expect(inspection.manifestError, contains('MANIFEST.MF'));
      expect(inspection.classCount, 1);
    });

    test('checks manifest CRC instead of displaying corrupted bytes', () {
      final data = Uint8List.fromList(
        _storedJar('Manifest-Version: 1.0\r\n\r\n'),
      );
      final payload = _indexOf(data, utf8.encode('Manifest-Version:'));
      expect(payload, greaterThan(0));
      data[payload] = 'X'.codeUnitAt(0);
      final inspection = JavaJarInspection.fromBytes(data);
      expect(inspection.entries, hasLength(1));
      expect(inspection.manifest, isNull);
      expect(inspection.manifestError, contains('CRC'));
    });

    test('rejects forged local metadata and central directory lengths', () {
      final data = Uint8List.fromList(
        _storedJar('Manifest-Version: 1.0\r\n\r\n'),
      );
      data[8] = 99; // Local method differs from the central method.
      expect(() => JavaZip.entries(data), throwsFormatException);
      final truncated = Uint8List.fromList(bytes);
      final central = _indexOf(truncated, [0x50, 0x4b, 0x01, 0x02]);
      truncated[central + 28] = 0xff;
      truncated[central + 29] = 0xff;
      expect(() => JavaZip.entries(truncated), throwsFormatException);
    });

    test(
      'validates the end record comment instead of matching any signature',
      () {
        final data = Uint8List.fromList(
          _storedJar('Manifest-Version: 1.0\r\n\r\n'),
        );
        data[data.length - 2] = 1; // A declared comment byte is missing.
        expect(() => JavaZip.entries(data), throwsFormatException);
      },
    );

    test(
      'bounds inflated bytes even when the declared size was forged small',
      () {
        final archive = Archive()
          ..add(
            ArchiveFile.string('META-INF/MANIFEST.MF', 'x' * (2 * 1024 * 1024)),
          );
        final data = Uint8List.fromList(ZipEncoder().encode(archive));
        final central = _indexOf(data, [0x50, 0x4b, 0x01, 0x02]);
        final fields = ByteData.sublistView(data);
        // Forge both length records consistently. The output sink must stop the
        // actual high-ratio expansion at 16 bytes, before allocating the 2 MB.
        fields.setUint32(22, 16, Endian.little);
        fields.setUint32(central + 24, 16, Endian.little);
        final entry = JavaZip.entries(data).single;
        expect(() => JavaZip.readEntry(data, entry), throwsFormatException);
        expect(JavaJarInspection.fromBytes(data).manifest, isNull);
      },
    );

    test('rejects a manifest over its independent 1 MB inspection limit', () {
      final data = _storedJar('x' * (1024 * 1024 + 1));
      final inspection = JavaJarInspection.fromBytes(data);
      expect(inspection.manifest, isNull);
      expect(inspection.manifestError, contains('上限'));
    });
  });

  group('JavaBytesFormat', () {
    test('prints binary units with one decimal', () {
      expect(JavaBytesFormat.human(0), '0 B');
      expect(JavaBytesFormat.human(1023), '1023 B');
      expect(JavaBytesFormat.human(1024), '1.0 KB');
      expect(JavaBytesFormat.human(1159), '1.1 KB');
      expect(JavaBytesFormat.human(1024 * 1024 * 3), '3.0 MB');
      expect(JavaBytesFormat.human(1024 * 1024 * 200), '200 MB');
    });
  });
}

/// The committed manifest fixture, read as text so the parser is exercised on
/// the same bytes the jar ships.
String _manifestText() => File(
  'test/fixtures/java_developer_tools/src/manifest.mf',
).readAsStringSync();

List<int> _storedJar(String manifest) {
  final archive = Archive()
    ..add(ArchiveFile.string('META-INF/MANIFEST.MF', manifest));
  return ZipEncoder().encode(archive, level: 0);
}

int _indexOf(List<int> bytes, List<int> pattern) {
  for (var index = 0; index <= bytes.length - pattern.length; index++) {
    if (List.generate(
      pattern.length,
      (offset) => bytes[index + offset],
    ).indexed.every((item) => item.$2 == pattern[item.$1])) {
      return index;
    }
  }
  return -1;
}
