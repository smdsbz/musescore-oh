export const engineInfo: () => string;
export const engineSetup: (modules?: Record<string, object>, cacheDir?: string) => boolean;
export const engineLoadMeta: (bytes: Uint8Array, tempDir: string, outPagePath?: string, dpi?: number, pageIndex?: number) => string;
export const engineFontSmoke: (outPath: string) => boolean;
export const engineRenderPage: (bytes: Uint8Array, tempDir: string, outPath: string, dpi?: number) => string;
