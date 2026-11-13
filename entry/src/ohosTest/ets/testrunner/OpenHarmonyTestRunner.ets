import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'MSOHTest';

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {
  }

  onPrepare(): void {
    hilog.info(0x0DE0, TAG, '%{public}s', 'runner onPrepare');
  }

  async onRun(): Promise<void> {
    hilog.info(0x0DE0, TAG, '%{public}s', 'runner onRun');
    const delegator = abilityDelegatorRegistry.getAbilityDelegator();
    const args = abilityDelegatorRegistry.getArguments();
    const cmd = `aa start -d 0 -a TestAbility -b ${args.bundleName}`;
    try {
      await delegator.executeShellCommand(cmd);
    } catch (e) {
      hilog.error(0x0DE0, TAG, 'start TestAbility failed: %{public}s', JSON.stringify(e));
    }
  }
}
