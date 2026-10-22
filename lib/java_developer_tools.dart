/// Pure, offline analysis logic behind the Java developer tools.
///
/// Everything here works on data the user already has locally: JVM descriptors
/// typed or copied from `javap`, stack traces pasted from a console, and the
/// raw bytes of a `.class` file or `.jar` archive. There is no network, no
/// subprocess and no Flutter import, so each transformation is unit tested
/// directly and the pages in `java_developer_tool_pages.dart` only format what
/// these functions return.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A type decoded from a JVM descriptor such as `Ljava/lang/String;` or `[I`.
class JavaDescriptorType {
  const JavaDescriptorType({
    required this.descriptor,
    required this.baseName,
    required this.dimensions,
    required this.isPrimitive,
  });

  /// The exact descriptor text this type was read from.
  final String descriptor;

  /// The element type in source form, e.g. `java.lang.String` or `int`.
  ///
  /// Binary names keep the `$` that javac uses for nested classes, which is how
  /// `javap` prints them.
  final String baseName;

  /// Number of array dimensions; `0` for a non-array type.
  final int dimensions;

  final bool isPrimitive;

  bool get isArray => dimensions > 0;

  bool get isVoid => baseName == 'void';

  /// The type as Java source would write it, including `[]` for arrays.
  String get javaName => '$baseName${'[]' * dimensions}';

  @override
  String toString() => javaName;
}

/// A method descriptor split into its parameter and return types.
class JavaMethodDescriptor {
  const JavaMethodDescriptor({
    required this.descriptor,
    required this.parameters,
    required this.returnType,
  });

  final String descriptor;
  final List<JavaDescriptorType> parameters;
  final JavaDescriptorType returnType;

  /// `(java.lang.String, int) -> void`, the form a reader can scan quickly.
  String get signature =>
      '(${parameters.map((type) => type.javaName).join(', ')}) '
      '-> ${returnType.javaName}';

  /// `(Ljava/lang/String;I)V` rebuilt from the decoded parts.
  ///
  /// Equal to [descriptor] for any descriptor this class accepts, which is what
  /// makes the round trip testable.
  String get rebuiltDescriptor =>
      '(${parameters.map((type) => type.descriptor).join()})'
      '${returnType.descriptor}';
}

/// Parses JVM field and method descriptors, and writes them back.
///
/// A descriptor is the erased, binary form the class-file format stores. The
/// page uses this to answer "what does `[[Ljava/lang/String;` actually mean?"
/// and the reverse, without running `javap`.
abstract final class JavaDescriptors {
  static const Map<String, String> _bySymbol = {
    'B': 'byte',
    'C': 'char',
    'D': 'double',
    'F': 'float',
    'I': 'int',
    'J': 'long',
    'S': 'short',
    'Z': 'boolean',
    'V': 'void',
  };

  static final Map<String, String> _byName = {
    for (final entry in _bySymbol.entries) entry.value: entry.key,
  };

  /// Decodes a single field descriptor, e.g. `[Ljava/lang/String;`.
  static JavaDescriptorType parseField(String descriptor) {
    final text = descriptor.trim();
    if (text.isEmpty) throw const FormatException('请输入 JVM 类型描述符');
    final parsed = _parseAt(text, 0);
    if (parsed.end != text.length) {
      throw FormatException('描述符末尾有多余内容：${text.substring(parsed.end)}');
    }
    return parsed.type;
  }

  /// Decodes a method descriptor such as `(Ljava/lang/String;I)V`.
  static JavaMethodDescriptor parseMethod(String descriptor) {
    final text = descriptor.trim();
    if (!text.startsWith('(')) {
      throw const FormatException('方法描述符以 ( 开头，例如 (Ljava/lang/String;I)V');
    }
    var index = 1;
    final parameters = <JavaDescriptorType>[];
    var parameterSlots = 0;
    while (index < text.length && text[index] != ')') {
      final parsed = _parseAt(text, index);
      parameters.add(parsed.type);
      parameterSlots +=
          !parsed.type.isArray &&
              (parsed.type.baseName == 'long' ||
                  parsed.type.baseName == 'double')
          ? 2
          : 1;
      if (parameterSlots > 255) {
        throw const FormatException('方法参数不能超过 255 个 JVM 槽位');
      }
      index = parsed.end;
    }
    if (index >= text.length) {
      throw const FormatException('方法描述符缺少右括号 )');
    }
    final returns = _parseAt(text, index + 1, allowVoid: true);
    if (returns.end != text.length) {
      throw FormatException('返回值后有多余内容：${text.substring(returns.end)}');
    }
    return JavaMethodDescriptor(
      descriptor: text,
      parameters: List.unmodifiable(parameters),
      returnType: returns.type,
    );
  }

  /// Decodes whichever kind [descriptor] is, so a pasted line can be either.
  ///
  /// Returns a [JavaMethodDescriptor] when the text starts with `(` and a
  /// [JavaDescriptorType] otherwise.
  static Object parseAny(String descriptor) {
    final text = descriptor.trim();
    if (text.startsWith('(')) return parseMethod(text);
    return parseField(text);
  }

  /// Writes the field descriptor for a Java source type name.
  ///
  /// Accepts primitives (`int`), arrays (`int[]`, `java.lang.String[]`) and
  /// class names (`java.lang.String`, `java.util.Map$Entry`). A simple name is
  /// treated as living in the unnamed package, matching javac's output for a
  /// top-level class without `package`.
  static String descriptorOf(String javaType) {
    return _descriptorOf(javaType, allowVoid: false);
  }

  static String _descriptorOf(String javaType, {required bool allowVoid}) {
    var text = javaType.trim();
    if (text.isEmpty) throw const FormatException('请输入 Java 类型名');
    var dimensions = 0;
    while (text.endsWith('[]')) {
      dimensions++;
      text = text.substring(0, text.length - 2).trim();
    }
    if (text.isEmpty) throw const FormatException('数组缺少元素类型');
    final primitive = _byName[text];
    if (primitive != null) {
      if (primitive == 'V' && (!allowVoid || dimensions > 0)) {
        throw const FormatException('void 只能作为方法返回类型');
      }
      if (dimensions > 255) throw const FormatException('数组维度不能超过 255');
      return '${'[' * dimensions}$primitive';
    }
    if (text.contains(RegExp(r'\s'))) {
      throw FormatException('类型名中不能包含空格：$text');
    }
    if (RegExp(r'[/;\[\]()<>,:?\\]').hasMatch(text) ||
        text
            .split('.')
            .any((part) => part.isEmpty || RegExp(r'^\d').hasMatch(part))) {
      throw FormatException('无效的 Java 类型名：$text');
    }
    if (dimensions > 255) throw const FormatException('数组维度不能超过 255');
    final internal = text.replaceAll('.', '/');
    return '${'[' * dimensions}L$internal;';
  }

  /// Writes a method descriptor from source type names.
  static String methodDescriptorOf(
    List<String> parameterTypes,
    String returnType,
  ) {
    final parameters = parameterTypes.map((type) => descriptorOf(type)).join();
    final descriptor =
        '($parameters)${_descriptorOf(returnType, allowVoid: true)}';
    parseMethod(descriptor);
    return descriptor;
  }

  /// Parses one type starting at [start].
  static ({JavaDescriptorType type, int end}) _parseAt(
    String text,
    int start, {
    bool allowVoid = false,
  }) {
    var dimensions = 0;
    var index = start;
    while (index < text.length && text[index] == '[') {
      dimensions++;
      index++;
    }
    if (dimensions > 255) throw const FormatException('数组维度不能超过 255');
    if (index >= text.length) {
      throw const FormatException('数组描述符缺少元素类型');
    }
    final symbol = text[index];
    final primitiveName = _bySymbol[symbol];
    if (primitiveName != null) {
      if (primitiveName == 'void' && (!allowVoid || dimensions > 0)) {
        throw const FormatException('void 只能作为方法返回类型');
      }
      index++;
      return (
        type: JavaDescriptorType(
          descriptor: text.substring(start, index),
          baseName: primitiveName,
          dimensions: dimensions,
          isPrimitive: true,
        ),
        end: index,
      );
    }
    if (symbol == 'L') {
      final close = text.indexOf(';', index);
      if (close < 0) throw const FormatException('对象描述符缺少结尾的 ;');
      final internal = text.substring(index + 1, close);
      if (internal.isEmpty) throw const FormatException('对象描述符缺少类名');
      if (internal.contains(RegExp(r'[.\[;]')) ||
          internal.split('/').any((part) => part.isEmpty)) {
        throw FormatException('无效的 JVM 类名：$internal');
      }
      index = close + 1;
      return (
        type: JavaDescriptorType(
          descriptor: text.substring(start, index),
          baseName: internal.replaceAll('/', '.'),
          dimensions: dimensions,
          isPrimitive: false,
        ),
        end: index,
      );
    }
    throw FormatException('无法识别的描述符字符：$symbol');
  }
}

/// One `at ...` frame of a Java stack trace.
class JavaStackFrame {
  const JavaStackFrame({
    required this.className,
    required this.methodName,
    this.moduleName,
    this.fileName,
    this.lineNumber,
    this.isNative = false,
  });

  /// Fully qualified class name, with `$` for nested classes.
  final String className;

  /// Method name, including `lambda$main$0` shapes.
  final String methodName;

  /// The module prefix JDK 9+ prints, e.g. `java.base`; null when absent.
  final String? moduleName;

  /// Source file name; null for a native or unknown-source frame.
  final String? fileName;

  /// Source line; null for a native frame, unknown source or a line-less file.
  final int? lineNumber;

  final bool isNative;

  bool get hasSourceLocation => fileName != null;

  /// The text between the parentheses, as the JVM's printer writes it.
  String get location {
    if (isNative) return 'Native Method';
    if (fileName == null) return 'Unknown Source';
    return lineNumber == null ? fileName! : '$fileName:$lineNumber';
  }

  /// The whole frame as one line, without the leading tab.
  String get display => 'at $className.$methodName($location)';

  /// Whether [className] starts with one of the runtime prefixes.
  bool isRuntimeFrame(List<String> runtimePrefixes) =>
      runtimePrefixes.any((prefix) => className.startsWith(prefix));

  @override
  String toString() => display;
}

/// One throwable inside a stack trace, with its own frames.
///
/// A trace can contain the primary failure plus `Caused by:` and `Suppressed:`
/// sections; each becomes its own instance.
class JavaThrowable {
  JavaThrowable({
    required this.header,
    required this.frames,
    this.exceptionClass = '',
    this.message,
    this.depth = 0,
    this.isSuppressed = false,
    this.isCausedBy = false,
    this.omittedCommonFrames = 0,
  });

  /// The header line without the `Caused by:` / `Suppressed:` marker.
  final String header;

  /// Best-effort exception type, e.g. `java.lang.IllegalStateException`.
  final String exceptionClass;

  /// Text after `: ` on the header, including continuation lines.
  final String? message;

  final List<JavaStackFrame> frames;

  /// 0 for the primary failure, N for a throwable nested N levels down.
  final int depth;

  final bool isSuppressed;
  final bool isCausedBy;

  /// The `... N more` count, which refers to frames shared with the parent.
  final int omittedCommonFrames;

  /// The marker that precedes the header when re-printing.
  String get marker {
    if (isSuppressed) return 'Suppressed: ';
    if (isCausedBy) return 'Caused by: ';
    return '';
  }
}

/// A parsed Java stack trace.
class JavaStackTraceReport {
  JavaStackTraceReport({
    required this.throwables,
    this.threadName,
    this.unparsedLines = const [],
  });

  final List<JavaThrowable> throwables;

  /// `main` from `Exception in thread "main" ...`.
  final String? threadName;

  /// Lines that are neither headers, frames nor `... N more` markers.
  final List<String> unparsedLines;

  JavaThrowable? get primary => throwables.isEmpty ? null : throwables.first;

  bool get isEmpty => throwables.isEmpty;

  /// Every frame in the trace, in printed order.
  List<JavaStackFrame> get allFrames => [
    for (final throwable in throwables) ...throwable.frames,
  ];

  /// Distinct classes seen in the trace, in first-seen order.
  List<String> get classes {
    final seen = <String>[];
    for (final frame in allFrames) {
      if (!seen.contains(frame.className)) seen.add(frame.className);
    }
    return seen;
  }

  /// How many frames belong to the trace's own code rather than the runtime.
  int applicationFrameCount([List<String> runtimePrefixes = _defaultRuntime]) =>
      allFrames.where((f) => !f.isRuntimeFrame(runtimePrefixes)).length;
}

const List<String> _defaultRuntime = JavaStackTrace.defaultRuntimePrefixes;

/// Parses Java stack traces and re-prints them with the noise removed.
abstract final class JavaStackTrace {
  /// Class prefixes that belong to the JDK (or to runtimes that print frames in
  /// JDK-shaped traces), used by the "application frames only" filter.
  static const List<String> defaultRuntimePrefixes = [
    'java.',
    'javax.',
    'jdk.',
    'sun.',
    'com.sun.',
    'kotlin.',
    'kotlinx.',
    'org.junit.',
    'org.gradle.',
    'worker.org.gradle.',
  ];

  static final RegExp _framePattern = RegExp(
    r'^at\s+([^\s()]+)\.([^\s.()/]+)\((.*)\)$',
  );

  static final RegExp _headerPrefix = RegExp(
    r'^Exception in thread "([^"]*)"\s+',
  );

  static final RegExp _omittedPattern = RegExp(r'^\.\.\. (\d+) more$');

  /// Parses [text] into throwables, frames and leftovers.
  ///
  /// Never throws for malformed input: text that is not a stack trace simply
  /// yields an empty report with its lines recorded in
  /// [JavaStackTraceReport.unparsedLines], so the page can say so honestly.
  static JavaStackTraceReport parse(String text) {
    final lines = const LineSplitter().convert(text);
    final throwables = <JavaThrowable>[];
    final leftovers = <String>[];
    String? threadName;

    List<JavaStackFrame> frames = [];
    var header = '';
    var exceptionClass = '';
    var messageBuffer = StringBuffer();
    var hasMessage = false;
    var depth = 0;
    var isCausedBy = false;
    var isSuppressed = false;
    var omitted = 0;
    var open = false;

    void close() {
      if (!open) return;
      throwables.add(
        JavaThrowable(
          header: header,
          exceptionClass: exceptionClass,
          message: hasMessage ? messageBuffer.toString() : null,
          frames: List.unmodifiable(frames),
          depth: depth,
          isCausedBy: isCausedBy,
          isSuppressed: isSuppressed,
          omittedCommonFrames: omitted,
        ),
      );
      frames = [];
      header = '';
      exceptionClass = '';
      messageBuffer = StringBuffer();
      hasMessage = false;
      omitted = 0;
      open = false;
    }

    for (final rawLine in lines) {
      final line = rawLine.replaceFirst(RegExp(r'^\s+'), '').trimRight();
      if (line.isEmpty) continue;

      final omittedMatch = _omittedPattern.firstMatch(line);
      if (omittedMatch != null) {
        if (open) {
          omitted = int.tryParse(omittedMatch.group(1)!) ?? 0;
        } else {
          leftovers.add(line);
        }
        continue;
      }

      final frameMatch = _framePattern.firstMatch(line);
      if (frameMatch != null) {
        if (!open) {
          leftovers.add(line);
          continue;
        }
        final qualified = frameMatch.group(1)!;
        final location = frameMatch.group(3)!;
        final split = qualified.lastIndexOf('/');
        final moduleName = split < 0 ? null : qualified.substring(0, split);
        final className = split < 0
            ? qualified
            : qualified.substring(split + 1);
        frames.add(
          _frame(className, frameMatch.group(2)!, location, moduleName),
        );
        continue;
      }

      // A header: primary, `Caused by:` or `Suppressed:`.
      var candidate = line;
      var marker = false;
      var nextSuppressed = false;
      if (candidate.startsWith('Caused by: ')) {
        candidate = candidate.substring('Caused by: '.length);
        marker = true;
      } else if (candidate.startsWith('Suppressed: ')) {
        candidate = candidate.substring('Suppressed: '.length);
        marker = true;
        nextSuppressed = true;
      }

      final threadMatch = _headerPrefix.firstMatch(candidate);
      if (!marker && threadMatch != null) {
        threadName = threadMatch.group(1);
        candidate = candidate.substring(threadMatch.end);
      }

      final looksLikeHeader =
          marker || (!open && _looksLikeThrowableHeader(candidate));

      // A wrapped message continues the previous header, not a new throwable.
      // Once frames have started, a line that is neither a frame nor a header is
      // stray output rather than message text, so it is kept aside.
      if (open && !looksLikeHeader) {
        if (frames.isNotEmpty) {
          leftovers.add(line);
          continue;
        }
        messageBuffer
          ..write(messageBuffer.isEmpty ? '' : '\n')
          ..write(candidate);
        hasMessage = true;
        continue;
      }

      if (!looksLikeHeader) {
        // Keep a bare line that appears before any header (banner text etc.).
        if (!open) {
          leftovers.add(line);
          continue;
        }
        messageBuffer
          ..write(messageBuffer.isEmpty ? '' : '\n')
          ..write(candidate);
        hasMessage = true;
        continue;
      }

      close();
      open = true;
      isSuppressed = nextSuppressed;
      isCausedBy = marker && !isSuppressed;
      depth = isCausedBy ? throwables.length : 0;
      header = candidate;
      final separator = candidate.indexOf(': ');
      exceptionClass =
          (separator < 0 ? candidate : candidate.substring(0, separator))
              .trim();
      if (separator >= 0) {
        messageBuffer.write(candidate.substring(separator + 2));
        hasMessage = true;
      }
    }
    close();
    return JavaStackTraceReport(
      throwables: throwables,
      threadName: threadName,
      unparsedLines: List.unmodifiable(leftovers),
    );
  }

  /// Re-prints [report], optionally keeping only application frames and only
  /// frames that contain [contains].
  ///
  /// `... N more` markers are dropped when a filter is active: the original
  /// count describes the unfiltered trace, so printing it would lie.
  static String render(
    JavaStackTraceReport report, {
    bool onlyApplicationFrames = false,
    bool keepCommonFrames = true,
    List<String> runtimePrefixes = defaultRuntimePrefixes,
    String? contains,
    int maxFrames = 200,
  }) {
    final needle = contains?.trim().toLowerCase() ?? '';
    final buffer = StringBuffer();
    for (final (index, throwable) in report.throwables.indexed) {
      if (buffer.isNotEmpty) buffer.writeln();
      final threadPrefix = index == 0 && report.threadName != null
          ? 'Exception in thread "${report.threadName}" '
          : '';
      buffer.writeln('$threadPrefix${throwable.marker}${throwable.header}');
      final wrappedMessage = throwable.message?.indexOf('\n') ?? -1;
      if (wrappedMessage >= 0) {
        buffer.writeln(throwable.message!.substring(wrappedMessage + 1));
      }

      final kept = throwable.frames.where((frame) {
        if (onlyApplicationFrames && frame.isRuntimeFrame(runtimePrefixes)) {
          return false;
        }
        if (needle.isEmpty) return true;
        return frame.display.toLowerCase().contains(needle);
      }).toList();

      final filtered = onlyApplicationFrames || needle.isNotEmpty;
      final shown = kept.length > maxFrames ? kept.sublist(0, maxFrames) : kept;
      for (final frame in shown) {
        // [JavaStackFrame.display] already starts with `at `.
        buffer.writeln('\t$frame');
      }
      if (kept.length > shown.length) {
        buffer.writeln('\t... 其余 ${kept.length - shown.length} 帧已省略');
      }
      if (filtered && kept.isEmpty && throwable.frames.isNotEmpty) {
        buffer.writeln('\t（过滤后没有保留的栈帧）');
      }
      if (!filtered && keepCommonFrames && throwable.omittedCommonFrames > 0) {
        buffer.writeln('\t... ${throwable.omittedCommonFrames} more');
      }
    }
    return buffer.toString().trimRight();
  }

  /// Whether [line] starts a new throwable section.
  ///
  /// The JVM prints `java.lang.RuntimeException: message`, but a user exception
  /// may not end in `Exception`/`Error`, so a dotted class name is accepted too.
  /// Compiler diagnostics (`Main.java:5: error: ...`) and log banners
  /// (`BUILD SUCCESSFUL`, `warning: ...`) are rejected so they do not become
  /// fake throwables.
  static bool _looksLikeThrowableHeader(String line) {
    final colon = line.indexOf(':');
    final name = (colon < 0 ? line : line.substring(0, colon)).trim();
    if (name.isEmpty || name.contains(RegExp(r'\s'))) return false;
    if (!RegExp(r'^[^\s:;\[\]()/\\]+$').hasMatch(name)) return false;
    if (RegExp(r'\.(java|kt|groovy|scala|js|py)$').hasMatch(name)) return false;
    return name.endsWith('Exception') ||
        name.endsWith('Error') ||
        name.endsWith('Throwable') ||
        name.contains('.');
  }

  /// One `at ...` line, tolerating the `Native Method` / `Unknown Source`
  /// shapes and the optional `:line` suffix.
  static JavaStackFrame _frame(
    String className,
    String methodName,
    String location,
    String? moduleName,
  ) {
    if (location == 'Native Method') {
      return JavaStackFrame(
        className: className,
        methodName: methodName,
        moduleName: moduleName,
        isNative: true,
      );
    }
    if (location == 'Unknown Source' || location.isEmpty) {
      return JavaStackFrame(
        className: className,
        methodName: methodName,
        moduleName: moduleName,
      );
    }
    // `Main.java:12` or an unusual `Main.java` with no line.
    final colon = location.lastIndexOf(':');
    final fileName = colon < 0 ? location : location.substring(0, colon);
    final lineNumber = colon < 0
        ? null
        : int.tryParse(location.substring(colon + 1));
    return JavaStackFrame(
      className: className,
      methodName: methodName,
      moduleName: moduleName,
      fileName: fileName,
      lineNumber: lineNumber,
    );
  }
}

/// One field or method read from a class file.
class JavaClassMember {
  const JavaClassMember({
    required this.name,
    required this.descriptor,
    required this.modifiers,
    required this.typeText,
  });

  final String name;

  /// The raw descriptor, e.g. `(Ljava/lang/String;I)Ljava/lang/String;`.
  final String descriptor;

  /// Decoded modifiers, e.g. `public static`.
  final List<String> modifiers;

  /// For methods `(java.lang.String, int) -> java.lang.String`; for fields the
  /// decoded Java type.
  final String typeText;

  /// The member as Java source would write it: `public static void
  /// main(java.lang.String[])`. Falls back to the raw descriptor when it cannot
  /// be decoded.
  String get display {
    final prefix = modifiers.isEmpty ? '' : '${modifiers.join(' ')} ';
    if (!descriptor.startsWith('(')) return '$prefix$typeText $name';
    try {
      final method = JavaDescriptors.parseMethod(descriptor);
      final parameters = method.parameters
          .map((type) => type.javaName)
          .join(', ');
      return '$prefix${method.returnType.javaName} $name($parameters)';
    } on FormatException {
      return '$prefix$typeText $name';
    }
  }

  /// `name: source-like declaration  [descriptor]`, one line per member.
  String get listing => '$name: $display  [$descriptor]';
}

/// A parsed `.class` file.
///
/// Only the parts a reader needs are decoded: version, access flags, the class
/// hierarchy, members and the class-level attribute names. The constant pool is
/// summarised by tag rather than dumped.
class JavaClassFile {
  JavaClassFile({
    required this.minorVersion,
    required this.majorVersion,
    required this.modifiers,
    required this.thisClass,
    required this.superClass,
    required this.interfaces,
    required this.constantPoolTags,
    required this.constantPoolSlots,
    required this.fields,
    required this.methods,
    required this.attributes,
    required this.byteLength,
  });

  final int minorVersion;
  final int majorVersion;
  final List<String> modifiers;

  /// Dotted binary name, e.g. `fixtures.Greeting`.
  final String? thisClass;

  /// Dotted superclass name; `null` for `java.lang.Object` and module info.
  final String? superClass;

  final List<String> interfaces;

  /// `Utf8` -> number of entries, in the order they appear in the pool.
  final Map<String, int> constantPoolTags;

  /// Constant pool slot count including the unused zero slot and the second
  /// slot of every `long`/`double`.
  final int constantPoolSlots;

  final List<JavaClassMember> fields;
  final List<JavaClassMember> methods;

  /// Class-level attribute names, e.g. `SourceFile`, `BootstrapMethods`.
  final List<String> attributes;

  final int byteLength;

  /// True when the bytes start with the class-file magic `CAFEBABE`.
  static bool looksLikeClassFile(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0xCA &&
      bytes[1] == 0xFE &&
      bytes[2] == 0xBA &&
      bytes[3] == 0xBE;

  /// The Java release the major version targets, e.g. `17`.
  String get javaRelease {
    if (majorVersion >= 49) return '${majorVersion - 44}';
    return '1.${majorVersion - 44}';
  }

  /// `Java 17 (major 61, minor 0)`, the line a reader checks first.
  String get versionText =>
      'Java $javaRelease (major $majorVersion, '
      'minor $minorVersion)';

  /// `class fixtures.Greeting extends java.lang.Object`.
  String get declaration {
    final buffer = StringBuffer();
    final keyword = modifiers.contains('interface')
        ? 'interface'
        : modifiers.contains('enum')
        ? 'enum'
        : 'class';
    final declarationModifiers = modifiers
        .where((modifier) => modifier != keyword)
        .join(' ');
    buffer.write(
      '${declarationModifiers.isEmpty ? '' : '$declarationModifiers '}'
      '$keyword ${thisClass ?? '<unknown>'}',
    );
    if (superClass != null && keyword != 'interface') {
      buffer.write(' extends $superClass');
    }
    if (interfaces.isNotEmpty) {
      buffer.write(
        ' ${keyword == 'interface' ? 'extends' : 'implements'} '
        '${interfaces.join(', ')}',
      );
    }
    return buffer.toString();
  }

  /// The constant pool summary as `Utf8: 42` lines.
  String get constantPoolSummary => constantPoolTags.entries
      .map((entry) => '${entry.key}: ${entry.value}')
      .join('\n');

  /// Parses [bytes] as a class file, throwing [FormatException] with a readable
  /// message when it is not one.
  factory JavaClassFile.parse(List<int> input) {
    final bytes = Uint8List.fromList(input);
    if (!looksLikeClassFile(bytes)) {
      throw const FormatException('不是 Java class 文件：缺少 CAFEBABE 魔数');
    }
    final reader = _Reader(bytes, 4);
    try {
      final minor = reader.u2();
      final major = reader.u2();

      final poolCount = reader.u2();
      if (poolCount == 0) throw const FormatException('class 常量池不能为空');
      final poolTagCounts = <String, int>{};
      final utf8 = <int, String>{};
      final classIndexes = <int, int>{};
      final nameAndType = <int, ({int name, int descriptor})>{};

      var index = 1;
      while (index < poolCount) {
        final tag = reader.u1();
        final label = _constantPoolLabels[tag] ?? 'tag$tag';
        poolTagCounts.update(label, (value) => value + 1, ifAbsent: () => 1);
        switch (tag) {
          case 1:
            final length = reader.u2();
            utf8[index] = reader.utf8(length);
          case 3:
          case 4:
            reader.skip(4);
          case 5:
          case 6:
            reader.skip(8);
            // Long and double occupy two constant-pool slots.
            index++;
            if (index >= poolCount) {
              throw const FormatException('long/double 常量缺少第二个槽位');
            }
          case 7:
            classIndexes[index] = reader.u2();
          case 8:
            reader.skip(2);
          case 9:
          case 10:
          case 11:
          case 12:
            if (tag == 12) {
              final nameIndex = reader.u2();
              final descriptorIndex = reader.u2();
              nameAndType[index] = (
                name: nameIndex,
                descriptor: descriptorIndex,
              );
            } else {
              reader.skip(4);
            }
          case 15:
            reader.skip(3);
          case 16:
            reader.skip(2);
          case 17:
          case 18:
            reader.skip(4);
          case 19:
          case 20:
            reader.skip(2);
          default:
            throw FormatException('常量池第 $index 项标签未知：$tag');
        }
        index++;
      }

      String? className(int poolIndex) {
        if (poolIndex == 0) return null;
        final nameIndex = classIndexes[poolIndex];
        final name = nameIndex == null ? null : utf8[nameIndex];
        if (name == null) throw const FormatException('class 类名引用无效');
        return name.replaceAll('/', '.');
      }

      String utf8At(int poolIndex) {
        final value = utf8[poolIndex];
        if (value == null) throw const FormatException('class UTF8 引用无效');
        return value;
      }

      final flags = reader.u2();
      final thisIndex = reader.u2();
      final superIndex = reader.u2();
      final interfaceCount = reader.u2();
      final interfaces = <String>[
        for (var i = 0; i < interfaceCount; i++) ?className(reader.u2()),
      ];

      List<JavaClassMember> members({required bool isMethod}) {
        final count = reader.u2();
        final members = <JavaClassMember>[];
        for (var i = 0; i < count; i++) {
          final memberFlags = reader.u2();
          final nameIndex = reader.u2();
          final descriptorIndex = reader.u2();
          final attributeCount = reader.u2();
          for (var a = 0; a < attributeCount; a++) {
            reader.skip(2);
            reader.skip(reader.u4());
          }
          final name = utf8At(nameIndex);
          final descriptor = utf8At(descriptorIndex);
          members.add(
            JavaClassMember(
              name: name,
              descriptor: descriptor,
              modifiers: [
                for (final entry in _memberFlagNames.entries)
                  if (memberFlags & entry.key != 0)
                    isMethod && entry.key == 0x0040
                        ? 'bridge'
                        : isMethod && entry.key == 0x0080
                        ? 'varargs'
                        : entry.value,
              ],
              typeText: isMethod
                  ? _decodeMethod(descriptor, name)
                  : _decodeType(descriptor),
            ),
          );
        }
        return members;
      }

      final fields = members(isMethod: false);
      final methods = members(isMethod: true);

      final attributeCount = reader.u2();
      final attributes = <String>[];
      for (var a = 0; a < attributeCount; a++) {
        attributes.add(utf8At(reader.u2()));
        reader.skip(reader.u4());
      }
      if (reader.offset != bytes.length) {
        throw const FormatException('class 文件末尾有多余内容');
      }

      return JavaClassFile(
        minorVersion: minor,
        majorVersion: major,
        modifiers: [
          for (final entry in _classFlagNames.entries)
            if (flags & entry.key != 0) entry.value,
        ],
        thisClass: className(thisIndex),
        superClass: className(superIndex),
        interfaces: List.unmodifiable(interfaces),
        constantPoolTags: Map.unmodifiable(poolTagCounts),
        constantPoolSlots: poolCount,
        fields: List.unmodifiable(fields),
        methods: List.unmodifiable(methods),
        attributes: List.unmodifiable(attributes),
        byteLength: bytes.length,
      );
    } on RangeError {
      throw const FormatException('class 文件被截断，结构不完整');
    }
  }

  static String _decodeType(String descriptor) {
    try {
      return JavaDescriptors.parseField(descriptor).javaName;
    } on FormatException {
      return descriptor;
    }
  }

  static String _decodeMethod(String descriptor, String name) {
    try {
      return JavaDescriptors.parseMethod(descriptor).signature;
    } on FormatException {
      return descriptor;
    }
  }
}

const Map<int, String> _constantPoolLabels = {
  1: 'Utf8',
  3: 'Integer',
  4: 'Float',
  5: 'Long',
  6: 'Double',
  7: 'Class',
  8: 'String',
  9: 'Fieldref',
  10: 'Methodref',
  11: 'InterfaceMethodref',
  12: 'NameAndType',
  15: 'MethodHandle',
  16: 'MethodType',
  17: 'Dynamic',
  18: 'InvokeDynamic',
  19: 'Module',
  20: 'Package',
};

const Map<int, String> _classFlagNames = {
  0x0001: 'public',
  0x0010: 'final',
  0x0200: 'interface',
  0x0400: 'abstract',
  0x1000: 'synthetic',
  0x2000: 'annotation',
  0x4000: 'enum',
  0x8000: 'module',
};

const Map<int, String> _memberFlagNames = {
  0x0001: 'public',
  0x0002: 'private',
  0x0004: 'protected',
  0x0008: 'static',
  0x0010: 'final',
  0x0020: 'synchronized',
  0x0040: 'volatile',
  0x0080: 'transient',
  0x0100: 'native',
  0x0400: 'abstract',
  0x0800: 'strictfp',
  0x1000: 'synthetic',
};

/// A big-endian reader over class-file and ZIP bytes.
class _Reader {
  _Reader(this.bytes, this.offset);

  final Uint8List bytes;
  int offset;

  int u1() {
    if (offset + 1 > bytes.length) throw RangeError('u1');
    return bytes[offset++];
  }

  int u2() {
    if (offset + 2 > bytes.length) throw RangeError('u2');
    final value = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    return value;
  }

  int u4() {
    if (offset + 4 > bytes.length) throw RangeError('u4');
    final value =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;
    return value & 0xFFFFFFFF;
  }

  /// Reads a length-prefixed "modified UTF-8" string as class files store it.
  ///
  /// Decodes UTF-16 code units, including the special two-byte NUL encoding and
  /// three-byte surrogate units. Standard UTF-8 would corrupt those constants.
  String utf8(int length) {
    if (offset + length > bytes.length) throw RangeError('utf8');
    final slice = bytes.sublist(offset, offset + length);
    offset += length;
    final units = <int>[];
    var index = 0;
    int continuation() {
      if (index >= slice.length || slice[index] & 0xC0 != 0x80) {
        throw const FormatException('class modified UTF-8 序列无效');
      }
      return slice[index++] & 0x3F;
    }

    while (index < slice.length) {
      final first = slice[index++];
      if (first >= 1 && first <= 0x7F) {
        units.add(first);
      } else if (first & 0xE0 == 0xC0) {
        final value = ((first & 0x1F) << 6) | continuation();
        if (value != 0 && value < 0x80) {
          throw const FormatException('class modified UTF-8 序列无效');
        }
        units.add(value);
      } else if (first & 0xF0 == 0xE0) {
        final value =
            ((first & 0x0F) << 12) | (continuation() << 6) | continuation();
        if (value < 0x800) {
          throw const FormatException('class modified UTF-8 序列无效');
        }
        units.add(value);
      } else {
        throw const FormatException('class modified UTF-8 序列无效');
      }
    }
    return String.fromCharCodes(units);
  }

  void skip(int count) {
    if (count < 0) throw RangeError('skip');
    if (offset + count > bytes.length) throw RangeError('skip');
    offset += count;
  }
}

/// A little-endian reader over ZIP records.
///
/// ZIP stores every multi-byte field little-endian, unlike the class file
/// format, so it needs its own reader rather than [_Reader].
class _ZipReader {
  _ZipReader(this.bytes, this.offset);

  final Uint8List bytes;
  int offset;

  int u2() {
    if (offset + 2 > bytes.length) throw const FormatException('ZIP 数据被截断');
    final value = bytes[offset] | (bytes[offset + 1] << 8);
    offset += 2;
    return value;
  }

  int u4() {
    if (offset + 4 > bytes.length) throw const FormatException('ZIP 数据被截断');
    final value =
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    offset += 4;
    return value & 0xFFFFFFFF;
  }

  void skip(int count) {
    if (count < 0 || offset + count > bytes.length) {
      throw const FormatException('ZIP 数据被截断');
    }
    offset += count;
  }
}

/// Tolerant standard UTF-8 decoding for ZIP names and manifest bytes.
String utf8Decode(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// One entry of a ZIP/JAR central directory.
class JavaZipEntry {
  const JavaZipEntry({
    required this.name,
    required this.compressionMethod,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.crc32,
    required this.localHeaderOffset,
    this.flags = 0,
  });

  final String name;
  final int compressionMethod;
  final int compressedSize;
  final int uncompressedSize;
  final int crc32;
  final int localHeaderOffset;
  final int flags;

  bool get isDirectory => name.endsWith('/');

  bool get isClassFile => name.endsWith('.class');

  bool get isManifest => name.toUpperCase() == 'META-INF/MANIFEST.MF';

  String get compressionName => switch (compressionMethod) {
    0 => 'stored',
    8 => 'deflate',
    _ => 'method $compressionMethod',
  };

  /// The package the entry lives in, or `''` for the root.
  String get directory {
    final slash = name.lastIndexOf('/');
    return slash < 0 ? '' : name.substring(0, slash);
  }

  /// `fixtures/Greeting.class  deflate  512 -> 1159 B`
  String get listing {
    if (isDirectory) return name;
    return '$name  $compressionName  '
        '${JavaBytesFormat.human(compressedSize)} -> '
        '${JavaBytesFormat.human(uncompressedSize)}';
  }
}

/// Reads the ZIP container structure that a JAR is built on.
///
/// Only the central directory and single entries are read: enough for real
/// inspection (listing, sizes, the manifest). The existing archive package
/// decodes central records, DEFLATE and CRC; strict bounds are checked here
/// before parsing or extracting any user-supplied data.
abstract final class JavaZip {
  static const int _centralDirectoryHeader = 0x02014B50;
  static const int _localHeader = 0x04034B50;
  static const int maxArchiveBytes = 32 * 1024 * 1024;
  static const int maxEntryBytes = 32 * 1024 * 1024;
  static const int maxEntries = 16384;

  /// True when [bytes] end with an end-of-central-directory record.
  static bool looksLikeZip(List<int> bytes) {
    try {
      _endRecordOffset(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Lists the archive's entries in central-directory order.
  static List<JavaZipEntry> entries(List<int> input) {
    if (input.length > maxArchiveBytes) {
      throw const FormatException('ZIP 文件超过 32 MB 检查上限');
    }
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    final end = _endRecordOffset(bytes);
    final reader = _ZipReader(bytes, end);
    reader.skip(4); // signature
    final disk = reader.u2();
    final directoryDisk = reader.u2();
    final entryCount = reader.u2();
    final totalCount = reader.u2();
    if (disk != 0 || directoryDisk != 0 || entryCount != totalCount) {
      throw const FormatException('暂不支持分卷 ZIP 压缩包');
    }
    if (entryCount > maxEntries) {
      throw const FormatException('ZIP 条目数量超过检查上限');
    }
    final directorySize = reader.u4();
    final directoryOffset = reader.u4();
    if (directoryOffset == 0xFFFFFFFF || entryCount == 0xFFFF) {
      throw const FormatException('暂不支持 ZIP64 压缩包');
    }
    if (directorySize == 0xFFFFFFFF) {
      throw const FormatException('暂不支持 ZIP64 压缩包');
    }
    if (directoryOffset + directorySize != end) {
      throw const FormatException('ZIP 中央目录超出文件范围');
    }

    final stream = InputMemoryStream(
      bytes,
      offset: directoryOffset,
      length: directorySize,
    );
    final entries = <JavaZipEntry>[];
    final names = <String>{};
    for (var i = 0; i < entryCount; i++) {
      if (stream.length < 46 ||
          stream.readUint32() != _centralDirectoryHeader) {
        throw const FormatException('ZIP 中央目录条目签名无效');
      }
      final start = stream.position;
      final headerReader = _ZipReader(bytes, directoryOffset + start + 24);
      final nameLength = headerReader.u2();
      final extraLength = headerReader.u2();
      final commentLength = headerReader.u2();
      if (nameLength + extraLength + commentLength > stream.length - 42) {
        throw const FormatException('ZIP 中央目录条目被截断');
      }
      final header = ZipFileHeader()..read(stream);
      if (header.generalPurposeBitFlag & 0x0041 != 0) {
        throw const FormatException('压缩包已加密，无法离线读取');
      }
      if (header.diskNumberStart != 0) {
        throw const FormatException('暂不支持分卷 ZIP 压缩包');
      }
      if (!names.add(header.filename)) {
        throw FormatException('ZIP 条目名称重复：${header.filename}');
      }
      final entry = JavaZipEntry(
        name: header.filename,
        compressionMethod: header.compressionMethod,
        compressedSize: header.compressedSize,
        uncompressedSize: header.uncompressedSize,
        crc32: header.crc32,
        localHeaderOffset: header.localHeaderOffset,
        flags: header.generalPurposeBitFlag,
      );
      _payloadRange(bytes, entry, directoryOffset);
      entries.add(entry);
    }
    if (!stream.isEOS) {
      throw const FormatException('ZIP 中央目录条目数与长度不符');
    }
    return List.unmodifiable(entries);
  }

  /// Reads and, when needed, inflates one entry's bytes.
  ///
  /// Returns null for an unsupported compression method instead of throwing, so
  /// a JAR with one exotic entry still lists and inspects the rest.
  static Uint8List? readEntry(
    List<int> input,
    JavaZipEntry entry, {
    int maxBytes = maxEntryBytes,
  }) {
    if (entry.isDirectory) return null;
    if (input.length > maxArchiveBytes ||
        entry.uncompressedSize > maxBytes ||
        entry.uncompressedSize < 0) {
      throw const FormatException('ZIP 解压后大小超过检查上限');
    }
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    final endRecord = _ZipReader(bytes, _endRecordOffset(bytes) + 16);
    final range = _payloadRange(bytes, entry, endRecord.u4());
    final payload = Uint8List.sublistView(bytes, range.start, range.end);
    Uint8List decoded;
    switch (entry.compressionMethod) {
      case 0:
        decoded = payload;
      case 8:
        try {
          final output = _BoundedZipOutput(entry.uncompressedSize);
          Inflate(payload, output: output);
          decoded = output.getBytes();
        } catch (error) {
          throw FormatException('ZIP DEFLATE 数据无效：$error');
        }
      default:
        return null;
    }
    if (decoded.length != entry.uncompressedSize) {
      throw const FormatException('ZIP 解压长度与中央目录不符');
    }
    if (getCrc32(decoded) != entry.crc32) {
      throw const FormatException('ZIP CRC 校验失败');
    }
    return decoded;
  }

  static ({int start, int end}) _payloadRange(
    Uint8List bytes,
    JavaZipEntry entry,
    int directoryOffset,
  ) {
    final header = entry.localHeaderOffset;
    if (header < 0 || header + 30 > directoryOffset) {
      throw const FormatException('ZIP 本地条目超出文件范围');
    }
    final reader = _ZipReader(bytes, header);
    if (reader.u4() != _localHeader) {
      throw const FormatException('ZIP 本地条目签名无效');
    }
    reader.skip(2);
    final flags = reader.u2();
    final method = reader.u2();
    reader.skip(4);
    final crc = reader.u4();
    final compressed = reader.u4();
    final uncompressed = reader.u4();
    final nameLength = reader.u2();
    final extraLength = reader.u2();
    final start = reader.offset + nameLength + extraLength;
    final end = start + entry.compressedSize;
    if (entry.compressedSize < 0 ||
        start > directoryOffset ||
        end > directoryOffset) {
      throw const FormatException('ZIP 条目数据超出文件范围');
    }
    final name = utf8Decode(
      bytes.sublist(reader.offset, reader.offset + nameLength),
    );
    if (flags != entry.flags ||
        method != entry.compressionMethod ||
        name != entry.name) {
      throw const FormatException('ZIP 本地条目与中央目录不符');
    }
    if (flags & 0x0041 != 0) throw const FormatException('ZIP 条目已加密');
    if (flags & 8 == 0) {
      if (crc != entry.crc32 ||
          compressed != entry.compressedSize ||
          uncompressed != entry.uncompressedSize) {
        throw const FormatException('ZIP 本地长度/CRC 与中央目录不符');
      }
    } else {
      final descriptor = _ZipReader(bytes, end);
      var descriptorCrc = descriptor.u4();
      if (descriptorCrc == 0x08074B50) descriptorCrc = descriptor.u4();
      if (descriptorCrc != entry.crc32 ||
          descriptor.u4() != entry.compressedSize ||
          descriptor.u4() != entry.uncompressedSize ||
          descriptor.offset > directoryOffset) {
        throw const FormatException('ZIP 数据描述符与中央目录不符');
      }
    }
    return (start: start, end: end);
  }

  /// Finds the end-of-central-directory record, whose comment can be up to
  /// 64 KiB, so it is searched backwards rather than assumed to be last.
  static int _endRecordOffset(List<int> bytes) {
    if (bytes.length < 22) {
      throw const FormatException('不是 ZIP/JAR 文件：文件过短');
    }
    final limit = bytes.length - 22;
    final stop = limit - 0xFFFF > 0 ? limit - 0xFFFF : 0;
    for (var offset = limit; offset >= stop; offset--) {
      if (bytes[offset] == 0x50 &&
          bytes[offset + 1] == 0x4B &&
          bytes[offset + 2] == 0x05 &&
          bytes[offset + 3] == 0x06 &&
          offset + 22 + bytes[offset + 20] + (bytes[offset + 21] << 8) ==
              bytes.length) {
        return offset;
      }
    }
    throw const FormatException('不是 ZIP/JAR 文件：找不到中央目录结尾');
  }
}

/// Bounds every write used by archive's inflater, including back references;
/// checking the declared size alone cannot stop a forged-size compression bomb.
class _BoundedZipOutput extends OutputMemoryStream {
  _BoundedZipOutput(this.limit) : super(size: 1024);
  final int limit;

  void _check(int count) {
    if (count < 0 || length + count > limit) {
      throw const FormatException('ZIP 解压长度超过声明大小');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    if (distance <= 0 || distance > length) {
      throw const FormatException('ZIP DEFLATE 回溯距离无效');
    }
    super.writeBackReference(distance, count);
  }
}

/// A parsed `META-INF/MANIFEST.MF`.
class JavaManifest {
  JavaManifest({required this.mainAttributes, required this.sections});

  /// Attributes of the main section, keyed by their original name.
  final Map<String, String> mainAttributes;

  /// Named sections, keyed by the value of their `Name:` attribute.
  final Map<String, Map<String, String>> sections;

  static final RegExp _linePattern = RegExp(r'^([^:]+):\s?(.*)$');

  /// Parses manifest text.
  ///
  /// The format folds long values: a line may be at most 72 bytes and wraps
  /// with a leading space on the continuation. Delegating to [parseBytes] keeps
  /// one unfolding implementation for both entry points.
  factory JavaManifest.parse(String text) =>
      JavaManifest.parseBytes(utf8.encode(text));

  /// Parses manifest bytes, un-folding at the byte level.
  ///
  /// Folding can split a multi-byte UTF-8 character across two lines, so the
  /// continuation bytes are joined before decoding.
  factory JavaManifest.parseBytes(List<int> bytes) {
    final lines = <List<int>>[];
    var current = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      final byte = bytes[i];
      if (byte == 0x0D) continue;
      if (byte == 0x0A) {
        lines.add(current);
        current = <int>[];
        continue;
      }
      // A leading space starts a continuation line; drop it and keep going.
      if (byte == 0x20 && current.isEmpty && lines.isNotEmpty) {
        final previous = lines.removeLast();
        current = previous;
        continue;
      }
      current.add(byte);
    }
    if (current.isNotEmpty) lines.add(current);
    return _parseLines(lines.map(utf8Decode).toList());
  }

  static JavaManifest _parseLines(List<String> lines) {
    final main = <String, String>{};
    final sections = <String, Map<String, String>>{};
    var target = main;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        // A blank line ends the section; main attributes come first.
        target = main;
        continue;
      }
      final match = _linePattern.firstMatch(line);
      if (match == null) continue;
      final key = match.group(1)!.trim();
      final value = match.group(2)!.trim();
      if (key == 'Name') {
        final section = <String, String>{key: value};
        sections[value] = section;
        target = section;
        continue;
      }
      target[key] = value;
    }
    return JavaManifest(
      mainAttributes: Map<String, String>.unmodifiable(main),
      sections: Map<String, Map<String, String>>.unmodifiable(
        sections.map(
          (key, value) =>
              MapEntry(key, Map<String, String>.unmodifiable(value)),
        ),
      ),
    );
  }

  /// Case-insensitive lookup in the main section, as the manifest spec requires.
  String? operator [](String key) {
    final lower = key.toLowerCase();
    for (final entry in mainAttributes.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  String? get mainClass => this['Main-Class'];

  String? get implementationTitle => this['Implementation-Title'];

  String? get implementationVersion => this['Implementation-Version'];

  String? get manifestVersion => this['Manifest-Version'];

  bool get isMultiRelease =>
      (this['Multi-Release'] ?? '').toLowerCase() == 'true';
}

/// A JAR/ZIP inspected entirely from its bytes.
class JavaJarInspection {
  JavaJarInspection({
    required this.entries,
    required this.manifest,
    this.manifestError,
  });

  final List<JavaZipEntry> entries;
  final JavaManifest? manifest;

  /// Why the manifest could not be read, when it could not be.
  final String? manifestError;

  /// Parses [bytes] as a JAR, recording an unreadable manifest instead of
  /// failing the whole inspection.
  factory JavaJarInspection.fromBytes(List<int> bytes) {
    final entries = JavaZip.entries(bytes);
    final manifestEntry = entries
        .where((entry) => entry.isManifest)
        .firstOrNull;
    if (manifestEntry == null) {
      return JavaJarInspection(
        entries: entries,
        manifest: null,
        manifestError: '压缩包中没有 META-INF/MANIFEST.MF',
      );
    }
    if (entries.where((entry) => entry.isManifest).length != 1) {
      return JavaJarInspection(
        entries: entries,
        manifest: null,
        manifestError: '压缩包中有多个 MANIFEST.MF，清单存在歧义',
      );
    }
    try {
      final payload = JavaZip.readEntry(
        bytes,
        manifestEntry,
        maxBytes: 1024 * 1024,
      );
      if (payload == null) {
        throw const FormatException('清单压缩方式不受支持');
      }
      return JavaJarInspection(
        entries: entries,
        manifest: JavaManifest.parseBytes(payload),
      );
    } on FormatException catch (error) {
      return JavaJarInspection(
        entries: entries,
        manifest: null,
        manifestError: error.message,
      );
    }
  }

  int get classCount => entries.where((entry) => entry.isClassFile).length;

  int get fileCount => entries.where((entry) => !entry.isDirectory).length;

  int get totalUncompressedBytes => entries.fold(
    0,
    (sum, entry) => sum + (entry.isDirectory ? 0 : entry.uncompressedSize),
  );

  /// Distinct package directories that contain class files.
  List<String> get packages {
    final seen = <String>[];
    for (final entry in entries) {
      if (!entry.isClassFile) continue;
      if (!seen.contains(entry.directory)) seen.add(entry.directory);
    }
    return seen;
  }

  /// The `module-info.class` entry, when the archive is a modular JAR.
  bool get isModular =>
      entries.any((entry) => entry.name == 'module-info.class');

  /// Entry names in archive order, capped at [limit] for display.
  List<String> entryListing({int limit = 60}) {
    final lines = [for (final entry in entries.take(limit)) entry.listing];
    if (entries.length > limit) {
      lines.add('... 其余 ${entries.length - limit} 个条目已省略');
    }
    return lines;
  }
}

/// Human-readable byte counts shared by the file inspection tools.
abstract final class JavaBytesFormat {
  /// `812 B`, `12.3 KB`, `4.5 MB`. Binary units, one decimal from KB up.
  static String human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }
}
