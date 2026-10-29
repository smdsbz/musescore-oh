export const engineInfo: () => string;
export const engineSetup: (modules?: Record<string, object>, cacheDir?: string) => boolean;
export const engineOpenScore: (bytes: Uint8Array, tempDir: string) => string;
export const engineRenderView: (handle: number, viewIndex: number, outDir: string, dpi?: number) => string;
export const engineFontSmoke: (outPath: string) => boolean;
