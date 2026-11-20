/*
 * Exported entry point for qfli-interop/1.
 *
 * Studio starts this ability with a project reference. The ability keeps the
 * app in the foreground while the JDK compiles and runs, because a sibling app
 * may not start abilities from the background, and it finishes itself when the
 * run reports a terminal event.
 */
import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import {
  compileAndRun,
  prepareProject,
  emit,
  parseRequest,
  InteropRequest,
  Refusal,
} from './InteropReceiver';

export default class InteropAbility extends UIAbility {
  private running: boolean = false;
  private pendingWant: Want | null = null;
  private delayId: number = -1;

  onCreate(want: Want): void {
    // Handling the request here would race the ability's own start: a
    // startAbility issued before the window stage exists fails with 16200001
    // (caller invalid), which silently ate every event. The want waits for
    // onWindowStageCreate, where the token is complete.
    this.pendingWant = want;
  }

  onNewWant(want: Want): void {
    // A second request while one is running is refused honestly instead of
    // queueing behind an unknown wait.
    if (this.running || this.pendingWant !== null) {
      this.refuseBusy(want);
      return;
    }
    // A reused singleton never sees onWindowStageCreate again, so a want parked
    // for the window stage would sit here forever and the run dialog would hang
    // on "connecting". The ability is already started, so it can deliver the
    // final response through Studio's bridge ability.
    this.handle(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // No UI of its own. The window exists only because a background
    // application may neither start another application's UI ability (the
    // response event would be refused) nor reliably deliver common events; the
    // run therefore finishes while this ability still holds the foreground,
    // hands the result to Studio in one event, and terminates.
    windowStage.loadContent('pages/InteropIdle', (error: BusinessError | null) => {
      if (error !== null) {
        console.error(`QFLI_INTEROP_WINDOW_FAILED ${error.code}`);
      }
    });
    const want = this.pendingWant;
    this.pendingWant = null;
    if (want !== null) {
      this.handle(want);
    }
  }

  onWindowStageDestroy(): void {
    // A re-used singleton whose window is torn down while a deferred want is
    // still parked would never run it; the request dies with the process.
    this.pendingWant = null;
  }

  private handle(want: Want): void {
    const source = want.parameters;
    if (source === undefined) {
      this.context.terminateSelf();
      return;
    }
    let request: InteropRequest;
    try {
      request = parseRequest(source);
    } catch (error) {
      const refusal = error as Refusal;
      console.error(`QFLI_INTEROP_PARSE_FAILED ${refusal.code} ${refusal.message}`);
      this.refuseRaw(source, refusal.message, refusal.code).finally(() => {
        this.context.terminateSelf();
      });
      return;
    }
    this.running = true;
    this.execute(request);
  }

  private async execute(request: InteropRequest): Promise<void> {
    // The allowance belongs to this request and is released in finally.
    try {
      const delayInfo = backgroundTaskManager.requestSuspendDelay(
        'qfli-interop compile and run',
        () => {
          console.error('QFLI_INTEROP_SUSPEND_WARNING');
        });
      this.delayId = delayInfo.requestId;
      console.error(`QFLI_INTEROP_TRANSIENT remaining=${delayInfo.actualDelayTime}`);
    } catch (error) {
      console.error(`QFLI_INTEROP_TRANSIENT_FAILED ${(error as BusinessError).code}`);
    }
    try {
      if (request.action === 'analyze') {
        await emit(this.context, request, 1, 'done', '能力探测完成', 0);
        return;
      }
      const project = await prepareProject(this.context, request);
      await compileAndRun(this.context, request, project);
    } catch (error) {
      const refusal = error instanceof Refusal
        ? error : new Refusal('internal', '跨应用执行失败');
      console.error(`QFLI_INTEROP_RUN_FAILED ${refusal.code} ${refusal.message}`);
      await this.refuse(request, refusal.message, refusal.code);
    } finally {
      this.running = false;
      if (this.delayId >= 0) {
        try {
          backgroundTaskManager.cancelSuspendDelay(this.delayId);
        } catch (error) {
          console.error('QFLI_INTEROP_RELEASE_FAILED');
        }
        this.delayId = -1;
      }
      // Hand the foreground back to Studio the moment the result event is out;
      // the run dialog never shows the idle window longer than the compile.
      this.minimizeWindow();
      this.context.terminateSelf();
    }
  }

  /** Minimizes this ability's window. Failure is never fatal. */
  private minimizeWindow(): void {
    window.getLastWindow(this.context).then((candidate) => {
      candidate.minimize().catch((failure: BusinessError) => {
        console.error(`QFLI_INTEROP_MINIMIZE_FAILED ${failure.code}`);
      });
    }).catch((failure: BusinessError) => {
      console.error(`QFLI_INTEROP_LASTWINDOW_FAILED ${failure.code}`);
    });
  }

  /**
   * Reports a refusal through the same event stream the caller already reads.
   *
   * The caller awaits this before the finally terminates the ability: an
   * in-flight start whose caller is already terminating fails with 16200001
   * and the refusal never reaches Studio.
   */
  private async refuse(request: InteropRequest, message: string, code: string): Promise<void> {
    await emit(this.context, request, 1, 'error', message, undefined, code).catch(() => {
      // Studio is gone; the run stops either way.
    });
  }

  private refuseBusy(want: Want): void {
    const source = want.parameters;
    if (source === undefined) {
      return;
    }
    // The ongoing run keeps this ability alive, so no terminate here.
    this.refuseRaw(source, '已有编译或运行任务', 'internal');
  }

  /** Sends an error event using nothing but the raw parameters. */
  private async refuseRaw(source: Record<string, Object>, message: string, code: string): Promise<void> {
    if (source['callerBundle'] !== 'com.azurekiln.qflistudio') return;
    const parameters: Record<string, Object> = {};
    parameters['protocol'] = 'qfli-interop/1';
    parameters['sessionId'] = `${source['sessionId'] ?? ''}`;
    parameters['sessionToken'] = `${source['sessionToken'] ?? ''}`;
    parameters['seq'] = 1;
    parameters['event'] = 'error';
    parameters['text'] = message;
    parameters['code'] = code;
    const reply: Want = {
      bundleName: `${source['callerBundle'] ?? ''}`,
      abilityName: 'InteropBridgeAbility',
      action: 'action.system.qfli.interop.event',
      parameters: parameters,
    };
    try {
      await this.context.startAbility(reply);
    } catch (failure) {
      console.error(`QFLI_INTEROP_REFUSAL_UNSENT ${(failure as BusinessError).code}`);
    }
  }
}
