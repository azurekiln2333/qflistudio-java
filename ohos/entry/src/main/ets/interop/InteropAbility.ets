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
import {
  compileAndRun,
  copyPayload,
  emit,
  parseRequest,
  InteropRequest,
  Refusal,
} from './InteropReceiver';

export default class InteropAbility extends UIAbility {
  private running: boolean = false;

  onCreate(want: Want): void {
    this.handle(want);
  }

  onNewWant(want: Want): void {
    // A second request while one is running is refused honestly instead of
    // queueing behind an unknown wait.
    if (this.running) {
      this.refuseBusy(want);
      return;
    }
    this.handle(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // No UI of its own: the editor already shows progress. Loading the existing
    // page keeps the ability in the foreground without a second window.
    windowStage.loadContent('pages/Index', (error: BusinessError | null) => {
      if (error !== null) {
        console.error(`QFLI_INTEROP_WINDOW_FAILED ${error.code}`);
      }
    });
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
      this.refuseRaw(source, refusal.message, refusal.code);
      this.context.terminateSelf();
      return;
    }
    this.running = true;
    this.execute(request);
  }

  private async execute(request: InteropRequest): Promise<void> {
    try {
      if (request.action === 'analyze') {
        await emit(this.context, request, 1, 'done', '能力探测完成', 0);
        return;
      }
      const project = copyPayload(this.context, request);
      await compileAndRun(this.context, request, project);
    } catch (error) {
      const refusal = error as Refusal;
      this.refuse(request, refusal.message, refusal.code);
    } finally {
      this.running = false;
      this.context.terminateSelf();
    }
  }

  /**
   * Reports a refusal through the same event stream the caller already reads.
   *
   * A refusal before the request is understood cannot name a session, so the
   * caller side also treats a start failure as a refusal.
   */
  private refuse(request: InteropRequest, message: string, code: string): void {
    emit(this.context, request, 99, 'error', message, undefined, code).catch(() => {
      // Studio is gone; the run stops either way.
    });
  }

  private refuseBusy(want: Want): void {
    const source = want.parameters;
    if (source === undefined) {
      return;
    }
    this.refuseRaw(source, '已有编译或运行在进行中', 'internal');
  }

  /** Sends an error event using nothing but the raw parameters. */
  private refuseRaw(source: Record<string, Object>, message: string, code: string): void {
    const parameters: Record<string, Object> = {};
    parameters['protocol'] = 'qfli-interop/1';
    parameters['sessionId'] = `${source['sessionId'] ?? ''}`;
    parameters['seq'] = 1;
    parameters['event'] = 'error';
    parameters['text'] = message;
    parameters['code'] = code;
    const reply: Want = {
      bundleName: `${source['callerBundle'] ?? ''}`,
      abilityName: 'InteropBridgeAbility',
      parameters: parameters,
    };
    this.context.startAbility(reply).catch((failure: BusinessError) => {
      console.error(`QFLI_INTEROP_REFUSAL_UNSENT ${failure.code}`);
    });
  }
}
