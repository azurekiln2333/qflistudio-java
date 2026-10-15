import 'package:flutter_test/flutter_test.dart';
import 'package:qfli_java/java_tools_extra.dart';

/// Unit tests for the Java keyword, primitive and escape reference.
void main() {
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
