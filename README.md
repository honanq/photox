# 相册增强（HiddenAlbum）

照片 App 的相册增强插件：把「已隐藏」相簿变成空相簿、去掉「人物与地点」分组，
并可以单独隐藏「我的相簿」里的任意相簿。全部行为由「设置 ▸ 相册增强」控制。

- 包标识：`com.simon.hidden-album`
- 作者：Simon
- 环境：iOS 16.0+，roothide 引导（另有 rootless 构建目标），Objective-C
- 适配：照片 App（`com.apple.mobileslideshow`）

## 功能

1. **已隐藏相簿显示为空**：保留系统原生认证，始终保留真实数据源；原生隐私控制器
   已解锁时才将界面设为系统空态，并隐藏照片数量页脚。失败、取消与重新锁定均由系统处理。
   不修改认证结果，也不替系统关闭或开启照片的 Face ID 设置。
2. **隐藏「人物与地点」**：相簿页中的「人物与地点」整组连同标题一起不显示。
3. **按相簿隐藏**：在设置里逐个勾选「我的相簿」中要隐藏的相簿（含「最近项目」「个人收藏」
   等智能相簿），勾选后该卡片从相簿页消失，后面的卡片自动补位。
4. **删除时不再询问**（默认关闭）：开启后，查看照片时点删除按钮直接删除，不再弹
   「从相簿中移除 / 删除 / 取消」。删除的照片仍在「最近删除」里，可照常恢复。
5. **播放视频时自动开启声音**（默认关闭）：开启后，视频一开始播放就有声音；
   此后静音按钮照常工作，静音、恢复与按钮图标都随状态变化。

开关改动后照片 App 会自动重启一次以生效；相簿清单需要先打开一次照片的「相簿」页才会刷新。

## 实现要点

只有九个钩子，每个都落在实现该方法的类上：

| 类 / 方法 | 作用 |
| --- | --- |
| `-[PXPhotosViewModel _updateEmptyPlaceholderState]` | 先执行原生更新，仅在「已隐藏」已原生解锁时设置系统空态并关闭数量页脚；锁定时保留原生状态 |
| `-[PXGadgetUIViewController collectionView:numberOfItemsInSection:]` | 「人物与地点」段不留条目 |
| `-[PXGadgetUIViewController collectionView:layout:referenceSizeForHeaderInSection:]` | 该段标题高度归零 |
| `-[PUAlbumsGadgetProvider gadgets]` | 读取相簿清单，写入设置页读取的偏好域 |
| `-[PUDoubleHeightHorizontalAlbumListGadgetLayout layoutAttributesForItemAtIndexPath:]` | 隐藏指定相簿的卡片，并按可见序号重排 |
| `-[PUOneUpViewController presentViewController:animated:completion:]` | 「删除时不再询问」：命中照片查看器的删除确认弹窗（先「从相簿中移除 / 删除」，再「删除照片」）时，直接执行其中的「删除」动作而不弹出 |
| `-[PUOneUpBarsController _performMuteAction:]` | 「自动开声」：静音按钮在自己的变更块里同时设置播放器静音状态与会话音量，并让工具栏重算按钮 |
| `-[PUBrowsingVideoPlayer setMuted:]` | 起播阶段 Photos 自己发出的静音请求按「不静音」执行 |
| `-[PXVideoSession setVolume:withFade:]` | 记住当前会话，并在起播时把音量置为 1.0 |

「已隐藏」按视图模型缓存相簿身份，但每次更新都读取原生锁定状态，不缓存认证结果；
接口在安装钩子时检查，缺少必要接口就保留原流程。「人物与地点」按 gadget 缓存，
相簿隐藏与槽位按「设置代次 + 列表条数」缓存；相簿清单只在数组指针变化时扫描，
内容未变不写偏好，布局实例只解析一次数据源。同条数换序或数组原地修改的缓存失效尚未全面验证。
没有轮询或定时刷新；生产代码仅保留 `ApelinLoaded` 加载标记。

不修改 `gadgets` 的返回值、也不改 `gadgetForIndexPath:` 的下标：照片 App 仍按原下标取
相簿 gadget，删元素会导致越界崩溃与卡片串位。

## 目录

- `Sources/Tweak.m` — 插件本体
- `PreferenceBundle/` — 设置面板（Root.plist 与相簿子页面）
- `apelin-project.json` — 构建与打包描述
