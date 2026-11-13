import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ScoreLibrary, ImportStatus, ImportOneResult } from '../../../main/ets/data/ScoreLibrary';
import { writeBytes, readAll, rmIfExists, bytesEqual, flipMid } from './util/Helpers';

/**
 * I1 哈希喂数端到端（直调 importOne）：
 * 杀死接线层变异——两处读取调用同源化（self-hash→恒 Identical）、stub 结果被忽略、
 * 相同文件也调回调（次序对调）。决策矩阵的分支归属在 Local 层 PlanImportTest，此处不重复。
 * 盲区：readAllFromFd 分块读循环（小 fixture 单次 read 即完，行为等价杀不掉）。
 */
const FILE = 'zz_test_i1.mscz';

class S {
  static ctx: common.UIAbilityContext | null = null;
  static rootPath: string = '';
  static pristine: Uint8Array = new Uint8Array(0);
  static cache: string = '';
}

export default function importTest() {
  describe('ImportTest', () => {
    beforeAll(async (): Promise<void> => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const ability = await delegator.getCurrentTopAbility();
      const ctx = ability.context as common.UIAbilityContext;
      S.ctx = ctx;
      ScoreLibrary.init(ctx);
      S.rootPath = new fileUri.FileUri(
        'file://docs/storage/Users/currentUser/Download/' + ctx.abilityInfo.bundleName).path ?? '';
      // fixture 在 entry_test 模块 rawfile，须用该模块的资源管理器（top ability 可能是主模块的）
      const testRm = ctx.createModuleContext('entry_test').resourceManager;
      S.pristine = new Uint8Array(await testRm.getRawFileContent('twinkle_twinkle_little_star.mscz'));
      S.cache = `${ctx.cacheDir}/${FILE}`;
    });

    afterAll(async (): Promise<void> => {
      await rmIfExists(S.cache);
      await rmIfExists(`${S.rootPath}/${FILE}`);
    });

    it('i1_hashPipeline', 0, async (done: Function) => {
      await rmIfExists(`${S.rootPath}/${FILE}`);
      // 1. 全新导入（顺带钉 Copied 接线）
      await writeBytes(S.cache, S.pristine);
      let r: ImportOneResult = await ScoreLibrary.importOne(`file://${S.cache}`);
      expect(r.status).assertEqual(ImportStatus.Copied);
      // 2. 同名同 size 异内容 ×stub(false)：Declined 且库内字节未动
      const flipped = flipMid(S.pristine);
      await writeBytes(S.cache, flipped);
      r = await ScoreLibrary.importOne(`file://${S.cache}`, (): Promise<boolean> => Promise.resolve(false));
      expect(r.status).assertEqual(ImportStatus.Declined);
      let libNow = await readAll(`${S.rootPath}/${FILE}`);
      expect(bytesEqual(libNow, S.pristine)).assertTrue();
      // 3. 同名同 size 异内容 ×stub(true)：库内字节换新（self-hash 变异在此必红）
      r = await ScoreLibrary.importOne(`file://${S.cache}`, (): Promise<boolean> => Promise.resolve(true));
      expect(r.status).assertEqual(ImportStatus.Copied);
      libNow = await readAll(`${S.rootPath}/${FILE}`);
      expect(bytesEqual(libNow, flipped)).assertTrue();
      // 4. 库=源（此刻 cache 即 flipped）：Identical 且不打扰回调（相同文件不弹框的接线锚）
      let spy = 0;
      r = await ScoreLibrary.importOne(`file://${S.cache}`, (): Promise<boolean> => {
        spy++;
        return Promise.resolve(true);
      });
      expect(r.status).assertEqual(ImportStatus.Identical);
      expect(spy).assertEqual(0);
      done();
    });
  });
}
