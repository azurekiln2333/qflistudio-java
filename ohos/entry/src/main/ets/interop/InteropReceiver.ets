/*
 * qfli-interop/1 receiver for QFLIJVMX.
 *
 * Studio sends a project to this app instead of compiling it itself. The two
 * apps are separate sandboxes, so the project arrives as files that Studio has
 * already written to its own cache and as a validated directory name. This file
 * re-validates everything, copies the project into its own cache, compiles with
 * the bundled JDK and runs the entry class.
 *
 * Rules here mirror `qfli_studio_core/lib/interop/interop_protocol.dart`. A rule
 * on only one side is a hole, so change both together.
 */
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { getLayout, startJava, pollJava, cancelJava } from 'libqfli_jdk_layout.so';

export const PROTOCOL = 'qfli-interop/1';
export const LANGUAGE = 'java';

/** The only caller this app answers. */
const ALLOWED_CALLER = 'com.azurekiln.qflistudio';

/** Studio's bridge ability, which receives our events. */
const BRIDGE_ABILITY = 'InteropBridgeAbility';

const MAX_FILES = 64;
const MAX_PAYLOAD_BYTES = 256 * 1024;
const MAX_PATH_LENGTH = 240;
const MAX_STDIN_BYTES = 4 * 1024;
const MIN_TIMEOUT_MS = 1000;
const MAX_TIMEOUT_MS = 120000;
const POLL_INTERVAL_MS = 80;
const OUTPUT_TAIL_BYTES = 128 * 1024;

export interface InteropRequest {
  sessionId: string;
  language: string;
  entry: string;
  action: string;
  stdin: string;
  timeoutMs: number;
  callerBundle: string;
  bridgeAction: string;
  payloadDirectory: string;
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
  if (!Number.isFinite(timeout) || timeout < MIN_TIMEOUT_MS || timeout > MAX_TIMEOUT_MS) {
    throw new Refusal('bad_request', 'timeoutMs 超出范围');
  }
  const stdin = read('stdin');
  if (stdin.length > MAX_STDIN_BYTES) {
    throw new Refusal('payload_too_large', 'stdin 超过 4 KiB');
  }
  const entry = read('entry');
  if (action !== 'analyze') {
    validatePath(entry);
    if (!entry.endsWith('.java')) {
      throw new Refusal('bad_request', '入口必须是 .java 文件');
    }
  }
  const directory = read('payloadDirectory');
  if (!directory.startsWith('/') || directory.indexOf('..') >= 0) {
    throw new Refusal('bad_request', 'payload 目录无效');
  }
  return {
    sessionId: sessionId,
    language: language,
    entry: entry,
    action: action,
    stdin: stdin,
    timeoutMs: timeout,
    callerBundle: read('callerBundle'),
    bridgeAction: read('bridgeAction'),
    payloadDirectory: directory,
  };
}

class CopiedProject {
  root: string = '';
  entry: string = '';
  sources: string[] = [];
}

/**
 * Copies the payload into this app's own cache.
 *
 * The source directory belongs to Studio. Only the manifest it wrote is trusted
 * to name files, and every name is re-validated before the read, so a crafted
 * manifest cannot reach outside the project.
 */
export function copyPayload(context: common.UIAbilityContext, request: InteropRequest): CopiedProject {
  if (!exists(request.payloadDirectory)) {
    throw new Refusal('bad_request', 'payload 目录不存在');
  }
  const manifestPath = `${request.payloadDirectory}/manifest.json`;
  if (!exists(manifestPath)) {
    throw new Refusal('bad_request', 'payload 清单缺失');
  }
  let names: Object[];
  try {
    const parsed = JSON.parse(readText(manifestPath)) as Object;
    if (!Array.isArray(parsed)) {
      throw new Refusal('bad_request', 'payload 清单格式错误');
    }
    names = parsed as Object[];
  } catch (error) {
    throw new Refusal('bad_request', 'payload 清单不是合法 JSON');
  }
  if (names.length > MAX_FILES) {
    throw new Refusal('payload_too_large', 'payload 超过 64 个文件');
  }
  const root = `${context.cacheDir}/qfli_interop/in/${request.sessionId}`;
  if (exists(root)) {
    fs.rmdirSync(root);
  }
  ensureDirectory(root);
  const project = new CopiedProject();
  project.root = root;
  let bytes = 0;
  for (const item of names) {
    const name = `${item}`;
    validatePath(name);
    const source = `${request.payloadDirectory}/${name}`;
    if (!exists(source)) {
      throw new Refusal('bad_request', `payload 缺少文件 ${name}`);
    }
    const target = `${root}/${name}`;
    const parent = target.substring(0, target.lastIndexOf('/'));
    ensureDirectory(parent);
    fs.copyFileSync(source, target);
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

/** Sends one event to Studio's bridge ability. */
export async function emit(context: common.UIAbilityContext, request: InteropRequest,
    seq: number, event: string, text: string, exitCode?: number, code?: string): Promise<void> {
  const parameters: Record<string, Object> = {};
  parameters['protocol'] = PROTOCOL;
  parameters['sessionId'] = request.sessionId;
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
    parameters: parameters,
  };
  try {
    await context.startAbility(want);
  } catch (error) {
    // Studio is gone or refused the event. The run still has to stop, so the
    // failure is reported through the local log instead of being retried.
    const failure = error as BusinessError;
    console.error(`QFLI_INTEROP_EVENT_FAILED ${failure.code}`);
  }
}

/** Reads the tail of a file that a child process wrote. */
class OutputTail {
  private offset: number = 0;
  private kept: string = '';

  /** Returns the text appended since the previous call. */
  read(path: string): string {
    if (!exists(path)) {
      return '';
    }
    try {
      const size = fs.statSync(path).size;
      if (size <= this.offset) {
        return '';
      }
      const chunkSize = Math.min(size - this.offset, 64 * 1024);
      const buffer = new ArrayBuffer(chunkSize);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, buffer, { offset: this.offset, length: chunkSize });
      } finally {
        fs.closeSync(file);
      }
      this.offset += chunkSize;
      const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
      this.kept = (this.kept + text).slice(-OUTPUT_TAIL_BYTES);
      return text;
    } catch (error) {
      return '';
    }
  }
}

/** Parses `package demo;` so the main class name is right. */
export function mainClassOf(source: string, entryName: string): string {
  const match = /^\s*package\s+([A-Za-z_][\w.]*)\s*;/m.exec(source);
  const base = entryName.substring(entryName.lastIndexOf('/') + 1).replace(/\.java$/, '');
  return match === null ? base : `${match[1]}.${base}`;
}

/**
 * Compiles and runs the copied project, streaming real output to Studio.
 *
 * The JDK bridge runs the JVM as a child of this app, so stdout and stderr are
 * files this receiver owns and reads by offset. Nothing here invents output: a
 * poll that has not finished keeps waiting.
 */
export async function compileAndRun(context: common.UIAbilityContext,
    request: InteropRequest, project: CopiedProject): Promise<void> {
  let seq = 1;
  await emit(context, request, seq++, 'accepted', `QFLIJVMX 接收 ${request.language} 项目`);
  if (request.action === 'analyze') {
    await emit(context, request, seq, 'done', '能力探测完成', 0);
    return;
  }

  const layout = getLayout();
  const home = `${context.filesDir}/usr`;
  const work = `${context.cacheDir}/qfli_interop/work/${request.sessionId}`;
  ensureDirectory(work);
  const classes = `${work}/classes`;
  ensureDirectory(classes);

  await emit(context, request, seq++, 'progress', '编译中');
  const javacOutput = `${work}/javac.out`;
  const javacError = `${work}/javac.err`;
  const javacPid = startJava(`${layout.libraryDirectory}/libqfli_javac.so`, layout.libraryDirectory,
    project.root, '/dev/null', javacOutput, javacError,
    ['javac', '--release', '17', '-encoding', 'UTF-8', '-d', classes].concat(project.sources));
  const javacTail = new OutputTail();
  const javacErrorTail = new OutputTail();
  let javacExit = -1;
  while (javacExit < 0) {
    const polled = pollJava(javacPid);
    if (polled !== null) {
      javacExit = polled;
    }
    const out = javacTail.read(javacOutput);
    const err = javacErrorTail.read(javacError);
    if (out.length > 0) {
      await emit(context, request, seq++, 'stdout', out);
    }
    if (err.length > 0) {
      await emit(context, request, seq++, 'stderr', err);
    }
    if (javacExit < 0) {
      await sleep(POLL_INTERVAL_MS);
    }
  }
  const finalOut = javacTail.read(javacOutput);
  const finalErr = javacErrorTail.read(javacError);
  if (finalOut.length > 0) {
    await emit(context, request, seq++, 'stdout', finalOut);
  }
  if (finalErr.length > 0) {
    await emit(context, request, seq++, 'stderr', finalErr);
  }
  if (javacExit !== 0) {
    await emit(context, request, seq, 'error', '编译失败', javacExit, 'compile_failed');
    return;
  }
  if (request.action === 'compile') {
    await emit(context, request, seq, 'done', '编译完成', 0);
    return;
  }

  await emit(context, request, seq++, 'progress', '运行中');
  const source = readText(project.entry);
  const mainClass = mainClassOf(source, request.entry);
  const stdinPath = `${work}/stdin.txt`;
  writeText(stdinPath, request.stdin);
  const runOutput = `${work}/java.out`;
  const runError = `${work}/java.err`;
  const runPid = startJava(`${layout.libraryDirectory}/libqfli_java.so`, layout.libraryDirectory,
    project.root, stdinPath, runOutput, runError,
    ['java', '-Dfile.encoding=UTF-8', '-Dstdout.encoding=UTF-8', '-Dstderr.encoding=UTF-8',
      '-classpath', classes, mainClass]);
  const runOutTail = new OutputTail();
  const runErrTail = new OutputTail();
  const deadline = Date.now() + request.timeoutMs;
  let exit = -1;
  while (exit < 0) {
    const polled = pollJava(runPid);
    if (polled !== null) {
      exit = polled;
    }
    const out = runOutTail.read(runOutput);
    const err = runErrTail.read(runError);
    if (out.length > 0) {
      await emit(context, request, seq++, 'stdout', out);
    }
    if (err.length > 0) {
      await emit(context, request, seq++, 'stderr', err);
    }
    if (exit >= 0) {
      break;
    }
    if (Date.now() > deadline) {
      cancelJava(runPid);
      await emit(context, request, seq, 'error', '运行超时', 124, 'timeout');
      cleanUp(project, work);
      return;
    }
    await sleep(POLL_INTERVAL_MS);
  }
  const lastOut = runOutTail.read(runOutput);
  const lastErr = runErrTail.read(runError);
  if (lastOut.length > 0) {
    await emit(context, request, seq++, 'stdout', lastOut);
  }
  if (lastErr.length > 0) {
    await emit(context, request, seq++, 'stderr', lastErr);
  }
  if (exit === 0) {
    await emit(context, request, seq, 'done', '运行完成', 0);
  } else {
    await emit(context, request, seq, 'error', `程序退出码 ${exit}`, exit, 'run_failed');
  }
  cleanUp(project, work);
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
