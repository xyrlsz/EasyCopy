<div align="center">
  <img src="assets/icons/app_icon_rounded_1024.png" alt="EasyCopy Logo" width="160" />
  <h1>EasyCopy</h1>
  <p><strong>专为移动端打造的原生沉浸式漫画阅读体验</strong></p>
  <p>
    一个基于 Flutter 的创新型漫画客户端。它并非简单的 WebView 套壳，而是通过在后台无感加载目标站点，提取结构化数据，最终使用纯正的 Flutter 原生组件重新构建首页、发现、排行及阅读等核心界面。<br/>
    既能无缝对接原网站的内容池与账号体系，又能彻底掌控移动端的交互细节、流畅度与缓存策略。
  </p>
</div>

---

## ✨ 核心特性

- 🚀 **完全原生重构**：告别网页版在移动端的卡顿与不适，以 Flutter 原生 UI 渲染首页、分类、排行榜及漫画详情页。
- 📱 **纯粹阅读体验**：量身定制的无缝图片流阅读器，支持自动记录阅读进度、本地与在线章节无缝衔接。
- 🛡️ **高可用节点调度**：内置多候选域名池，启动时自动智能测速；主站异常时无缝 Failover 切换，拒绝单点故障。
- 💾 **强悍的离线引擎**：
  - 持久化下载队列，可稳定从已获取进度的位置继续补齐章节图片。
  - 页面级按策略缓存，涵盖不同生效 TTL 与登录隔离域。
  - 阅读页图片与封面数据独立采用差异化的高效缓存机制。
- 🔐 **融合登录体系**：调用站点原生接口进行无感登录认证，并以网页端作为兜底方案，全应用级别共享 Token 与 Cookie。

## 📸 界面预览

| 首页推荐 | 漫画详情 | 沉浸阅读 |
| :---: | :---: | :---: |
| <img src="docs/screenshots/home-fresh.png" width="260"/> | <img src="docs/screenshots/detail-page.png" width="260"/> | <img src="docs/screenshots/reader-page.png" width="260"/> |

## 🏗️ 架构与核心实现

本项目不仅是一个客户端，更是一套「Web 转 Native」的高效解析框架：

1. **暗中接管**：后台 `WebView` 使用桌面 UA 静默加载目标网页。
2. **DOM 抽离**：注入 `page_extractor_script.dart` 脚本，将 DOM 节点降维解析为统一的结构化 JSON。
3. **数据反序列化**：`EasyCopyScreen` 监听并捕获数据，映射回结构化领域模型（`EasyCopyPage`）。
4. **原生重绘**：Flutter 依靠上述标准数据，利用原生组件渲染出流畅的交互界面。

### 核心模块一览

- **生命周期与容器 (`lib/easy_copy_screen.dart` & `lib/easy_copy_screen/`)**：统一管理路由导航、Web态装载进度与全局事件派发。
- **高可用网关 (`lib/services/host_manager.dart`)**：探活侧载机制与主节点智能重定向。
- **缓存大脑 (`lib/services/page_repository.dart`)**：复杂页面的多级缓存（Memory/Disk）与数据一致性比对。
- **持久化下载器 (`lib/services/comic_download_service.dart` & `download_queue_store.dart`)**：主控并发队列处理和全本缓存生命周期。

## 📁 目录结构

```text
lib/
├── models/       # 领域驱动的数据模型 (Home, Detail, Reader 等)
├── services/     # 核心中间件与后端服务 (节点管理、鉴权、缓存、队列)
├── webview/      # 核心解析引擎提取脚本
├── easy_copy_screen/ # 主界面复杂逻辑与状态分拆的 part 文件
├── widgets/      # 页面级组件与复用 UI (如个人中心视图、设置项、下载管理)
├── app_config.dart # 全局配置常量
└── app_theme.dart  # 全局主题样式定义
test/             # 测试套件 (涉及解析逻辑与网络切换断言)
docs/             # README 使用的真机截图物料
android/          # Android Native 工程
```

## 💻 开发者指南

**开发环境声明：**
- **Flutter**: 3.38.7
- **Dart**: 3.10.7

### 快速启动

```bash
# 获取最新依赖包
flutter pub get

# 启动并部署至 Android 物理机 / 模拟器
flutter run -d android
```

### 构建与发行

构建标准的 release APK 应用：

```bash
flutter build apk --release --target-platform android-arm64
```

如需针对终端设备的指令集进行分割（减少多余的包体积）：

```bash
flutter build apk --release --target-platform=android-arm64 --split-per-abi
```
> **提示：** 部署产物默认输出至 `build/app/outputs/flutter-apk/` 目录。

## 🧪 持续集成与质量检验

每次代码合并前，请确保通过所有静态风格校验与单元测试：

```bash
# 静态代码分析
flutter analyze

# 核心链路回归测试
flutter test
```
*主要测试覆盖面包含：高可用网络探测回退、页面级缓存读写时效、下载队列事务持久化、鉴权隔离等核心业务链路。*

## ⚠️ 特别声明

- **平台聚焦**：目前仓库仅单独保留与维护 Android 工程。
- **非通用爬虫**：框架重度耦合于目标站点的 DOM 结构设计与接口规范，非通用全网抽取框架。
- **渐进式覆盖**：若遇到尚未进行原生标准化重写的页面（标注为 `unknown` 路由类型），当前会直接使用标准的未支持页面提示进行展示，不会继续尝试原生渲染。

---
<div align="center">
  <p>Made with ❤️ by Huangusaki</p>
</div>
