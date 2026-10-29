/** JSON 记录取值工具：供 @Concurrent taskpool 函数 import 使用 */
export function recStr(rec: Record<string, Object>, key: string): string {
  const v = rec[key] as string;
  return v !== undefined ? v : '';
}

export function recNum(rec: Record<string, Object>, key: string): number {
  const v = rec[key] as number;
  return v !== undefined ? v : 0;
}
