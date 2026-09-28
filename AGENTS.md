# AGENTS.md

macOS 菜单栏常驻工具箱（Swift，macOS 14.0+）。工程文件由 XcodeGen 从 `project.yml` 生成，源码在 `Sources/`，测试在 `Tests/`。

## Worktree 工作流（必须遵守）

**所有复杂任务必须在 git worktree 中完成，完成后再 handoff 回主工作区并清理。** 简单修正（typo、单行 bug 修复、文档微调、单行配置改动）可直接在主工作区进行。

需要 worktree 的「复杂任务」包括但不限于：

- 新功能或跨多个文件的改动
- 行为变更、公共接口 / 配置 / schema 修改
- 重构、迁移、依赖升级
- 任何需要构建或跑测试验证的改动

### 流程

```bash
# 1. 创建 worktree（固定放在 .worktrees/ 下，该目录已被 gitignore）
git worktree add .worktrees/<task-name> -b task/<task-name>

# 2. 在 worktree 内完成实现、构建、测试，按任务粒度提交
cd .worktrees/<task-name>

# 3. Handoff：回到主工作区合入任务分支
cd <repo-root>
git merge --no-ff task/<task-name>        # 或按需 cherry-pick / rebase

# 4. 验证通过后清理 worktree 和分支
git worktree remove .worktrees/<task-name>
git branch -d task/<task-name>
```

### 规则

- worktree 命名 `.worktrees/<task-name>`，分支命名 `task/<task-name>`，两者保持一致。
- worktree 内的改动必须先提交（或至少 `git diff` 可完整导出）再 handoff，不允许留一堆未提交改动就删 worktree。
- 合入前在主工作区跑一遍构建 / 测试确认无冲突、无回归，再清理。
- 分支已合入用 `git branch -d`；确认丢弃才用 `-D`。
- 残留 worktree 用 `git worktree list` 检查、`git worktree prune` 兜底清理。
- 多 worktree 并行时注意：每个 worktree 会重新跑 `xcodegen generate`，`ToolBox.xcodeproj` 不提交（gitignored），互不干扰。

## 构建与测试

```bash
brew install xcodegen        # 仅需一次
./build.sh                   # 校验 OCR 运行时 + xcodegen + Release 构建 + 同步到 /Applications/ToolBox.app 并启动
OPEN=0 ./build.sh            # 只构建不启动
```

- 工程生成：`xcodegen generate`（`project.yml` 是唯一事实来源，不要直接改 `.xcodeproj`）
- 单元测试：`xcodebuild test -scheme ToolBox -destination 'platform=macOS'`（覆盖 `ToolBoxTests`、`ToolBoxCLITests`；`BuildScriptTests`/`OCRWorkerTests` 见 `Tests/`）
- 构建产物：`build/Build/Products/Release/ToolBox.app`

## 代码约定

- Swift，遵循现有文件风格；新增工具函数前先搜是否已有实现，避免重复逻辑。
- 界面字符串走现有本地化机制（简中 / 繁中 / 英语），不要硬编码用户可见文案。
- 行为、命令、配置或 public API 变化时更新 `README.md` / `docs/` 中相应文档。
