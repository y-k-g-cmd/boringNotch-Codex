# boringNotch Codex

基于 [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 的非官方独立 fork，保留原有媒体、日历和文件架体验，增加 Codex 任务提醒及双区收纳。

**状态：Beta 测试版。项目仓库：https://github.com/y-k-g-cmd/boringNotch-Codex 。**

维护方针：固定在上游 v2.7.3 基础独立维护，不自动跟进上游 2.8、RC 或 Nightly。自动更新未来仅服务于本 fork 自己发布的版本。

## 功能

- Codex 正在运行、完成和等待人工操作的状态卡片；任务跳转、已识别请求的选择与提交。
- 完成提醒下滑展开、任务边框提示，展示时长可调；连接失败五分钟后停止自动尝试。
- 复制区和剪切区，可拖到区域入口切换收纳方式。内部切区只修改记录，不操作原文件。
- 双指切页、任务浏览区域划分，中英文设置、区域顺序和隔空投送显示开关。

不支持在刘海内自由输入新的后续指令；不接入 Claude Code、WorkBuddy 或额度查询。

## 构建与安装

测试版：[v0.1.0-beta.1](https://github.com/y-k-g-cmd/boringNotch-Codex/releases/tag/v0.1.0-beta.1)，基于构建 271.18，适用 macOS 15+，包含 Apple Silicon 与 Intel。请先阅读 [安装及限制](docs/BETA_INSTALL.md)。这是 ad-hoc 本地签名、尚未经过 Developer ID 签名或 Apple 公证的测试包。

从源码构建见 [BUILDING.md](BUILDING.md)。应用显示版本为 0.1.0，构建号为 271.18。

首次运行时按需要授权 Codex 数据目录、文件夹及媒体等功能。新 fork 使用独立 Bundle ID，原本本地版的设置和安全书签不会自动迁移。

## Codex 兼容性与隐私

Codex 接入使用桌面客户端的非公开本地 IPC，并读取授权目录中的会话索引。它不是 OpenAI 官方 API 集成，客户端更新可能使它失效。未承诺任意 Codex 版本兼容。

目录选择授权范围覆盖整个被选目录；代码不读取 `auth.json`。任务名称、摘要等数据在本机展示；请勿把真实会话数据放进问题反馈或截图。请求操作由用户主动点击提交，不自动代选或审批。详见 [PRIVACY.md](PRIVACY.md)。

## 验证状态

本地 271.18：Finder 直接拖至复制／剪切文字入口、区域高亮、内部切区及拖入区域时的触觉反馈均已由用户实测；异步选择题提交曾验证。源会话路由、过期请求拒绝、流式刷新和重连有回归检查。

多文件剪切、目标完整性、取消拖动、不同 Codex 版本及多显示器仍需补充实测。公开测试版已单独完成依赖解析、完整双架构 Xcode Archive、严格签名检查，以及新身份的首次启动引导和媒体刘海显示检查；尚未完成新身份下的完整 Codex 授权和文件拖放验收。详见 [发布准备记录](docs/PUBLICATION_STATUS.md)。

## 自动更新

当前关闭，已移除上游 appcast 和公钥。计划由本项目 GitHub Pages 提供 `appcast.xml`，GitHub Releases 托管下载包；自己的 Sparkle 更新签名密钥配置完成并实际测试后再开启。详见 [更新发布指南](docs/UPDATES.md)。

## 来源、许可证与致谢

基于上游 v2.7.3 / `16b0f11f51c79d42e27c10d77fd9e53c11410fdb` 修改。不是上游官方版本，也不代表 OpenAI 或 Pinland。Pinland 仅提供交互设计参考，没有包含其代码、图标、截图或宣传素材。

本衍生项目沿用 [GPLv3](LICENSE)，保留原作者版权和 [第三方许可证](THIRD_PARTY_LICENSES)。原说明保存在 [UPSTREAM_README.md](docs/UPSTREAM_README.md)。媒体框架等组件仍按各自许可证分发，详情见 [第三方说明](docs/THIRD_PARTY.md)。

见 [CHANGELOG.md](CHANGELOG.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 与 [SECURITY.md](SECURITY.md)。
