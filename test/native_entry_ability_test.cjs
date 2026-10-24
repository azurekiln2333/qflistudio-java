// Execute the actual EntryAbility handlers with only OHOS system APIs stubbed.
// This is behavioral host coverage, not ArkTS compilation or target execution.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const tsPath = process.env.QFLI_TYPESCRIPT ||
  'D:/ProgramFiles/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript';
const ts = require(tsPath);

function loadAbility() {
  const handlers = new Map();
  const calls = { remote: [], events: [], shares: [], picker: [], java: [], register: [] };
  const context = {
    config: { colorMode: 1 },
    eventHub: { emit: (...args) => calls.events.push(args) },
    startAbility: (...args) => { calls.remote.push(args); return Promise.resolve(); },
  };
  class FlutterAbility {
    constructor() { this.context = context; }
    configureFlutterEngine() {}
    onWindowStageCreate() {}
  }
  class MethodChannel {
    constructor(messenger, name) { this.name = name; }
    setMethodCallHandler(handler) { handlers.set(this.name, handler); }
  }
  const systemShare = {
    SharedData: class { constructor(record) { this.record = record; } },
    ShareController: class {
      constructor(data) { this.data = data; }
      show(ability, options) {
        calls.shares.push([ability, this.data.record, options]);
        return Promise.resolve();
      }
    },
  };
  const modules = {
    '@ohos/flutter_ohos': { FlutterAbility, MethodChannel },
    '@kit.ShareKit': { systemShare },
    '@kit.AbilityKit': { ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 1 } } },
    '@kit.ArkUI': {
      router: { pushUrl: (...args) => { calls.remote.push(args); return Promise.resolve(); } },
    },
    '@kit.AccountKit': {
      authentication: {
        HuaweiIDProvider: class {
          constructor() { calls.remote.push('HuaweiIDProvider'); }
          createAuthorizationWithHuaweiIDRequest() { return {}; }
        },
        AuthenticationController: class {
          executeRequest() {
            calls.remote.push('executeRequest');
            return Promise.resolve({ data: { authorizationCode: 'remote-code' } });
          }
        },
      },
    },
    '../plugins/GeneratedPluginRegistrant': {
      GeneratedPluginRegistrant: { registerWith: (engine) => calls.register.push(engine) },
    },
    './PickerBridge': {
      isPickerMethod: (method) => ['pickDocument', 'saveDocument', 'pickPhotos', 'readUri', 'writeUri'].includes(method),
      handlePickerCall: (ability, call, result) => {
        calls.picker.push([ability, call.method]);
        result.success('picked');
      },
    },
    './JavaBridge': { configureJavaChannel: (...args) => calls.java.push(args) },
  };
  const source = fs.readFileSync(path.join(root, 'ohos/entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    reportDiagnostics: true,
  });
  assert.deepEqual(compiled.diagnostics, []);
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module,
    exports: module.exports,
    require: (name) => {
      assert.ok(Object.hasOwn(modules, name), `Unexpected system import: ${name}`);
      return modules[name];
    },
  }, { filename: 'EntryAbility.js' });
  const ability = new module.exports.default();
  const engine = { dartExecutor: { getBinaryMessenger: () => ({}) } };
  ability.configureFlutterEngine(engine);
  async function invoke(channel, method, args = {}) {
    const results = [];
    handlers.get(channel).onMethodCall({
      method,
      argument: (key) => args[key],
    }, {
      success: (value) => results.push({ success: value }),
      error: (code, message, details) => results.push({ code, message, details }),
      notImplemented: () => results.push({ notImplemented: true }),
    });
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(results.length, 1, `${channel}/${method} must answer exactly once`);
    return results[0];
  }
  return { ability, engine, calls, context, invoke };
}

test('native remote routes reject every direct call without launching external abilities or accounts', async () => {
  const { invoke, calls } = loadAbility();
  for (const method of ['openAgreement', 'openUrl']) {
    for (const url of ['https://example.com', 'http://example.com', 'file:///data/local', undefined]) {
      const result = await invoke('qflistudio/platform', method, { url, title: 'Remote' });
      assert.equal(result.code, 'OFFLINE_ONLY');
      assert.ok(result.message.length > 0);
    }
  }
  assert.equal((await invoke('qflistudio/huawei_account', 'login')).code, 'OFFLINE_ONLY');
  assert.deepEqual(calls.remote, []);
  assert.deepEqual(await invoke('qflistudio/platform', 'unknown'), { notImplemented: true });
  assert.deepEqual(await invoke('qflistudio/huawei_account', 'unknown'), { notImplemented: true });
});

test('native startup progress still clamps finite values and rejects invalid values', async () => {
  const { invoke, calls } = loadAbility();
  for (const progress of [-1, 0.4, 2]) {
    assert.deepEqual(await invoke('qflistudio/platform', 'startupProgress', { progress }), { success: null });
  }
  assert.deepEqual(calls.events, [
    ['EVENT_STARTUP_PROGRESS', 0],
    ['EVENT_STARTUP_PROGRESS', 0.4],
    ['EVENT_STARTUP_PROGRESS', 1],
  ]);
  for (const progress of [undefined, '0.5', NaN, Infinity]) {
    assert.equal((await invoke('qflistudio/platform', 'startupProgress', { progress })).code, 'INVALID_PROGRESS');
  }
  assert.equal(calls.events.length, 3);
});

test('native local share, picker, Java bridge and window startup stay wired', async () => {
  const { ability, engine, calls, context, invoke } = loadAbility();
  assert.deepEqual(calls.java, [[engine, context]]);
  assert.deepEqual(calls.register, [engine]);
  const result = await invoke('qflistudio/platform', 'shareText', { title: 'Title', text: 'local 😀' });
  assert.deepEqual(result, { success: null });
  assert.equal(calls.shares[0][0], context);
  assert.equal(calls.shares[0][1].content, 'local 😀');
  assert.equal(calls.shares[0][1].title, 'Title');
  for (const method of ['pickDocument', 'saveDocument', 'pickPhotos', 'readUri', 'writeUri']) {
    assert.deepEqual(await invoke('qflistudio/platform', method), { success: 'picked' });
  }
  assert.equal(calls.picker.length, 5);
  const colors = [];
  const stage = { getMainWindowSync: () => ({ setWindowBackgroundColor: (color) => colors.push(color) }) };
  ability.onWindowStageCreate(stage);
  context.config.colorMode = 0;
  ability.onWindowStageCreate(stage);
  assert.deepEqual(colors, ['#FF111418', '#FFF8F9FF']);
  assert.deepEqual(calls.remote, []);
});

test('standalone native page registry exposes only the local Flutter entry', () => {
  const registry = JSON.parse(fs.readFileSync(path.join(root, 'ohos/entry/src/main/resources/base/profile/main_pages.json'), 'utf8'));
  assert.deepEqual(registry.src, ['pages/Index']);
});
