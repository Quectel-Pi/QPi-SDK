# Quectel M2 SDK Skills（AI 技能包）

本目录为 Quectel M2 SDK 配套的 **AI 技能**（SKILL.md），供 AI 助手（VS Code Copilot / Claude Code 等）按需加载，覆盖 SDK 全生命周期操作。

## 技能列表

| 技能 | 用途 | 目录 |
|------|------|------|
| **sdk-build** | 编译 app / kernel / overlays / 完整固件 | `sdk-build/` |
| **sdk-flash** | rkdeveloptool 烧录固件/分区 | `sdk-flash/` |
| **sdk-overlays** | 设备树 overlay 编写/编译/打包 | `sdk-overlays/` |
| **sdk-board-test** | 上板验证 / 冒烟测试 / ADB 部署 | `sdk-board-test/` |

## 使用方式

AI 助手通过 `description` 中的关键词自动匹配并加载对应 skill。
例如用户说「编译固件」→ 触发 `sdk-build`；「烧录板子」→ 触发 `sdk-flash`。

## 与构建脚本的关系

```
用户需求 ──→ AI 加载 Skill ──→ 调用 SDK 脚本 / 工具
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
            tools/build-*.sh    rkdeveloptool      adb
             (编译/打包)        (烧录)             (上板验证)
```

## 对齐《QPi 开发者罗盘》

本文档的 Skill 层对应罗盘设计中的 AI Skill 能力：

| 罗盘 Skill | 本 SDK 对应 |
|-----------|------------|
| SDLC 编排器 | （多 skill 组合：build → flash → board-test） |
| 需求评估 | （文档/模板查询） |
| 驱动/系统适配 | `sdk-overlays`（外设启用/禁用） |
| Bug 定位 | `sdk-build`（编译错误分析）+ 外设知识库 |
| 上板验证 | `sdk-board-test` |
| 竞品开源调研 | （非 SDK 范围） |

## 新增 Skill 规范

1. 创建目录 `skills/<skill-name>/SKILL.md`
2. 前置 YAML frontmatter 必须包含：
   - `name`：小写连字符命名，与目录名一致
   - `description`：**关键词丰富**的触发描述（含中英文触发词）
   - `metadata.version`：语义化版本
3. 正文用「何时使用 → 工作流程 → 常见坑」结构
