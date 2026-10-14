import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools_extra.dart';

/// Unit tests for the additional offline tools.
///
/// The digests, codecs and generators are all pure functions, so they are
/// checked directly here; the page only formats their output.
void main() {
  group('JavaBase64', () {
    test('round-trips ASCII and CJK', () {
      expect(JavaBase64.encode('hello'), 'aGVsbG8=');
      expect(JavaBase64.decode('aGVsbG8='), 'hello');
      const cjk = '你好，Java';
      expect(JavaBase64.decode(JavaBase64.encode(cjk)), cjk);
    });

    test('uses the URL-safe alphabet without padding', () {
      // A character whose UTF-8 bytes encode to the index-62 and index-63
      // symbols in the standard alphabet but '-' and '_' in the URL-safe one.
      // 'ÿ' is U+00FF -> C3 BF -> "w78=".
      const text = '\u00ff\u00ff\u00fe';
      final standard = JavaBase64.encode(text);
      final urlSafe = JavaBase64.encodeUrlSafe(text);
      expect(standard, isNot(urlSafe));
      expect(urlSafe, isNot(contains('+')));
      expect(urlSafe, isNot(contains('/')));
      expect(urlSafe, isNot(contains('=')));
      expect(JavaBase64.decodeUrlSafe(urlSafe), text);
    });

    test('reports invalid input instead of dropping it', () {
      expect(() => JavaBase64.decode('%%%'), throwsA(isA<FormatException>()));
    });
  });

  group('JavaUrlCodec', () {
    test('encodes spaces as + and escapes the rest', () {
      expect(JavaUrlCodec.encode('a b'), 'a+b');
      expect(JavaUrlCodec.encode('café'), 'caf%C3%A9');
      expect(JavaUrlCodec.encode('a=1&b=2'), 'a%3D1%26b%3D2');
    });

    test('decodes what it encoded', () {
      for (final text in ['a b', 'café', 'a=1&b=2', '中 文']) {
        expect(JavaUrlCodec.decode(JavaUrlCodec.encode(text)), text);
      }
    });

    test('rejects a malformed escape', () {
      expect(() => JavaUrlCodec.decode('%ZZ'), throwsA(isA<FormatException>()));
    });
  });

  group('JavaDigest', () {
    // vectors from RFC 1321, RFC 3174 and FIPS 180-4.
    test('matches the published test vectors', () {
      expect(
        JavaDigest.md5('abc'),
        '900150983cd24fb0d6963f7d28e17f72',
      );
      expect(
        JavaDigest.sha1('abc'),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
      expect(
        JavaDigest.sha256('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('matches the empty-input vectors', () {
      expect(JavaDigest.md5(''), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(
        JavaDigest.sha1(''),
        'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      );
      expect(
        JavaDigest.sha256(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('handles input past one 64-byte block', () {
      // 62 bytes pushes the padding into a second block, which catches
      // length-padding mistakes. The expected values are the published ones for
      // this exact input.
      const long =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(
        JavaDigest.sha256(long),
        'f506898cc7c2e092f9eb9fadae7ba50383f5b46a2a4fe5597dbb553a78981268',
      );
      // The md5 of 1M 'a' is a standard long-vector check.
      expect(
        JavaDigest.md5('a' * 1000000),
        '7707d6ae4e027c70eea2a935c2296f21',
      );
    });

    test('all() reports the three digests together', () {
      final result = JavaDigest.all('abc');
      expect(result.keys, ['MD5', 'SHA-1', 'SHA-256']);
      expect(result['MD5'], '900150983cd24fb0d6963f7d28e17f72');
    });
  });

  group('JavaRegex', () {
    test('finds matches with index and groups', () {
      final result = JavaRegex.test(r'(\d+)-(\d+)', 'a 12-34 b 56-78');
      expect(result.ok, isTrue);
      expect(result.matches.length, 2);
      expect(result.matches.first.value, '12-34');
      expect(result.matches.first.index, 2);
      expect(result.matches.first.groups, ['12', '34']);
    });

    test('reports an invalid pattern instead of throwing', () {
      final result = JavaRegex.test('(', 'x');
      expect(result.ok, isFalse);
      expect(result.error, contains('正则无效'));
    });

    test('honours the flags', () {
      expect(JavaRegex.test('ABC', 'abc').matches, isEmpty);
      expect(
        JavaRegex.test('ABC', 'abc', caseSensitive: false).matches.length,
        1,
      );
      // Without dotAll a newline is not matched by '.'.
      expect(JavaRegex.test('a.b', 'a\nb').matches, isEmpty);
      expect(JavaRegex.test('a.b', 'a\nb', dotAll: true).matches.length, 1);
    });

    test('caps the match list', () {
      final result = JavaRegex.test('a', 'a' * 500);
      expect(result.truncated, isTrue);
      expect(result.matches.length, JavaRegex.maxMatches);
    });

    test('replaceAll rewrites every match', () {
      expect(JavaRegex.replaceAll(r'\d', 'a1b2', '#'), 'a#b#');
    });
  });

  group('JavaColorInfo', () {
    test('parses the three hex widths', () {
      expect(JavaColorInfo.parse('#fff').hexArgb, '#FFFFFFFF');
      expect(JavaColorInfo.parse('#FF0000').hexArgb, '#FFFF0000');
      expect(JavaColorInfo.parse('#80FF0000').alpha, 0x80);
      expect(JavaColorInfo.parse('FF0000').hexRgb, '#FF0000');
    });

    test('renders the notations Java/Android use', () {
      final color = JavaColorInfo.parse('#336699');
      expect(color.hexArgb, '#FF336699');
      expect(color.hexRgb, '#336699');
      expect(color.kotlinHex, '0xFF336699');
      expect(color.cssRgb, 'rgb(51, 102, 153)');
      expect(color.red, 0x33);
      expect(color.green, 0x66);
      expect(color.blue, 0x99);
    });

    test('reports an invalid colour', () {
      expect(() => JavaColorInfo.parse('nope'), throwsA(isA<FormatException>()));
      expect(() => JavaColorInfo.parse('#12345'), throwsA(isA<FormatException>()));
    });

    test('computes hue/saturation/lightness', () {
      final red = JavaColorInfo.parse('#FF0000');
      expect(red.hue, 0);
      expect(red.saturation, 1);
      final grey = JavaColorInfo.parse('#808080');
      expect(grey.saturation, 0);
      expect(grey.cssHsl, contains('%'));
    });
  });

  group('JavaUuid', () {
    test('v4 has the right shape and version bits', () {
      final uuid = JavaUuid.v4();
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(uuid),
        isTrue,
        reason: uuid,
      );
    });

    test('v4 is not constant', () {
      expect(JavaUuid.v4(), isNot(JavaUuid.v4()));
    });

    test('v5 is deterministic for a name in the DNS namespace', () {
      // The well-known reference value for "www.example.com" in the DNS
      // namespace.
      expect(
        JavaUuid.v5('www.example.com', '6ba7b810-9dad-11d1-80b4-00c04fd430c8'),
        '2ed6657d-e927-568b-95e1-2665a8aea6a2',
      );
    });

    test('v3 is deterministic and carries version 3', () {
      final uuid = JavaUuid.v3('www.example.com', '');
      expect(uuid, JavaUuid.v3('www.example.com', ''));
      expect(uuid[14], '3');
    });
  });

  group('JavaReference', () {
    test('lists the eight primitives and the keywords', () {
      expect(JavaReference.primitives.length, 8);
      expect(JavaReference.primitives.first.name, 'byte');
      expect(JavaReference.keywords.map((e) => e.name), contains('volatile'));
      expect(JavaReference.keywords.length, greaterThan(50));
    });

    test('documents the Java escapes', () {
      final names = JavaReference.escapes.map((e) => e.name).toList();
      expect(names, containsAll([r'\n', r'\t', r'\\', r'\uXXXX']));
    });
  });
}
