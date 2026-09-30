import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { FlutterEngine, MethodChannel, MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { getLayout, startJava, pollJava, cancelJava } from 'libqfli_jdk_layout.so';

interface LibraryLink {
  path: string;
  library: string;
}

interface JdkManifest {
  version: number;
  id: string;
  libraries: LibraryLink[];
}

interface JdkLayout {
  home: string;
  java: string;
  javac: string;
  libraryDirectory: string;
}

function writeFile(path: string, data: ArrayBuffer | string): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, data);
  } finally {
    fs.closeSync(file);
  }
}

function ensureDirectory(path: string): void {
  if (!fs.accessSync(path)) fs.mkdirSync(path, true);
}

async function prepare(context: common.UIAbilityContext): Promise<JdkLayout> {
  const installed = getLayout();
  const content = await context.resourceManager.getRawFileContent(`jdk-${installed.abi}.json`);
  const manifest = JSON.parse(util.TextDecoder.create('utf-8').decodeWithStream(content)) as JdkManifest;
  if (manifest.version !== 1) throw new Error('Unsupported JDK layout');
  const home = `${context.filesDir}/usr`;
  const marker = `${home}/.qfli-jdk-id`;
  if (!fs.accessSync(marker) || fs.readTextSync(marker) !== manifest.id || !fs.accessSync(`${home}/lib/modules`)) {
    const staging = `${context.filesDir}/usr-install`;
    const zipPath = `${context.cacheDir}/jdk-install.zip`;
    if (fs.accessSync(staging)) fs.rmdirSync(staging);
    ensureDirectory(staging);
    try {
      const bytes = await context.resourceManager.getRawFileContent(`jdk-${installed.abi}.zip`);
      writeFile(zipPath, bytes.buffer);
      await zlib.decompressFile(zipPath, staging, {});
      if (!fs.accessSync(`${staging}/lib/modules`)) throw new Error('JDK modules are missing');
      writeFile(`${staging}/.qfli-jdk-id`, manifest.id);
      if (fs.accessSync(home)) fs.rmdirSync(home);
      fs.renameSync(staging, home);
    } finally {
      if (fs.accessSync(staging)) fs.rmdirSync(staging);
      if (fs.accessSync(zipPath)) fs.unlinkSync(zipPath);
    }
  }
  for (const item of manifest.libraries) {
    const target = `${installed.libraryDirectory}/${item.library}`;
    if (!fs.accessSync(target)) throw new Error(`JDK library is missing: ${item.library}`);
  }
  ensureDirectory(`${home}/tmp`);
  return {
    home: home,
    java: `${installed.libraryDirectory}/libqfli_java.so`,
    javac: `${installed.libraryDirectory}/libqfli_javac.so`,
    libraryDirectory: installed.libraryDirectory,
  };
}

export function configureJavaChannel(engine: FlutterEngine, context: common.UIAbilityContext): void {
  let preparation: Promise<JdkLayout> | undefined;
  const channel = new MethodChannel(engine.dartExecutor.getBinaryMessenger(), 'qfli_jvmx/jdk');
  channel.setMethodCallHandler({
    onMethodCall(call: MethodCall, result: MethodResult): void {
      if (call.method === 'start' || call.method === 'poll' || call.method === 'cancel') {
        try {
          if (call.method === 'start') {
            result.success(startJava(call.argument('home') as string, call.argument('libraries') as string,
              call.argument('cwd') as string, call.argument('input') as string,
              call.argument('output') as string, call.argument('error') as string,
              call.argument('args') as string[]));
          } else if (call.method === 'poll') {
            result.success(pollJava(call.argument('pid') as number));
          } else {
            cancelJava(call.argument('pid') as number);
            result.success(null);
          }
        } catch (error) {
          result.error('JDK_PROCESS_FAILED', (error as Error).message, null);
        }
        return;
      }
      if (call.method !== 'prepare') {
        result.notImplemented();
        return;
      }
      if (preparation === undefined) preparation = prepare(context);
      preparation.then((layout: JdkLayout) => {
        const response = new Map<string, string>();
        response.set('home', layout.home);
        response.set('java', layout.java);
        response.set('javac', layout.javac);
        response.set('libraryDirectory', layout.libraryDirectory);
        result.success(response);
      }).catch((error: Error) => {
        preparation = undefined;
        result.error('JDK_PREPARE_FAILED', error.message, null);
      });
    },
  });
}
