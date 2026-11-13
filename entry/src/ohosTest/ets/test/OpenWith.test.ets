import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry, Driver, ON, On, MatchPattern } from '@kit.TestKit';
import { fileUri } from '@kit.CoreFileKit';
import { common, Want } from '@kit.AbilityKit';
import { ScoreLibrary } from '../../../main/ets/data/ScoreLibrary';
import { writeBytes, readAll, rmIfExists, bytesEqual, sleep } from './util/Helpers';

/**
 * B 系：startAbility(viewData want) 显式拉起 EntryAbility 模拟「打开方式」（绕过系统路由段），
 * 杀死 EntryAbility→AppStorage→@Watch→consumePendingOpenUri→confirmOverwrite 按钮方向的接线变异。
 * toast 文案为 best-effort，主断言落在稳定状态（库字节 + 页面）。
 */
const FILE = 'zz_test_ow.mscz';

class S {
  static ctx: common.UIAbilityContext | null = null;
  static rootPath: string = '';
  static cache: string = '';
  static twinkle: Uint8Array = new Uint8Array(0);
  static marathon: Uint8Array = new Uint8Array(0);
  static driver: Driver | null = null;
  static bundle: string = '';
}

async function openViaWant(): Promise<void> {
  const want: Want = {
    action: 'ohos.want.action.viewData',
    uri: `file://${S.cache}`,
    type: 'application/octet-stream',
    bundleName: S.bundle,
    abilityName: 'EntryAbility'
  };
  await abilityDelegatorRegistry.getAbilityDelegator().startAbility(want);
}

async function exists(match: On): Promise<boolean> {
  try {
    const c = await S.driver!.findComponent(match);
    return c !== undefined && c !== null;
  } catch (e) {
    return false;
  }
}

async function waitFor(match: On, timeoutMs: number): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await exists(match)) {
      return true;
    }
    await sleep(500);
  }
  return false;
}

async function clickButton(label: string): Promise<boolean> {
  try {
    const btn = await S.driver!.findComponent(ON.text(label));
    await btn.click();
    return true;
  } catch (e) {
    return false;
  }
}

/** 回主页（ScoreView→Index），以「刷新」按钮为 Index 标记 */
async function backToIndex(): Promise<void> {
  for (let i = 0; i < 3; i++) {
    if (await exists(ON.text('刷新'))) {
      return;
    }
    await S.driver!.pressBack();
    await sleep(800);
  }
}

export default function openWithTest() {
  describe('OpenWithFlowTest', () => {
    beforeAll(async (): Promise<void> => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const ability = await delegator.getCurrentTopAbility();
      const ctx = ability.context as common.UIAbilityContext;
      S.ctx = ctx;
      S.bundle = ctx.abilityInfo.bundleName;
      ScoreLibrary.init(ctx);
      S.rootPath = new fileUri.FileUri(
        'file://docs/storage/Users/currentUser/Download/' + S.bundle).path ?? '';
      await ScoreLibrary.ensureDir();
      S.cache = `${ctx.cacheDir}/${FILE}`;
      // fixture 在 entry_test 模块 rawfile，须用该模块的资源管理器（top ability 可能是主模块的）
      const testRm = ctx.createModuleContext('entry_test').resourceManager;
      S.twinkle = new Uint8Array(await testRm.getRawFileContent('twinkle_twinkle_little_star.mscz'));
      S.marathon = new Uint8Array(await testRm.getRawFileContent('open_marathon.mscz'));
      S.driver = Driver.create();
      await rmIfExists(`${S.rootPath}/${FILE}`);
      // B1 起点：库内已有同名同内容文件
      await writeBytes(`${S.rootPath}/${FILE}`, S.twinkle);
      await writeBytes(S.cache, S.twinkle);
    });

    afterAll(async (): Promise<void> => {
      await rmIfExists(S.cache);
      await rmIfExists(`${S.rootPath}/${FILE}`);
    });

    it('b1_identical_straightToScoreView', 0, async (done: Function) => {
      await openViaWant();
      const ok = await waitFor(ON.text('总谱'), 15000);
      expect(ok).assertTrue();
      const titled = await waitFor(ON.text('Twinkle', MatchPattern.CONTAINS), 5000);
      expect(titled).assertTrue();
      done();
    });

    it('b2_conflict_decline_keepsLibrary', 0, async (done: Function) => {
      await backToIndex();
      expect(await exists(ON.text('刷新'))).assertTrue();
      // 顶名异内容：marathon 字节占库内文件名
      await writeBytes(S.cache, S.marathon);
      await openViaWant();
      const dialog = await waitFor(ON.text('同名曲谱已存在'), 10000);
      expect(dialog).assertTrue();
      expect(await clickButton('取消')).assertTrue();
      await sleep(1000);
      const libNow = await readAll(`${S.rootPath}/${FILE}`);
      expect(bytesEqual(libNow, S.twinkle)).assertTrue();
      expect(await exists(ON.text('刷新'))).assertTrue();
      done();
    });

    it('b3_conflict_overwrite_replacesAndOpens', 0, async (done: Function) => {
      expect(await exists(ON.text('刷新'))).assertTrue();
      await openViaWant();
      const dialog = await waitFor(ON.text('同名曲谱已存在'), 10000);
      expect(dialog).assertTrue();
      expect(await clickButton('覆盖')).assertTrue();
      const opened = await waitFor(ON.text('Marathon', MatchPattern.CONTAINS), 15000);
      expect(opened).assertTrue();
      const libNow = await readAll(`${S.rootPath}/${FILE}`);
      expect(bytesEqual(libNow, S.marathon)).assertTrue();
      // 原 B5 并入：覆盖后回主页，列表行显示新大小（ForEach key 回归锚；5835→6 KB，1906→2 KB）
      await backToIndex();
      const row = await waitFor(ON.text('2 KB', MatchPattern.CONTAINS), 8000);
      expect(row).assertTrue();
      done();
    });

    /**
     * T1 移调端到端（marathon 单乐器，instruments===1 使总谱即有调性按钮）：
     * 杀 partMenuItems 门控、openTransposeDialog 传参、applyTranspose 增量基准、标签接线。
     * 盲区：outDir 的 t${transposeCount} 缓存击穿接线（标签断言杀不掉，图像断言跨设备脆弱不补）。
     */
    it('b4_transpose_endToEnd', 0, async (done: Function) => {
      // b3 结束态：库内 FILE=marathon、cache=marathon → identical 直开
      await openViaWant();
      const opened = await waitFor(ON.text('Marathon', MatchPattern.CONTAINS), 15000);
      expect(opened).assertTrue();
      const tonality = await waitFor(ON.text('CM/Am'), 10000);
      expect(tonality).assertTrue();
      // titleBar 调性按钮点击（B 系首次点击 titleBar 元素，探针失败即红）
      expect(await clickButton('CM/Am')).assertTrue();
      const dlg = await waitFor(ON.text('初始调性'), 8000);
      expect(dlg).assertTrue();
      expect(await clickButton('+')).assertTrue();
      expect(await clickButton('+')).assertTrue();
      expect(await clickButton('确认')).assertTrue();
      const after = await waitFor(ON.text('DM/Bm'), 30000);
      expect(after).assertTrue();
      done();
    });
  });
}
