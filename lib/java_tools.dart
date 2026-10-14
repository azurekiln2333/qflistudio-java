/// Pure conversion logic for the Java tool page.
///
/// Kept free of Flutter so the arithmetic can be unit tested directly. The UI in
/// `java_tools_page.dart` only formats what these functions return.
library;

/// Java's four integer primitives plus `char`, each with the width that decides
/// its two's-complement representation and overflow range.
enum JavaPrimitive {
  byte('byte', 8, signed: true),
  short('short', 16, signed: true),
  int_('int', 32, signed: true),
  long('long', 64, signed: true),
  char_('char', 16, signed: false);

  const JavaPrimitive(this.label, this.width, {required this.signed});

  final String label;
  final int width;

  /// Whether the type is signed. `char` is a 16-bit unsigned value in Java.
  final bool signed;

  int get bits => width;

  int get maxSigned => signed ? (1 << (width - 1)) - 1 : (1 << width) - 1;

  int get minSigned => signed ? -(1 << (width - 1)) : 0;
}

/// Parses an integer literal the way a Java programmer writes one: decimal, or
/// `0x`/`0b`/leading-`0` for hex, binary and octal.
///
/// Returns a [BigInt] so 64-bit values and negative literals survive, and throws
/// [FormatException] with a readable message rather than returning null.
BigInt parseJavaInt(String source) {
  var text = source.trim();
  if (text.isEmpty) throw const FormatException('请输入整数');
  var negative = false;
  if (text.startsWith('-') || text.startsWith('+')) {
    negative = text.startsWith('-');
    text = text.substring(1);
  }
  // Java accepts underscores inside numeric literals (`1_000_000`).
  text = text.replaceAll('_', '');
  if (text.isEmpty) throw const FormatException('整数格式无效');

  var radix = 10;
  final lower = text.toLowerCase();
  if (lower.startsWith('0x')) {
    radix = 16;
    text = text.substring(2);
  } else if (lower.startsWith('0b')) {
    radix = 2;
    text = text.substring(2);
  } else if (text.length > 1 && text.startsWith('0')) {
    radix = 8;
    text = text.substring(1);
  }
  if (text.isEmpty) throw const FormatException('整数格式无效');
  final value = BigInt.tryParse(text, radix: radix);
  if (value == null) throw const FormatException('整数格式无效');
  return negative ? -value : value;
}

/// One integer viewed through a Java primitive's width.
///
/// Holds the low [width] bits and derives every representation from them, which
/// is what makes the overflow semantics correct: the value is truncated to the
/// type first, then read back.
class JavaIntValue {
  JavaIntValue(BigInt value, this.type)
    : pattern = value & ((BigInt.one << type.bits) - BigInt.one);

  /// Constructs from an already-masked bit pattern.
  const JavaIntValue._(this.pattern, this.type);

  final BigInt pattern;
  final JavaPrimitive type;

  BigInt get _mask => (BigInt.one << type.bits) - BigInt.one;

  /// The value as the type would store it: signed types reinterpret the top bit.
  BigInt get signedValue =>
      type.signed && pattern >= (BigInt.one << (type.bits - 1))
      ? pattern - (BigInt.one << type.bits)
      : pattern;

  /// True when the original literal did not fit and lost bits on the way in.
  bool overflowedFrom(BigInt source) =>
      source < BigInt.from(type.minSigned) ||
      source > BigInt.from(type.maxSigned);

  String get decimal => signedValue.toString();

  String get hexadecimal =>
      '0x${pattern.toRadixString(16).toUpperCase().padLeft(type.bits ~/ 4, '0')}';

  String get binary =>
      '0b${pattern.toRadixString(2).padLeft(type.bits, '0')}';

  // Java does not zero-pad octal literals, so neither does this view; the
  // leading `0` is the literal's own radix marker.
  String get octal => '0${pattern.toRadixString(8)}';

  /// The `char` view, only meaningful for 16-bit values.
  String? get charView {
    if (type.bits != 16) return null;
    final code = pattern.toInt();
    if (code == 0) return null;
    return String.fromCharCode(code);
  }

  JavaIntValue _same(BigInt value) => JavaIntValue._(
    value & _mask,
    type,
  );
}

/// Parses [source], reads it as [type], and reports whether it overflowed.
///
/// Throws [FormatException] when the text is not a valid literal.
({JavaIntValue value, bool overflowed}) readJavaInt(
  String source,
  JavaPrimitive type,
) {
  final raw = parseJavaInt(source);
  final value = JavaIntValue(raw, type);
  return (value: value, overflowed: value.overflowedFrom(raw));
}

/// The Java bitwise and shift operators, named as they are written in source.
enum JavaBitOp {
  and('&'),
  or('|'),
  xor('^'),
  leftShift('<<'),
  arithmeticRightShift('>>'),
  logicalRightShift('>>>');

  const JavaBitOp(this.symbol);

  final String symbol;
}

/// Applies [op] to [left] with [right], honouring [left]'s type width.
///
/// `~` is handled separately by [applyComplement] because it is unary.
JavaIntValue applyJavaBitOp(
  JavaIntValue left,
  JavaBitOp op,
  JavaIntValue right,
) {
  final width = left.type.bits;
  final a = left.pattern;
  final b = right.pattern;
  switch (op) {
    case JavaBitOp.and:
      return left._same(a & b);
    case JavaBitOp.or:
      return left._same(a | b);
    case JavaBitOp.xor:
      return left._same(a ^ b);
    case JavaBitOp.leftShift:
      return left._same(a << b.toInt());
    case JavaBitOp.arithmeticRightShift:
      // Java's `>>` shifts in a copy of the sign bit. Shifting the signed value
      // and re-masking reproduces that for a signed type.
      final shift = b.toInt();
      if (left.type.signed) {
        return left._same(left.signedValue >> shift);
      }
      return left._same(a >> shift);
    case JavaBitOp.logicalRightShift:
      // `>>>` shifts in zeros. Java leaves the width per shift amount: for an
      // int it is `<< 32`-style masking, so the operand is clamped here to the
      // type width, matching the common one-step use.
      final shift = b.toInt();
      if (shift >= width) return left._same(BigInt.zero);
      return left._same(a >> shift);
  }
}

/// Java's unary complement `~x`, truncated to [value]'s width.
JavaIntValue applyJavaComplement(JavaIntValue value) =>
    value._same(~value.pattern);

/// Escapes or unescapes a Java string literal, and renders a text block.
abstract final class JavaString {
  /// Converts plain text into a Java string literal body (without the quotes).
  ///
  /// Escapes the characters that would otherwise end the literal or change its
  /// meaning, and leaves printable non-ASCII alone: Java source is UTF-16, so a
  /// literal CJK character is valid and far more readable than `\uXXXX`.
  static String toLiteral(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      switch (rune) {
        case 0x5C:
          buffer.write(r'\\');
        case 0x22:
          buffer.write(r'\"');
        case 0x0A:
          buffer.write(r'\n');
        case 0x0D:
          buffer.write(r'\r');
        case 0x09:
          buffer.write(r'\t');
        case 0x08:
          buffer.write(r'\b');
        case 0x0C:
          buffer.write(r'\f');
        default:
          if (rune < 0x20 || rune == 0x7F) {
            // Control characters have no short escape; use a unicode escape.
            buffer.write('\\u${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}');
          } else {
            buffer.writeCharCode(rune);
          }
      }
    }
    return buffer.toString();
  }

  /// Parses a Java string literal back into plain text.
  ///
  /// Accepts the body with or without surrounding quotes, and understands the
  /// standard escapes plus `\uXXXX`. Unknown escapes are kept verbatim rather
  /// than dropped, so the round trip is lossless for text this class produced.
  static String fromLiteral(String literal) {
    var text = literal.trim();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char != r'\' || i + 1 >= text.length) {
        buffer.write(char);
        continue;
      }
      final next = text[++i];
      switch (next) {
        case 'n':
          buffer.write('\n');
        case 'r':
          buffer.write('\r');
        case 't':
          buffer.write('\t');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case '"':
          buffer.write('"');
        case "'":
          buffer.write("'");
        case r'\':
          buffer.write(r'\');
        case 'u':
          if (i + 4 < text.length) {
            final code = int.tryParse(text.substring(i + 1, i + 5), radix: 16);
            if (code != null) {
              buffer.writeCharCode(code);
              i += 4;
              break;
            }
          }
          // Not a valid escape; keep it as written.
          buffer.write(r'\u');
        default:
          buffer.write(r'\');
          buffer.write(next);
      }
    }
    return buffer.toString();
  }

  /// Renders text as a Java text block (`"""`), which preserves newlines.
  ///
  /// Java strips incidental leading whitespace up to the closing delimiter, so
  /// the block is closed at column zero and the content is aligned accordingly.
  static String toTextBlock(String text) {
    final body = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
    return '"""\n$body\n"""';
  }
}

/// One code point's representations, as the character tool displays them.
class UnicodeInfo {
  UnicodeInfo(this.codePoint);

  final int codePoint;

  String get hex => 'U+${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  String get javaEscape =>
      '\\u${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  /// UTF-8 bytes, as Java would write them to a stream.
  List<int> get utf8Bytes => _utf8(codePoint);

  /// UTF-16 code units. A code point above the BMP becomes a surrogate pair.
  List<int> get utf16Units {
    if (codePoint <= 0xFFFF) return [codePoint];
    final offset = codePoint - 0x10000;
    return [0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF)];
  }

  String get utf8BytesHex =>
      utf8Bytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');

  String get utf16UnitsHex =>
      utf16Units.map((u) => u.toRadixString(16).toUpperCase().padLeft(4, '0')).join(' ');

  static List<int> _utf8(int codePoint) {
    if (codePoint <= 0x7F) return [codePoint];
    if (codePoint <= 0x7FF) {
      return [0xC0 | (codePoint >> 6), 0x80 | (codePoint & 0x3F)];
    }
    if (codePoint <= 0xFFFF) {
      return [
        0xE0 | (codePoint >> 12),
        0x80 | ((codePoint >> 6) & 0x3F),
        0x80 | (codePoint & 0x3F),
      ];
    }
    return [
      0xF0 | (codePoint >> 18),
      0x80 | ((codePoint >> 12) & 0x3F),
      0x80 | ((codePoint >> 6) & 0x3F),
      0x80 | (codePoint & 0x3F),
    ];
  }
}

/// A field of a generated Java class.
class JavaField {
  JavaField({
    required this.name,
    required this.type,
    required this.declaration,
    required this.assignment,
  });

  final String name;
  final String type;

  /// The declaration, e.g. `private final String name;`.
  final String declaration;

  /// The constructor assignment, e.g. `this.name = name;`.
  final String assignment;
}

/// Generates a POJO or record from a JSON object.
///
/// The generator is deliberately shallow about *inference*: it derives the field
/// types from the JSON value types and recurses into nested objects and arrays,
/// which is enough for the DTOs a learner writes against an API.
abstract final class JavaClassGenerator {
  /// Builds the source for [json], naming the root class [rootName].
  static String generate(
    Object? json,
    String rootName, {
    required bool asRecord,
  }) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('根节点必须是 JSON 对象');
    }
    final classes = <String>[];
    final root = _Declaration(
      name: _className(rootName),
      fields: _fieldsFor(json, _className(rootName), classes),
    );
    classes.add(_render(root, asRecord: asRecord));
    return classes.reversed.join('\n\n');
  }

  static String _render(_Declaration declaration, {required bool asRecord}) {
    final buffer = StringBuffer();
    if (asRecord) {
      buffer.writeln(
        'public record ${declaration.name}${_recordHeader(declaration)} {}',
      );
      return buffer.toString().trimRight();
    }
    buffer.writeln('public class ${declaration.name} {');
    for (final field in declaration.fields) {
      buffer.writeln('    ${field.declaration}');
    }
    buffer.writeln();
    buffer.writeln('    public ${declaration.name}(');
    for (var i = 0; i < declaration.fields.length; i++) {
      final field = declaration.fields[i];
      final comma = i == declaration.fields.length - 1 ? '' : ',';
      buffer.writeln('            ${field.type} ${field.name}$comma');
    }
    buffer.writeln('    ) {');
    for (final field in declaration.fields) {
      buffer.writeln('        ${field.assignment}');
    }
    buffer.writeln('    }');
    buffer.write('}');
    return buffer.toString();
  }

  /// `(String a, int b)`, inserted between the record name and `{`.
  static String _recordHeader(_Declaration declaration) {
    if (declaration.fields.isEmpty) return '';
    final parts = declaration.fields
        .map((field) => '${field.type} ${field.name}')
        .join(', ');
    return '($parts)';
  }

  static List<JavaField> _fieldsFor(
    Map<String, Object?> json,
    String owner,
    List<String> classes,
  ) {
    final fields = <JavaField>[];
    for (final entry in json.entries) {
      final name = _fieldName(entry.key);
      final type = _typeFor(entry.value, name, owner, classes);
      fields.add(
        JavaField(
          name: name,
          type: type,
          declaration: 'private final $type $name;',
          assignment: 'this.$name = $name;',
        ),
      );
    }
    return fields;
  }

  static String _typeFor(
    Object? value,
    String fieldName,
    String owner,
    List<String> classes,
  ) {
    if (value == null) return 'Object';
    if (value is bool) return 'boolean';
    if (value is int) return 'long';
    if (value is double) return 'double';
    if (value is String) return 'String';
    if (value is Map<String, Object?>) {
      // A nested object becomes its own class, named after the field.
      final nested = _className('${owner}_$fieldName');
      final fields = _fieldsFor(value, nested, classes);
      final declaration = _Declaration(name: nested, fields: fields);
      classes.add(_render(declaration, asRecord: false));
      return nested;
    }
    if (value is List) {
      final element = value.isEmpty
          ? 'Object'
          : _typeFor(value.first, fieldName, owner, classes);
      return 'List<$element>';
    }
    return 'Object';
  }

  /// Turns a JSON key into a legal camelCase Java identifier.
  static String _fieldName(String key) {
    final parts = key
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'value';
    final buffer = StringBuffer(parts.first);
    for (final part in parts.skip(1)) {
      buffer.write(part[0].toUpperCase());
      buffer.write(part.substring(1));
    }
    var name = buffer.toString();
    if (RegExp(r'^[0-9]').hasMatch(name)) name = 'value$name';
    return name;
  }

  /// Turns an arbitrary name into a legal Java class name.
  static String _className(String raw) {
    final parts = raw
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'Generated';
    final buffer = StringBuffer();
    for (final part in parts) {
      buffer.write(part[0].toUpperCase());
      buffer.write(part.substring(1));
    }
    var name = buffer.toString();
    if (RegExp(r'^[0-9]').hasMatch(name)) name = 'Generated$name';
    return name;
  }
}

class _Declaration {
  _Declaration({required this.name, required this.fields});

  final String name;
  final List<JavaField> fields;
}

/// Timestamp conversion between epoch values and local date/time.
abstract final class JavaTimestamp {
  /// Formats an epoch value in local time as `yyyy-MM-dd HH:mm:ss.SSS`.
  ///
  /// [unit] selects seconds or milliseconds, which is the only difference the
  /// Java APIs care about (`System.currentTimeMillis` vs `Instant.getEpochSecond`).
  static String toLocal(DateTime local, {required bool milliseconds}) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-'
        '${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
        '${milliseconds ? '.${local.millisecond.toString().padLeft(3, '0')}' : ''}';
  }

  /// Parses `yyyy-MM-dd HH:mm:ss[.SSS]` (and `T`-separated ISO input) as local
  /// time, returning null when the text is not a date this tool accepts.
  static DateTime? parseLocal(String source) {
    final text = source.trim().replaceFirst('T', ' ');
    if (text.isEmpty) return null;
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[ ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,3}))?$',
    ).firstMatch(text);
    if (match == null) {
      final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
      if (dateOnly == null) return null;
      return DateTime(
        int.parse(dateOnly.group(1)!),
        int.parse(dateOnly.group(2)!),
        int.parse(dateOnly.group(3)!),
      );
    }
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6) ?? '0'),
      int.parse(match.group(7)?.padRight(3, '0') ?? '0'),
    );
  }
}
