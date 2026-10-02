import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { MsczMetadata, newMetadata } from '../model/MsczMetadata';

export class EngineParseResult {
  meta: MsczMetadata = newMetadata('');
  engineUsed: string = '';
  rendered: boolean = false;
  renderWidth: number = 0;
  renderHeight: number = 0;
  renderMillis: number = 0;
  renderError: string = '';
}

export class RenderPageResult {
  ok: boolean = false;
  path: string = '';
  width: number = 0;
  height: number = 0;
  millis: number = 0;
  error: string = '';
}

export function pick(rec: Record<string, Object>, key: string, fallback: string): string {
  const v = rec[key] as string;
  return (v !== undefined && v !== '') ? v : fallback;
}

export function pickNum(rec: Record<string, Object>, key: string, fallback: number): number {
  const v = rec[key] as number;
  return (v !== undefined && v > 0) ? v : fallback;
}

export function utoa(bytes: Uint8Array): string {
  const encoder = new util.Base64Helper();
  return encoder.encodeToStringSync(bytes);
}

export function dumpPngBase64(path: string): void {
  try {
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const stat = fileIo.statSync(f.fd);
    const buf = new ArrayBuffer(stat.size);
    const view = new Uint8Array(buf);
    let got = 0;
    while (got < stat.size) {
      const n = fileIo.readSync(f.fd, buf, { offset: got, length: stat.size - got });
      if (n <= 0) {
        break;
      }
      got += n;
    }
    fileIo.closeSync(f.fd);
    console.info(`B64SIZE file=${stat.size} read=${got}`);
    const b64 = utoa(view.subarray(0, got));
    const sleeper = new Int32Array(new SharedArrayBuffer(4));
    let emitted = 0;
    for (let i = 0; i < b64.length; i += 520) {
      console.info(`B64|${i}|${b64.substring(i, i + 520)}`);
      emitted++;
      if (emitted < 40) {
        Atomics.wait(sleeper, 0, 0, 220);
      } else if (emitted % 4 === 0) {
        Atomics.wait(sleeper, 0, 0, 50);
      }
    }
    console.info(`B64END total=${b64.length}`);
  } catch (e) {
    console.info(`B64 dump failed: ${JSON.stringify(e)}`);
  }
}
