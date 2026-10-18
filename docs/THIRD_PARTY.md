# 来源及第三方组件

上游：TheBoredTeam/boring.notch，基础提交 `16b0f11f51c79d42e27c10d77fd9e53c11410fdb`，原作者和原许可证保留。修改日期：2026-10-17 至 2026-10-18；定制内容见 CHANGELOG。本地上游输入是浅克隆，本候选保留其中唯一可用的基础提交；没有声称已获取完整历史。GitHub Fork 创建后保留其服务端上游关联，推送前应检查分支关系。没有把整个工程声明为原创。

`BUILD_DEPENDENCIES.json` 与 `Package.resolved` 记录实际依赖修订；依赖各自的许可不会因主项目 GPLv3 而消失。`THIRD_PARTY_LICENSES` 保留了随上游分发的声明，包括 MediaRemoteAdapter 的 BSD 3-Clause 条款。SPM 组件在解析后还应检查各自 LICENSE，正式二进制分发前整理需要附带的声明。

`mediaremote-adapter/MediaRemoteAdapter.framework` 是沿用上游已提交的预编译组件；上游来源与构建信息见 https://github.com/ungive/mediaremote-adapter 和 `mediaremote-adapter` 目录。源码发布候选没有声称已逐条完成全部二进制依赖许可证审计，也没有声称该框架可由本仓库单独完整重建。发布二进制前应核对适用许可、来源、重签步骤及对应构建材料。

Pinland 为交互设计参考，不包含其源码或宣传图片；OpenAI、Codex 及 boringNotch 的名称不表示官方背书。

已从全部 12 个 SPM 依赖的锁定提交读取顶层许可文件，副本及修订列表见 [third-party](third-party/README.md)。这些材料来自精确提交，即使本机 checkout HEAD 不同也不使用另一个版本的许可替代。
