import { picker, fileIo } from '@kit.CoreFileKit';
import bundleManager from '@ohos.bundle.bundleManager';
import deviceInfo from '@ohos.deviceInfo';
import { MsczMetadata } from '../model/MsczMetadata';
import { EngineReader } from '../engine/EngineReader';
import { errMessage } from '../mscz/MsczReader';
import { engineInfo, engineSetup } from 'libmsohengine.so';
import { EngineParseResult } from '../engine/EngineTypes';

interface SampleItem {
  rawfile: string;
  label: string;
  fmt: string;
}

@Component
struct MetaRowComp {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .opacity(0.55)
        .width(96)
      Text(this.value === '' ? '—' : this.value)
        .fontSize(15)
        .layoutWeight(1)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }
}

@Entry
@Component
struct Index {
  @State engine: string = '';
  @State samples: SampleItem[] = [
    { rawfile: 'bad_moon.mscz', label: 'Bad Moon', fmt: 'MS 2.0.3 / 格式 2.06' },
    { rawfile: 'stay_with_me.mscz', label: '真夜中のドア / Stay With Me', fmt: 'MS 3.5.2 / 格式 3.01' },
    { rawfile: 'omens_of_love.mscz', label: 'Omens of Love', fmt: 'MS 3.2.2 / 格式 3.01' },
    { rawfile: 'take_me.mscz', label: 'Take Me (Mint Jams)', fmt: 'MS 4.6.5 / 格式 4.60' },
  ];
  @State meta: MsczMetadata | null = null;
  @State engineUsed: string = '';
  @State pageImg: string = '';
  @State pageVersion: number = 0;
  @State viewerOpen: boolean = false;
  @State pageErr: string = '';
  @State busy: boolean = false;
  @State errorText: string = '';
  @State activeRawfile: string = '';

  aboutToAppear(): void {
    try {
      this.engine = engineInfo();
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
      }, this.getUIContext().getHostContext()!.cacheDir);
    } catch (e) {
      this.engine = `native 加载失败: ${errMessage(e as Object)}`;
    }
  }

  async parseRawfile(item: SampleItem): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.activeRawfile = item.rawfile;
    this.pageImg = '';
    this.pageErr = '';
    try {
      const ctx = this.getUIContext().getHostContext()!;
      const bytes: Uint8Array = await ctx.resourceManager.getRawFileContent(item.rawfile);
      const pageIndex = item.rawfile === 'omens_of_love.mscz' ? 1 : 0;
      const result: EngineParseResult = await EngineReader.parseBytes(bytes, item.rawfile, ctx.cacheDir, false, pageIndex);
      this.meta = result.meta;
      this.engineUsed = result.engineUsed;
      const pagePath = `${ctx.cacheDir}/page0.png`;
      let exists = false;
      try {
        exists = fileIo.accessSync(pagePath);
      } catch (e) {
        console.info(`MSOH access check failed: ${JSON.stringify(e)}`);
      }
      if (result.rendered && exists) {
        this.pageVersion++;
        this.pageImg = `file://${pagePath}?v=${this.pageVersion}`;
      } else {
        this.pageErr = result.rendered ? 'PNG 未找到' : result.renderError;
      }
    } catch (e) {
      this.meta = null;
      this.errorText = errMessage(e as Object);
    }
    this.busy = false;
  }

  async openPicker(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.pageImg = '';
    this.pageErr = '';
    try {
      const docPicker = new picker.DocumentViewPicker();
      const uris: string[] = await docPicker.select({
        fileSuffixFilters: ['mscz'],
        maxSelectNumber: 1,
      });
      if (uris.length > 0) {
        const ctx = this.getUIContext().getHostContext()!;
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(file.fd);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buf);
        fileIo.closeSync(file.fd);
        const bytes = new Uint8Array(buf);
        const name = decodeURIComponent(uris[0].split('/').pop() ?? uris[0]);
        const result: EngineParseResult = await EngineReader.parseBytes(bytes, name, ctx.cacheDir, false, 0);
        this.meta = result.meta;
        this.engineUsed = result.engineUsed;
        this.activeRawfile = '';
        const pagePath = `${ctx.cacheDir}/page0.png`;
        let exists = false;
        try {
          exists = fileIo.accessSync(pagePath);
        } catch (e) {
          exists = false;
        }
        if (result.rendered && exists) {
          this.pageVersion++;
          this.pageImg = `file://${pagePath}?v=${this.pageVersion}`;
        } else {
          this.pageErr = result.rendered ? 'PNG 未找到' : result.renderError;
        }
      }
    } catch (e) {
      this.errorText = errMessage(e as Object);
    }
    this.busy = false;
  }

  build() {
    Stack() {
      Column() {
        Column() {
          Text('MuseScore OH')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
          Text(this.engine)
            .fontSize(11)
            .opacity(0.5)
            .maxLines(1)
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)

        Scroll() {
          Column() {
            Text('内置样本(只读)')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .padding({ top: 4, bottom: 8 })
            ForEach(this.samples, (item: SampleItem) => {
              Row() {
                Column() {
                  Text(item.label)
                    .fontSize(15)
                  Text(item.fmt)
                    .fontSize(11)
                    .opacity(0.5)
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.activeRawfile === item.rawfile && this.busy) {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                } else {
                  Text('解析')
                    .fontSize(14)
                    .fontColor('#007DFF')
                }
              }
              .width('100%')
              .padding(12)
              .borderRadius(12)
              .backgroundColor(this.activeRawfile === item.rawfile ? '#1A007DFF' : Color.Transparent)
              .onClick(() => {
                this.parseRawfile(item);
              })
            }, (item: SampleItem) => item.rawfile)

            Button('从文件选择 .mscz…')
              .width('100%')
              .margin({ top: 8, bottom: 16 })
              .backgroundColor('#007DFF')
              .onClick(() => {
                this.openPicker();
              })

            if (this.errorText !== '') {
              Text(this.errorText)
                .fontSize(13)
                .fontColor('#E84026')
                .padding(12)
                .width('100%')
            }

            if (this.meta !== null) {
              Column() {
                Text(this.meta.title)
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                if (this.meta.subtitle !== '') {
                  Text(this.meta.subtitle)
                    .fontSize(13)
                    .opacity(0.7)
                    .margin({ top: 2 })
                }
                Divider().margin({ top: 10, bottom: 6 })
                MetaRowComp({ label: '引擎', value: this.engineUsed })
                if (this.pageErr !== '') {
                  MetaRowComp({ label: '渲染', value: `失败: ${this.pageErr}` })
                }
                if (this.pageImg !== '') {
                  Image(this.pageImg)
                    .objectFit(ImageFit.Contain)
                    .width('100%')
                    .height(320)
                    .backgroundColor('#F5F5F5')
                    .borderRadius(8)
                    .margin({ top: 8 })
                    .onClick(() => {
                      this.viewerOpen = true;
                    })
                }
                MetaRowComp({ label: '作曲', value: this.meta.composer })
                MetaRowComp({ label: '作词/改编', value: this.meta.lyricist })
                MetaRowComp({ label: '格式版本', value: `${this.meta.formatVersion}(程序 ${this.meta.programVersion})` })
                MetaRowComp({ label: '谱表/小节', value: `${this.meta.staffCount} 表 / ${this.meta.measureCount} 小节` })
                MetaRowComp({ label: '拍号', value: this.meta.timeSig })
                MetaRowComp({ label: '调号', value: this.meta.keySig })
                MetaRowComp({ label: '速度', value: this.meta.tempoBpm > 0 ? `${this.meta.tempoBpm} BPM` : '' })
                MetaRowComp({ label: 'Division', value: this.meta.division > 0 ? `${this.meta.division}` : '' })
                MetaRowComp({ label: '解析耗时', value: `${this.meta.parseMillis} ms` })
              }
              .width('100%')
              .padding(16)
              .borderRadius(16)
              .backgroundColor('#14000000')
              .alignItems(HorizontalAlign.Start)
            }
          }
          .constraintSize({ minHeight: '100%' })
          .padding({ left: 16, right: 16, bottom: 32 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('100%')

      if (this.viewerOpen && this.pageImg !== '') {
        Image(this.pageImg)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .backgroundColor('#EE000000')
          .onClick(() => {
            this.viewerOpen = false;
          })
      }
    }
  }
}
