# ToastPeek 开发笔记

只记代码里看不出来的东西。

## 构建与测试

- `scripts/build.sh`（Debug）、`scripts/build.sh install`（Release 并装到 /Applications，先正常退出运行中的实例）。
- `scripts/test.sh` 跑单元测试（只覆盖与引擎无关的逻辑）；`scripts/l10n_missing.py` 列出缺中文的字符串。
- 工程由 `ToastPeek/project.yml` 经 XcodeGen 生成，`.xcodeproj` 不入库。
- 签名用本机 Apple Development 证书，不公证。Release 是 universal（arm64 + x86_64），Debug 仅 arm64。产物与缓存在 `~/Developer/Builds/ToastPeek`。

## 数据位置

- `~/Library/Application Support/ToastPeek`：`state.json`（及 `.bak`）、`Favicons`、`shortcuts.json`。
- 日志：`~/Library/Logs/ToastPeek`。
- 每个 Space 一个 `WKWebsiteDataStore`（以 Space 的 `dataStoreID` 为标识），Cookie 互相隔离。

## 调试探针（仅 Debug）

`ToastPeek --automation <目录>` 会读 `<目录>/in.txt` 的命令、把结果写进 `out.txt`；`TOASTPEEK_SUPPORT_DIR` 把数据目录指到临时位置，不碰真实数据。命令列表见 `Support/Automation.swift` 文件头与各 `case`。合成事件不会触发 AppKit 拖拽，拖拽类交互要真人验证。

## 已知限制

- 画中画：macOS 的 WKWebView 没有公开接口。
- 不支持 Chrome 扩展、密码管理器、同步。
- 无辅助功能授权时无法发送真实鼠标事件。
