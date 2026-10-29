import { common } from '@kit.AbilityKit';
import bundleManager from '@ohos.bundle.bundleManager';
import deviceInfo from '@ohos.deviceInfo';
import {
  HdsNavigation, HdsNavigationTitleMode, TextStyleMode, HdsListItemCard, SuffixArrow,
  ScrollEffectType, BlurStrategy, hdsMaterial
} from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { engineInfo, engineSetup } from 'libmsohengine.so';
import { ScoreLibrary, ScoreFileEntry } from '../data/ScoreLibrary';
import { ScoreView, ScoreViewParams } from './ScoreView';

const TAG = 'Index';
/** 内容顶部让位量：ignoreLayoutSafeArea(TOP) 后视口含状态栏，
 *  需让出「状态栏+迷你标题栏」全高（OhMyWiki 同配方实测 104vp） */
const TITLE_INSET_TOTAL: number = 108;

interface ScoreItem {
  entry: ScoreFileEntry;
  key: string;
}

function formatSize(bytes: number): string {
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return Math.round(bytes / 1024) + ' KB';
  }
  return bytes + ' B';
}

function formatDate(sec: number): string {
  const d = new Date(sec * 1000);
  const p = (n: number): string => n.toString().padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

@Entry
@Component
struct Index {
  private pathStack: NavPathStack = new NavPathStack();
  @State scores: ScoreItem[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State publicPath: string = '';
  @State seeding: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ScoreLibrary.init(ctx);
    this.publicPath = ScoreLibrary.getDisplayRoot();
    try {
      // 引擎无头环境初始化：必须在主 JS 线程（详见 mscore_engine.cpp EngineSetup）
      console.info(`MSOH engine: ${engineInfo()}`);
      engineSetup({
          'bundle.bundleManager': {
            'BundleFlag': bundleManager.BundleFlag,
            'getBundleInfoForSelfSync': bundleManager.getBundleInfoForSelfSync
          },
          'deviceInfo': {
            'deviceType': deviceInfo.deviceType,
            'marketName': deviceInfo.marketName,
            'productModel': deviceInfo.productModel,
            'osFullName': deviceInfo.osFullName,
            'brand': deviceInfo.brand,
            'manufacture': deviceInfo.manufacture,
            'sdkApiVersion': deviceInfo.sdkApiVersion,
            'displayVersion': deviceInfo.displayVersion,
            'majorVersion': deviceInfo.majorVersion,
            'seniorVersion': deviceInfo.seniorVersion,
            'featureVersion': deviceInfo.featureVersion
          }
        }, ctx.cacheDir);
      } catch (e) {
        console.info(`MSOH engine setup failed: ${JSON.stringify(e)}`);
      }
    this.refresh();
  }

  async refresh(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      await ScoreLibrary.ensureDir();
      const list = await ScoreLibrary.listScores();
      const items: ScoreItem[] = [];
      for (const e of list) {
        items.push({ entry: e, key: e.fileName });
      }
      this.scores = items;
      console.info(`MSOH ${TAG}: discovered ${items.length} scores`);
    } catch (e) {
      this.errorMsg = '扫描失败：' + JSON.stringify(e);
    }
    this.loading = false;
  }

  private openScore(item: ScoreItem): void {
    const params: ScoreViewParams = {
      fileName: item.entry.fileName
    };
    this.pathStack.pushPathByName('ScoreView', params);
  }

  /** 把内置示例曲谱复制进公共下载目录（rawfile 未打包样本时提示） */
  private async seedSamples(): Promise<void> {
    this.seeding = true;
    try {
      const n = await ScoreLibrary.seedBuiltinSamples();
      if (n === 0) {
        this.getUIContext().getPromptAction().showToast({ message: '没有可导入的内置示例', duration: 2000 });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: `已导入 ${n} 份示例曲谱`, duration: 2000 });
        await this.refresh();
      }
    } finally {
      this.seeding = false;
    }
  }

  build() {
    HdsNavigation(this.pathStack) {
      Column() {
        if (this.loading) {
          Column({ space: 8 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('sys.color.brand'))
            Text('正在扫描曲谱库…')
              .fontSize(14)
              .fontColor($r('sys.color.font_tertiary'))
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.scroller) {
            Column({ space: 12 }) {
              if (this.errorMsg.length > 0) {
                Text(this.errorMsg)
                  .fontSize(13)
                  .fontColor($r('app.color.error'))
                  .padding(12)
              }

              if (this.scores.length === 0) {
                this.EmptyGuide()
              } else {
                Text(`共 ${this.scores.length} 份曲谱 · ${this.publicPath}`)
                  .fontSize(13)
                  .fontColor($r('sys.color.font_tertiary'))
                  .width('100%')
                  .padding({ left: 16, right: 16 })

                ForEach(this.scores, (item: ScoreItem) => {
                  HdsListItemCard({
                    textItem: {
                      primaryText: { text: item.entry.displayName },
                      secondaryText: {
                        text: `${formatSize(item.entry.sizeBytes)} · ${formatDate(item.entry.mtime)}`
                      }
                    },
                    suffixItem: new SuffixArrow(),
                    onClick: (): void => {
                      this.openScore(item);
                    }
                  })
                }, (item: ScoreItem) => item.key)
              }
            }
            .width('100%')
            .padding({ top: TITLE_INSET_TOTAL, bottom: 32 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.comp_background_gray'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .titleBar({
      content: {
        title: { mainTitle: '乐谱' },
        menu: {
          value: [{
            content: {
              label: '刷新',
              type: TextStyleMode.NORMAL,
              action: (): void => {
                this.refresh();
              }
            }
          }]
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
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: Color.Transparent, blurRadius: 12, maskExtraHeight: 24 },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
            menuStyle: { iconColor: $r('sys.color.font_primary'), textColor: $r('sys.color.font_primary') }
          }
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.scroller])
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
  }

  @Builder
  PageMap(name: string, param: ESObject) {
    if (name === 'ScoreView') {
      ScoreView({ fileName: (param as ScoreViewParams).fileName })
    }
  }

  @Builder
  EmptyGuide() {
    Column({ space: 10 }) {
      Text('曲谱库为空')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .margin({ top: 32 })

      Text('把 .mscz 曲谱文件放进手机的公共下载目录，每份曲谱就会出现在这里。\n' +
        '路径：我的手机 → ' + this.publicPath)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Start)
        .lineHeight(22)
        .padding({ left: 24, right: 24 })

      Text('放入文件后回到本应用，点右上角「刷新」。')
        .fontSize(13)
        .fontColor($r('sys.color.font_tertiary'))

      Button(this.seeding ? '正在导入…' : '导入内置示例曲谱')
        .height(48)
        .fontSize(16)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .borderRadius(24)
        .padding({ left: 24, right: 24 })
        .margin({ top: 12 })
        .enabled(!this.seeding)
        .onClick(() => {
          this.seedSamples();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 32 })
  }
}
