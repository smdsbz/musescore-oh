import { describe, it, expect } from '@ohos/hypium';
import { uniformTypeDescriptor } from '@kit.ArkData';

/** C1：utd.json5 是本仓库配置；探针查得到 = 配置内容正确且已注册进系统库 */
export default function utdTest() {
  describe('UtdRegistrationTest', () => {
    it('c1_msczTypeId', 0, () => {
      const got = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.mscz');
      expect(got).assertEqual('io.smdsbz.musescoreoh.mscz');
    });
  });
}
