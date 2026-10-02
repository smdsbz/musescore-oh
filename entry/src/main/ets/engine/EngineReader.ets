import { taskpool } from '@kit.ArkTS';
import { engineLoadMeta } from 'libmsohengine.so';
import { extractMeta } from 'libmsoh.so';
import { MsczMetadata, newMetadata } from '../model/MsczMetadata';
import { EngineParseResult, pick, pickNum, dumpPngBase64 } from './EngineTypes';

// Runs on a taskpool worker: real MS4 engine first, transitional parser
// fills any empty fields.
@Concurrent
function engineParseTask(bytes: Uint8Array, fileName: string, cacheDir: string, renderOut: string,
  dumpB64: boolean, pageIndex: number): EngineParseResult {
  const out = new EngineParseResult();
  const meta = newMetadata(fileName);
  let engineOk = false;
  let engineMillis = 0;
  let eRec: Record<string, Object> | null = null;

  try {
    const eJson: string = engineLoadMeta(bytes, cacheDir, renderOut, 55, pageIndex);
    eRec = JSON.parse(eJson) as Record<string, Object>;
    if (eRec['ok'] === true) {
      engineOk = true;
      engineMillis = eRec['parseMillis'] as number;
      meta.formatVersion = pick(eRec, 'formatVersion', meta.formatVersion);
      meta.title = pick(eRec, 'title', meta.title);
      meta.subtitle = pick(eRec, 'subtitle', meta.subtitle);
      meta.composer = pick(eRec, 'composer', meta.composer);
      meta.lyricist = pick(eRec, 'lyricist', meta.lyricist);
      meta.staffCount = eRec['staffCount'] as number;
      meta.measureCount = eRec['measureCount'] as number;
      meta.timeSig = pick(eRec, 'timeSig', meta.timeSig);
      if ((eRec['keySigAccidentals'] as number) !== 0 || meta.keySig === '') {
        meta.keySig = eRec['keySig'] as string;
        meta.keySigAccidentals = eRec['keySigAccidentals'] as number;
      }
    } else {
      console.info(`MSOH engine rejected [${fileName}]: ${eRec['error']}`);
    }
  } catch (e) {
    console.info(`MSOH engine exception [${fileName}]: ${JSON.stringify(e)}`);
  }

  // Transitional parser: fills what the engine left empty (tempo, division,
  // programVersion, mscx entry name, and any empty text fields above).
  const tJson: string = extractMeta(bytes);
  const tRec: Record<string, Object> = JSON.parse(tJson) as Record<string, Object>;
  meta.programVersion = pick(tRec, 'programVersion', meta.programVersion);
  meta.mscxEntry = pick(tRec, 'mscxEntry', meta.mscxEntry);
  meta.tempoBpm = pickNum(tRec, 'tempoBpm', meta.tempoBpm);
  meta.division = pickNum(tRec, 'division', meta.division);
  meta.title = pick(tRec, 'title', meta.title);
  meta.subtitle = pick(tRec, 'subtitle', meta.subtitle);
  meta.composer = pick(tRec, 'composer', meta.composer);
  meta.lyricist = pick(tRec, 'lyricist', meta.lyricist);
  meta.formatVersion = pick(tRec, 'formatVersion', meta.formatVersion);
  meta.timeSig = pick(tRec, 'timeSig', meta.timeSig);
  if (meta.keySig === '') {
    meta.keySig = tRec['keySig'] as string;
  }

  if (eRec !== null) {
    if (eRec['renderOk'] === true) {
      out.rendered = true;
      out.renderWidth = eRec['renderW'] as number;
      out.renderHeight = eRec['renderH'] as number;
      if (dumpB64) {
        dumpPngBase64(renderOut);


      }
    } else if (eRec['renderError'] !== undefined) {
      out.renderError = eRec['renderError'] as string;
    }
  }
  if (engineOk) {
    out.engineUsed = `MS4 引擎(${engineMillis}ms) + 兜底解析`;
  } else {
    out.engineUsed = '兜底解析(引擎未接受该文件)';
  }

  out.meta = meta;
  return out;
}

export class EngineReader {
  static async parseBytes(bytes: Uint8Array, fileName: string, cacheDir: string,
    dumpB64: boolean = false, pageIndex: number = 0): Promise<EngineParseResult> {
    const started = Date.now();
    const renderOut = `${cacheDir}/page0.png`;
    const task: taskpool.Task = new taskpool.Task(engineParseTask, bytes, fileName, cacheDir,
      renderOut, dumpB64, pageIndex);
    const result = await taskpool.execute(task) as EngineParseResult;
    result.meta.parseMillis = Date.now() - started;
    const m = result.meta;
    console.info(`MSOH [${fileName}] engine=${result.engineUsed} v=${m.formatVersion} ` +
      `${m.staffCount}表/${m.measureCount}节 ${m.timeSig} ${m.keySig} title=${m.title} ` +
      `render=${result.rendered} ${result.renderWidth}x${result.renderHeight} err=${result.renderError}`);
    return result;
  }
}
