import { fileIo } from '@kit.CoreFileKit';

export async function writeBytes(path: string, data: Uint8Array): Promise<void> {
  const f = await fileIo.open(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    await fileIo.write(f.fd, data.buffer);
  } finally {
    await fileIo.close(f.fd);
  }
}

export async function readAll(path: string): Promise<Uint8Array> {
  const f = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const st = await fileIo.stat(f.fd);
    const buf = new ArrayBuffer(st.size);
    await fileIo.read(f.fd, buf);
    return new Uint8Array(buf);
  } finally {
    await fileIo.close(f.fd);
  }
}

export async function rmIfExists(path: string): Promise<void> {
  try {
    await fileIo.unlink(path);
  } catch (e) {
    // 不存在即视为已清理
  }
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** 同 size 异内容：翻中段一个字节（importOne 只拷贝不解析，任意字节可用作 .mscz 源） */
export function flipMid(src: Uint8Array): Uint8Array {
  const out = new Uint8Array(src.length);
  out.set(src);
  const mid = out.length >> 1;
  out[mid] = out[mid] ^ 0xFF;
  return out;
}

export function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}
