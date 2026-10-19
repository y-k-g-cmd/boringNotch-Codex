# 测试版安装

适用 macOS 15 或更高版本。下载包同时包含 Apple Silicon 和 Intel 代码；本轮实际运行环境为 Apple Silicon，Intel 未做硬件实测。

## 安装与首次启动

1. 从本仓库 GitHub Releases 选择对应版本的测试包，核对同页 SHA256SUMS.txt；尚未上传的本地候选包以维护者提供的文件和校验值为准。
2. 打开 DMG（或解压 ZIP），将 `boringNotch Codex.app` 拖入“应用程序”。先退出其他 boringNotch 实例，再启动本 fork。
3. 这是 ad-hoc 本地签名的测试版，尚无 Developer ID 签名及 Apple 公证。macOS 可能阻止首次运行。仅在核对来源和校验值后自行决定是否信任；系统提示的说明见 [Apple 官方指南](https://support.apple.com/zh-cn/102445)。不需要关闭整个系统的 Gatekeeper 或 SIP。
4. Codex 功能需要在应用内主动选择并授权 Codex 数据目录。授权包含整个所选文件夹；代码不读取 auth.json。不要把密码或令牌提交到问题反馈。

本 fork 使用独立应用身份，不自动继承原版或旧本地测试版的偏好、收纳记录及授权。无需复制认证文件。自动更新关闭，后续测试包从本仓库 Releases 手动下载。

## 本轮验证及限制

本地 271.18 的 Finder 双入口、内部切区及拖动进入区域时的触觉反馈已实测确认。271.20 的失败拖放后高亮清理与收起、271.21 的悬停移除且保留原文件也已由用户实测确认。Beta 2 DMG 的校验和及挂载后的应用严格签名检查通过。公开身份另行构建并做启动及基础界面检查；不把旧身份的文件授权与 GUI 验收视为新身份的完整验收。

Codex 使用非公开本地 IPC，客户端更新可能使接入失效。Intel、多显示器、复杂多文件剪切和跨卷移动仍需更多实测。触觉反馈受系统和硬件状态影响，没有震动强度参数。

## 来源与许可

版本、源码提交和计划 tag 见随包 `BUILD-INFO.json`；本地候选包可能尚未上传对应 tag。仓库：https://github.com/y-k-g-cmd/boringNotch-Codex

基于上游 v2.7.3 的独立 fork，沿用 GPLv3；非上游官方发行，亦非 OpenAI 官方产品。下载包随附 LICENSE、THIRD_PARTY_LICENSES、精确依赖许可副本和 BUILD-INFO.json；同一 Release 提供对应源码归档。依赖修订见 BUILD_DEPENDENCIES.json 和 Package.resolved。
