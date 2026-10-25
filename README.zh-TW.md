# QFLIJVMX（qfli_java）

[簡體中文](README.md) · [English](README.en.md)

QFLIJVMX 是一個離線 Java 編輯器。
它用 `javac` 編譯原始碼。
它用 `java` 執行程式。
共享核心 `qfli_studio_core` 提供介面。

## 功能

- 編輯器提供檔案樹與語法醒目提示。
- 專案支援空範本與 Java 範本。
- 編譯器處理專案內全部 `.java` 檔案。
- 程式從 `lib/` 與 `libs/` 收集 JAR。
- 程式讀取專案根目錄的 `input.txt` 作為標準輸入。
- 終端機顯示編譯錯誤與程式輸出。
- 編譯器檢查未儲存的緩衝區。
  編輯器定位診斷。
  檢查不寫原始碼。
  檢查不執行程式。
- 獨立偵錯頁支援本機 JDI。
  它提供中斷點、單步執行、呼叫堆疊與區域變數。
  該頁面只讀取已儲存檔案。
- 內建終端機支援 `javac` 與 `java`。
  兩者使用同一套 JDK。
- 工具頁直接顯示 9 張 Java 卡片。
  工具頁還顯示 9 張通用卡片。
- 共享內容包提供 280 個 Java 主題。
- 這些功能無需網際網路。
  JDI 使用本機回環連線。
  OHOS 原生入口拒絕遠端路由。

## 目錄結構

本應用程式是一個獨立儲存庫。
把共享核心簽出至同層級目錄。

```text
checkout-parent/
  qfli_studio_core/
  qfli_java/
```

`pubspec.yaml` 透過路徑相依引用共享核心。
編輯器修補位於 `../qfli_studio_core/vendor/re_editor`。

## 準備

本專案要求 Dart `^3.11.5`。
請使用滿足該約束的 Flutter SDK。
在本儲存庫執行下列命令。

```bash
flutter pub get
flutter run -d DEVICE_ID
```

把 `DEVICE_ID` 換成目標裝置識別碼。

## 桌面 JDK

Windows、Linux 與 macOS 使用主機 JDK。
程式依下列順序尋找 JDK。

1. `QFLI_JAVA_HOME`
2. `JAVA_HOME`
3. `PATH` 中的目錄

把環境變數設定為 JDK 根目錄。
該 JDK 的 `bin/` 必須包含 `javac` 與 `java`。
也可把該 `bin/` 加入 `PATH`。
編譯器固定使用 `--release 17`。
建議使用 JDK 17。
較新版本的主機 JDK 通過不證明目標裝置通過。

## 多檔案、JAR 與輸入

編譯器遞迴收集專案內的 `.java` 檔案。
它跳過以點開頭的目錄與 `build`。
程式遞迴收集 `lib/` 與 `libs/` 下的 JAR。
程式從所選檔案決定入口類別。
程式從原始碼讀取套件名稱。
編譯器把產物寫入暫存目錄。
執行結束後，程式刪除該目錄。
編譯逾時上限預設為 60 秒。
編譯輸出上限預設為 512 KiB。

把輸入寫入專案根目錄的 `input.txt`。
程式不會下載相依套件。

## 行動端原生 JDK

Android 與 HarmonyOS 可封裝 OpenJDK 17.0.20。
Android 使用 HotSpot server。
HarmonyOS 使用 Zero 解譯器。
映像 ABI 必須與目標裝置相符。
程式通過真實版本探測後才回報 JDK 可用。

先建置平台映像。
再依建置說明暫存映像。
最後封裝應用程式。

- [原生 JDK 概覽](native/openjdk/README.md)
- [Android 建置](native/openjdk/android/README.md)
- [HarmonyOS 建置](native/openjdk/ohos/README.md)

## 檢查與測試

在本儲存庫執行下列命令。

```bash
flutter analyze
flutter test
```

主機測試不證明裝置行為。
在共享核心儲存庫驗收內容目錄。

```bash
dart run tool/verify_java_content.dart "JDK17_HOME"
```

把 `JDK17_HOME` 換成真實 JDK 17 的根目錄。
驗收涵蓋 280 個主題主程式。
這些程式對應 1120 處內容片段。

用臨時入口驗收目標裝置。

```bash
flutter run -t tools/java_catalog_ohos_smoke.dart -d DEVICE_ID
flutter run -t tools/jdk_smoke.dart -d DEVICE_ID
flutter run -t tools/java_runtime_acceptance.dart -d DEVICE_ID
```

三個入口分別驗收內容目錄、JDK、診斷與偵錯。
驗收後，重新安裝正常入口。

```bash
flutter run -t lib/main.dart -d DEVICE_ID
```

## 平台驗證範圍

下列結果只涵蓋當時的原始碼。
請依目標平台重新驗收後續版本。

| 日期 | 目標 | 結果 |
| --- | --- | --- |
| 2026-10-22 | WSL，OpenJDK 17.0.20.1 | 280/280 個主程式通過。 |
| 2026-10-22 | 應用程式測試主機 | 235 項測試通過。靜態分析未回報問題。 |
| 2026-10-22 | HarmonyOS 7.0.0.107，API 26，x86_64 | 280/280 個主程式通過。26 項診斷檢查通過。16 項偵錯檢查通過。 |
| 2026-09-30 | OpenHarmony 6.1.1.125，API 24，x86_64 | 8 項應用程式內 JDK 檢查通過。 |
| 2026-10-02 | Android，API 37，x86_64，16 KiB 頁 | 8 項應用程式內 JDK 檢查通過。 |

## 尚未完成

- 共享編輯器偵錯功能的本應用程式裝置驗收尚未完成。
- 練習答案的完整驗收尚未完成。
- Android 與 HarmonyOS ARM64 真機執行尚未驗證。
  成功封裝不證明真機通過。
- Android API 28 執行尚未驗證。
- iOS 與 Web 不支援執行 Java。
- Spring Boot 準備腳本與本機 JAR 組裝程式碼可用。
  介面範本尚未接入。

## 授權

授權條款見 [LICENSE](LICENSE)。
