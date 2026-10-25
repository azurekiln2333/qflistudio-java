# QFLIJVMX（qfli_java）

[繁體中文](README.zh-TW.md) · [English](README.en.md)

QFLIJVMX 是一个离线 Java 编辑器。
它用 `javac` 编译源码。
它用 `java` 运行程序。
共享内核 `qfli_studio_core` 提供界面。

## 功能

- 编辑器提供文件树与代码高亮。
- 项目支持空模板与 Java 模板。
- 编译器处理项目内全部 `.java` 文件。
- 程序从 `lib/` 与 `libs/` 收集 JAR。
- 程序读取项目根的 `input.txt` 作为标准输入。
- 终端显示编译错误与程序输出。
- 编译器检查未保存的缓冲区。
  编辑器定位诊断。
  检查不写源码。
  检查不运行程序。
- 独立调试页支持本地 JDI。
  它提供断点、单步、调用栈与局部变量。
  该页面只读取已保存文件。
- 内置终端支持 `javac` 与 `java`。
  两者使用同一套 JDK。
- 工具页直接显示 9 张 Java 卡片。
  工具页还显示 9 张通用卡片。
- 共享内容包提供 280 个 Java 主题。
- 这些功能无需互联网。
  JDI 使用本机回环连接。
  OHOS 原生入口拒绝远程路由。

## 目录结构

本应用是一个独立仓库。
把共享内核检出到同级目录。

```text
checkout-parent/
  qfli_studio_core/
  qfli_java/
```

`pubspec.yaml` 通过路径依赖引用共享内核。
编辑器补丁位于 `../qfli_studio_core/vendor/re_editor`。

## 准备

本项目要求 Dart `^3.11.5`。
请使用满足该约束的 Flutter SDK。
在本仓库运行以下命令。

```bash
flutter pub get
flutter run -d DEVICE_ID
```

把 `DEVICE_ID` 换成目标设备标识。

## 桌面 JDK

Windows、Linux 与 macOS 使用主机 JDK。
程序按以下顺序查找 JDK。

1. `QFLI_JAVA_HOME`
2. `JAVA_HOME`
3. `PATH` 中的目录

把环境变量配置为 JDK 根目录。
该 JDK 的 `bin/` 必须包含 `javac` 与 `java`。
也可把该 `bin/` 加入 `PATH`。
编译器固定使用 `--release 17`。
推荐使用 JDK 17。
更高版本的主机 JDK 通过不证明目标设备通过。

## 多文件、JAR 与输入

编译器递归收集项目内的 `.java` 文件。
它跳过以点开头的目录与 `build`。
程序递归收集 `lib/` 与 `libs/` 下的 JAR。
程序从所选文件确定入口类。
程序从源码读取包名。
编译器把产物写入临时目录。
运行结束后，程序删除该目录。
编译超时上限默认为 60 秒。
编译输出上限默认为 512 KiB。

把输入写入项目根的 `input.txt`。
程序不会下载依赖。

## 移动端原生 JDK

Android 与 HarmonyOS 可打包 OpenJDK 17.0.20。
Android 使用 HotSpot server。
HarmonyOS 使用 Zero 解释器。
镜像 ABI 必须与目标设备匹配。
程序通过真实版本探测后才报告 JDK 可用。

先构建平台镜像。
再按构建说明暂存镜像。
最后打包应用。

- [原生 JDK 概览](native/openjdk/README.md)
- [Android 构建](native/openjdk/android/README.md)
- [HarmonyOS 构建](native/openjdk/ohos/README.md)

## 检查与测试

在本仓库运行以下命令。

```bash
flutter analyze
flutter test
```

主机测试不证明设备行为。
在共享内核仓库验收内容目录。

```bash
dart run tool/verify_java_content.dart "JDK17_HOME"
```

把 `JDK17_HOME` 换成真实 JDK 17 的根目录。
验收覆盖 280 个主题主程序。
这些程序对应 1120 处内容片段。

用临时入口验收目标设备。

```bash
flutter run -t tools/java_catalog_ohos_smoke.dart -d DEVICE_ID
flutter run -t tools/jdk_smoke.dart -d DEVICE_ID
flutter run -t tools/java_runtime_acceptance.dart -d DEVICE_ID
```

三个入口分别验收内容目录、JDK、诊断与调试。
验收后，重新安装正常入口。

```bash
flutter run -t lib/main.dart -d DEVICE_ID
```

## 平台验证范围

以下结果只覆盖当时的源码。
请按目标平台重新验收后续版本。

| 日期 | 目标 | 结果 |
| --- | --- | --- |
| 2026-10-22 | WSL，OpenJDK 17.0.20.1 | 280/280 个主程序通过。 |
| 2026-10-22 | 应用测试主机 | 235 项测试通过。静态分析未报告问题。 |
| 2026-10-22 | HarmonyOS 7.0.0.107，API 26，x86_64 | 280/280 个主程序通过。26 项诊断检查通过。16 项调试检查通过。 |
| 2026-09-30 | OpenHarmony 6.1.1.125，API 24，x86_64 | 8 项应用内 JDK 检查通过。 |
| 2026-10-02 | Android，API 37，x86_64，16 KiB 页 | 8 项应用内 JDK 检查通过。 |

## 尚未完成

- 共享编辑器调试器的本应用设备验收尚未完成。
- 练习答案的完整验收尚未完成。
- Android 与 HarmonyOS ARM64 真机运行尚未验证。
  成功打包不证明真机通过。
- Android API 28 运行尚未验证。
- iOS 与 Web 不支持运行 Java。
- Spring Boot 准备脚本与本地 JAR 组装代码可用。
  界面模板尚未接入。

## 许可

许可证见 [LICENSE](LICENSE)。
