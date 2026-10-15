import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools.dart';

/// Unit tests for the Java tool page's conversion logic.
///
/// The logic lives in `lib/java_tools.dart`, separate from the widgets, so the
/// arithmetic can be checked without pumping any UI.
void main() {
  group('parseJavaInt', () {
    test('reads decimal, hex, binary and octal literals', () {
      expect(parseJavaInt('255'), BigInt.from(255));
      expect(parseJavaInt('0xFF'), BigInt.from(255));
      expect(parseJavaInt('0b1111_1111'), BigInt.from(255));
      expect(parseJavaInt('0377'), BigInt.from(255));
      expect(parseJavaInt('-42'), BigInt.from(-42));
    });

    test('ignores underscores inside literals', () {
      expect(parseJavaInt('1_000_000'), BigInt.from(1000000));
      expect(parseJavaInt('0x00_FF'), BigInt.from(255));
    });

    test('rejects invalid input with a readable message', () {
      expect(() => parseJavaInt(''), throwsFormatException);
      expect(() => parseJavaInt('nope'), throwsFormatException);
      expect(() => parseJavaInt('0x'), throwsFormatException);
    });
  });

  group('JavaIntValue representations', () {
    test('shows all four bases for a positive int', () {
      final value = JavaIntValue(BigInt.from(255), JavaPrimitive.int_);
      expect(value.decimal, '255');
      expect(value.hexadecimal, '0x000000FF');
      expect(
        value.binary,
        '0b00000000'
        '00000000'
        '00000000'
        '11111111',
      );
      expect(value.octal, '0377');
    });

    test('reinterprets the top bit as a negative value', () {
      // 0xFFFFFFFF is -1 when read as a signed int, exactly as Java would.
      final value = JavaIntValue(BigInt.from(0xFFFFFFFF), JavaPrimitive.int_);
      expect(value.signedValue, BigInt.from(-1));
      expect(value.decimal, '-1');
      expect(value.hexadecimal, '0xFFFFFFFF');
    });

    test('byte truncates and reports overflow', () {
      final read = readJavaInt('300', JavaPrimitive.byte);
      // 300 & 0xFF == 44, and the source did not fit.
      expect(read.value.decimal, '44');
      expect(read.overflowed, isTrue);
    });

    test('a value inside the range does not report overflow', () {
      final read = readJavaInt('127', JavaPrimitive.byte);
      expect(read.value.decimal, '127');
      expect(read.overflowed, isFalse);
    });

    test('char is unsigned and exposes a character view', () {
      final value = JavaIntValue(BigInt.from(0x4E2D), JavaPrimitive.char_);
      expect(value.type.signed, isFalse);
      expect(value.decimal, '20013');
      expect(value.charView, '中');
    });
  });

  group('bit operations', () {
    test('& | ^ combine patterns', () {
      final a = JavaIntValue(BigInt.from(12), JavaPrimitive.int_);
      final b = JavaIntValue(BigInt.from(10), JavaPrimitive.int_);
      expect(applyJavaBitOp(a, JavaBitOp.and, b).decimal, '8');
      expect(applyJavaBitOp(a, JavaBitOp.or, b).decimal, '14');
      expect(applyJavaBitOp(a, JavaBitOp.xor, b).decimal, '6');
    });

    test('~ complements within the width', () {
      final a = JavaIntValue(BigInt.from(0), JavaPrimitive.int_);
      expect(applyJavaComplement(a).decimal, '-1');
    });

    test('>> keeps the sign, >>> shifts in zeros', () {
      final negative = JavaIntValue(BigInt.from(-8), JavaPrimitive.int_);
      final one = JavaIntValue(BigInt.one, JavaPrimitive.int_);
      // -8 >> 1 == -4, but -8 >>> 1 is a large positive number.
      expect(
        applyJavaBitOp(negative, JavaBitOp.arithmeticRightShift, one).decimal,
        '-4',
      );
      expect(
        applyJavaBitOp(negative, JavaBitOp.logicalRightShift, one).decimal,
        '2147483644',
      );
    });

    test('left shift overflows out of the width', () {
      final value = JavaIntValue(BigInt.from(1), JavaPrimitive.byte);
      final shift = JavaIntValue(BigInt.from(8), JavaPrimitive.byte);
      expect(applyJavaBitOp(value, JavaBitOp.leftShift, shift).decimal, '0');
    });
  });

  group('JavaString', () {
    test('escapes the characters that matter', () {
      expect(JavaString.toLiteral('a"b\\c'), r'a\"b\\c');
      expect(JavaString.toLiteral('line\nbreak'), r'line\nbreak');
      expect(JavaString.toLiteral('tab\there'), r'tab\there');
      expect(JavaString.toLiteral('\u0001'), r'\u0001');
    });

    test('keeps printable non-ASCII readable', () {
      expect(JavaString.toLiteral('中文'), '中文');
    });

    test('round-trips through a literal', () {
      const original = 'He said "hi"\n\t中文 \\ end';
      final literal = '"${JavaString.toLiteral(original)}"';
      expect(JavaString.fromLiteral(literal), original);
    });

    test('decodes \\uXXXX escapes', () {
      expect(JavaString.fromLiteral(r'"\u4E2D\u6587"'), '中文');
    });

    test('renders a text block', () {
      expect(JavaString.toTextBlock('a\nb\n'), '"""\na\nb\n"""');
    });
  });

  group('JavaClassGenerator', () {
    const json = {
      'name': 'Ada',
      'age': 36,
      'active': true,
      'tags': ['a', 'b'],
      'address': {'city': 'London', 'zip': 12345},
    };

    test('generates a POJO with typed fields', () {
      final source = JavaClassGenerator.generate(
        json,
        'user_profile',
        asRecord: false,
      );
      expect(source, contains('public class UserProfile {'));
      expect(source, contains('private final String name;'));
      expect(source, contains('private final long age;'));
      expect(source, contains('private final boolean active;'));
      expect(source, contains('private final List<String> tags;'));
      // The nested object becomes its own class.
      expect(source, contains('public class UserProfileAddress {'));
      expect(source, contains('private final long zip;'));
      expect(source, contains('this.name = name;'));
    });

    test('generates a record when asked', () {
      final source = JavaClassGenerator.generate(
        const {'id': 1, 'title': 'x'},
        'Item',
        asRecord: true,
      );
      // A record declares its components in the header, so it needs no body.
      expect(source, 'public record Item(long id, String title) {}');
    });

    test('camel-cases awkward keys and guards leading digits', () {
      final source = JavaClassGenerator.generate(
        const {'first-name': 'a', '2fa': true},
        'Weird',
        asRecord: false,
      );
      expect(source, contains('private final String firstName;'));
      expect(source, contains('private final boolean value2fa;'));
    });

    test('rejects a non-object root', () {
      expect(
        () => JavaClassGenerator.generate(const [1, 2], 'X', asRecord: false),
        throwsFormatException,
      );
    });
  });
}
