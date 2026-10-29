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
  private meta: ScoreMetaInfo | null = null;
  /** 异步令牌：页面 pop 或重复切换后使旧协程结果失效 */
  private runSeq: number = 0;
  private scroller: Scroller = new Scroller();

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
      const outDir = `${ctx.cacheDir}/render/h${this.meta?.handle ?? 0}_v${viewIndex}`;
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

  private selectView(viewIndex: number): void {
    if (viewIndex === this.viewIndex || this.loading) {
      return;
    }
    this.showView(viewIndex, this.runSeq);
  }

  /** 标题栏菜单项：有分谱时为「当前视角」按钮（点击弹下拉）；无分谱则空 */
  private partMenuItems(): Array<HdsNavigationMenuItemOptions> {
    if (this.parts.length < 2) {
      return [];
    }
    const item: HdsNavigationMenuItemOptions = {
      content: {
        label: this.partName(this.viewIndex),
        type: TextStyleMode.NORMAL,
        isEnabled: !this.loading,
        action: (): void => {
          this.openPartMenu();
        }
      }
    };
    return [item];
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
