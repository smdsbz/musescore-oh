import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';

export interface ScoreFileEntry {
  fileName: string;
  displayName: string;
  sizeBytes: number;
  /** 秒级时间戳（fileIo Stat.mtime） */
  mtime: number;
}

export interface ImportResult {
  copied: number;
  /** 源就在公共下载目录本应用子目录内（无需复制）的份数 */
  alreadyInLibrary: number;
}

/**
 * 公共下载目录数据源：Download/<bundleName>/。
 * 应用对以自己包名命名的下载子目录有直接读写权限（无需任何授权），
 * 用户把 .mscz 文件放进该目录即可被主页列表发现。
 */
export class ScoreLibrary {
  private static rootPath: string = '';
  private static ctx: common.UIAbilityContext | null = null;

  static init(context: common.UIAbilityContext): void {
    ScoreLibrary.ctx = context;
    const bundleName = context.abilityInfo.bundleName;
    const uri = 'file://docs/storage/Users/currentUser/Download/' + bundleName;
    try {
      ScoreLibrary.rootPath = new fileUri.FileUri(uri).path ?? '';
    } catch (e) {
      console.info(`MSOH ScoreLibrary FileUri failed: ${JSON.stringify(e)}`);
      ScoreLibrary.rootPath = '';
    }
  }

  /** 供 UI 展示：Download/&lt;bundleName&gt; */
  static getDisplayRoot(): string {
    return 'Download/' + (ScoreLibrary.rootPath.split('/').pop() ?? '');
  }

  static async ensureDir(): Promise<boolean> {
    if (ScoreLibrary.rootPath === '') {
      return false;
    }
    try {
      if (!await fileIo.access(ScoreLibrary.rootPath)) {
        await fileIo.mkdir(ScoreLibrary.rootPath);
      }
      return true;
    } catch (e) {
      console.info(`MSOH ScoreLibrary ensureDir failed: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 顶层 .mscz 文件列表（按修改时间倒序，最新在前） */
  static async listScores(): Promise<ScoreFileEntry[]> {
    const entries: ScoreFileEntry[] = [];
    if (ScoreLibrary.rootPath === '') {
      return entries;
    }
    let names: string[] = [];
    try {
      names = await fileIo.listFile(ScoreLibrary.rootPath);
    } catch (e) {
      console.info(`MSOH ScoreLibrary listFile failed: ${JSON.stringify(e)}`);
      return entries;
    }
    for (const n of names) {
      if (!n.toLowerCase().endsWith('.mscz')) {
        continue;
      }
      try {
        const st = await fileIo.stat(`${ScoreLibrary.rootPath}/${n}`);
        const entry: ScoreFileEntry = {
          fileName: n,
          displayName: n.substring(0, n.length - 5),
          sizeBytes: st.size,
          mtime: st.mtime
        };
        entries.push(entry);
      } catch (e) {
        console.info(`MSOH ScoreLibrary stat skip ${n}: ${JSON.stringify(e)}`);
      }
    }
    entries.sort((a: ScoreFileEntry, b: ScoreFileEntry): number => b.mtime - a.mtime);
    return entries;
  }

  static async readBytes(fileName: string): Promise<Uint8Array> {
    const file = await fileIo.open(`${ScoreLibrary.rootPath}/${fileName}`, fileIo.OpenMode.READ_ONLY);
    try {
      const st = await fileIo.stat(file.fd);
      const buf = new ArrayBuffer(st.size);
      const view = new Uint8Array(buf);
      let got = 0;
      while (got < st.size) {
        const n = await fileIo.read(file.fd, buf, { offset: got, length: st.size - got });
        if (n <= 0) {
          break;
        }
        got += n;
      }
      return got === st.size ? view : view.subarray(0, got);
    } finally {
      await fileIo.close(file.fd);
    }
  }

  /**
   * 把文件选择器返回的 URI 复制进公共下载目录（同名覆盖，已在库内的跳过）。
   */
  static async importFromUris(uris: string[]): Promise<ImportResult> {
    const res: ImportResult = { copied: 0, alreadyInLibrary: 0 };
    if (ScoreLibrary.rootPath === '') {
      return res;
    }
    for (const uri of uris) {
      let name = '';
      try {
        const srcPath = new fileUri.FileUri(uri).path ?? '';
        name = srcPath.split('/').pop() ?? '';
        if (name === '' || !name.toLowerCase().endsWith('.mscz')) {
          continue;
        }
        if (srcPath.startsWith(`${ScoreLibrary.rootPath}/`)) {
          res.alreadyInLibrary++;
          continue;
        }
        const src = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
        try {
          await fileIo.copyFile(src.fd, `${ScoreLibrary.rootPath}/${name}`);
        } finally {
          await fileIo.close(src.fd);
        }
        res.copied++;
      } catch (e) {
        console.info(`MSOH ScoreLibrary import skip ${name}: ${JSON.stringify(e)}`);
      }
    }
    return res;
  }

  /** 把 rawfile 内置示例曲谱复制进公共下载目录（已存在的同名文件跳过） */
  static async seedBuiltinSamples(): Promise<number> {
    const ctx = ScoreLibrary.ctx;
    if (ctx === null) {
      return 0;
    }
    let names: string[] = [];
    try {
      names = await ctx.resourceManager.getRawFileList('');
    } catch (e) {
      console.info(`MSOH ScoreLibrary getRawFileList failed: ${JSON.stringify(e)}`);
      return 0;
    }
    let copied = 0;
    for (const n of names) {
      if (!n.toLowerCase().endsWith('.mscz')) {
        continue;
      }
      const dest = `${ScoreLibrary.rootPath}/${n}`;
      try {
        const bytes: Uint8Array = await ctx.resourceManager.getRawFileContent(n);
        const file = await fileIo.open(dest,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          await fileIo.write(file.fd, bytes.buffer);
        } finally {
          await fileIo.close(file.fd);
        }
        copied++;
      } catch (e) {
        console.info(`MSOH ScoreLibrary seed skip ${n}: ${JSON.stringify(e)}`);
      }
    }
    return copied;
  }
}
