// Execute the production receiver with deterministic OHOS filesystem/process
// doubles. This covers orchestration, not ArkTS compilation or device execution.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.QFLI_TYPESCRIPT ||
  'D:/ProgramFiles/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');

function receiver(programs, options = {}) {
  const files = new Map([['/project/Main.java', Buffer.from('class Main {}')]]);
  const directories = new Set(['/project']);
  const processes = new Map();
  const calls = { starts: [], cancels: [], reaped: [], events: [], removed: [] };
  let now = 0;
  let polls = 0;
  const io = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
    accessSync: (name) => files.has(name) || directories.has(name),
    mkdirSync: (name) => directories.add(name),
    openSync: (name, mode) => {
      if (mode & 1) files.set(name, Buffer.alloc(0));
      return { fd: name };
    },
    closeSync: () => {},
    statSync: (name) => ({ size: files.get(name).length }),
    readSync: (fd, buffer, { offset, length }) => {
      const count = Math.min(length, options.shortRead || length, files.get(fd).length - offset);
      new Uint8Array(buffer).set(files.get(fd).subarray(offset, offset + count));
      return count;
    },
    writeSync: (fd, value) => files.set(fd, Buffer.from(value)),
    readTextSync: (name) => files.get(name).toString('utf8'),
    rmdirSync: (name) => {
      assert.equal(processes.size, 0, 'scratch cannot be deleted while a child is owned');
      calls.removed.push(name);
      directories.delete(name);
    },
  };
  const native = {
    startJava: (home, libraries, cwd, input, output, error, args) => {
      const program = programs[calls.starts.length];
      assert.ok(program, 'unexpected extra Java child');
      const pid = calls.starts.length + 10;
      calls.starts.push({ pid, args: Array.from(args), at: now });
      files.set(output, Buffer.alloc(0));
      files.set(error, Buffer.alloc(0));
      processes.set(pid, { program, output, error, index: 0, cancelled: false, stops: 0 });
      return pid;
    },
    pollJava: (pid) => {
      assert.ok(++polls < 2000, 'receiver exceeded deterministic polling limit');
      const child = processes.get(pid);
      assert.ok(child, 'polling an already reaped child');
      if (child.cancelled) {
        if (child.program.neverReap || child.stops++ < (child.program.stopPolls || 0)) return null;
        if (child.program.stopOutput) files.set(child.output, Buffer.from(child.program.stopOutput));
        processes.delete(pid);
        calls.reaped.push(pid);
        return 137;
      }
      const states = child.program.states || [{ exit: null }];
      const state = states[Math.min(child.index++, states.length - 1)];
      if (state.stdout !== undefined) files.set(child.output, Buffer.from(state.stdout));
      if (state.stderr !== undefined) files.set(child.error, Buffer.from(state.stderr));
      if (state.exit !== null) {
        processes.delete(pid);
        calls.reaped.push(pid);
      }
      return state.exit;
    },
    cancelJava: (pid) => {
      assert.ok(processes.has(pid));
      calls.cancels.push({ pid, at: now });
      processes.get(pid).cancelled = true;
    },
  };
  const modules = {
    '@kit.CoreFileKit': { fileIo: io },
    '@kit.ArkTS': { util: { TextDecoder: { create: (encoding) => {
      const decoder = new TextDecoder(encoding);
      return { decodeToString: (bytes, flags) => decoder.decode(bytes, flags) };
    } } } },
    '@ohos.zlib': { decompressFile: async () => {} },
    'libqfli_jdk_layout.so': native,
    '../entryability/JavaBridge': { prepareJdk: async () => ({ home: '/jdk', libraryDirectory: '/libs' }) },
  };
  const source = fs.readFileSync(path.join(__dirname,
    '../ohos/entry/src/main/ets/interop/InteropReceiver.ets'), 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    reportDiagnostics: true,
  });
  assert.deepEqual(compiled.diagnostics, []);
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports,
    require: (name) => {
      assert.ok(Object.hasOwn(modules, name), `Unexpected system import: ${name}`);
      return modules[name];
    },
    Date: { now: () => now },
    setTimeout: (callback, duration) => { now += duration; queueMicrotask(callback); },
    console: { error: () => {} },
  }, { filename: 'InteropReceiver.js' });
  const context = {
    cacheDir: '/cache',
    startAbility: async (want) => {
      assert.equal(processes.size, 0, 'terminal response must follow native reaping');
      calls.events.push(want.parameters);
    },
  };
  const request = {
    sessionId: 'session_1234', sessionToken: '1234567890abcdef', language: 'java',
    entry: 'Main.java', action: options.action || 'run', stdin: '', timeoutMs: 1000,
    callerBundle: 'com.azurekiln.qflistudio', bridgeAction: 'action.system.qfli.interop.event',
    payloadUri: 'file://project.zip',
  };
  return {
    calls, processes,
    run: () => module.exports.compileAndRun(context, request,
      { root: '/project', entry: '/project/Main.java', sources: ['/project/Main.java'] }),
  };
}

const compiled = { states: [{ exit: 0 }] };

test('final output drains beyond 64 KiB without splitting UTF-8', async () => {
  const output = `${'a'.repeat(65535)}😀${'b'.repeat(70000)}结束`;
  const fixture = receiver([compiled, { states: [{ exit: 0, stdout: output }] }]);
  await fixture.run();
  assert.equal(fixture.calls.events.length, 1);
  const event = fixture.calls.events[0];
  assert.equal(event.event, 'done');
  assert.ok(event.text.endsWith('结束\n运行完成'));
  assert.ok(!event.text.includes('\uFFFD'));
  assert.equal(event.sessionToken, '1234567890abcdef');
  assert.equal(event.seq, 1);
  assert.deepEqual(fixture.calls.reaped, [10, 11]);
});

test('short reads and UTF-8 bytes split between polls keep the exact text', async () => {
  const text = Buffer.from('起始😀结尾');
  const fixture = receiver([compiled, { states: [
    { exit: null, stdout: text.subarray(0, 5) },
    { exit: 0, stdout: text },
  ] }], { shortRead: 2 });
  await fixture.run();
  assert.equal(fixture.calls.events[0].text, '起始😀结尾\n运行完成');
});

test('incomplete final UTF-8 is flushed once after native exit', async () => {
  const fixture = receiver([compiled, { states: [{ exit: 0, stdout: Buffer.from([0x41, 0xe4, 0xb8]) }] }]);
  await fixture.run();
  assert.equal(fixture.calls.events[0].text, 'A\uFFFD\n运行完成');
});

test('compiler timeout kills and reaps before its one terminal callback', async () => {
  const fixture = receiver([{ stopPolls: 3, stopOutput: 'compiler tail' }]);
  await fixture.run();
  assert.equal(fixture.calls.starts.length, 1);
  assert.deepEqual(fixture.calls.reaped, [10]);
  assert.equal(fixture.calls.cancels.length, 1);
  assert.equal(fixture.calls.events.length, 1);
  assert.equal(fixture.calls.events[0].code, 'timeout');
  assert.equal(fixture.calls.events[0].exitCode, 124);
  assert.equal(fixture.calls.events[0].text, 'compiler tail\n编译超时');
  assert.deepEqual(fixture.calls.removed, ['/project', '/cache/qfli_interop/work/session_1234']);
});

test('run uses the remaining compile budget and retains post-cancel output', async () => {
  const states = Array.from({ length: 12 }, () => ({ exit: null }));
  states.push({ exit: 0 });
  const fixture = receiver([{ states }, { stopPolls: 2, stopOutput: 'last run bytes' }]);
  await fixture.run();
  assert.equal(fixture.calls.starts[1].at, 960);
  assert.equal(fixture.calls.cancels[0].pid, 11);
  assert.ok(fixture.calls.cancels[0].at <= 1080, 'run must not receive a fresh timeout budget');
  assert.deepEqual(fixture.calls.reaped, [10, 11]);
  assert.equal(fixture.calls.events[0].text, 'last run bytes\n运行超时');
  assert.equal(fixture.calls.events[0].code, 'timeout');
});

test('unreaped cancellation fails within its grace period and retains scratch', async () => {
  const fixture = receiver([{ neverReap: true }]);
  await assert.rejects(fixture.run(), (error) => {
    assert.equal(error.code, 'internal');
    assert.match(error.message, /尚未回收/);
    return true;
  });
  assert.equal(fixture.calls.cancels.length, 1);
  assert.equal(fixture.processes.size, 1);
  assert.deepEqual(fixture.calls.events, []);
  assert.deepEqual(fixture.calls.removed, []);
});

test('compiler diagnostics are retained and a failed compile never runs main', async () => {
  const fixture = receiver([{ states: [{ exit: 1, stderr: 'Main.java: compile error' }] }]);
  await fixture.run();
  assert.equal(fixture.calls.starts.length, 1);
  assert.equal(fixture.calls.events[0].code, 'compile_failed');
  assert.match(fixture.calls.events[0].text, /Main.java: compile error/);
});

test('compile-only requests return one done event without a run child', async () => {
  const fixture = receiver([compiled], { action: 'compile' });
  await fixture.run();
  assert.equal(fixture.calls.starts.length, 1);
  assert.equal(fixture.calls.events.length, 1);
  assert.equal(fixture.calls.events[0].event, 'done');
});
