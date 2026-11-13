import { taskpool } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import bundleManager from '@ohos.bundle.bundleManager';
import deviceInfo from '@ohos.deviceInfo';
import { engineInfo, engineSetup, engineOpenScore, engineRenderView, engineTransposeView } from 'libmsohengine.so';
import { recStr, recNum } from './JsonRec';

export interface PartInfo {
  name: string;
  staves: number;
  measures: number;
  pages: number;
  instruments: number;
  keySig: number;
  prefer: number;
}

export interface ScoreMetaInfo {
  handle: number;
  title: string;
  subtitle: string;
  composer: string;
  lyricist: string;
  formatVersion: string;
  staffCount: number;
  measureCount: number;
  pageCount: number;
  timeSig: string;
  keySig: string;
  keySigAccidentals: number;
  instruments: number;
  prefer: number;
  parts: PartInfo[];
  parseMillis: number;
}

export interface OpenResult {
  ok: boolean;
  error: string;
  meta: ScoreMetaInfo | null;
}

export interface RenderedPageInfo {
  file: string;
  w: number;
  h: number;
}

export interface RenderResult {
  ok: boolean;
  error: string;
  pages: RenderedPageInfo[];
  ms: number;
}

export interface TransposeResult {
  ok: boolean;
  error: string;
  keySig: number;
}

@Concurrent
function openScoreTask(bytes: Uint8Array, tempDir: string): OpenResult {
  const rec: Record<string, Object> = JSON.parse(engineOpenScore(bytes, tempDir)) as Record<string, Object>;
  const result: OpenResult = { ok: false, error: '', meta: null };
  if (rec['ok'] !== true) {
    result.error = recStr(rec, 'error') !== '' ? recStr(rec, 'error') : '引擎未能打开该文件';
    return result;
  }
  const parts: PartInfo[] = [];
  const rawParts = rec['parts'] as Object[];
  if (rawParts !== undefined) {
    for (const p of rawParts) {
      const pr = p as Record<string, Object>;
      const item: PartInfo = {
        name: recStr(pr, 'name'),
        staves: recNum(pr, 'staves'),
        measures: recNum(pr, 'measures'),
        pages: recNum(pr, 'pages'),
        instruments: recNum(pr, 'instruments'),
        keySig: recNum(pr, 'keySig'),
        prefer: recNum(pr, 'prefer')
      };
      parts.push(item);
    }
  }
  const meta: ScoreMetaInfo = {
    handle: recNum(rec, 'handle'),
    title: recStr(rec, 'title'),
    subtitle: recStr(rec, 'subtitle'),
    composer: recStr(rec, 'composer'),
    lyricist: recStr(rec, 'lyricist'),
    formatVersion: recStr(rec, 'formatVersion'),
    staffCount: recNum(rec, 'staffCount'),
    measureCount: recNum(rec, 'measureCount'),
    pageCount: recNum(rec, 'pageCount'),
    timeSig: recStr(rec, 'timeSig'),
    keySig: recStr(rec, 'keySig'),
    keySigAccidentals: recNum(rec, 'keySigAccidentals'),
    instruments: recNum(rec, 'instruments'),
    prefer: recNum(rec, 'prefer'),
    parts: parts,
    parseMillis: recNum(rec, 'parseMillis')
  };
  result.ok = true;
  result.meta = meta;
  return result;
}

@Concurrent
function renderViewTask(handle: number, viewIndex: number, outDir: string, dpi: number): RenderResult {
  const rec: Record<string, Object> = JSON.parse(engineRenderView(handle, viewIndex, outDir, dpi)) as Record<string, Object>;
  const result: RenderResult = { ok: false, error: '', pages: [], ms: 0 };
  if (rec['ok'] !== true) {
    result.error = recStr(rec, 'error') !== '' ? recStr(rec, 'error') : '渲染失败';
    return result;
  }
  const rawPages = rec['pages'] as Object[];
  if (rawPages !== undefined) {
    for (const p of rawPages) {
      const pr = p as Record<string, Object>;
      const page: RenderedPageInfo = { file: recStr(pr, 'file'), w: recNum(pr, 'w'), h: recNum(pr, 'h') };
      result.pages.push(page);
    }
  }
  result.ok = true;
  result.ms = recNum(rec, 'ms');
  return result;
}

@Concurrent
function transposeViewTask(handle: number, viewIndex: number, semitones: number): TransposeResult {
  const rec: Record<string, Object> = JSON.parse(engineTransposeView(handle, viewIndex, semitones)) as Record<string, Object>;
  const result: TransposeResult = { ok: false, error: '', keySig: 0 };
  if (rec['ok'] !== true) {
    result.error = recStr(rec, 'error') !== '' ? recStr(rec, 'error') : '移调失败';
    return result;
  }
  result.ok = true;
  result.keySig = recNum(rec, 'keySig');
  return result;
}


/**
 * 引擎客户端：open/renderView 均在 taskpool 执行，并用串行队列保证
 * 同一时刻只有一个 native 引擎调用（引擎非线程安全，且跨 worker 线程
 * 复用同一 Qt 无头环境）。
 */
export class ScoreEngine {
  private static chain: Promise<void> = Promise.resolve();

  /**
   * 无头引擎初始化：必须在主 JS 线程调用（详见 mscore_engine.cpp EngineSetup）。
   * 幂等（C++ 侧 static 守卫），Index 与测试共用。
   */
  static setup(ctx: common.UIAbilityContext): boolean {
    try {
      console.info(`MSOH engine: ${engineInfo()}`);
      return engineSetup({
        'bundle.bundleManager': {
          'BundleFlag': bundleManager.BundleFlag,
          'getBundleInfoForSelfSync': bundleManager.getBundleInfoForSelfSync
        },
        'deviceInfo': {
          'deviceType': deviceInfo.deviceType,
          'marketName': deviceInfo.marketName,
          'productModel': deviceInfo.productModel,
          'osFullName': deviceInfo.osFullName,
          'brand': deviceInfo.brand,
          'manufacture': deviceInfo.manufacture,
          'sdkApiVersion': deviceInfo.sdkApiVersion,
          'displayVersion': deviceInfo.displayVersion,
          'majorVersion': deviceInfo.majorVersion,
          'seniorVersion': deviceInfo.seniorVersion,
          'featureVersion': deviceInfo.featureVersion
        }
      }, ctx.cacheDir);
    } catch (e) {
      console.info(`MSOH engine setup failed: ${JSON.stringify(e)}`);
      return false;
    }
  }

  private static run<T>(job: () => Promise<T>): Promise<T> {
    const next = ScoreEngine.chain.then(job, job);
    ScoreEngine.chain = next.then(() => { }, () => { });
    return next;
  }

  static open(bytes: Uint8Array, tempDir: string): Promise<OpenResult> {
    return ScoreEngine.run(async (): Promise<OpenResult> => {
      const task: taskpool.Task = new taskpool.Task(openScoreTask, bytes, tempDir);
      return await taskpool.execute(task) as OpenResult;
    });
  }

  static renderView(handle: number, viewIndex: number, outDir: string, dpi: number): Promise<RenderResult> {
    return ScoreEngine.run(async (): Promise<RenderResult> => {
      const task: taskpool.Task = new taskpool.Task(renderViewTask, handle, viewIndex, outDir, dpi);
      return await taskpool.execute(task) as RenderResult;
    });
  }

  static transposeView(handle: number, viewIndex: number, semitones: number): Promise<TransposeResult> {
    return ScoreEngine.run(async (): Promise<TransposeResult> => {
      const task: taskpool.Task = new taskpool.Task(transposeViewTask, handle, viewIndex, semitones);
      return await taskpool.execute(task) as TransposeResult;
    });
  }
}
