/// Static reference data for the Java-specific tools.
library;

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
