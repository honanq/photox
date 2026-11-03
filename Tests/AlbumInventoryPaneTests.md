# 相簿设置子页合成回归

AlbumInventoryPaneTests.m 直接包含生产的 HiddenAlbumAlbumsController.m，仅将
PSListController、PSSpecifier 和 NSUserDefaults 替换为内存对象。不链接 Preferences，
不启动设置或照片、不访问真实偏好、不读取照片，也不操作屏幕。

覆盖：

- 非数组清单、非字典条目、非字符串 id/title、空值和重复标识。
- 有效条目保留原来的 hide.<id>、偏好域、默认值及设置变更通知。
- 首次空态后收到前台事件会刷新；离页后不在前台事件中读偏好，重新进入会刷新。
- 相同清单不重建行；改名、数量变化、同数量换序和清空都会更新。
- 10000 次 specifiers 缓存命中不重复读取偏好；观察者不保留控制器。
- 独立 inventoryChanged 信号刷新可见子页，重复 viewDidLoad 不重复监听，离页不读偏好，销毁时取消令牌；notify 注册与取消均使用内存替身。

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
