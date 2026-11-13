import { common } from '@kit.AbilityKit';
import { picker, fileUri } from '@kit.CoreFileKit';
import bundleManager from '@ohos.bundle.bundleManager';
import deviceInfo from '@ohos.deviceInfo';
import {
  HdsNavigation, HdsNavigationTitleMode, TextStyleMode, HdsListItemCard, SuffixArrow,
  ScrollEffectType, BlurStrategy, hdsMaterial
} from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { engineInfo, engineSetup } from 'libmsohengine.so';
import { ScoreLibrary, ScoreFileEntry, ImportStatus } from '../data/ScoreLibrary';
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
  @State importing: boolean = false;
  /** 「打开方式」传入的文件 URI（EntryAbility 暂存，热启动时 @Watch 触发处理） */
  @StorageLink('msohPendingOpenUri') @Watch('onPendingOpenUri') pendingOpenUri: string = '';
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
    this.consumePendingOpenUri();
  }

  private onPendingOpenUri(): void {
    this.consumePendingOpenUri();
  }

  /** 处理「打开方式」传入的文件：复制进曲谱库（相同/已在库内免复制，冲突问询）后直接打开 */
  private async consumePendingOpenUri(): Promise<void> {
    const uri = this.pendingOpenUri;
    if (uri.length === 0) {
      return;
    }
    this.pendingOpenUri = '';
    const fileName = (new fileUri.FileUri(uri).path ?? '').split('/').pop() ?? '';
    if (!fileName.toLowerCase().endsWith('.mscz')) {
      // 兜底声明了 octet-stream，可能收到非曲谱文件
      this.getUIContext().getPromptAction().showToast({ message: '仅支持打开 .mscz 曲谱文件', duration: 2000 });
      return;
    }
    const r = await ScoreLibrary.importOne(uri, (n: string): Promise<boolean> => this.confirmOverwrite(n));
    if (r.status === ImportStatus.Error) {
      this.getUIContext().getPromptAction().showToast({ message: '打开曲谱文件失败', duration: 2000 });
      return;
    }
    if (r.status === ImportStatus.Declined) {
      this.getUIContext().getPromptAction().showToast({ message: '已保留曲谱库内版本', duration: 2000 });
      return;
    }
    if (r.status === ImportStatus.Copied) {
      this.getUIContext().getPromptAction().showToast({ message: '已导入曲谱库', duration: 2000 });
      await this.refresh();
    }
    const params: ScoreViewParams = { fileName: r.fileName };
    this.pathStack.pushPathByName('ScoreView', params);
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

  /** 同名且内容不同时的覆盖确认（系统 AlertDialog；取消/覆盖/遮罩与返回键都会 settle） */
  private confirmOverwrite(fileName: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      this.getUIContext().showAlertDialog({
        title: '同名曲谱已存在',
        message: `「${fileName.replace(/\.mscz$/i, '')}」与曲谱库内的同名文件内容不同，是否覆盖？`,
        autoCancel: true,
        cancel: (): void => resolve(false),
        primaryButton: {
          value: '取消',
          action: (): void => resolve(false)
        },
        secondaryButton: {
          value: '覆盖',
          fontColor: $r('app.color.error'),
          action: (): void => resolve(true)
        }
      } as AlertDialogParamWithButtons);
    });
  }

  /** 文件选择器导入：逐份复制进公共下载目录，同名冲突询问是否覆盖（用户取消选择器则静默返回） */
  private async pickAndImport(): Promise<void> {
    if (this.importing) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const docPicker = new picker.DocumentViewPicker(ctx);
    const opts = new picker.DocumentSelectOptions();
    opts.fileSuffixFilters = ['.mscz'];
    opts.maxSelectNumber = 50;
    let uris: string[] = [];
    try {
      uris = await docPicker.select(opts);
    } catch (e) {
      console.info(`MSOH ${TAG} picker cancelled or failed: ${JSON.stringify(e)}`);
      return;
    }
    if (uris.length === 0) {
      return;
    }
    this.importing = true;
    try {
      let copied = 0;
      let same = 0;
      let declined = 0;
      let openName = '';
      for (const uri of uris) {
        const r = await ScoreLibrary.importOne(uri, (n: string): Promise<boolean> => this.confirmOverwrite(n));
        if (r.status === ImportStatus.Copied) {
          copied++;
        } else if (r.status === ImportStatus.Identical || r.status === ImportStatus.InLibrary) {
          same++;
          openName = r.fileName;
        } else if (r.status === ImportStatus.Declined) {
          declined++;
        }
      }
      const prompt = this.getUIContext().getPromptAction();
      if (copied > 0 && declined > 0) {
        prompt.showToast({ message: `已导入 ${copied} 份，跳过 ${declined} 份同名曲谱`, duration: 2000 });
      } else if (copied > 0) {
        prompt.showToast({ message: `已导入 ${copied} 份曲谱`, duration: 2000 });
      } else if (declined > 0) {
        prompt.showToast({ message: `已跳过 ${declined} 份同名曲谱`, duration: 2000 });
      } else if (same > 0) {
        prompt.showToast({ message: '所选曲谱已在曲谱库内', duration: 2000 });
      } else {
        prompt.showToast({ message: '未能导入所选文件', duration: 2000 });
      }
      if (copied > 0) {
        await this.refresh();
      }
      if (uris.length === 1 && openName.length > 0) {
        const params: ScoreViewParams = { fileName: openName };
        this.pathStack.pushPathByName('ScoreView', params);
      }
    } finally {
      this.importing = false;
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
                // key 含 mtime/size：同名覆盖后行内容变了，HdsListItemCard 不响应参数更新，须换 key 强制重建
                }, (item: ScoreItem) => `${item.key}:${item.entry.mtime}:${item.entry.sizeBytes}`)
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
        title: { mainTitle: 'MuseScoreOH' },
        menu: {
          value: [{
            content: {
              label: '导入',
              type: TextStyleMode.NORMAL,
              action: (): void => {
                this.pickAndImport();
              }
            }
          }, {
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

      Text('放入文件后回到本应用，点右上角「刷新」；\n或直接点右上角「导入」，从文件管理器选择 .mscz 文件。')
        .fontSize(13)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 32 })
  }
}
