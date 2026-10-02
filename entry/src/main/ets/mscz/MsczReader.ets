import { taskpool } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { resourceManager } from '@kit.LocalizationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { extractMeta } from 'libmsoh.so';
import { MsczMetadata, newMetadata } from '../model/MsczMetadata';

// Runs on a taskpool worker; the heavy lifting (unzip + XML walk) happens in
// native C++ (libmsoh), this only maps the JSON result into the model.
// Main-thread parsing froze the app (THREAD_BLOCK_6S) on ~10MB scores.
@Concurrent
function parseMsczTask(bytes: Uint8Array, fileName: string): MsczMetadata {
  const json: string = extractMeta(bytes);
  const rec: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
  const meta: MsczMetadata = newMetadata(fileName);
  meta.mscxEntry = rec['mscxEntry'] as string;
  meta.formatVersion = rec['formatVersion'] as string;
  meta.programVersion = rec['programVersion'] as string;
  meta.title = rec['title'] as string;
  meta.subtitle = rec['subtitle'] as string;
  meta.composer = rec['composer'] as string;
  meta.lyricist = rec['lyricist'] as string;
  meta.staffCount = rec['staffCount'] as number;
  meta.measureCount = rec['measureCount'] as number;
  meta.timeSig = rec['timeSig'] as string;
  meta.keySig = rec['keySig'] as string;
  meta.keySigAccidentals = rec['keySigAccidentals'] as number;
  meta.tempoBpm = rec['tempoBpm'] as number;
  meta.division = rec['division'] as number;
  meta.parseMillis = rec['parseMillis'] as number;
  return meta;
}

export class MsczReader {
  static async parseBytes(bytes: Uint8Array, fileName: string): Promise<MsczMetadata> {
    const started = Date.now();
    const task: taskpool.Task = new taskpool.Task(parseMsczTask, bytes, fileName);
    const meta = await taskpool.execute(task) as MsczMetadata;
    const nativeMs = meta.parseMillis;
    meta.parseMillis = Date.now() - started;
    console.info(`MSOH parse result [${fileName}] native=${nativeMs}ms total=${meta.parseMillis}ms ` +
      `v=${meta.formatVersion} ${meta.staffCount}表/${meta.measureCount}节 ${meta.keySig} ${meta.tempoBpm}bpm ` +
      `title=${meta.title}`);
    return meta;
  }

  static async parseRawfile(rm: resourceManager.ResourceManager, rawfileName: string): Promise<MsczMetadata> {
    const bytes: Uint8Array = await rm.getRawFileContent(rawfileName);
    return MsczReader.parseBytes(bytes, rawfileName);
  }

  static async parseUri(uri: string): Promise<MsczMetadata> {
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      const bytes = new Uint8Array(buf);
      const name = uri.split('/').pop() ?? uri;
      return MsczReader.parseBytes(bytes, decodeURIComponent(name));
    } finally {
      fileIo.closeSync(file.fd);
    }
  }
}

export function errMessage(e: Object): string {
  const be = e as BusinessError;
  return `${be.code ?? ''} ${be.message ?? JSON.stringify(e)}`;
}
