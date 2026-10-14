# Diagnosis: OHOS 软键盘弹出后页面不再调整布局

Date: 2026-10-14
Status: 排查完成；**方案 A 已按此报告执行**（`resizeToAvoidBottomInset: false` 已删除）

## 结论（一句话）

**是 `resizeToAvoidBottomInset: false` 造成的**，位置在
`qfli_studio_core/lib/editor/editor_page.dart:1039`。这是**未提交**的改动，
由中断的 sub-agent 引入、被我保留下来。它从未进入任何提交。

## 根因证据

### 证据 1 — 该行位置与状态

`qfli_studio_core/lib/editor/editor_page.dart:1033-1039`：

```dart
child: Scaffold(
  key: _scaffoldKey,
  // Do not let the soft keyboard resize the editor body: a
  // keyboard-driven resize rebuilds the body via LayoutBuilder, which
  // on OHOS can detach the freshly attached IME and dismiss the
  // keyboard right after it appears.
  resizeToAvoidBottomInset: false,     // ← line 1039
```

`git diff` 显示这是**新增行**（`+`），且：

```
$ git log --oneline -S "resizeToAvoidBottomInset" --all -- lib/editor/editor_page.dart
（空）
```

**全仓库历史中从未提交过这行** —— 它是未提交的工作区改动。

### 证据 2 — HEAD 版本没有这个 flag

`git show HEAD:lib/editor/editor_page.dart` 第 1024-1026 行：

```dart
child: Scaffold(
  key: _scaffoldKey,
  drawerScrimColor: scheme.surface,     // ← 直接就是下一个属性，没有 resize flag
```

### 证据 3 — 全项目只有这一处

```
$ grep resizeToAvoidBottomInset (core + java lib/)
qfli_studio_core\lib\editor\editor_page.dart:1039: resizeToAvoidBottomInset: false,
```

只有这一处，且是**唯一**被关闭的地方；其他所有 Scaffold 都用默认值 `true`。

### 证据 4 — 编辑器页没有其他地方自行处理 inset

`editor_page.dart` 里 `MediaQuery` 只用于取宽度：
- `:555` `MediaQuery.sizeOf(context).width`
- `:992` `MediaQuery.sizeOf(context).width`

**没有**任何 `MediaQuery.viewInsetsOf(...)` / `viewInsets.bottom` 的补偿逻辑。
所以关闭 `resizeToAvoidBottomInset` 之后，**没有任何替代机制**去让布局避让键盘。

## 机制说明（为什么这会造成"不再被顶起"）

Flutter 的 `Scaffold.resizeToAvoidBottomInset`（默认 `true`）负责把
`MediaQuery.viewInsets.bottom`（= 软键盘高度）从 body 高度里扣掉。
设为 `false` 后，Scaffold **忽略**键盘 inset，body 保持满高，
于是软键盘浮在内容之上而不是把内容顶起 —— 正是你观察到的现象。

## 是哪个提交/改动引入的

**不是任何提交，是未提交的工作区改动。**

时间线：

| 阶段 | 状态 |
| --- | --- |
| 提交历史（含 `e45b4f0`、`021a90e`） | 无该 flag，行为正常（键盘顶起布局） |
| 10-14 子 agent 中断留下的工作区改动 | **加入** `resizeToAvoidBottomInset: false` |
| 我接手 `10-14-ohos-terminal-editor-focus` 时 | **保留**了它（见 `notes/diagnosis.md:98,120`、`notes/implementation.md:48`） |

我当时的理由是"键盘触发的 resize 会重建 body、在 OHOS 上可能拆掉刚连上的 IME"。
这个理由**未经真机验证**，是推理；而它带来的副作用（布局不再避让键盘）现在是实际发生的。

## 排除的其他嫌疑（都已核查，均无关）

### ohos 侧窗口/键盘配置：无相关配置，且近期提交未改动

- `EntryAbility.ets`：全文搜索 `keyboardAvoidMode` / `setWindowLayoutFullScreen`
  / `windowSoftInputMode` → **无匹配**。
- `Index.ets` 的 `FlutterPage`（`:67`）只设了 `width('100%')` / `height('100%')`。
- `module.json5` / `app.json5`：无任何 `window` / `softInput` 配置。
- `e45b4f0` 对 `EntryAbility.ets` 的改动只有新增 `openAgreement` / `startupProgress`
  两个 channel 分支和 `router` import（`git show e45b4f0 -- .../EntryAbility.ets`），
  **不涉及窗口或键盘**。
- `e45b4f0` 对 `Index.ets` 只改了 `.height(...)` 与背景色，无键盘相关改动。
- `setWindowLayoutFullScreen` / `expandSafeArea` 的唯一匹配都在引擎插件内
  （`ohos/oh_modules/.../FlutterManager.ets:593`、`FlutterPage.ets:66`），
  是第三方代码，非本项目配置。

### 其他未提交改动：均与布局无关

| 文件 | 改动 | 是否影响键盘避让 |
| --- | --- | --- |
| `ohos/build-profile.json5` | 只换了 `keyPassword` / `storePassword` 两个签名密码 | 无关 |
| `pubspec.yaml` | 新增 `assets/spring_boot/3.5.16/` 资源声明 | 无关 |
| `analysis_options.yaml` | 新增 `build/**` 到 analyzer exclude | 无关 |
| `.gitignore` | 新增 `/assets/spring_boot/` | 无关 |
| `terminal_input.dart` | 新增 `isOhosPlatform` / `restoreKeyboard` | 无关（不改布局） |
| `terminal_pane.dart` | `_focusInput` 用 `restoreKeyboard`；`_onKey` 去掉坏分支 | 无关（不改布局） |
| `editor_page.dart:439-447` | `_handlePointerDown` 里 OHOS 先 `unfocusInput()` | 无关（焦点，不改 inset） |

**注意**：`editor_page.dart` 有**两处**未提交改动，只有第 1039 行那处影响布局。

### `SafeArea`：不是原因

`editor_page.dart:1437` 和其他页面的 `SafeArea` 只管状态栏/刘海，
不负责键盘 inset，且这些都不是本次改动引入的。

## 建议的修复方案

### 方案 A（推荐，最小、最直接）

**删除 `editor_page.dart:1039` 的 `resizeToAvoidBottomInset: false`**，
连同 1035-1038 行的注释一起删掉，恢复 HEAD 行为。

- 代价：当时想规避的"键盘弹出导致 IME 被拆掉"问题可能复现（但**那个问题本身也从未验证过**）。
- 收益：布局避让键盘恢复正常，且消除一处未经证实的改动。
- 风险：低。这是回到已验证的 HEAD 行为。

### 方案 B（若确实需要防止 resize 干扰 IME）

保留 `resizeToAvoidBottomInset: false`，但**自行补偿**布局，
在编辑器 body 外层加 `MediaQuery.viewInsetsOf(context).bottom` 的 padding：

```dart
Padding(
  padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
  child: <body>,
)
```

- 收益：既阻止 Scaffold 自身 resize，又让内容避让键盘。
- 代价：改动较大，需要处理 `AnimatedPadding` 过渡、终端面板高度联动等，
  且要防止和终端面板自身的高度逻辑冲突。
- 建议：**先不做**，除非方案 A 证实会带回 IME 问题。

### 方案 C（先验证再决定）

先按方案 A 改回，在 **OHOS 真机**上实测两件事：
1. 键盘弹出时布局是否恢复避让；
2. "点编辑器键盘闪退"是否复现。

根据实测结果再决定是否需要方案 B。
**注意**：目前无 OHOS 设备（`hdc list targets` 为空），且 `flutter build hap`
仍卡在签名问题，所以第 2 点暂时测不了。

### 我的建议

**采用方案 A**，理由：那行改动的收益从未被验证，而它的副作用已经实际发生。
如果后续真机上发现 IME 问题，再用方案 B 定向解决 —— 而不是先付出确定的代价
去防一个未经证实的问题。

### 执行结果

**已按方案 A 执行**：`editor_page.dart` 中的 `resizeToAvoidBottomInset: false`
及其注释已删除，HEAD 行为恢复。用户要求的真机复测（布局是否恢复避让、
键盘是否仍闪退）因**当前无 OHOS 设备**而尚未进行。

## 附：与 10-14 任务记录的关系

`notes/diagnosis.md:98` 和 `notes/implementation.md:48` 把我保留这行的决策
记录为正确。**那份记录需要更正**：该决策已在本次排查中被证明有实际副作用。
建议在修复后同步更新这两个文件与 `.trellis/spec/frontend/editor-terminal.md`
第 13.3 节（该节目前把这行写成"required configuration"）。
