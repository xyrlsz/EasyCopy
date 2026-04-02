# EasyCopy 项目接手说明

## 项目定位
- Flutter Android 漫画客户端，核心是把站点页面解析成结构化数据，再用原生 Flutter UI 渲染。
- 当前重难点集中在下载缓存、目录切换、缓存迁移恢复、Android SAF 目录桥接。

## 主要目录
- `lib/easy_copy_screen.dart`
  - 主界面状态容器，负责启动链路、导航、阅读器状态、下载管理入口。
- `lib/easy_copy_screen/`
  - 主界面拆分逻辑，含标准页、阅读页和页面组件。
- `lib/services/`
  - 业务核心。
  - `download_queue_manager.dart`：下载队列、缓存目录切换、迁移恢复、下载状态通知。
  - `comic_download_service.dart`：章节缓存下载、缓存库扫描、目录迁移、缓存删除。
  - `download_storage_service.dart`：缓存目录解析与候选目录加载。
  - `download_storage_migration_store.dart`：未完成迁移持久化状态。
  - `android_document_tree_bridge.dart`：Flutter 到 Android SAF 桥接。
  - `host_manager.dart`：站点主机探测与切换。
  - `page_repository.dart`：页面级缓存和加载。
- `android/app/src/main/kotlin/com/huangusaki/easycopy/`
  - Android 原生桥接，`DocumentTreeStorageBridge.kt` 是 SAF 目录读写核心。
- `test/services/`
  - 现有单测主要覆盖下载缓存服务和 HostManager。

## 启动链路
1. `lib/main.dart`
   - 初始化 `AppPreferencesController` 后启动应用。
2. `EasyCopyScreen.initState`
   - 初始化 WebView、下载队列管理器、阅读器状态与平台桥接。
3. `_bootstrap()`
   - 初始化 Host、Session、偏好、阅读进度。
   - 恢复下载队列与缓存目录状态。
   - 加载首页并刷新缓存漫画列表。

## 下载 / 缓存 / 迁移
- 下载入口
  - `DownloadQueueManager._runTask()` 调 `_EasyCopyScreenDownloadTaskRunner.download()`
  - 最终进入 `ComicDownloadService.downloadChapter()`
- 缓存库存储结构
  - 目录层级为 `漫画名/章节名/`
  - 章节目录写入图片文件和 `manifest.json`
- 缓存库读取
  - `ComicDownloadService.loadCachedLibrary()` 读取漫画目录、章节目录和 manifest
- 目录切换
  - `EasyCopyScreen._applyDownloadStoragePreferences()`
  - `DownloadQueueManager.applyStoragePreferences()`
  - `ComicDownloadService` 负责实际文件迁移
- 迁移恢复
  - `DownloadStorageMigrationStore` 负责落盘状态
  - `DownloadQueueManager.recoverInterruptedStorageMigration()` 负责重启后恢复

## Android SAF 桥接
- Flutter 侧
  - `android_document_tree_bridge.dart`
  - 暴露目录选择、读取、写入、遍历、删除与迁移调用
- Android 侧
  - `DocumentTreeStorageBridge.kt`
  - 负责 SAF `DocumentFile` 操作与 MethodChannel 回传
- 重点风险
  - 目录遍历、exists、readText 如果在主线程执行，缓存量大时会直接拖慢应用

## 当前维护关注点
- 启动期不要同步做重缓存扫描或重迁移
- 缓存库刷新要避免重复并发触发
- 目录迁移要分阶段恢复，避免中途退出后状态错乱
- Flutter 与 Android 两侧都需要结构化 debug 日志，方便用 `flutter run` 和 `adb logcat` 对照排查
