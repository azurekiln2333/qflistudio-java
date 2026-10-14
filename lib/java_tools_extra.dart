/// Additional offline conversion logic for the Java tools page.
///
/// Split from `java_tools.dart` to keep each file readable; both are pure Dart
/// so the widgets can stay thin and the arithmetic is unit testable. No network
/// and no new dependency: Base64 and UTF-8 come from `dart:convert`, and the
/// digests are implemented here because `crypto` is not in the lockfile.
library;

import 'dart:convert';
import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Base64
// ---------------------------------------------------------------------------

/// Base64 in the two alphabets Java's `Base64` class exposes.
abstract final class JavaBase64 {
  /// Standard alphabet (`Base64.getEncoder()`).
  static String encode(String text) => base64.encode(utf8.encode(text));

  /// Standard alphabet (`Base64.getDecoder()`); throws [FormatException] on
  /// invalid input rather than silently returning garbage.
  static String decode(String text) {
    final normalized = text.trim().replaceAll(RegExp(r'\s'), '');
    return utf8.decode(base64.decode(normalized));
  }

  /// URL-safe alphabet without padding (`Base64.getUrlEncoder().withoutPadding()`).
  static String encodeUrlSafe(String text) => base64Url
      .encode(utf8.encode(text))
      .replaceAll('=', '');

  /// URL-safe alphabet, padding restored.
  static String decodeUrlSafe(String text) {
    final normalized = text.trim().replaceAll(RegExp(r'\s'), '');
    final padding = (4 - normalized.length % 4) % 4;
    return utf8.decode(
      base64Url.decode('$normalized${'=' * padding}'),
    );
  }
}

// ---------------------------------------------------------------------------
// URL encoding
// ---------------------------------------------------------------------------

/// Percent-encoding as `URLEncoder`/`URLDecoder` do it in Java.
abstract final class JavaUrlCodec {
  /// `URLEncoder.encode`: spaces become `+`, and everything outside
  /// `A-Za-z0-9-_.*` is percent-encoded (Java's own unreserved set).
  static String encode(String text) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(text)) {
      final char = String.fromCharCode(byte);
      if (RegExp(r'[A-Za-z0-9\-_.*]').hasMatch(char)) {
        buffer.write(char);
      } else if (char == ' ') {
        buffer.write('+');
      } else {
        buffer.write(
          '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
    return buffer.toString();
  }

  /// `URLDecoder.decode`, which is the inverse of [encode] including `+`.
  static String decode(String text) {
    final bytes = <int>[];
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '+') {
        bytes.add(0x20);
      } else if (char == '%' && i + 2 < text.length) {
        final hex = text.substring(i + 1, i + 3);
        final value = int.tryParse(hex, radix: 16);
        if (value == null) throw FormatException('无效的百分号转义：%$hex');
        bytes.add(value);
        i += 2;
      } else {
        bytes.add(char.codeUnitAt(0));
      }
    }
    return utf8.decode(bytes);
  }
}

// ---------------------------------------------------------------------------
// Message digests
// ---------------------------------------------------------------------------

/// Pure-Dart `MessageDigest` equivalents.
///
/// Implemented here rather than pulled from `crypto`, which is not a dependency
/// of this app. All three are byte-oriented and operate on UTF-8 input.
abstract final class JavaDigest {
  static String md5(String text) => _hex(_md5(utf8.encode(text)));

  static String sha1(String text) => _hex(_sha1(utf8.encode(text)));

  static String sha256(String text) => _hex(_sha256(utf8.encode(text)));

  /// Raw-byte entry points, used by the UUID generators which hash binary
  /// namespace bytes rather than text.
  static List<int> md5Bytes(List<int> bytes) => _md5(bytes);

  static List<int> sha1Bytes(List<int> bytes) => _sha1(bytes);

  static List<int> sha256Bytes(List<int> bytes) => _sha256(bytes);

  /// MD5, SHA-1 and SHA-256 for one input, in the order the UI lists them.
  static Map<String, String> all(String text) => {
    'MD5': md5(text),
    'SHA-1': sha1(text),
    'SHA-256': sha256(text),
  };

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // -- MD5 (RFC 1321) ------------------------------------------------------

  static const List<int> _md5Shift = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];

  static List<int> _md5(List<int> input) {
    final message = _pad(input, littleEndianLength: true);
    var a0 = 0x67452301;
    var b0 = 0xefcdab89;
    var c0 = 0x98badcfe;
    var d0 = 0x10325476;
    const k = <int>[
      0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, //
      0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
      0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
      0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
      0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
      0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
      0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
      0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
      0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
      0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
      0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
      0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
      0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
      0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
      0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
      0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ];
    for (var offset = 0; offset < message.length; offset += 64) {
      final m = List<int>.generate(
        16,
        (i) => _readInt32(message, offset + i * 4, littleEndian: true),
      );
      var a = a0;
      var b = b0;
      var c = c0;
      var d = d0;
      for (var i = 0; i < 64; i++) {
        int f;
        int g;
        if (i < 16) {
          f = (b & c) | (~b & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | (~d & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | ~d);
          g = (7 * i) % 16;
        }
        f = _add32(_add32(_add32(f, a), k[i]), m[g]);
        a = d;
        d = c;
        c = b;
        b = _add32(b, _rotateLeft(f, _md5Shift[i]));
      }
      a0 = _add32(a0, a);
      b0 = _add32(b0, b);
      c0 = _add32(c0, c);
      d0 = _add32(d0, d);
    }
    final out = <int>[];
    for (final word in [a0, b0, c0, d0]) {
      out.addAll(_writeInt32(word, littleEndian: true));
    }
    return out;
  }

  // -- SHA-1 (RFC 3174) ----------------------------------------------------

  static List<int> _sha1(List<int> input) {
    final message = _pad(input, littleEndianLength: false);
    var h0 = 0x67452301;
    var h1 = 0xefcdab89;
    var h2 = 0x98badcfe;
    var h3 = 0x10325476;
    var h4 = 0xc3d2e1f0;
    for (var offset = 0; offset < message.length; offset += 64) {
      final w = List<int>.filled(80, 0);
      for (var i = 0; i < 16; i++) {
        w[i] = _readInt32(message, offset + i * 4, littleEndian: false);
      }
      for (var i = 16; i < 80; i++) {
        w[i] = _rotateLeft(
          w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16],
          1,
        );
      }
      var a = h0;
      var b = h1;
      var c = h2;
      var d = h3;
      var e = h4;
      for (var i = 0; i < 80; i++) {
        int f;
        int k;
        if (i < 20) {
          f = (b & c) | (~b & d);
          k = 0x5a827999;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 0x6ed9eba1;
        } else if (i < 60) {
          f = (b & c) | (b & d) | (c & d);
          k = 0x8f1bbcdc;
        } else {
          f = b ^ c ^ d;
          k = 0xca62c1d6;
        }
        final temp = _add32(
          _add32(_add32(_add32(_rotateLeft(a, 5), f), e), k),
          w[i],
        );
        e = d;
        d = c;
        c = _rotateLeft(b, 30);
        b = a;
        a = temp;
      }
      h0 = _add32(h0, a);
      h1 = _add32(h1, b);
      h2 = _add32(h2, c);
      h3 = _add32(h3, d);
      h4 = _add32(h4, e);
    }
    return [
      for (final word in [h0, h1, h2, h3, h4])
        ..._writeInt32(word, littleEndian: false),
    ];
  }

  // -- SHA-256 (FIPS 180-4) ------------------------------------------------

  static const List<int> _sha256K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static List<int> _sha256(List<int> input) {
    final message = _pad(input, littleEndianLength: false);
    final h = <int>[
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    for (var offset = 0; offset < message.length; offset += 64) {
      final w = List<int>.filled(64, 0);
      for (var i = 0; i < 16; i++) {
        w[i] = _readInt32(message, offset + i * 4, littleEndian: false);
      }
      for (var i = 16; i < 64; i++) {
        final s0 =
            _rotateRight(w[i - 15], 7) ^
            _rotateRight(w[i - 15], 18) ^
            (w[i - 15] >> 3);
        final s1 =
            _rotateRight(w[i - 2], 17) ^
            _rotateRight(w[i - 2], 19) ^
            (w[i - 2] >> 10);
        w[i] = _add32(_add32(_add32(w[i - 16], s0), w[i - 7]), s1);
      }
      var a = h[0];
      var b = h[1];
      var c = h[2];
      var d = h[3];
      var e = h[4];
      var f = h[5];
      var g = h[6];
      var hh = h[7];
      for (var i = 0; i < 64; i++) {
        final s1 = _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
        final ch = (e & f) ^ (~e & g);
        final temp1 = _add32(
          _add32(_add32(_add32(hh, s1), ch), _sha256K[i]),
          w[i],
        );
        final s0 = _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = _add32(s0, maj);
        hh = g;
        g = f;
        f = e;
        e = _add32(d, temp1);
        d = c;
        c = b;
        b = a;
        a = _add32(temp1, temp2);
      }
      h[0] = _add32(h[0], a);
      h[1] = _add32(h[1], b);
      h[2] = _add32(h[2], c);
      h[3] = _add32(h[3], d);
      h[4] = _add32(h[4], e);
      h[5] = _add32(h[5], f);
      h[6] = _add32(h[6], g);
      h[7] = _add32(h[7], hh);
    }
    return [
      for (final word in h) ..._writeInt32(word, littleEndian: false),
    ];
  }

  // -- shared helpers ------------------------------------------------------

  /// Appends the `10…0` padding and the 64-bit big/little-endian length.
  static List<int> _pad(List<int> input, {required bool littleEndianLength}) {
    final bitLength = input.length * 8;
    final out = List<int>.from(input)..add(0x80);
    while (out.length % 64 != 56) {
      out.add(0);
    }
    out.addAll(
      _writeInt64(bitLength, littleEndian: littleEndianLength),
    );
    return out;
  }

  static int _add32(int a, int b) => (a + b) & 0xFFFFFFFF;

  static int _rotateLeft(int value, int count) =>
      ((value << count) | (value >> (32 - count))) & 0xFFFFFFFF;

  static int _rotateRight(int value, int count) =>
      ((value >> count) | (value << (32 - count))) & 0xFFFFFFFF;

  static int _readInt32(
    List<int> bytes,
    int offset, {
    required bool littleEndian,
  }) {
    if (littleEndian) {
      return bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24);
    }
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static List<int> _writeInt32(int value, {required bool littleEndian}) =>
      littleEndian
      ? [
          value & 0xFF,
          (value >> 8) & 0xFF,
          (value >> 16) & 0xFF,
          (value >> 24) & 0xFF,
        ]
      : [
          (value >> 24) & 0xFF,
          (value >> 16) & 0xFF,
          (value >> 8) & 0xFF,
          value & 0xFF,
        ];

  static List<int> _writeInt64(int value, {required bool littleEndian}) {
    final low = value & 0xFFFFFFFF;
    final high = (value >> 32) & 0xFFFFFFFF;
    final bytes = <int>[];
    if (littleEndian) {
      bytes.addAll(_writeInt32(low, littleEndian: true));
      bytes.addAll(_writeInt32(high, littleEndian: true));
    } else {
      bytes.addAll(_writeInt32(high, littleEndian: false));
      bytes.addAll(_writeInt32(low, littleEndian: false));
    }
    return bytes;
  }
}

// ---------------------------------------------------------------------------
// Regular expressions
// ---------------------------------------------------------------------------

/// One `RegExp` match, flattened for display.
class JavaRegexMatch {
  JavaRegexMatch({
    required this.index,
    required this.value,
    required this.groups,
    required this.namedGroups,
  });

  final int index;
  final String value;
  final List<String?> groups;
  final Map<String, String?> namedGroups;
}

/// Result of running a pattern over an input, or the reason it failed.
class JavaRegexResult {
  JavaRegexResult.error(this.error)
    : matches = const [],
      truncated = false;

  JavaRegexResult.success(this.matches, {required this.truncated})
    : error = null;

  final List<JavaRegexMatch> matches;
  final String? error;
  final bool truncated;

  bool get ok => error == null;
}

/// `java.util.regex` tester backed by Dart's `RegExp`.
///
/// The two dialects differ in places (notably named groups: Dart uses
/// `(?<name>...)` while Java uses the same spelling, but Dart has no possessive
/// quantifiers or `\p{...}` script classes), so the UI says so rather than
/// pretending they are identical.
abstract final class JavaRegex {
  static const int maxMatches = 200;

  static JavaRegexResult test(
    String pattern,
    String input, {
    bool multiLine = false,
    bool dotAll = false,
    bool caseSensitive = true,
  }) {
    final RegExp expression;
    try {
      expression = RegExp(
        pattern,
        multiLine: multiLine,
        dotAll: dotAll,
        caseSensitive: caseSensitive,
      );
    } on FormatException catch (error) {
      return JavaRegexResult.error('正则无效：${error.message}');
    }
    final matches = <JavaRegexMatch>[];
    var count = 0;
    for (final match in expression.allMatches(input)) {
      if (count++ >= maxMatches) {
        return JavaRegexResult.success(matches, truncated: true);
      }
      matches.add(
        JavaRegexMatch(
          index: match.start,
          value: match.group(0) ?? '',
          groups: [
            for (var i = 1; i <= match.groupCount; i++) match.group(i),
          ],
          namedGroups: match.groupNames.isEmpty
              ? const {}
              : {
                  for (final name in match.groupNames)
                    name: match.namedGroup(name),
                },
        ),
      );
    }
    return JavaRegexResult.success(matches, truncated: false);
  }

  /// Replaces every match, as `Matcher.replaceAll` does.
  static String replaceAll(String pattern, String input, String replacement) {
    return input.replaceAll(RegExp(pattern), replacement);
  }
}

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

/// A colour in the notations a Java/Android project needs.
class JavaColorInfo {
  JavaColorInfo(this.argb);

  /// Constructs from `#RGB`, `#RRGGBB` or `#AARRGGBB`, with or without `#`.
  factory JavaColorInfo.parse(String text) {
    var hex = text.trim().replaceFirst('#', '').toUpperCase();
    if (hex.startsWith('0X')) hex = hex.substring(2);
    final value = int.tryParse(hex, radix: 16);
    if (value == null) throw FormatException('无效的十六进制颜色：$text');
    switch (hex.length) {
      case 3:
        // #RGB expands each nibble, as CSS does.
        final r = hex[0], g = hex[1], b = hex[2];
        return JavaColorInfo(
          int.parse('FF$r$r$g$g$b$b', radix: 16),
        );
      case 6:
        return JavaColorInfo(0xFF000000 | value);
      case 8:
        return JavaColorInfo(value);
      default:
        throw const FormatException('颜色应为 #RGB、#RRGGBB 或 #AARRGGBB');
    }
  }

  factory JavaColorInfo.fromArgb(int a, int r, int g, int b) =>
      JavaColorInfo(((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF));

  /// The packed `0xAARRGGBB` value, as Android's `Color` stores it.
  final int argb;

  int get alpha => (argb >> 24) & 0xFF;
  int get red => (argb >> 16) & 0xFF;
  int get green => (argb >> 8) & 0xFF;
  int get blue => argb & 0xFF;

  /// `#AARRGGBB`, the Android resource notation.
  String get hexArgb =>
      '#${argb.toRadixString(16).toUpperCase().padLeft(8, '0')}';

  /// `#RRGGBB`, the CSS/Flutter notation when the value is opaque.
  String get hexRgb =>
      '#${(argb & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}';

  /// `color(0xAARRGGBB)`, the Kotlin/Compose spelling.
  String get kotlinHex =>
      '0x${argb.toRadixString(16).toUpperCase().padLeft(8, '0')}';

  /// `rgb(r, g, b)` / `rgba(...)`.
  String get cssRgb => alpha == 255
      ? 'rgb($red, $green, $blue)'
      : 'rgba($red, $green, $blue, ${(alpha / 255).toStringAsFixed(3)})';

  /// Hue in degrees, 0-360.
  double get hue {
    final r = red / 255;
    final g = green / 255;
    final b = blue / 255;
    final max = math.max(r, math.max(g, b));
    final min = math.min(r, math.min(g, b));
    final delta = max - min;
    if (delta == 0) return 0;
    double h;
    if (max == r) {
      h = ((g - b) / delta) % 6;
    } else if (max == g) {
      h = (b - r) / delta + 2;
    } else {
      h = (r - g) / delta + 4;
    }
    return (h * 60 + 360) % 360;
  }

  double get saturation {
    final max = math.max(red, math.max(green, blue)) / 255;
    final min = math.min(red, math.min(green, blue)) / 255;
    if (max == 0) return 0;
    return (max - min) / max;
  }

  double get lightness =>
      (math.max(red, math.max(green, blue)) +
          math.min(red, math.min(green, blue))) /
      (2 * 255);

  /// `hsl(h, s%, l%)`, rounded for display.
  String get cssHsl =>
      'hsl(${hue.round()}, ${(saturation * 100).round()}%, ${(lightness * 100).round()}%)';
}

// ---------------------------------------------------------------------------
// UUID
// ---------------------------------------------------------------------------

/// UUID generation, including the deterministic v3/v5 (name-based) forms.
abstract final class JavaUuid {
  /// A random version-4 UUID, `8-4-4-4-12` lowercase.
  static String v4([math.Random? random]) {
    final rng = random ?? math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 1
    return _format(bytes);
  }

  /// A version-3 (MD5 name-based) UUID for [name] in [namespace].
  static String v3(String name, String namespace) {
    final input = _namespaceBytes(namespace) + utf8.encode(name);
    final digest = JavaDigest.md5Bytes(input);
    digest[6] = (digest[6] & 0x0F) | 0x30;
    digest[8] = (digest[8] & 0x3F) | 0x80;
    return _format(digest);
  }

  /// A version-5 (SHA-1 name-based) UUID for [name] in [namespace].
  static String v5(String name, String namespace) {
    final input = _namespaceBytes(namespace) + utf8.encode(name);
    final digest = JavaDigest.sha1Bytes(input).sublist(0, 16);
    digest[6] = (digest[6] & 0x0F) | 0x50;
    digest[8] = (digest[8] & 0x3F) | 0x80;
    return _format(digest);
  }

  /// Parses a UUID's namespace argument, or the RFC 4122 DNS namespace by
  /// default when the text is not a UUID.
  static List<int> _namespaceBytes(String namespace) {
    final hex = namespace.trim().replaceAll('-', '');
    if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
      return _hexToBytes(hex);
    }
    // 6ba7b810-9dad-11d1-80b4-00c04fd430c8 (DNS namespace).
    return _hexToBytes('6ba7b8109dad11d180b400c04fd430c8');
  }

  static List<int> _hexToBytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

  static String _format(List<int> bytes) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}

// ---------------------------------------------------------------------------
// Java reference data
// ---------------------------------------------------------------------------

/// One entry in the keyword / primitive quick reference.
class JavaReferenceEntry {
  const JavaReferenceEntry(this.name, this.detail);

  final String name;
  final String detail;
}

/// Static Java facts worth keeping next to the converters. Data only, no logic.
abstract final class JavaReference {
  static const List<JavaReferenceEntry> primitives = [
    JavaReferenceEntry('byte', '8 位有符号，-128..127'),
    JavaReferenceEntry('short', '16 位有符号，-32768..32767'),
    JavaReferenceEntry('int', '32 位有符号，默认整型字面量'),
    JavaReferenceEntry('long', '64 位有符号，字面量加 L'),
    JavaReferenceEntry('float', '32 位 IEEE 754，字面量加 f'),
    JavaReferenceEntry('double', '64 位 IEEE 754，默认小数字面量'),
    JavaReferenceEntry('char', '16 位无符号 UTF-16 码元'),
    JavaReferenceEntry('boolean', 'true / false'),
  ];

  static const List<JavaReferenceEntry> keywords = [
    JavaReferenceEntry('abstract', '抽象类或方法'),
    JavaReferenceEntry('assert', '断言，需 -ea 启用'),
    JavaReferenceEntry('boolean', '布尔类型'),
    JavaReferenceEntry('break', '跳出循环或 switch'),
    JavaReferenceEntry('byte', '8 位整型'),
    JavaReferenceEntry('case', 'switch 分支'),
    JavaReferenceEntry('catch', '捕获异常'),
    JavaReferenceEntry('char', '字符类型'),
    JavaReferenceEntry('class', '类声明'),
    JavaReferenceEntry('const', '保留字，未使用'),
    JavaReferenceEntry('continue', '进入下一次循环'),
    JavaReferenceEntry('default', 'switch 默认分支'),
    JavaReferenceEntry('do', 'do-while 循环'),
    JavaReferenceEntry('double', '双精度浮点'),
    JavaReferenceEntry('else', '条件分支'),
    JavaReferenceEntry('enum', '枚举声明'),
    JavaReferenceEntry('extends', '继承'),
    JavaReferenceEntry('final', '不可修改'),
    JavaReferenceEntry('finally', '异常收尾块'),
    JavaReferenceEntry('float', '单精度浮点'),
    JavaReferenceEntry('for', 'for 循环'),
    JavaReferenceEntry('goto', '保留字，未使用'),
    JavaReferenceEntry('if', '条件判断'),
    JavaReferenceEntry('implements', '实现接口'),
    JavaReferenceEntry('import', '导入包'),
    JavaReferenceEntry('instanceof', '类型判断'),
    JavaReferenceEntry('int', '32 位整型'),
    JavaReferenceEntry('interface', '接口声明'),
    JavaReferenceEntry('long', '64 位整型'),
    JavaReferenceEntry('native', '本地方法'),
    JavaReferenceEntry('new', '创建实例'),
    JavaReferenceEntry('package', '包声明'),
    JavaReferenceEntry('private', '仅本类可见'),
    JavaReferenceEntry('protected', '子类/同包可见'),
    JavaReferenceEntry('public', '公开'),
    JavaReferenceEntry('return', '返回'),
    JavaReferenceEntry('short', '16 位整型'),
    JavaReferenceEntry('static', '静态成员'),
    JavaReferenceEntry('strictfp', '严格浮点'),
    JavaReferenceEntry('super', '父类引用'),
    JavaReferenceEntry('switch', '多分支选择'),
    JavaReferenceEntry('synchronized', '同步块'),
    JavaReferenceEntry('this', '当前实例'),
    JavaReferenceEntry('throw', '抛出异常'),
    JavaReferenceEntry('throws', '声明异常'),
    JavaReferenceEntry('transient', '不参与序列化'),
    JavaReferenceEntry('try', '异常处理块'),
    JavaReferenceEntry('var', '局部变量类型推断'),
    JavaReferenceEntry('void', '无返回值'),
    JavaReferenceEntry('volatile', '禁止指令重排'),
    JavaReferenceEntry('while', 'while 循环'),
  ];

  /// The escape sequences Java accepts in a string literal.
  static const List<JavaReferenceEntry> escapes = [
    JavaReferenceEntry(r'\t', '制表符 U+0009'),
    JavaReferenceEntry(r'\b', '退格 U+0008'),
    JavaReferenceEntry(r'\n', '换行 U+000A'),
    JavaReferenceEntry(r'\r', '回车 U+000D'),
    JavaReferenceEntry(r'\f', '换页 U+000C'),
    JavaReferenceEntry(r"\'", '单引号'),
    JavaReferenceEntry(r'\"', '双引号'),
    JavaReferenceEntry(r'\\', '反斜杠'),
    JavaReferenceEntry(r'\uXXXX', 'Unicode 转义，四位十六进制'),
  ];
}
