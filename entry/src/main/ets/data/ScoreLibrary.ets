import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export interface ScoreFileEntry {
  fileName: string;
  displayName: string;
  sizeBytes: number;
  /** 秒级时间戳（fileIo Stat.mtime） */
  mtime: number;
}

export enum ImportStatus {
  /** 目标不存在（或用户确认覆盖后）已复制入库 */
  Copied,
  /** 同名同内容（size+MD5 相同），未复制 */
  Identical,
  /** 源文件本身就在库目录内 */
  InLibrary,
  /** 同名且内容不同，UI 层未确认覆盖 */
  Declined,
  Error
}

export interface ImportOneResult {
  fileName: string;
  status: ImportStatus;
}

/** 同名且内容不同时，由 UI 层弹确认框决定是否覆盖库内文件 */
export type OverwriteConfirm = (fileName: string) => Promise<boolean>;

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
      try {
        await fileIo.mkdir(ScoreLibrary.rootPath);
      } catch (e) {
        // 目录已存在（含冷启动 refresh 与导入链并发首建的竞争）时 mkdir 抛错，交给下方 access 确认
      }
      return await fileIo.access(ScoreLibrary.rootPath);
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
      return await ScoreLibrary.readAllFromFd(file.fd);
    } finally {
      await fileIo.close(file.fd);
    }
  }

  private static async readAllFromFd(fd: number): Promise<Uint8Array> {
    const st = await fileIo.stat(fd);
    const buf = new ArrayBuffer(st.size);
    const view = new Uint8Array(buf);
    let got = 0;
    while (got < st.size) {
      const n = await fileIo.read(fd, buf, { offset: got, length: st.size - got });
      if (n <= 0) {
        break;
      }
      got += n;
    }
    return got === st.size ? view : view.subarray(0, got);
  }

  private static async md5Hex(data: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('MD5');
    const blob: cryptoFramework.DataBlob = { data: data };
    await md.update(blob);
    const out = await md.digest();
    let hex = '';
    for (let i = 0; i < out.data.length; i++) {
      hex += out.data[i] < 16 ? '0' : '';
      hex += out.data[i].toString(16);
    }
    return hex;
  }

  /**
   * 把文件选择器返回的 URI 复制进公共下载目录。
   * 同名且内容相同（size+MD5）则跳过复制；同名且内容不同时经 shouldOverwrite 询问，未确认则不覆盖。
   */
  static async importOne(uri: string, shouldOverwrite?: OverwriteConfirm): Promise<ImportOneResult> {
    if (ScoreLibrary.rootPath === '' || !await ScoreLibrary.ensureDir()) {
      return { fileName: '', status: ImportStatus.Error };
    }
    let name = '';
    try {
      const srcPath = new fileUri.FileUri(uri).path ?? '';
      name = srcPath.split('/').pop() ?? '';
      if (name === '' || !name.toLowerCase().endsWith('.mscz')) {
        return { fileName: name, status: ImportStatus.Error };
      }
      if (srcPath.startsWith(`${ScoreLibrary.rootPath}/`)) {
        return { fileName: name, status: ImportStatus.InLibrary };
      }
      const dest = `${ScoreLibrary.rootPath}/${name}`;
      const src = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      try {
        if (!await fileIo.access(dest)) {
          await fileIo.copyFile(src.fd, dest);
          return { fileName: name, status: ImportStatus.Copied };
        }
        const sameSize = (await fileIo.stat(src.fd)).size === (await fileIo.stat(dest)).size;
        if (sameSize &&
          await ScoreLibrary.md5Hex(await ScoreLibrary.readAllFromFd(src.fd)) ===
          await ScoreLibrary.md5Hex(await ScoreLibrary.readBytes(name))) {
          return { fileName: name, status: ImportStatus.Identical };
        }
        if (shouldOverwrite !== undefined && await shouldOverwrite(name)) {
          await fileIo.copyFile(src.fd, dest);
          return { fileName: name, status: ImportStatus.Copied };
        }
        return { fileName: name, status: ImportStatus.Declined };
      } finally {
        await fileIo.close(src.fd);
      }
    } catch (e) {
      console.info(`MSOH ScoreLibrary import skip ${name}: ${JSON.stringify(e)}`);
      return { fileName: name, status: ImportStatus.Error };
    }
  }

}
