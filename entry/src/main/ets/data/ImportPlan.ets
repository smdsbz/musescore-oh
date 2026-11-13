/**
 * 导入决策纯函数（零 @kit 依赖，可在 Local Test 宿主环境直接运行）。
 * importOne 负责 IO（stat/md5/copy）与回调调用时机，五态归属只在这里。
 */
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

/** 是否需要打扰 UI 询问覆盖——判定与 planImport 同源（无回调时落 Declined 即冲突），接线层勿自行重复判断 */
export function isConflict(destExists: boolean, sameSize: boolean, sameHash: boolean): boolean {
  return planImport(destExists, sameSize, sameHash, false, false) === ImportStatus.Declined;
}

export function planImport(destExists: boolean, sameSize: boolean, sameHash: boolean,
  hasCallback: boolean, overwrite: boolean): ImportStatus {
  if (!destExists) {
    return ImportStatus.Copied;
  }
  if (sameSize && sameHash) {
    return ImportStatus.Identical;
  }
  return hasCallback && overwrite ? ImportStatus.Copied : ImportStatus.Declined;
}
