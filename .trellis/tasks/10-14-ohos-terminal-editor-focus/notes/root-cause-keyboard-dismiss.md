# Root Cause: 键盘弹出后立即收起（终端面板中间高度才触发）

Date: 2026-10-14
Status: 已定位并修复。未提交 git。

## 现象回顾

`resizeToAvoidBottomInset` 恢复默认（`true`）后，"键盘弹出立刻收起"回来了，
且只在终端面板拖到**某个中间高度**时出现；很高或很低都不出现。

## 根因（带证据）

**不是 IME 问题，也不是 inset 问题。是终端面板的 `compact` 布局把含焦点的
`TextField` 子树整个换掉了，导致 `FocusNode` 的 element 被卸载。**

### 证据链

1. 键盘弹出 → body 可用高度减少（`resizeToAvoidBottomInset: true` 的正常行为）。

2. `EditorPage` 用 `LayoutBuilder` 从 body 高度算出 `compactPanel`
   —— `qfli_studio_core/lib/editor/editor_page.dart:1442-1485`：

   ```dart
   body: LayoutBuilder(
     builder: (context, constraints) {
       final bodyHeight = constraints.maxHeight;
       ...
       final maxPanelHeight = ceiling.clamp(collapsedPanelHeight, bodyHeight);
       // 1468-1470
       final compactPanel =
           maxPanelHeight < TerminalPanelMetrics.minExpandedHeight;
   ```

   并在 `editor_page.dart:1538` 把它传下去：`compactPanel: compactPanel`。

3. `_buildTerminalPanel` 把它接到 `TerminalPane` 的 `compact`
   —— `editor_page.dart:1607`：`compact: compactPanel`。

4. **`TerminalPane.build` 原本在 `compact` 时走另一条分支**，返回的子树里
   **没有** prompt（因此没有 `TextField`）。这是修复前的
   `terminal_pane.dart:961`：

   ```dart
   if (_collapsed || widget.compact) {
     ...  // returns header-only Column: no prompt, no TextField
   }
   return Column(... _buildTranscript(context) ...);  // has the prompt
   ```

5. prompt（`TextField`，`terminal_pane.dart` 的 `_buildPromptRow`）是唯一
   持有 `_session.focusNode` 的地方：
   `terminal_pane.dart:1401` `focusNode: _session.focusNode`。
   子树被换掉 → `TextField` 的 element 卸载 → `FocusNode` 失去 element →
   平台 IME 关闭 → **键盘弹起后立刻收起**。

### 阈值计算与该现象的吻合

`editor_page.dart:1446-1485` 的实际公式：

```
maxPanelHeight = min(bodyHeight * 0.7, bodyHeight - 140)   // minEditorHeight=140
compactPanel   = maxPanelHeight < 120                       // minExpandedHeight=120
```

在 `bodyHeight < 466.7` 区间内 `bodyHeight - 140` 更小，所以：

```
compact  ⇔  bodyHeight - 140 < 120  ⇔  bodyHeight < 260
```

设屏幕全高 `H`、键盘高 `K`、终端面板拖拽高度 `drag`
（弹出后 `bodyHeight = H - drag - K`）：

```
compact  ⇔  H - drag - K < 260  ⇔  drag > H - K - 260
```

`H=900, K=300` 时，`drag > 340` 即触发。再看 `Offstage` 的隐藏条件
（`editor_page.dart:1530` 附近）：

```
offstage ⇔ bodyHeight - 58 < 140 ⇔ bodyHeight < 198
```

推演：

| drag | bodyHeight | maxPanelHeight | compact | offstage | 结果 |
| --- | --- | --- | --- | --- | --- |
| 150 | 450 | 310.0 | false | false | 正常 |
| 250 | 350 | 210.0 | false | false | 正常 |
| 340 | 260 | 120.0 | false | false | 正常 |
| **400** | **200** | **60.0** | **true** | **false** | **输入被卸载 → 键盘闪退** |
| 500 | 100 | -40.0 | true | true | 面板已隐藏，无闪退 |
| 600 | 0 | -140.0 | true | true | 面板已隐藏，无闪退 |

**这正是"只有中间高度才触发"的窗口**：`compact` 变 true 但面板还没被
`Offstage` 隐藏的那一段。这与用户观察完全一致。

### 为什么之前没暴露

`resizeToAvoidBottomInset: false` 阻止了 `bodyHeight` 随键盘收缩，所以
`compact` 永远不会因为键盘而翻转，这个潜在缺陷被掩盖了。`compact` 分支
本身由 `b75f656`（`feat(core): checkpoint two weeks of studio work`）引入，
不是本次未提交改动造成的。

## 修复

**思路**：不禁止 resize，也不增删子树；让 body 在两种模式下**占据同一个
Column 槽位、同一条 element 路径**，只改变它的**高度**。

`terminal_pane.dart` 的 `build` 改成单一稳定的 Column：

```
Column([
  if (...) resizeHandle,
  header,                      // collapsed/compact header 或 expanded header
  Flexible(fit: loose,         // 唯一的 body 槽位，两种模式都在这里
    child: SizedBox(
      width: double.infinity,
      height: headerOnly ? 0 : null,   // 只改高度，不删除
      child: _buildBody(context),
    ),
  ),
])
```

要点：

- `_buildBody(context)` 是 transcript（内含 prompt/`TextField`），**两种模式
  都在同一槽位、同一 widget 链**，所以 element 被复用，`FocusNode` 保持挂载。
- header-only 时高度给 **0** 而不是移除子树。0 仍是**有界**高度，transcript
  的 `ListView` 可以合法布局。
  - 先试过 `Offstage` / `Visibility(maintainState)`：它们保留 state，但会给
    child **无界高度**，`ListView` 直接 `Vertical viewport was given unbounded
    height` 断言失败。所以不能用。
- 顺带把两个 header 抽成 `_buildCollapsedHeader` / `_buildExpandedHeader`，
  并把 body 抽成 `_buildBody`，让 build 只剩一个布局形状。

**没有**重新引入 `resizeToAvoidBottomInset: false`。

## 测试

新增 `qfli_studio_core/test/terminal_compact_focus_test.dart`：

- 挂载 `TerminalPane` 到 600x300（展开态），聚焦 prompt。
- 保持同一 `GlobalKey`，切到 600x90 + `compact: true`（模拟键盘导致的
  body 收缩把 `compactPanel` 翻成 true）。
- 断言：`EditableText` 仍在（`skipOffstage: false` 才可见）、**是同一个
  element**、且仍持有焦点。
- 再切回展开态，断言仍是同一个 element 且仍有焦点。

验证：

| 阶段 | 结果 |
| --- | --- |
| 修复前（`git stash` 掉 terminal_pane.dart） | **失败**（`Found 0 widgets with type "EditableText"`） |
| 修复后 | **通过** |

关于 finder：`compact` 下输入被放在 0 高度槽位，Flutter 的默认 finder 会跳过
非 onstage 子树，所以测试必须用 `skipOffstage: false`。这一点在测试里已注明。

另外为测试加了 `@visibleForTesting focusInputForTest()`
（`terminal_pane.dart`），因为真实聚焦路径是 250ms 延迟的单击处理器，从测试
驱动它只会依赖指针时序，而不是被测行为。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| `dart analyze lib/editor/terminal_pane.dart` | No issues found |
| `flutter analyze`（core，lib+test 自有代码） | 0 问题 |
| `terminal_compact_focus_test.dart` | 1/1 通过（修复前失败） |
| `terminal_pane_test` + `editor_run_test` + 新测试 | 42/42 通过 |
| 6 个 terminal 相关套件 | 73/73 通过 |
| `flutter test`（java 仓库） | 34/34 通过 |
| `flutter test`（core 全量） | 仅剩 6 个 `widget_test.dart` 既有失败（改动前同样失败，与本任务无关） |

## 仍需真机验证

- 修复的效果（键盘弹出时布局避让且不闪退）**必须在 OHOS 真机上复测**。
  当前无设备（`hdc list targets` 为空），且 `flutter build hap` 仍卡在签名。
- 本修复只保证：布局切换不再卸载输入控件。若真机上仍有闪退，说明还存在
  第二条路径（例如 IME 连接被别处断开），需要另查。
