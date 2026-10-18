# 从源码构建

## 前置条件

- macOS 与完整 Xcode；首次启动并接受许可、安装组件需由使用者本人完成。
- 本地功能版 271.15 和此公开候选版均在 Xcode 27.1 完成完整构建；公开候选版从新目录解析公开依赖，严格签名检查通过，不承诺旧版 Xcode 可用。
- 已提交 `Package.resolved` 和 `BUILD_DEPENDENCIES.json`；首次依赖下载需要网络。不要添加个人 SwiftPM 镜像配置。

## 本地测试构建

打开 `boringNotch.xcodeproj`，选择 `boringNotch` scheme 和 My Mac，然后 Build。或者在正常 macOS 终端执行：

```sh
bash scripts/build-local.sh
```

脚本使用 ad-hoc 本地签名，输出到 `.local-build/Xcode/Build/Products/Debug/boringNotch.app`。默认 Bundle ID 为 `io.github.y-k-g-cmd.boringnotchcodex`，XPC helper 随主应用 ID 定位。需要改变发布者时同步修改主程序和 helper 的身份。

本地配置保留沙箱及 Hardened Runtime。`boringNotch.local.entitlements` 为加载已有媒体框架启用应用级 `disable-library-validation`，不是系统级关闭安全检查。正式分发应重签嵌入框架，使用自己的 Developer ID 和公证，并重新评估此例外。

不要同时运行原版与本 fork；首次试用可先退出其他刘海实例。沙箱目录和书签与旧本地测试版隔离。

## 检查

```sh
python3 scripts/check-public.py
bash scripts/check-update-config.sh
bash scripts/check-core.sh
bash scripts/check-interactions.sh
bash scripts/check-stream.sh
bash scripts/check-shelf.sh
```

这些检查使用合成数据或隔离状态。不要在 CI 运行 `LiveIPCCheck.swift`；它会尝试连接运行中的 Codex。文件书签检查若缺少 ScopedBookmarksAgent 会明确跳过；这不是完整 Finder 拖放测试。

GitHub 基础检查只做源码审查；完整 macOS 检查与构建可手动触发，不会自动签名、上传或发布 Release。

## 正式发行

先阅读 `docs/UPDATES.md` 和 `docs/PUBLISHING.md`。更新签名私钥、Apple 签名私钥及令牌不能进入 Git；每个二进制版本须提供与之对应的源码 tag 和构建材料。当前不提供已经过公证的正式发行包。
