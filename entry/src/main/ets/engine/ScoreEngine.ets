import { taskpool } from '@kit.ArkTS';
import { engineOpenScore, engineRenderView } from 'libmsohengine.so';
import { recStr, recNum } from './JsonRec';

export interface PartInfo {
  name: string;
  staves: number;
  measures: number;
  pages: number;
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
        pages: recNum(pr, 'pages')
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

/**
 * 引擎客户端：open/renderView 均在 taskpool 执行，并用串行队列保证
 * 同一时刻只有一个 native 引擎调用（引擎非线程安全，且跨 worker 线程
 * 复用同一 Qt 无头环境）。
 */
export class ScoreEngine {
  private static chain: Promise<void> = Promise.resolve();

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
}
