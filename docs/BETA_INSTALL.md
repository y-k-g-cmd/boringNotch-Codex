# 测试版安装

适用 macOS 15 或更高版本。下载包同时包含 Apple Silicon 和 Intel 代码；本轮实际运行环境为 Apple Silicon，Intel 未做硬件实测。

## 安装与首次启动

1. 从本仓库 GitHub Releases 选择对应版本的测试包，核对同页 SHA256SUMS.txt；尚未上传的本地候选包以维护者提供的文件和校验值为准。
2. 打开 DMG（或解压 ZIP），将 `boringNotch Codex.app` 拖入“应用程序”。先退出其他 boringNotch 实例，再启动本 fork。
3. 这是 ad-hoc 本地签名的测试版，尚无 Developer ID 签名及 Apple 公证。macOS 可能阻止首次运行。仅在核对来源和校验值后自行决定是否信任；系统提示的说明见 [Apple 官方指南](https://support.apple.com/zh-cn/102445)。不需要关闭整个系统的 Gatekeeper 或 SIP。
4. Codex 功能需要在应用内主动选择并授权 Codex 数据目录。授权包含整个所选文件夹；代码不读取 auth.json。不要把密码或令牌提交到问题反馈。

本 fork 使用独立应用身份，不自动继承原版或旧本地测试版的偏好、收纳记录及授权。无需复制认证文件。自动更新关闭，后续测试包从本仓库 Releases 手动下载。

## Beta 3 新功能与权限

- 通过菜单栏跑猫／额度打开新的系统与用量浮窗，点击刷新可看到加载与失败状态。额度查询使用本机已安装的 Codex CLI。
- 查词默认快捷键 Control＋Option＋D；可在设置 → 快捷键调整。选中文字读取需要辅助功能授权；无选中文字时可输入查询。本机系统词库需先下载。
- 替换系统音量／亮度提示及手机遥控翻页需要辅助功能授权。公开版与本地测试版身份不同，旧授权不会自动继承；授权应用应以当前安装路径为准，更新后有时需重新开启。
- 手机翻页入口：设置 → 通用 → 阅读遥控。只在手动启动后监听局域网；手机与 Mac 连接同一可信 Wi-Fi，保持 Mac 唤醒，在图书中打开 EPUB 正文。可能需要允许本地网络／防火墙入站连接。详见 [手机翻页说明](https://github.com/y-k-g-cmd/boringNotch-Codex/blob/main/docs/PHONE_READER.md)。
- 额度异常提醒在设置 → Codex 中独立开关；只表示可能连接或登录异常，不等同于确认 Codex 断联。

## 本轮验证及限制

本地功能版已实测 Finder 收纳、失败拖放收起、移除保留原文件、媒体键提示、快捷键输入查词及底边动画、iPhone Books 翻页、新用量浮窗和刷新反馈。三次模拟额度失败通过真实刘海链路仅提醒一次；测试期间 Codex 保持连接。

这些是本地身份的实测结果，不替代公开身份下的首次授权和完整 GUI 验收。公开包另行构建、检查双架构与严格签名、校验 DMG 和挂载内容。

Codex 使用非公开本地 IPC，客户端更新可能使接入失效。Intel、多显示器、复杂多文件剪切和跨卷移动仍需更多实测。触觉反馈受系统和硬件状态影响，没有震动强度参数。手机翻页使用未加密局域网 HTTP，只用于可信网络；二维码等同控制凭证，不要公开分享。

## 来源与许可

版本、源码提交和计划 tag 见随包 `BUILD-INFO.json`；本地候选包可能尚未上传对应 tag。仓库：https://github.com/y-k-g-cmd/boringNotch-Codex

基于上游 v2.7.3 的独立 fork，沿用 GPLv3；非上游官方发行，亦非 OpenAI 官方产品。下载包随附 LICENSE、THIRD_PARTY_LICENSES、精确依赖许可副本和 BUILD-INFO.json；同一 Release 提供对应源码归档。依赖修订见 BUILD_DEPENDENCIES.json 和 Package.resolved。
