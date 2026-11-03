# 相簿设置子页合成回归

AlbumInventoryPaneTests.m 直接包含生产的 HiddenAlbumAlbumsController.m，将
PSListController、PSSpecifier、CFPreferences 的同步/读取及 Darwin 通知全部替换为内存对象。
NSUserDefaults 另设失败陷阱，防止回退到未经显式同步的 suite 缓存。不链接 Preferences，
不启动设置或照片、不访问真实偏好、不读取照片，也不操作屏幕。

覆盖：

- 非数组清单、非字典条目、非字符串 id/title、空值和重复标识；标识/标题保存不可变快照。
- 有效条目保留原来的 hide.<id>、偏好域、默认值及设置变更通知；开关仍使用系统读写方法。
- 首次渲染同步后读取持久清单，无须 Photos 响应；照片未运行时保留最后保存的清单。
- 出现及可见前台事件严格遵循「同步 → 读取持久清单 → inventoryRequest」顺序。
- inventoryChanged 只同步并重读；即使请求立即得到响应，也不会再发请求形成通知回环。
- 模拟跨进程缓存过期：改写存储后，specifier 缓存不自行读盘；下一事件同步后读取新值。
- nil、非法外层数据、非空但全损坏的条目数组及同步失败均保留已有有效行；失败后不 CopyAppValue，后续自然事件可恢复。
- 有效 @[] 明确清空旧列表，文案区分首次缺清单和当前确实没有相簿。
- 相同清单不重建行；改名、数量变化、同数量换序和清空都会更新。
- 10000 次 specifiers 缓存命中不读取、不同步、不请求；离页事件同样不产生这些操作。
- 重复 viewDidLoad 不重复监听；重新进入刷新；观察者不保留控制器，销毁时取消令牌。
- 页面提示照片运行时自动更新、首次需打开照片一次（无需相簿页）、未运行时使用持久缓存。

本轮使用下方严格编译、签名、执行方式通过：267 条断言，0 失败。
断言包含内存替身的通道、key、同步顺序及原生开关选择器检查，不代表 267 个独立场景。

在项目根目录运行。先将 PREFS_INCLUDE 设为本机已注册的 preferences 开发扩展的
support/include 目录；使用当前路径，不把解析后的 bootstrap 路径保存到仓库。
签名配置使用 apelin-device-executables skill 的 Tool.entitlements，放在忽略的
.apelin-local/ 目录中。

```sh
clang -arch arm64e -fobjc-arc -O2 -Wall -Wextra -Werror \
  -I "${PREFS_INCLUDE:?set PREFS_INCLUDE to the registered preferences support/include}" \
  -framework Foundation -framework UIKit \
  Tests/AlbumInventoryPaneTests.m -o .apelin-local/album-pane-tests
ldid -S.apelin-local/Tool.entitlements .apelin-local/album-pane-tests
./.apelin-local/album-pane-tests
```

这些测试证明合成数据下的页面逻辑，不证明真实 PSListController 的布局、Photos 的
清单采集、CFPreferences 跨进程写入/读取或实机页面显示已通过。上述行为需安装后回归。
