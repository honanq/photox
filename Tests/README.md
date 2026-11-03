# 合成缓存回归

这些测试直接包含生产源码，用合成对象替换外部数据源。它们不启动照片或设置、不读取真实相片、
不读写真实偏好、不进行认证、删除或视频播放，也不操作屏幕或安装 Hook。生产代码没有测试宏。

## 布局与展示（CacheTests.m）

直接包含 Sources/Tweak.m，元数据服务入口为惰性替身。检查：

- 槽位缓存命中，同数量新数组重排、设置代次、provider 和 dataSource 身份变化。
- dataSource 暂时为 nil 后恢复，非目标 dataSource 直通。
- 隐藏与补位只修改属性副本；几何缓存随 bounds/cardSize 变化，两张卡片可补位。
- 人物地点空标题重试、localizedTitle 备用，以及有效标题的正负缓存。
- 合成隐私状态：锁定请求不变、解锁后的重复内容发布保持空态、缺观察相簿时使用本模型展示来源、非目标及关闭时恢复页脚。
- 合成网格展示：仅原生已解锁且系统空态的 Hidden 隐藏网格；锁定、加载、非目标、关闭或换网格时释放自己的显隐覆盖，保留原本隐藏的网格；所有更新仍调用原生配置。
- 三组各 10000 次命中不重新读取 collection（槽位、展示身份、网格展示）；网格命中也不重复写 hidden。

```sh
clang -arch arm64e -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-function \
  -I Tests/Support -framework Foundation -framework UIKit -framework Photos \
  Tests/CacheTests.m -o .apelin-local/cache-tests
ldid -S.apelin-local/Tool.entitlements .apelin-local/cache-tests
./.apelin-local/cache-tests
```

## 图库清单服务（AlbumInventoryTests.m）

本轮严格编译、签名后执行：187 条断言，0 失败；断言数包含替身边界检查，并非独立场景数。

直接包含 Sources/HAAlbumInventory.m，PhotoKit 类、CFPreferences 及 notify 使用内存替身。检查：

- 不在构造期打开图库；查询及同步均离开主队列；没有请求授权或照片资源接口。
- 未授权、图库不可用或宿主上下文缺失时不覆盖旧清单；不回退到隐式单库查询。
- 每次查询明确绑定宿主库；切库时迁移观察者及查询上下文，不复用旧库的去重快照。
- 普通相簿及「最近项目 / 个人收藏」元数据、稳定排序、标识去重；不列出不受卡片布局控制的媒体/工具智能分类。
- nil 标题保留旧标题或使用未命名标签，不阻断全清单；缺失标识不发布部分结果。
- 归一化先去重后读标题，重复标识保持首项优先；每张智能卡片的类型只读一次。
- 图库变更直接消费 fetchResultAfterChanges；有效空结果清空旧条目。
- 相同清单不重复写；失败同步不发通知且清除发布缓存，下一自然事件用候选缓存重试，不重扫。
- 失败写 B 后返回先前 A 也会重新同步，不能将 cfprefsd 中未同步的 B 当作 A。
- 三组各 10000 次事件：无关照片变更不查询/不扫元数据，未就绪身份不重复扫描，排队刷新请求合并为一次查询。
- 设置请求与成功响应分离；停机在同步仍进行时等待排空，随后拒绝新工作并释放观察者。
- 命令行 dispatch_main 会退出入口线程，故主队列完成回调用队列标识而非 NSThread.isMainThread 验证。

```sh
clang -arch arm64e -fobjc-arc -O2 -Wall -Wextra -Werror \
  -framework Foundation -framework Photos \
  Tests/AlbumInventoryTests.m -o .apelin-local/inventory-tests
ldid -S.apelin-local/Tool.entitlements .apelin-local/inventory-tests
./.apelin-local/inventory-tests
```

先建立忽略的 .apelin-local/ 目录；其中 Tool.entitlements 取自 apelin-device-executables skill，
每次链接后重新签名。这些可执行文件不在包内、不属于产品源码匹配范围。

设置子页的独立测试另见 AlbumInventoryPaneTests.md。
这些断言不证明真实 Photos 的授权状态、库上下文、变更投递、最终 UI、冷启动补装、帧率或
CFPreferences 跨进程持久化已通过；这些仍需安装后在设备上单独回归。
