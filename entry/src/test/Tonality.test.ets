import { describe, it, expect } from '@ohos/hypium';
import { KEY_TONALITIES, transposedKeySigOf } from '../main/ets/engine/Tonality';

/**
 * transposedKeySigOf 是引擎 clampKey（pitchspelling.cpp + Key 枚举 C_B=-7…C_S=7）的镜像，
 * 期望值全部按引擎真值独立推导：k=7s mod 12、f=base+k、按 prefer 折回
 * （NONE→[-7,7]，SHARPS→[-4,7]，FLATS→[-7,4]，AUTO→[-6,6]）。
 * 杀的变异：k 映射退化为 k=s（s∈{2,4,6} 时 7s≡s mod 12 不可区分，必须奇数半音）、
 * 三档 prefer 边界写反/串档、wrap 单侧化。
 */
export default function tonalityTest() {
  describe('TonalityTest', () => {
    it('t1_kMapping_oddSemitones', 0, () => {
      // 奇数半音：k=7s mod 12 与 s 本身可区分（退化 k=s 会得 3/5/1）；AUTO 折回
      expect(transposedKeySigOf(0, 3, 3)).assertEqual(-3);
      expect(transposedKeySigOf(0, 5, 3)).assertEqual(-1);
      expect(transposedKeySigOf(0, 1, 3)).assertEqual(-5);
      expect(transposedKeySigOf(0, -1, 3)).assertEqual(5);
      expect(transposedKeySigOf(0, -3, 3)).assertEqual(3);
    });

    it('t2_preferTiers_ranges', 0, () => {
      // f_raw=7：NONE/SHARPS 保留（显式 NONE=作者要求不重拼，照文件），FLATS/AUTO 折回
      expect(transposedKeySigOf(5, 2, 0)).assertEqual(7);
      expect(transposedKeySigOf(5, 2, 1)).assertEqual(7);
      expect(transposedKeySigOf(5, 2, 2)).assertEqual(-5);
      expect(transposedKeySigOf(5, 2, 3)).assertEqual(-5);
      // f_raw=5：FLATS 上界 4
      expect(transposedKeySigOf(3, 2, 2)).assertEqual(-7);
      expect(transposedKeySigOf(3, 2, 3)).assertEqual(5);
      // f_raw=-5：SHARPS 下界 -4
      expect(transposedKeySigOf(-7, 2, 1)).assertEqual(7);
      expect(transposedKeySigOf(-7, 2, 0)).assertEqual(-5);
      // f_raw=-7（八度：k=0）：AUTO 下界 -6
      expect(transposedKeySigOf(-7, 12, 3)).assertEqual(5);
      expect(transposedKeySigOf(-7, 12, 0)).assertEqual(-7);
      expect(transposedKeySigOf(-7, 12, 1)).assertEqual(5);
      expect(transposedKeySigOf(-7, 12, 2)).assertEqual(-7);
    });

    it('t3_octaveAndZero', 0, () => {
      expect(transposedKeySigOf(4, 0, 2)).assertEqual(4);
      expect(transposedKeySigOf(-6, 12, 0)).assertEqual(-6);
      expect(transposedKeySigOf(6, -12, 0)).assertEqual(6);
    });

    it('t4_tonalityTable', 0, () => {
      expect(KEY_TONALITIES.length).assertEqual(15);
      expect(KEY_TONALITIES[0]).assertEqual('CbM/Abm');
      expect(KEY_TONALITIES[7]).assertEqual('CM/Am');
      expect(KEY_TONALITIES[14]).assertEqual('C#M/A#m');
      // 对称对抽查
      expect(KEY_TONALITIES[1]).assertEqual('GbM/Ebm');
      expect(KEY_TONALITIES[13]).assertEqual('F#M/D#m');
      // ScoreView 的用法：+2 半音 C→DM/Bm
      expect(KEY_TONALITIES[transposedKeySigOf(0, 2, 0) + 7]).assertEqual('DM/Bm');
    });

    /**
     * 正统 12 调写法表（用户裁定 2026-11-13）：文件无 <preferSharpFlat> 声明时 Part 默认
     * AUTO，移调永不写 7 升/7 降——C#M→DbM、CbM→BM，F#/Gb（6 个）并存（常规乐理实践：
     * 15 个书写调号中 7#/7b 取符号更少的等音调）。s=0..11 从 C 出发期望全部 ≤6 个升降号。
     */
    it('t5_orthodoxKeyTable', 0, () => {
      const expected: number[] = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5];
      for (let s = 0; s < 12; s++) {
        const f = transposedKeySigOf(0, s, 3);
        expect(f).assertEqual(expected[s]);
        expect(f >= -6 && f <= 6).assertTrue();
      }
    });
  });
}
