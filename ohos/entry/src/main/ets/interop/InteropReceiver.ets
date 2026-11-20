/*
 * qfli-interop/1 receiver for QFLIJVMX.
 *
 * Studio sends a project to this app instead of compiling it itself. The two
 * apps are separate sandboxes, so the project arrives as one zip inside the
 * caller's cache, shared under a file-URI read grant: the Want carries the uri
 * and FLAG_AUTH_READ_URI_PERMISSION, and the grant is what lets the open below
 * succeed. This file copies the zip into its own cache, decompresses it,
 * re-validates every restored path, compiles with the bundled JDK and runs the
 * entry class.
 *
 * Rules here mirror `qfli_studio_core/lib/interop/interop_protocol.dart`. A rule
 * on only one side is a hole, so change both together.
 */
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import zlib from '@ohos.zlib';
import { util } from '@kit.ArkTS';
import { startJava, pollJava, cancelJava } from 'libqfli_jdk_layout.so';
import { prepareJdk } from '../entryability/JavaBridge';

/** Studio's bridge ability, which receives our events. */
const BRIDGE_ABILITY = 'InteropBridgeAbility';
/**
 * The action Studio's bridge ability declares in its own module.json5.
 *
 * An exported ability that declares skills is started cross-app only when the
 * Want matches one of them; without the action the platform refuses the start
 * with 201 (ABMS13313) and the event never arrives.
 */
const BRIDGE_ACTION = 'action.system.qfli.interop.event';
export const PROTOCOL = 'qfli-interop/1';
export const LANGUAGE = 'java';

/** The only caller this app answers. */
const ALLOWED_CALLER = 'com.azurekiln.qflistudio';

const MAX_FILES = 64;
const MAX_PAYLOAD_BYTES = 256 * 1024;
const MAX_PATH_LENGTH = 240;
const MAX_STDIN_BYTES = 4 * 1024;
const MIN_TIMEOUT_MS = 1000;
const MAX_TIMEOUT_MS = 120000;
const POLL_INTERVAL_MS = 80;
const STOP_WAIT_MS = 5000;
const OUTPUT_TAIL_BYTES = 128 * 1024;
/** Cap of the aggregated output carried by the final event. */
const MAX_EVENT_TEXT = 64 * 1024;

export interface InteropRequest {
  sessionId: string;
  sessionToken: string;
  language: string;
  entry: string;
  action: string;
  stdin: string;
  timeoutMs: number;
  callerBundle: string;
  bridgeAction: string;
  payloadUri: string;
}

export class Refusal extends Error {
  code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

function exists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (error) {
    return false;
  }
}

function ensureDirectory(path: string): void {
  if (!exists(path)) {
    fs.mkdirSync(path, true);
  }
}

function writeText(path: string, text: string): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
}

function readText(path: string): string {
  return fs.readTextSync(path);
}

function utf8Length(text: string): number {
  let bytes = 0;
  for (let index = 0; index < text.length; index++) {
    const unit = text.charCodeAt(index);
    if (unit < 0x80) bytes++;
    else if (unit < 0x800) bytes += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < text.length &&
        text.charCodeAt(index + 1) >= 0xdc00 && text.charCodeAt(index + 1) <= 0xdfff) {
      bytes += 4;
      index++;
    } else bytes += 3;
  }
  return bytes;
}

/** Same grammar as InteropPath.validate on the Dart side. */
export function validatePath(path: string): void {
  if (path.length === 0 || path.length > MAX_PATH_LENGTH) {
    throw new Refusal('bad_request', 'payload 路径长度不合法');
  }
  if (path.indexOf('\u0000') >= 0 || path.indexOf('\\') >= 0) {
    throw new Refusal('bad_request', 'payload 路径包含非法字符');
  }
  if (path.charAt(0) === '/') {
    throw new Refusal('bad_request', 'payload 路径必须是相对路径');
  }
  if (/^[A-Za-z]:/.test(path)) {
    throw new Refusal('bad_request', 'payload 路径不能带盘符');
  }
  for (let index = 0; index < path.length; index++) {
    if (path.charCodeAt(index) < 0x20) {
      throw new Refusal('bad_request', 'payload 路径包含控制字符');
    }
  }
  for (const segment of path.split('/')) {
    if (segment.length === 0) {
      throw new Refusal('bad_request', 'payload 路径有空段');
    }
    if (segment === '.' || segment === '..') {
      throw new Refusal('bad_request', 'payload 路径不能包含 . 或 .. 段');
    }
    if (segment.charAt(0) === '.') {
      throw new Refusal('bad_request', 'payload 路径不能包含隐藏段');
    }
  }
}

/** Validates every field the caller controls before anything is copied. */
export function parseRequest(parameters: Record<string, Object>): InteropRequest {
  const read = (key: string): string => {
    const value = parameters[key];
    if (value === undefined || value === null) {
      throw new Refusal('bad_request', `缺少参数 ${key}`);
    }
    return `${value}`;
  };
  if (read('protocol') !== PROTOCOL) {
    throw new Refusal('unsupported_protocol', '不支持的协议版本');
  }
  const sessionId = read('sessionId');
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(sessionId)) {
    throw new Refusal('bad_request', '会话标识不合法');
  }
  const sessionToken = read('sessionToken');
  if (!/^[A-Za-z0-9]{16,64}$/.test(sessionToken)) {
    throw new Refusal('bad_request', '会话令牌不合法');
  }
  if (read('callerBundle') !== ALLOWED_CALLER) {
    throw new Refusal('caller_not_allowed', '调用方不被认可');
  }
  const language = read('language');
  if (language !== LANGUAGE) {
    throw new Refusal('unsupported_language', `本应用不支持 ${language}`);
  }
  const action = read('action');
  if (action !== 'compile' && action !== 'run' && action !== 'analyze') {
    throw new Refusal('bad_request', `未知 action：${action}`);
  }
  const timeout = Number(read('timeoutMs'));
  if (!Number.isInteger(timeout) || timeout < MIN_TIMEOUT_MS || timeout > MAX_TIMEOUT_MS) {
    throw new Refusal('bad_request', 'timeoutMs 超出范围');
  }
  const stdin = read('stdin');
  if (stdin.indexOf('\u0000') >= 0) {
    throw new Refusal('bad_request', 'stdin 不能包含 NUL');
  }
  if (utf8Length(stdin) > MAX_STDIN_BYTES) {
    throw new Refusal('payload_too_large', 'stdin 超过 4 KiB');
  }
  if (read('bridgeAction') !== BRIDGE_ACTION) {
    throw new Refusal('bad_request', '回调 action 无效');
  }
  const entry = read('entry');
  let payloadUri = '';
  if (action !== 'analyze') {
    validatePath(entry);
    if (!entry.endsWith('.java')) {
      throw new Refusal('bad_request', '入口必须是 .java 文件');
    }
    // The probe (analyze) sends an empty payload on purpose; only a run or a
    // compile must name the granted zip.
    payloadUri = read('payloadUri');
    if (!payloadUri.startsWith('file://')) {
      throw new Refusal('bad_request', 'payload 地址无效');
    }
  }
  return {
    sessionId: sessionId,
    sessionToken: sessionToken,
    language: language,
    entry: entry,
    action: action,
    stdin: stdin,
    timeoutMs: timeout,
    callerBundle: read('callerBundle'),
    bridgeAction: read('bridgeAction'),
    payloadUri: payloadUri,
  };
}

class CopiedProject {
  root: string = '';
  entry: string = '';
  sources: string[] = [];
}

/**
 * Builds the project inside this app's own cache.
 *
 * The zip belongs to Studio and is only readable through the Want's temporary
 * read grant, so the copy must happen while this ability handles the start
 * that carried it. After the decompress, every restored name is re-validated
 * and the count and byte caps are re-checked, so a crafted zip cannot escape
 * the session directory or smuggle in an oversized payload.
 */
export async function prepareProject(context: common.UIAbilityContext,
    request: InteropRequest): Promise<CopiedProject> {
  const root = `${context.cacheDir}/qfli_interop/in/${request.sessionId}`;
  const zipPath = `${root}.zip`;
  try {
    if (exists(root)) {
      fs.rmdirSync(root);
    }
    ensureDirectory(root);
    if (exists(zipPath)) {
      fs.unlinkSync(zipPath);
    }
  } catch (error) {
    console.error(`QFLI_INTEROP_PREP_FAILED ${(error as BusinessError).code} ${(error as BusinessError).message}`);
    throw new Refusal('internal', 'payload 准备失败');
  }
  let source: fs.File;
  try {
    source = fs.openSync(request.payloadUri, fs.OpenMode.READ_ONLY);
  } catch (error) {
    // The grant is the only thing that lets this open succeed; the code says
    // whether the uri was unknown (13900042) or unauthorized.
    console.error(`QFLI_INTEROP_OPEN_FAILED ${(error as BusinessError).code}`);
    throw new Refusal('bad_request', 'payload 未获授权或不存在');
  }
  try {
    fs.copyFileSync(source.fd, zipPath);
  } finally {
    fs.closeSync(source);
  }
  try {
    await zlib.decompressFile(zipPath, root);
  } catch (error) {
    console.error(`QFLI_INTEROP_UNZIP_FAILED ${(error as BusinessError).code}`);
    throw new Refusal('bad_request', 'payload 解压失败');
  } finally {
    try {
      fs.unlinkSync(zipPath);
    } catch (error) {
      // A leftover cache file is not a run failure.
    }
  }
  const names = fs.listFileSync(root, { recursion: true });
  if (names.length > MAX_FILES) {
    throw new Refusal('payload_too_large', 'payload 超过 64 个文件');
  }
  const project = new CopiedProject();
  project.root = root;
  let bytes = 0;
  for (const listed of names) {
    // listFileSync with recursion:true returns paths that start with a slash;
    // the payload grammar is relative, so the root prefix is stripped here.
    const name = listed.startsWith('/') ? listed.substring(1) : listed;
    validatePath(name);
    const target = `${root}/${name}`;
    const size = fs.statSync(target).size;
    bytes += size;
    if (bytes > MAX_PAYLOAD_BYTES) {
      throw new Refusal('payload_too_large', 'payload 超过 256 KiB');
    }
    if (name.endsWith('.java')) {
      project.sources.push(target);
    }
    if (name === request.entry) {
      project.entry = target;
    }
  }
  if (request.action !== 'analyze') {
    if (project.entry.length === 0) {
      throw new Refusal('bad_request', '入口文件不在 payload 中');
    }
    if (project.sources.length === 0) {
      throw new Refusal('bad_request', 'payload 中没有 .java 源文件');
    }
  }
  return project;
}

/**
 * Sends one event to Studio's bridge ability.
 *
 * The bridge relay only works while this application is still in the
 * foreground: the first few events hand the foreground back to Studio and the
 * system then refuses any further start from here (13313), which is why the
 * run streams nothing and delivers one final event instead — see
 * compileAndRun, which aggregates the output and emits a single done.
 */
export async function emit(context: common.UIAbilityContext, request: InteropRequest,
    seq: number, event: string, text: string, exitCode?: number, code?: string): Promise<void> {
  console.error(`QFLI_INTEROP_EMIT seq=${seq} event=${event} to=${request.callerBundle}`);
  const parameters: Record<string, Object> = {};
  parameters['protocol'] = PROTOCOL;
  parameters['sessionId'] = request.sessionId;
  parameters['sessionToken'] = request.sessionToken;
  parameters['seq'] = seq;
  parameters['event'] = event;
  parameters['text'] = text;
  if (exitCode !== undefined) {
    parameters['exitCode'] = exitCode;
  }
  if (code !== undefined) {
    parameters['code'] = code;
  }
  const want: Want = {
    bundleName: request.callerBundle,
    abilityName: BRIDGE_ABILITY,
    action: BRIDGE_ACTION,
    parameters: parameters,
  };
  try {
    await context.startAbility(want);
  } catch (error) {
    const failure = error as BusinessError;
    console.error(`QFLI_INTEROP_EVENT_FAILED ${failure.code}`);
  }
}

/** Reads the tail of a file that a child process wrote. */
class OutputTail {
  private offset: number = 0;
  private kept: string = '';
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  /** Drains the bytes present at the start of this read, retaining a bounded tail. */
  read(path: string): void {
    if (!exists(path)) {
      return;
    }
    try {
      const size = fs.statSync(path).size;
      if (size <= this.offset) {
        return;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        while (this.offset < size) {
          const chunkSize = Math.min(size - this.offset, 64 * 1024);
          const buffer = new ArrayBuffer(chunkSize);
          const count = fs.readSync(file.fd, buffer, { offset: this.offset, length: chunkSize });
          if (count <= 0) {
            break;
          }
          this.offset += count;
          const text = this.decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true });
          this.kept = (this.kept + text).slice(-OUTPUT_TAIL_BYTES);
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      console.error('QFLI_INTEROP_OUTPUT_READ_FAILED');
    }
  }

  /** Only flush the decoder after the native child has been reaped. */
  finish(path: string): void {
    this.read(path);
    const text = this.decoder.decodeToString(new Uint8Array(0));
    this.kept = (this.kept + text).slice(-OUTPUT_TAIL_BYTES);
  }

  /** Everything retained so far, for the single final event. */
  snapshot(): string {
    return this.kept;
  }
}

class ProcessResult {
  exitCode: number = 0;
  timedOut: boolean = false;
}

/** SIGKILL requests termination; pollJava owns the waitpid/reaping step. */
async function waitForProcess(pid: number, deadline: number,
    stdout: string, stderr: string, outTail: OutputTail, errTail: OutputTail): Promise<ProcessResult> {
  const result = new ProcessResult();
  let stopDeadline = 0;
  while (true) {
    const exit = pollJava(pid);
    outTail.read(stdout);
    errTail.read(stderr);
    if (exit !== null) {
      result.exitCode = exit;
      break;
    }
    if (!result.timedOut && Date.now() >= deadline) {
      cancelJava(pid);
      result.timedOut = true;
      stopDeadline = Date.now() + STOP_WAIT_MS;
    } else if (result.timedOut && Date.now() >= stopDeadline) {
      // Keep scratch files while the native child may still be using them.
      throw new Refusal('internal', '终止后尚未回收 Java 进程');
    }
    await sleep(POLL_INTERVAL_MS);
  }
  outTail.finish(stdout);
  errTail.finish(stderr);
  return result;
}

/** Parses `package demo;` so the main class name is right. */
export function mainClassOf(source: string, entryName: string): string {
  const match = /^\s*package\s+([A-Za-z_][\w.]*)\s*;/m.exec(source);
  const base = entryName.substring(entryName.lastIndexOf('/') + 1).replace(/\.java$/, '');
  return match === null ? base : `${match[1]}.${base}`;
}

/**
 * Compiles and runs the copied project, aggregating real output for Studio.
 *
 * The JDK bridge runs the JVM as a child of this app, so stdout and stderr are
 * files this receiver owns and reads by offset. Nothing here invents output: a
 * poll that has not finished keeps waiting.
 */
export async function compileAndRun(context: common.UIAbilityContext,
    request: InteropRequest, project: CopiedProject): Promise<void> {
  const seq = 1;
  if (request.action === 'analyze') {
    await emit(context, request, seq, 'done', '能力探测完成', 0);
    return;
  }

  // The bundled JDK is extracted into files/usr by prepare; startJava takes
  // that home, not the launcher library path, or the JVM fails to locate
  // lib/jvm.cfg inside the bundle directory.
  const deadline = Date.now() + request.timeoutMs;
  const layout = await prepareJdk(context);
  const work = `${context.cacheDir}/qfli_interop/work/${request.sessionId}`;
  ensureDirectory(work);
  const classes = `${work}/classes`;
  ensureDirectory(classes);
  if (Date.now() >= deadline) {
    await emit(context, request, seq, 'error', '编译超时', 124, 'timeout');
    cleanUp(project, work);
    return;
  }

  // The whole output crosses as one final event: every intermediate event
  // would hand the foreground back to Studio, and once this app is background
  // the system refuses the next bridge start and drops the rest of the run.
  const javacOutput = `${work}/javac.out`;
  const javacError = `${work}/javac.err`;
  const javacPid = startJava(layout.home, layout.libraryDirectory,
    project.root, '/dev/null', javacOutput, javacError,
    ['java', '-m', 'jdk.compiler/com.sun.tools.javac.Main',
     '-encoding', 'UTF-8', '-d', classes].concat(project.sources));
  const javacTail = new OutputTail();
  const javacErrorTail = new OutputTail();
  const compiled = await waitForProcess(javacPid, deadline,
    javacOutput, javacError, javacTail, javacErrorTail);
  if (compiled.timedOut) {
    const text = formatAggregate(javacTail.snapshot(), javacErrorTail.snapshot(), '编译超时');
    await emit(context, request, seq, 'error', text, 124, 'timeout');
    cleanUp(project, work);
    return;
  }
  const javacExit = compiled.exitCode;
  if (javacExit !== 0) {
    const text = formatAggregate('', javacErrorTail.snapshot(),
      `编译失败（退出码 ${javacExit}）`);
    await emit(context, request, seq, 'error', text, javacExit, 'compile_failed');
    cleanUp(project, work);
    return;
  }
  if (request.action === 'compile') {
    await emit(context, request, seq, 'done', '编译完成', 0);
    cleanUp(project, work);
    return;
  }
  if (Date.now() >= deadline) {
    await emit(context, request, seq, 'error', '运行超时', 124, 'timeout');
    cleanUp(project, work);
    return;
  }

  const source = readText(project.entry);
  const mainClass = mainClassOf(source, request.entry);
  const stdinPath = `${work}/stdin.txt`;
  writeText(stdinPath, request.stdin);
  const runOutput = `${work}/java.out`;
  const runError = `${work}/java.err`;
  const runPid = startJava(layout.home, layout.libraryDirectory,
    project.root, stdinPath, runOutput, runError,
    ['java', '-Dfile.encoding=UTF-8', '-Dstdout.encoding=UTF-8', '-Dstderr.encoding=UTF-8',
      '-classpath', classes, mainClass]);
  const runOutTail = new OutputTail();
  const runErrTail = new OutputTail();
  const ran = await waitForProcess(runPid, deadline,
    runOutput, runError, runOutTail, runErrTail);
  if (ran.timedOut) {
    const text = formatAggregate(runOutTail.snapshot(), runErrTail.snapshot(), '运行超时');
    await emit(context, request, seq, 'error', text, 124, 'timeout');
    cleanUp(project, work);
    return;
  }
  const exit = ran.exitCode;
  if (exit === 0) {
    const text = formatAggregate(runOutTail.snapshot(), runErrTail.snapshot(),
      '运行完成');
    await emit(context, request, seq, 'done', text, 0);
  } else {
    const text = formatAggregate(runOutTail.snapshot(), runErrTail.snapshot(),
      `程序退出码 ${exit}`);
    await emit(context, request, seq, 'error', text, exit, 'run_failed');
  }
  cleanUp(project, work);
}

/** Merges the retained output streams into one event text. */
function formatAggregate(stdout: string, stderr: string, summary: string): string {
  const parts: string[] = [];
  if (stdout.trim().length > 0) {
    parts.push(stdout.trimEnd());
  }
  if (stderr.trim().length > 0) {
    parts.push(`[stderr]\n${stderr.trimEnd()}`);
  }
  parts.push(summary);
  const text = parts.join('\n');
  return text.length > MAX_EVENT_TEXT ? text.substring(text.length - MAX_EVENT_TEXT) : text;
}

/** Removes this session's temporary trees. Failure is never fatal. */
function cleanUp(project: CopiedProject, work: string): void {
  for (const path of [project.root, work]) {
    try {
      if (exists(path)) {
        fs.rmdirSync(path);
      }
    } catch (error) {
      // A leftover cache directory is not a run failure.
      console.error('QFLI_INTEROP_CLEANUP_FAILED');
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });
}
