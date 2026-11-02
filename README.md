# 相册增强（HiddenAlbum）

照片 App 的相册增强插件：把「已隐藏」相簿变成空相簿、去掉「人物与地点」分组，
并可以单独隐藏「我的相簿」里的任意相簿。全部行为由「设置 ▸ 相册增强」控制。

- 包标识：`com.simon.hidden-album`
- 作者：Simon
- 环境：iOS 16.0+，roothide 引导（另有 rootless 构建目标），Objective-C
- 适配：照片 App（`com.apple.mobileslideshow`）

## 功能

1. **已隐藏相簿显示为空**：打开「已隐藏」相簿时显示系统自带的「无照片或视频」。
2. **隐藏「人物与地点」**：相簿页中的「人物与地点」整组连同标题一起不显示。
3. **按相簿隐藏**：在设置里逐个勾选「我的相簿」中要隐藏的相簿（含「最近项目」「个人收藏」
   等智能相簿），勾选后该卡片从相簿页消失，后面的卡片自动补位。
4. **删除时不再询问**（默认关闭）：开启后，查看照片时点删除按钮直接删除，不再弹
   「从相簿中移除 / 删除 / 取消」。删除的照片仍在「最近删除」里，可照常恢复。

开关改动后照片 App 会自动重启一次以生效；相簿清单需要先打开一次照片的「相簿」页才会刷新。

## 实现要点

只有五个钩子，每个都落在实现该方法的类上：

| 类 / 方法 | 作用 |
| --- | --- |
| `-[PXPhotosDataSource numberOfSections]` | 「已隐藏」智能相簿返回 0 段 |
| `-[PXGadgetUIViewController collectionView:numberOfItemsInSection:]` | 「人物与地点」段不留条目 |
| `-[PXGadgetUIViewController collectionView:layout:referenceSizeForHeaderInSection:]` | 该段标题高度归零 |
| `-[PUAlbumsGadgetProvider gadgets]` | 读取相簿清单，写入设置页读取的偏好域 |
| `-[PUDoubleHeightHorizontalAlbumListGadgetLayout layoutAttributesForItemAtIndexPath:]` | 隐藏指定相簿的卡片，并按可见序号重排 |
| `-[UIViewController presentViewController:animated:completion:]` | 「删除时不再询问」：命中照片查看器的删除确认弹窗时，直接执行其中的「删除」动作而不弹出 |

相簿可见性只扫描一次并缓存在 provider 上（设置变更或相簿数量变化才重建），
布局回调只做数组查表；没有轮询、没有定时刷新、没有日志输出。

不修改 `gadgets` 的返回值、也不改 `gadgetForIndexPath:` 的下标：照片 App 仍按原下标取
相簿 gadget，删元素会导致越界崩溃与卡片串位。

## 目录

- `Sources/Tweak.m` — 插件本体
- `PreferenceBundle/` — 设置面板（Root.plist 与相簿子页面）
- `apelin-project.json` — 构建与打包描述
