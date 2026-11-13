import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ScoreEngine, ScoreMetaInfo } from '../../../main/ets/engine/ScoreEngine';
import { rmIfExists } from './util/Helpers';

/**
 * 引擎桥端到端（经 ScoreEngine 包装层，顺带覆盖 JSON 字段映射）。
 * 杀的自有代码变异：meta 提取（staff(0) 调号/excerpts 循环）、setLayoutMode(SYSTEM) 被删、
 * CHUNK_PX 改大、dpi 接线断开、移调 Interval 索引退化/dir 恒 UP/拆块展平、块偏移漏调。
 * 盲区（不测）：三代 reader 分发（上游 MuseScore 代码）、渲染耗时、跨构建图像 golden。
 */
class S {
  static ctx: common.UIAbilityContext | null = null;
  static twinkle: Uint8Array = new Uint8Array(0);
  static marathon: Uint8Array = new Uint8Array(0);

  // taskpool 对 ArrayBuffer 参数是转移语义（传后原缓冲 detach），每次必须给新拷贝
  static tw(): Uint8Array {
    return S.twinkle.slice();
  }

  static ma(): Uint8Array {
    return S.marathon.slice();
  }
}

async function md5File(path: string): Promise<string> {
  const f = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const st = await fileIo.stat(f.fd);
    const buf = new ArrayBuffer(st.size);
    await fileIo.read(f.fd, buf);
    const md = cryptoFramework.createMd('MD5');
    const blob: cryptoFramework.DataBlob = { data: new Uint8Array(buf) };
    await md.update(blob);
    const out = await md.digest();
    let hex = '';
    for (let i = 0; i < out.data.length; i++) {
      hex += out.data[i] < 16 ? '0' : '';
      hex += out.data[i].toString(16);
    }
    return hex;
  } finally {
    await fileIo.close(f.fd);
  }
}

async function isPng(path: string): Promise<boolean> {
  const f = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const head = new ArrayBuffer(8);
    await fileIo.read(f.fd, head);
    const v = new Uint8Array(head);
    return v[0] === 0x89 && v[1] === 0x50 && v[2] === 0x4E && v[3] === 0x47
      && v[4] === 0x0D && v[5] === 0x0A && v[6] === 0x1A && v[7] === 0x0A;
  } finally {
    await fileIo.close(f.fd);
  }
}

async function cleanDir(dir: string): Promise<void> {
  try {
    const names = await fileIo.listFile(dir);
    for (const n of names) {
      await rmIfExists(`${dir}/${n}`);
    }
    await fileIo.rmdir(dir);
  } catch (e) {
    // 目录不存在即已清理
  }
}

export default function engineTest() {
  describe('EngineTest', () => {
    beforeAll(async (): Promise<void> => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const ability = await delegator.getCurrentTopAbility();
      const ctx = ability.context as common.UIAbilityContext;
      S.ctx = ctx;
      const ok = ScoreEngine.setup(ctx);
      expect(ok).assertTrue();
      const rm = ctx.createModuleContext('entry_test').resourceManager;
      S.twinkle = new Uint8Array(await rm.getRawFileContent('twinkle_twinkle_little_star.mscz'));
      S.marathon = new Uint8Array(await rm.getRawFileContent('open_marathon.mscz'));
    });

    afterAll(async (): Promise<void> => {
      await cleanDir(`${S.ctx!.cacheDir}/render/zz_test_e2a`);
      await cleanDir(`${S.ctx!.cacheDir}/render/zz_test_e2b`);
      await cleanDir(`${S.ctx!.cacheDir}/render/zz_test_e2c`);
      await cleanDir(`${S.ctx!.cacheDir}/render/zz_test_e4a`);
      await cleanDir(`${S.ctx!.cacheDir}/render/zz_test_e4b`);
    });

    it('e1_meta', 0, async (done: Function) => {
      const tw = await ScoreEngine.open(S.tw(), S.ctx!.cacheDir);
      expect(tw.ok).assertTrue();
      const m = tw.meta as ScoreMetaInfo;
      expect(m.title).assertEqual('Twinkle, Twinkle, Little Star');
      expect(m.formatVersion).assertEqual('4.60');
      expect(m.staffCount).assertEqual(5);
      expect(m.measureCount).assertEqual(13);
      expect(m.parts.length).assertEqual(4);
      expect(m.instruments).assertEqual(4);
      expect(m.keySigAccidentals).assertEqual(0);
      const ma = await ScoreEngine.open(S.ma(), S.ctx!.cacheDir);
      expect(ma.ok).assertTrue();
      const mm = ma.meta as ScoreMetaInfo;
      expect(mm.title).assertEqual('Open Marathon Fixture');
      expect(mm.measureCount).assertEqual(96);
      expect(mm.parts.length).assertEqual(0);
      expect(mm.instruments).assertEqual(1);
      expect(mm.pageCount > 0).assertTrue();
      done();
    });

    it('e2_renderStructure', 0, async (done: Function) => {
      const base = `${S.ctx!.cacheDir}/render`;
      // marathon 150dpi：连续布局必须分块（96 小节），全块 ≤2400px，PNG 有效且非空白
      const opened = await ScoreEngine.open(S.ma(), S.ctx!.cacheDir);
      expect(opened.ok).assertTrue();
      const dirA = `${base}/zz_test_e2a`;
      const r150 = await ScoreEngine.renderView(opened.meta!.handle, -1, dirA, 150);
      expect(r150.ok).assertTrue();
      expect(r150.pages.length >= 2).assertTrue();
      for (const p of r150.pages) {
        expect(p.h <= 2400).assertTrue();
        expect(p.w > 0).assertTrue();
        expect(await isPng(p.file)).assertTrue();
        const st = await fileIo.stat(p.file);
        // 全白 1240x2400 PNG 压缩后仅数 KB；有谱面内容远超 20KB
        expect(st.size > 20480).assertTrue();
      }
      // twinkle 双档 dpi：宽度比例 ≈ 72/150（杀 dpi 接线断开→恒默认回退）
      const tw = await ScoreEngine.open(S.tw(), S.ctx!.cacheDir);
      expect(tw.ok).assertTrue();
      const r72 = await ScoreEngine.renderView(tw.meta!.handle, -1, `${base}/zz_test_e2b`, 72);
      const rTw150 = await ScoreEngine.renderView(tw.meta!.handle, -1, `${base}/zz_test_e2c`, 150);
      expect(r72.ok && rTw150.ok).assertTrue();
      const ratio = r72.pages[0].w / rTw150.pages[0].w;
      expect(ratio > 0.4 && ratio < 0.56).assertTrue();
      done();
    });

    it('e3_transposeSemantics', 0, async (done: Function) => {
      // 三个独立 handle 避免移调累积：+2（Interval 索引退化）、-2（dir 恒 UP）、+14（>13 拆块）
      const h1 = await ScoreEngine.open(S.ma(), S.ctx!.cacheDir);
      const up = await ScoreEngine.transposeView(h1.meta!.handle, -1, 2);
      expect(up.ok).assertTrue();
      expect(up.keySig).assertEqual(2);
      const h2 = await ScoreEngine.open(S.ma(), S.ctx!.cacheDir);
      const down = await ScoreEngine.transposeView(h2.meta!.handle, -1, -2);
      expect(down.ok).assertTrue();
      expect(down.keySig).assertEqual(-2);
      const h3 = await ScoreEngine.open(S.ma(), S.ctx!.cacheDir);
      const oct = await ScoreEngine.transposeView(h3.meta!.handle, -1, 14);
      expect(oct.ok).assertTrue();
      expect(oct.keySig).assertEqual(2);
      // 移调后同 handle 重渲仍 ok
      const r = await ScoreEngine.renderView(h1.meta!.handle, -1, `${S.ctx!.cacheDir}/render/zz_test_e2a`, 72);
      expect(r.ok).assertTrue();
      done();
    });

    it('e4_determinism', 0, async (done: Function) => {
      const base = `${S.ctx!.cacheDir}/render`;
      const opened = await ScoreEngine.open(S.ma(), S.ctx!.cacheDir);
      expect(opened.ok).assertTrue();
      const ra = await ScoreEngine.renderView(opened.meta!.handle, -1, `${base}/zz_test_e4a`, 72);
      const rb = await ScoreEngine.renderView(opened.meta!.handle, -1, `${base}/zz_test_e4b`, 72);
      expect(ra.ok && rb.ok).assertTrue();
      expect(ra.pages.length).assertEqual(rb.pages.length);
      // 自等：同参数两次渲染逐块 md5 相等（杀块间状态污染）
      // 块间互异：同一次渲染各块 md5 两两不同（杀 onPaintPageSheet 偏移漏调→每块画同段）
      const hashesA: string[] = [];
      const hashesB: string[] = [];
      for (let i = 0; i < ra.pages.length; i++) {
        const ha = await md5File(ra.pages[i].file);
        const hb = await md5File(rb.pages[i].file);
        expect(ha === hb).assertTrue();
        hashesA.push(ha);
        hashesB.push(hb);
      }
      for (let i = 0; i < hashesA.length; i++) {
        for (let j = i + 1; j < hashesA.length; j++) {
          expect(hashesA[i] !== hashesA[j]).assertTrue();
        }
      }
      console.info(`MSOHTest golden md5 (record only): ${JSON.stringify(hashesA)}`);
      done();
    });
  });
}
