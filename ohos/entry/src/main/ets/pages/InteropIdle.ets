/*
 * Idle page shown while InteropAbility handles a cross-app request.
 *
 * The ability has no Flutter engine, so loading the FlutterPage host crashes.
 * This page is plain ArkUI: it only keeps the ability in the foreground while
 * the JDK compiles and runs, and never touches LocalStorage or the eventHub.
 */
@Entry
@Component
struct InteropIdle {
  build() {
    Stack({ alignContent: Alignment.Center }) {
      Text('QFLIJVMX 正在处理跨应用请求')
        .fontSize(14)
        .fontColor('#9E9E9E')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101014')
  }
}
