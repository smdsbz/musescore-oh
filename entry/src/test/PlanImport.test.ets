import { describe, it, expect } from '@ohos/hypium';
import { planImport, ImportStatus } from '../main/ets/data/ImportPlan';

/**
 * 决策矩阵：分支次序/组合的唯一权威（相同文件必须先于回调询问判 Identical 等）。
 * 后缀/InLibrary 等单行表达式不在测试范围（表达式镜像=1+1=2）。
 */
export default function planImportTest() {
  describe('PlanImportTest', () => {
    it('l1_freshImport_copied', 0, () => {
      expect(planImport(false, false, false, false, false)).assertEqual(ImportStatus.Copied);
      expect(planImport(false, true, true, true, true)).assertEqual(ImportStatus.Copied);
    });

    it('l2_conflict_noCallback_declined', 0, () => {
      expect(planImport(true, false, false, false, false)).assertEqual(ImportStatus.Declined);
      expect(planImport(true, true, false, false, false)).assertEqual(ImportStatus.Declined);
    });

    it('l3_conflict_callbackFalse_declined', 0, () => {
      expect(planImport(true, false, false, true, false)).assertEqual(ImportStatus.Declined);
      expect(planImport(true, true, false, true, false)).assertEqual(ImportStatus.Declined);
    });

    it('l4_conflict_callbackTrue_copied', 0, () => {
      expect(planImport(true, false, false, true, true)).assertEqual(ImportStatus.Copied);
      expect(planImport(true, true, false, true, true)).assertEqual(ImportStatus.Copied);
    });

    it('l5_identical_wins_over_ask', 0, () => {
      // 必须钉死回调=true：否则"哈希检查与询问次序对调"变异不可见
      expect(planImport(true, true, true, true, true)).assertEqual(ImportStatus.Identical);
    });
  });
}
