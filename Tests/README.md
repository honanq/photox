# 合成缓存回归

CacheTests.m 直接包含 Sources/Tweak.m 的生产函数，使用合成 collection、provider、dataSource、
布局对象和内存偏好替身。它不启动照片、不读取相片、不读写真实偏好、不进行认证、删除或视频播放，
也不会安装 Hook。构造函数只在测试翻译单元中禁用；生产源码没有测试宏或额外日志。

检查范围：

- 槽位缓存命中，同数量新数组重排、设置代次、provider 和 dataSource 身份变化。
- dataSource 暂时为 nil 后恢复，非目标 dataSource 直通。
- 隐藏与补位只修改属性副本；几何缓存随 bounds/cardSize 变化，两张卡片可补位。
- 人物地点空标题重试、localizedTitle 备用，以及有效标题的正负缓存。
- provider 清单缓存命中、多 provider 交替发布、相同清单去重、同步失败后的自然事件重试。
- 两组各 10000 次命中不重新读取 collection。

在 Apelin 项目根目录编译：

```sh
clang -arch arm64e -fobjc-arc -O2 -Wall -Wextra -Wno-unused-function \
  -I Tests/Support -framework Foundation -framework UIKit -framework Photos \
  Tests/CacheTests.m -o .apelin-local/cache-tests
ldid -S.apelin-local/Tool.entitlements .apelin-local/cache-tests
./.apelin-local/cache-tests
```

先建立忽略的 .apelin-local/ 目录；其中 Tool.entitlements 取自
apelin-device-executables skill，签名步骤不能跳过。此测试不在包内、不属于项目产品的源码匹配范围。

这些断言不证明 Photos 的最终 UI、冷启动补装、受控退出、帧率或真实清单持久化已通过；
这些仍需安装后在设备上单独回归。
