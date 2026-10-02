export interface MsczMetadata {
  fileName: string;
  mscxEntry: string;
  formatVersion: string;
  programVersion: string;
  title: string;
  subtitle: string;
  composer: string;
  lyricist: string;
  staffCount: number;
  measureCount: number;
  timeSig: string;
  keySig: string;
  keySigAccidentals: number;
  tempoBpm: number;
  division: number;
  parseMillis: number;
}

export function newMetadata(fileName: string): MsczMetadata {
  return {
    fileName: fileName,
    mscxEntry: '',
    formatVersion: '',
    programVersion: '',
    title: '',
    subtitle: '',
    composer: '',
    lyricist: '',
    staffCount: 0,
    measureCount: 0,
    timeSig: '',
    keySig: '',
    keySigAccidentals: 0,
    tempoBpm: 0,
    division: 0,
    parseMillis: 0,
  };
}
