# ToastPeek

macOS 浏览器：SwiftUI + AppKit 界面，WebKit 引擎（系统媒体栈，
H.264 / AAC / HEVC 走系统解码，无需自编译编解码器）。

- **侧边栏竖标签**：Favorites（全局）、Pinned + 文件夹、Today（12 小时后自动归档，可调）、Spaces（各自独立的数据存储：Cookie/登录互相隔离）
- **Command Bar**：⌘T 新标签、⌘L 编辑当前地址；跨 Space 搜标签/历史/命令，搜索建议
- **分屏**（⌃⇧=，最多 4 栏，可拖分隔条）、**Peek**（外部链接/Shift 点链接的小窗，可移入 Space）
- **Boosts**（按网站注入 CSS/JS；CSS 编辑即时生效，JS 在后续导航时生效）、内建扩展（Content Blocker 内容拦截、Dark Mode 暗色注入）、PDF 查看、资料库（下载、媒体、已归档标签）、查找、缩放提示
- 标签行：favicon、加载转圈、播放中喇叭（点一下静音）、悬停关闭；固定标签关闭=卸载并回到固定页。图标只从页面已作为图片加载的同源声明图标安全提取，不额外请求；仅声明 link 图标等无法提取的情况显示占位图，历史和 Boost 等无 profile 上下文的视图也显示占位图。图标缓存仅保留在会话中，旧版磁盘图标不再读取，清除全部浏览数据时删除。
- 查找使用 WebKit 原生匹配；WebKit 不提供可靠总数，因此命中时显示“找到匹配”而不显示数量，仍可前后导航。
- 深/浅色双套主题，主题色随 Space

## 构建

```bash
scripts/build.sh            # Debug 构建（签名：Apple Development）
scripts/build.sh install    # Release 构建并装到 /Applications（会先正常退出正在运行的实例）
scripts/test.sh             # 核心逻辑 + 真实 AppKit/WebKit 集成测试
```

先安装 Xcode 和 XcodeGen；将 `ToastPeek/config/Signing.local.xcconfig.example` 复制为同目录的 `Signing.local.xcconfig`，填写自己的固定签名身份。该本机文件不会进入版本控制。测试默认使用 ad-hoc 签名。

Release 构建包含 arm64 和 x86_64；Debug 构建使用主机架构，使用独立 bundle ID。产物与缓存在 `~/Developer/Builds/ToastPeek`。Release 数据在 `~/Library/Application Support/ToastPeek`，日志在 `~/Library/Logs/ToastPeek`；Debug 数据和日志在 `~/Library/Application Support/ToastPeek-Development`。Debug 可用 `TOASTPEEK_SUPPORT_DIR` 指定隔离目录。构建包含 Intel 架构不代表已经在 Intel 硬件验收。

安装脚本只退出安装路径对应的进程，验证暂存包并在失败时回滚；旧包备份保存在构建目录的 `InstallBackups` 私有目录，不留在 `/Applications`。`TOASTPEEK_BUILD_DIR` 和 `TOASTPEEK_INSTALL_DIR` 可分别覆盖构建目录和安装目录。安装前应正常退出其他使用正式数据的旧版本副本；旧版本不遵守新版本的写入锁。

退出会先保存状态，并等待下载取消及正在进行的文件提交完成；普通 SIGTERM、Dock Quit 和退出 Apple Event 使用相同的安全退出流程。若下载或存储仍在工作，退出可能等待，不会强制结束或跳过保存。

本版本包含审计整改：状态写入具有实例锁和损坏文件保留策略，下载提交与取消有完成屏障，favicon 按 profile/origin 隔离且不读取旧磁盘缓存，界面查找和多窗口状态按窗口隔离。Release 构建仅声明 arm64/x86_64 兼容性，未在 Intel 硬件上验收；构建为 ad-hoc、未公证。

## 已知限制

- 没有 Widevine、内建密码管理器或任意 Chrome/Safari Web Extension 支持。受保护媒体和登录兼容性需按网站、系统版本实测；系统编解码支持不能证明完整 DRM 播放链路可用。
- 未公证。

开发笔记见 `docs/NOTES.md`。

本仓库未包含临时审计工件、用户路径或截图；发布验证仅记录实际运行的命令及其限制。
