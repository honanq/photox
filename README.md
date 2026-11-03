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

**最多九个钩子目标，按功能开启情况注册，并非每次都装九个。** 默认设置且没有单独隐藏的
相簿卡片时，计划注册四个；只保留「已隐藏」空态且关闭人物地点功能时，仍需两个
（空态 + 设置页相簿清单）。全部功能保留并开启时，当前实现不能压成一至两个而不丢功能。
实际安装成功数量仍取决于系统接口是否存在。

布局只注册具体的 `PUDoubleHeightHorizontalAlbumListGadgetLayout` 自身实现的方法；
安装时比较本类与父类的方法，不会回退去钩布局基类。

| 类 / 方法 | 作用 |
| --- | --- |
| `-[PXPhotosViewModel setEmptyPlaceholderState:]` | 统一拦截空态发布；仅对原生已解锁的「已隐藏」发布系统空态并关闭数量页脚，原生锁定请求原样保留 |
| `-[PXGadgetUIViewController collectionView:numberOfItemsInSection:]` | 「人物与地点」段不留条目 |
| `-[PXGadgetUIViewController collectionView:layout:referenceSizeForHeaderInSection:]` | 该段标题高度归零 |
| `-[PUAlbumsGadgetProvider gadgets]` | 读取相簿清单，写入设置页读取的偏好域 |
| `-[PUDoubleHeightHorizontalAlbumListGadgetLayout layoutAttributesForItemAtIndexPath:]` | 隐藏指定相簿的卡片，并按可见序号重排 |
| `-[PUOneUpViewController presentViewController:animated:completion:]` | 「删除时不再询问」：命中照片查看器的删除确认弹窗（先「从相簿中移除 / 删除」，再「删除照片」）时，直接执行其中的「删除」动作而不弹出 |
| `-[PUOneUpBarsController _performMuteAction:]` | 「自动开声」：静音按钮在自己的变更块里同时设置播放器静音状态与会话音量，并让工具栏重算按钮 |
| `-[PUBrowsingVideoPlayer setMuted:]` | 起播阶段 Photos 自己发出的静音请求按「不静音」执行 |
| `-[PXVideoSession setVolume:withFade:]` | 跟踪当前会话，换会话时重置手动静音标记；原音量请求照常执行 |

「已隐藏」在空态 setter 的统一发布入口处理，防止后续原生重算覆盖展示；原生锁定请求优先。
按视图模型缓存相簿身份，隐私控制器没有观察相簿时回退到本模型 currentDataSource 的
containerCollection；只在展示入口访问，不进入数据源计数回调。每次发布仍读取原生锁定状态，
不缓存认证结果。接口在安装钩子时检查，缺少必要接口就保留原流程。
「人物与地点」按有效标题缓存判断，空标题不会永久缓存成否，且可以读取备用的 localizedTitle。

相簿设置只在启动、偏好通知或回前台时读取一次快照；有效的逐相簿设置未变时不增加代次。
槽位缓存按「设置代次 + 数据源身份 + provider 身份 + 数组身份 + 条数」失效，命中时不再
扫描相簿；数据源暂时为 nil 不会形成永久负缓存。几何缓存随视图尺寸或卡片尺寸变化而重算，
仅隐藏或移位时复制属性，不改写系统缓存。此机 iOS 17.1.1 的批量布局方法已通过只读
反汇编确认会循环调用单项入口并收集其返回属性，因此不需要另加批量布局钩子。

相簿清单按 provider 缓存，数组身份或条数改变才解析；多个 provider 交替读取时仍保持原有的
“最后读取清单”语义。未就绪的标识或标题不会发布空清单覆盖有效数据，同一生命周期代次不重复
扫描，回前台、设置通知或数组变化才允许重试；曾发布有效数据的 provider 变空时可以清空清单。
相同内容不重复排写，清单写入在串行后台队列执行，成功同步后发送独立的 inventoryChanged
通知；子页在重新出现、回前台或收到该通知时重读并比较清单，仅变化时重建行，并过滤无效条目。
受控退出排在已有写入之后；最新同步失败时由下一次自然事件重试，不轮询。
原生 gadgets 属性在此机为 copy/NSArray；相同对象、相同条数且已完成快照的原地变更不属于
当前缓存的支持范围，真机换序仍需回归。

类尚未加载时通过 dyld 镜像事件合并补装，不在布局热路径反复查类；关闭功能不新装对应
钩子，已装钩子按开关直通原实现。没有轮询或定时刷新；生产代码仅保留 `ApelinLoaded`
加载标记。

不修改 `gadgets` 的返回值、也不改 `gadgetForIndexPath:` 的下标：照片 App 仍按原下标取
相簿 gadget，删元素会导致越界崩溃与卡片串位。

## 目录

- `Sources/Tweak.m` — 插件本体
- `PreferenceBundle/` — 设置面板（Root.plist 与相簿子页面）
- `apelin-project.json` — 构建与打包描述
- `Tests/` — 独立合成缓存回归，不进入安装包；运行方式和验证边界见 Tests/README.md
