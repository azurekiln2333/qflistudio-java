# Native Startup Contract

## 1. Scope

Read this before changing `lib/main.dart`, the OHOS `EntryAbility`/`Index`
startup UI, or Android launch resources. The reference is the sibling
`qflistudio` shell. OHOS has an ArkUI startup screen; Android and desktop
use the shared Flutter `SplashScreen` after their native launch screen.

## 2. Signatures

- Channel: `qflistudio/platform`
- Method: `startupProgress`, arguments: `{ "progress": double }`
- Success: null; event: `EVENT_STARTUP_PROGRESS(number)` on the ability event hub.
- OHOS view: `FlutterPage({ viewId, splashScreenView: this.startupSplash })`
- Standalone native refusals: `qflistudio/platform` methods `openAgreement`,
  `openUrl`, and `qflistudio/huawei_account` method `login` return error code
  `OFFLINE_ONLY`, including direct calls with missing or invalid arguments.

## 3. Contracts

Progress is finite and normalized to `[0, 1]`. `EntryAbility` clamps it at the
channel boundary; `StartupSplash` displays `progress * 100`. Subscribe in
`aboutToAppear` and unsubscribe the same handler in `aboutToDisappear`.

On OHOS, call `deferFirstFrame()` before `runApp`. Initialize after the first
framework build, which still runs while engine frame submission is deferred.
Report 0.05 before JDK preparation, 0.25 afterward, and map the three store
completions to `0.25 + progress * 0.75`. Refresh `StudioProfile.current` after
JDK preparation so the first visible home page has the current runtime status.

Match the reference timing: a 160 ms subscription delay, a minimum 1100 ms
display, and 320 ms after local bootstrap. After `ready.value` is true, await
`binding.endOfFrame` before `allowFirstFrame()` in `finally`. `FlutterPage`
removes the native startup UI on its actual `onFirstFrame` callback.

Android must not defer the first Flutter loading frame or use this OHOS event
channel. Android launch/normal backgrounds, Android 12+ splash backgrounds,
and OHOS startup colors are `#F8F9FF` for light and `#111418` for dark.

The standalone Java native entry never dispatches these remote methods to
browser/router/account providers. Register only `pages/Index` in `main_pages`.
Keep local share, document picker, startup progress, plugins and Java bridge
available. The INTERNET permission remains needed by local loopback JDWP/JDI;
this route policy does not claim a network sandbox for user Java programs.

## 4. Validation And Errors

| Condition | Behavior |
| --- | --- |
| Finite progress outside `[0, 1]` | Clamp before emitting |
| Missing, nonnumeric, NaN, or infinite progress | `INVALID_PROGRESS`; no event |
| Missing native progress handler | Ignore `MissingPluginException`; continue startup |
| Native progress `PlatformException` | Log its code; continue startup |
| Unavailable JDK or unreadable local config | Existing preparation/store fallbacks still enter home |
| Initialization throws | Release the first-frame deferral in `finally` |
| Direct remote agreement/browser/account call | `OFFLINE_ONLY` before provider access; no external launch |

## 5. Cases

- Good: native OHOS icon/progress remains visible while JDK and stores load,
  then fades over the rendered home page.
- Base: Android displays its Flutter loading screen while initialization runs.
- Bad: a progress handler is unavailable; initialization must still finish.

## 6. Required Verification

`test/startup_test.dart` checks frame deferral through home layout, monotonic
progress reaching 1, missing-handler startup completion, and immediate Android
loading UI. Use temporary path-provider storage for these tests.

`node --test test/native_entry_ability_test.cjs` transpiles the actual EntryAbility
and invokes its channel handlers against system API doubles. Require remote
refusal envelopes with zero provider calls, local bridge/share/picker behavior,
progress validation, and the single local page registry. These host tests do not
replace ArkTS compilation or source-bound installed-HAP native channel checks.

Run Dart analysis and `flutter test --no-pub`, then build APK and HAP to check
native resources and ArkTS. Cold-start visual verification requires an available
device without system dialogs obscuring the startup transition; packaging and
widget tests alone do not prove the visual handoff on an OHOS device.

## 7. Wrong And Correct

Wrong: hide the native startup screen when progress reaches 100 percent or
immediately after `runApp`.

Correct: keep it until the first submitted Flutter frame contains the laid-out
home page. Progress reports initialization work; the engine callback owns removal.
