/**
 * 调性纯逻辑（零 @kit 依赖，可在 Local Test 宿主环境直接运行）。
 * transposedKeySigOf 是引擎 clampKey 的 ArkTS 镜像——两处刻意同构，改一处必须同步另一处。
 */
/** 调号→调性文本（大调/关系小调），下标 = 升降数 + 7 */
export const KEY_TONALITIES: string[] = [
  'CbM/Abm', 'GbM/Ebm', 'DbM/Bbm', 'AbM/Fm', 'EbM/Cm', 'BbM/Gm', 'FM/Dm', 'CM/Am',
  'GM/Em', 'DM/Bm', 'AM/F#m', 'EM/C#m', 'BM/G#m', 'F#M/D#m', 'C#M/A#m'
];

/**
 * 移调后的 fifths：k 满足 7k≡semitones (mod 12)，再按引擎 clampKey 同款
 * 升降号偏好折回（prefer：0=NONE→[-7,7]，1=SHARPS→[-4,7]，2=FLATS→[-7,4]，3=AUTO→[-6,6]；
 * 真值来源 pitchspelling.cpp clampKey + types.h Key 枚举 C_B=-7…C_S=7）
 */
export function transposedKeySigOf(base: number, semitones: number, prefer: number): number {
  if (semitones === 0) {
    return base;
  }
  const k = (((semitones % 12) + 12) % 12) * 7 % 12;
  let f = base + k;
  let smallest = -7;
  let largest = 7;
  if (prefer === 3) {
    smallest = -6;
    largest = 6;
  } else if (prefer === 1) {
    smallest = -4;
  } else if (prefer === 2) {
    largest = 4;
  }
  while (f < smallest) {
    f += 12;
  }
  while (f > largest) {
    f -= 12;
  }
  return f;
}
