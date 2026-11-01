import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  HdsNavDestination, TextStyleMode, ScrollEffectType, BlurStrategy, hdsMaterial,
  HdsNavigationMenuItemOptions
} from '@kit.UIDesignKit';
import { LengthMetrics, ComponentContent } from '@kit.ArkUI';
import { ScoreLibrary } from '../data/ScoreLibrary';
import { ScoreEngine, ScoreMetaInfo, RenderedPageInfo } from '../engine/ScoreEngine';

const TAG = 'ScoreView';
/** 渲染 DPI：150dpi 下 A4 ≈ 1240x1754px，屏显清晰且单页解码内存可控 */
const RENDER_DPI: number = 150;
/** 内容顶部让位量：与主页一致（状态栏+迷你标题栏全高） */
const TITLE_INSET_LOCAL: number = 108;
/** openMenu 锚点 id：标题栏右下角的隐形锚点，菜单从其下方展开 */
const MENU_ANCHOR_ID: string = 'partMenuAnchor';
/** 调号→调性文本（大调/关系小调），下标 = 升降数 + 7 */
const KEY_TONALITIES: string[] = [
  'CbM/Abm', 'GbM/Ebm', 'DbM/Bbm', 'AbM/Fm', 'EbM/Cm', 'BbM/Gm', 'FM/Dm', 'CM/Am',
  'GM/Em', 'DM/Bm', 'AM/F#m', 'EM/C#m', 'BM/G#m', 'F#M/D#m', 'C#M/A#m'
];

/**
 * 移调后的 fifths：k 满足 7k≡semitones (mod 12)，再按引擎 clampKey 同款
 * 升降号偏好折回（prefer：0/3=NONE/AUTO→[-6,6]，1=SHARPS→[-4,7]，2=FLATS→[-7,4]）
 */
export function transposedKeySigOf(base: number, semitones: number, prefer: number): number {
  if (semitones === 0) {
    return base;
  }
  const k = (((semitones % 12) + 12) % 12) * 7 % 12;
  let f = base + k;
  const smallest = prefer === 1 ? -4 : -7;
  const largest = prefer === 2 ? 4 : (prefer === 1 ? 7 : 6);
  while (f < smallest) {
    f += 12;
  }
  while (f > largest) {
    f -= 12;
  }
  return f;
}

@CustomDialog
struct TransposeDialog {
  controller?: CustomDialogController;
  @Link semitones: number;
  /** 打开对话框时已应用的总移调量（相对初始调性），确认仅在变化时可用 */
  @Link baseSemitones: number;
  @Link original: string;
  @Link baseKeySig: number;
  @Link prefer: number;
  onConfirmed: (semitones: number) => void = () => {
  };

  private transposedLabel(): string {
    const f = transposedKeySigOf(this.baseKeySig, this.semitones, this.prefer);
    return KEY_TONALITIES[f + 7];
  }

  private stepLabel(): string {
    if (this.semitones === 0) {
      return '未移调';
    }
    return `${this.semitones > 0 ? '上移' : '下移'} ${Math.abs(this.semitones)} 个半音`;
  }

  build() {
    Column({ space: 24 }) {
      Column({ space: 4 }) {
        Text(this.original)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text('初始调性')
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .alignItems(HorizontalAlign.Center)

      Row({ space: 16 }) {
        Button('−')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .width(48)
          .height(48)
          .borderRadius(24)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .enabled(this.semitones > -24)
          .onClick(() => {
            this.semitones -= 1;
          })
        Column({ space: 2 }) {
          Text(this.transposedLabel())
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text(this.stepLabel())
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        Button('+')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .width(48)
          .height(48)
          .borderRadius(24)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .enabled(this.semitones < 24)
          .onClick(() => {
            this.semitones += 1;
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .onClick(() => {
            this.controller?.close();
          })
        Button('确认')
          .layoutWeight(1)
          .enabled(this.semitones !== this.baseSemitones)
          .onClick(() => {
            const s = this.semitones;
            this.controller?.close();
            this.onConfirmed(s);
          })
      }
    }
    .padding(24)
    .width('100%')
  }
}

export interface ScoreViewParams {
  fileName: string;
}

interface PageItem {
  page: RenderedPageInfo;
  key: string;
}

interface ViewItem {
  name: string;
  index: number;
}

interface PartMenuParams {
  parts: ViewItem[];
  selected: number;
  onSelect: (index: number) => void;
}

@Builder
function PartMenuBuilder(params: PartMenuParams) {
  Menu() {
    ForEach(params.parts, (item: ViewItem) => {
      // MenuItem.selected 无可见样式（实测），当前视角用右侧 labelInfo 标记
      MenuItem({
        content: item.name,
        labelInfo: item.index === params.selected ? '当前' : ' '
      })
        .onClick(() => {
          params.onSelect(item.index);
        })
    }, (item: ViewItem) => `${item.index}-${item.name}`)
  }
}

@Component
export struct ScoreView {
  @Prop fileName: string = '';
  @State title: string = '';
  @State pages: PageItem[] = [];
  @State parts: ViewItem[] = [];
  @State viewIndex: number = -1;
  @State loading: boolean = true;
  @State loadingText: string = '正在打开曲谱…';
  @State errorMsg: string = '';
  /** 当前视图记谱调号升降数；±7 以外（含多乐器视角的 1000）表示无调性按钮 */
  @State viewKeySig: number = 1000;
  /** 各视图（-1=总谱）打开时的初始调号，移调永不改变，作移对话框固定基准 */
  private initialKeys: Map<number, number> = new Map();
  /** 各视图相对初始调已应用的总移调量（半音） */
  private appliedSemis: Map<number, number> = new Map();
  @State transposeCount: number = 0;
  @State dialogSemitones: number = 0;
  @State dialogBaseSemitones: number = 0;
  @State dialogOriginal: string = '';
  @State dialogBaseKeySig: number = 0;
  @State dialogPrefer: number = 3;
  private meta: ScoreMetaInfo | null = null;
  /** 异步令牌：页面 pop 或重复切换后使旧协程结果失效 */
  private runSeq: number = 0;
  private scroller: Scroller = new Scroller();
  private transposeController: CustomDialogController = new CustomDialogController({
    builder: TransposeDialog({
      semitones: this.dialogSemitones,
      baseSemitones: this.dialogBaseSemitones,
      original: this.dialogOriginal,
      baseKeySig: this.dialogBaseKeySig,
      prefer: this.dialogPrefer,
      onConfirmed: (semitones: number): void => {
        this.applyTranspose(semitones);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  aboutToAppear(): void {
    this.title = this.fileName.replace(/\.mscz$/i, '');
    this.load();
  }

  aboutToDisappear(): void {
    this.runSeq++;
  }

  private async load(): Promise<void> {
    const seq = ++this.runSeq;
    this.loading = true;
    this.errorMsg = '';
    this.loadingText = '正在打开曲谱…';
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes = await ScoreLibrary.readBytes(this.fileName);
      const open = await ScoreEngine.open(bytes, ctx.cacheDir);
      if (seq !== this.runSeq) {
        return;
      }
      if (!open.ok || open.meta === null) {
        this.errorMsg = open.error !== '' ? open.error : '曲谱打开失败';
        this.loading = false;
        return;
      }
      this.meta = open.meta;
      this.title = open.meta.title !== '' ? open.meta.title : this.title;
      const views: ViewItem[] = [{ name: '总谱', index: -1 }];
      for (let i = 0; i < open.meta.parts.length; i++) {
        views.push({ name: open.meta.parts[i].name, index: i });
      }
      this.parts = views;
      this.initialKeys.clear();
      this.appliedSemis.clear();
      this.initialKeys.set(-1, open.meta.keySigAccidentals);
      this.appliedSemis.set(-1, 0);
      for (let i = 0; i < open.meta.parts.length; i++) {
        this.initialKeys.set(i, open.meta.parts[i].keySig);
        this.appliedSemis.set(i, 0);
      }
      console.info(`MSOH ${TAG}: opened [${this.fileName}] title=${open.meta.title} ` +
        `parts=${open.meta.parts.length} pages=${open.meta.pageCount} ${open.meta.parseMillis}ms`);
      await this.showView(-1, seq);
    } catch (e) {
      if (seq !== this.runSeq) {
        return;
      }
      this.errorMsg = '打开失败：' + JSON.stringify(e);
      this.loading = false;
    }
  }

  private async showView(viewIndex: number, seq: number): Promise<void> {
    this.loadingText = viewIndex < 0 ? '正在渲染总谱…' : `正在渲染「${this.partName(viewIndex)}」分谱…`;
    this.loading = true;
    this.pages = [];
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const outDir = `${ctx.cacheDir}/render/h${this.meta?.handle ?? 0}_v${viewIndex}_t${this.transposeCount}`;
      const res = await ScoreEngine.renderView(this.meta?.handle ?? 0, viewIndex, outDir, RENDER_DPI);
      if (seq !== this.runSeq) {
        return;
      }
      if (!res.ok) {
        this.errorMsg = res.error;
        this.loading = false;
        return;
      }
      const items: PageItem[] = [];
      for (let i = 0; i < res.pages.length; i++) {
        items.push({ page: res.pages[i], key: `${viewIndex}-${i}-${res.pages[i].file}` });
      }
      this.viewIndex = viewIndex;
      this.pages = items;
      this.viewKeySig = this.computeViewKeySig();
      this.loading = false;
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
      console.info(`MSOH ${TAG}: view=${viewIndex} pages=${items.length} ${res.ms}ms`);
    } catch (e) {
      if (seq !== this.runSeq) {
        return;
      }
      this.errorMsg = '渲染失败：' + JSON.stringify(e);
      this.loading = false;
    }
  }

  private partName(viewIndex: number): string {
    if (this.meta === null || viewIndex < 0 || viewIndex >= this.meta.parts.length) {
      return '总谱';
    }
    return this.meta.parts[viewIndex].name;
  }

  /** 当前视角的记谱调号升降数；非单乐器视角返回 1000 */
  private computeViewKeySig(): number {
    if (this.meta === null) {
      return 1000;
    }
    if (this.viewIndex >= 0) {
      if (this.viewIndex >= this.meta.parts.length) {
        return 1000;
      }
      const p = this.meta.parts[this.viewIndex];
      return p.instruments === 1 ? p.keySig : 1000;
    }
    return this.meta.instruments === 1 ? this.meta.keySigAccidentals : 1000;
  }

  /** 调号/调性文本（大调/关系小调，如 "CM/Am"）；非单乐器视角返回 '' */
  private keyTonalities(): string {
    const n = this.viewKeySig;
    if (n < -7 || n > 7) {
      return '';
    }
    return KEY_TONALITIES[n + 7];
  }

  private openTransposeDialog(): void {
    if (this.loading || this.viewKeySig < -7 || this.viewKeySig > 7) {
      return;
    }
    const initial = this.initialKeys.get(this.viewIndex);
    if (initial === undefined || initial < -7 || initial > 7) {
      return;
    }
    this.dialogPrefer = this.viewPrefer();
    this.dialogBaseKeySig = initial;
    this.dialogOriginal = KEY_TONALITIES[initial + 7];
    this.dialogSemitones = this.appliedSemis.get(this.viewIndex) ?? 0;
    this.dialogBaseSemitones = this.dialogSemitones;
    this.transposeController.open();
  }

  private viewPrefer(): number {
    if (this.meta === null) {
      return 3;
    }
    if (this.viewIndex >= 0 && this.viewIndex < this.meta.parts.length) {
      return this.meta.parts[this.viewIndex].prefer;
    }
    return this.meta.prefer;
  }

  /** 确认移调：semitones 为相对初始调的总移调量，只对增量部分执行引擎移调 */
  private async applyTranspose(semitones: number): Promise<void> {
    if (this.meta === null || this.loading) {
      return;
    }
    const delta = semitones - (this.appliedSemis.get(this.viewIndex) ?? 0);
    if (delta === 0) {
      return;
    }
    this.loadingText = '正在移调…';
    this.loading = true;
    try {
      const res = await ScoreEngine.transposeView(this.meta.handle, this.viewIndex, delta);
      if (!res.ok) {
        this.errorMsg = res.error;
        this.loading = false;
        return;
      }
      if (this.viewIndex >= 0 && this.viewIndex < this.meta.parts.length) {
        this.meta.parts[this.viewIndex].keySig = res.keySig;
      } else {
        this.meta.keySigAccidentals = res.keySig;
      }
      this.viewKeySig = res.keySig;
      this.appliedSemis.set(this.viewIndex, semitones);
      this.transposeCount += 1;
      await this.showView(this.viewIndex, this.runSeq);
    } catch (e) {
      this.errorMsg = '移调失败：' + JSON.stringify(e);
      this.loading = false;
    }
  }

  private selectView(viewIndex: number): void {
    if (viewIndex === this.viewIndex || this.loading) {
      return;
    }
    this.showView(viewIndex, this.runSeq);
  }

  /** 标题栏菜单项：单乐器视角时最左侧为调号/调性按钮；有分谱时其后为「当前视角」按钮 */
  private partMenuItems(): Array<HdsNavigationMenuItemOptions> {
    const items: Array<HdsNavigationMenuItemOptions> = [];
    const tonality = this.keyTonalities();
    if (tonality !== '') {
      items.push({
        content: {
          label: tonality,
          type: TextStyleMode.NORMAL,
          isEnabled: !this.loading,
          action: (): void => {
            this.openTransposeDialog();
          }
        }
      });
    }
    if (this.parts.length < 2) {
      return items;
    }
    items.push({
      content: {
        label: this.partName(this.viewIndex),
        type: TextStyleMode.NORMAL,
        isEnabled: !this.loading,
        action: (): void => {
          this.openPartMenu();
        }
      }
    });
    return items;
  }

  /** 标题栏菜单项触发：openMenu 全局菜单锚定在标题栏右下角的隐形锚点上 */
  private openPartMenu(): void {
    const ui = this.getUIContext();
    const params: PartMenuParams = {
      parts: this.parts,
      selected: this.viewIndex,
      onSelect: (index: number): void => {
        this.selectView(index);
      }
    };
    const content = new ComponentContent<PartMenuParams>(ui, wrapBuilder(PartMenuBuilder), params);
    ui.getPromptAction().openMenu(content, { id: MENU_ANCHOR_ID }, {
      placement: Placement.BottomRight,
      offset: { x: 0, y: 4 }
    }).catch((e: BusinessError) => {
      console.info(`MSOH ${TAG}: openMenu failed ${e.code} ${e.message}`);
    });
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Column() {
          if (this.loading) {
            Column({ space: 10 }) {
              LoadingProgress()
                .width(40)
                .height(40)
                .color($r('sys.color.brand'))
              Text(this.loadingText)
                .fontSize(14)
                .fontColor($r('sys.color.font_tertiary'))
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.errorMsg.length > 0) {
            Column({ space: 10 }) {
              Text(this.errorMsg)
                .fontSize(14)
                .fontColor($r('app.color.error'))
                .textAlign(TextAlign.Center)
                .padding(20)
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            Scroll(this.scroller) {
              Column({ space: 12 }) {
                ForEach(this.pages, (item: PageItem) => {
                  Image(`file://${item.page.file}`)
                    .autoResize(true)
                    .objectFit(ImageFit.Contain)
                    .width('100%')
                    .aspectRatio(item.page.w / item.page.h)
                    .borderRadius(6)
                    .backgroundColor(Color.White)
                }, (item: PageItem) => item.key)
              }
              .width('100%')
              .padding({ top: TITLE_INSET_LOCAL, left: 12, right: 12, bottom: 32 })
            }
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
            .align(Alignment.Top)
            .edgeEffect(EdgeEffect.Spring)
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
          }
        }
        .width('100%')
        .height('100%')

        // 分谱下拉菜单锚点：标题栏右下角（菜单从其下方展开）
        Row()
          .id(MENU_ANCHOR_ID)
          .width(48)
          .height(1)
          .margin({ top: 96, right: 8 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.comp_background_gray'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .titleBar({
      content: {
        title: { mainTitle: this.title },
        menu: {
          value: this.partMenuItems()
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(20),
          blurEffectiveEndOffset: LengthMetrics.vp(60)
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        },
        blurStrategy: BlurStrategy.ENABLE,
        originalStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.comp_background_gray'),
            blurRadius: 12,
            maskExtraHeight: 24
          },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') },
            backIconStyle: { iconColor: $r('sys.color.font_primary') }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: Color.Transparent, blurRadius: 12, maskExtraHeight: 24 },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') },
            backIconStyle: { iconColor: $r('sys.color.font_primary') }
          }
        }
      }
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.scroller])
  }
}
