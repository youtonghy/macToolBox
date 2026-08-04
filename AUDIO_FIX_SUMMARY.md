# 音量系统修复总结

## 问题
应用重新打开后播放音频"断断续续"，需要归零到100%再重新调整才能恢复正常。

## 根本原因
1. **路由创建过早**：进程出现就立即创建带 gain 的路由
2. **Watchdog 过于激进**：`outputFrameCount` 停滞无条件判定为失败
3. **诊断基线陈旧**：增益更新后不重置，导致误判

→ 路由在应用音频启动脆弱期被反复 teardown/rebuild

## 已实施的修复

### ✅ P0：核心修复（3个）

| # | 修复内容 | 位置 | 效果 |
|---|---------|------|------|
| 1 | outputFrameCount 停滞检查改为有条件 | AudioRoutingService.swift:942 | 启动期不误判 |
| 2 | 增益更新后重置诊断基线 | AudioRoutingService.swift:1084-1089 | 正确的健康检查基准 |
| 3 | 延迟非100%路由创建 | RoutePlanCompiler.swift:62-72 | 等待 isRunningOutput |

### ✅ P1：增强修复（3个）

| # | 修复内容 | 位置 | 效果 |
|---|---------|------|------|
| 4 | 添加重建冷却期和失败计数 | AudioRoutingService.swift:25-41, 666-729 | 3次上限+5秒冷却 |
| 5 | 清理过期 terminalRouteFailures | AudioRoutingService.swift:459-463 | 防止状态泄漏 |
| 6 | Audio server 重启期间缓存用户输入 | AudioRoutingService.swift:351-357, 915-927 | 不丢失用户操作 |

## 编译状态

```bash
xcodebuild -scheme ToolBox -configuration Debug build
```

✅ **BUILD SUCCEEDED** (P0 + P1)

## 效果对比

### 修复前
```
进程出现 → 立即创建路由 → Tap在启动期安装 → 
帧停滞 → Watchdog误判 → teardown → 重建 → 
再次误判 → 断断续续
```

### 修复后
```
进程出现 → 等待 isRunningOutput → 稳定后创建路由 → 
短暂帧停滞被容忍 → 健康检查使用正确基线 → 
路由稳定运行
```

## 测试建议

1. **基本场景**：设置音量 50% → 关闭应用 → 重新打开 → 播放
   - 预期：音频流畅，不断续

2. **快速启动**：设置音量 30% → 关闭 → 立即打开并快速播放
   - 预期：可能有短暂延迟但不抖动

3. **Audio Server 重启**：设置音量 60% → 拔插音频设备 → 检查
   - 预期：路由自动恢复，音量保持 60%

4. **失败恢复**：触发 3 次路由失败
   - 预期：第 4 次不再重试，避免无限循环

## 待实施（P2）

1. PendingTaskOwnership 超时保护
2. defer 块避免丢失中间值
3. stop() 等待清理完成

---

**状态**：P0 ✅ | P1 ✅ | P2 待实施  
**日期**：2025-01-03  
**详细文档**：./AUDIO_VOLUME_STUTTER_FIX.md
