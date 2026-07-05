# macOS 后台 CPU / 耗电问题修复说明

本文档记录 FlClash 在较新 macOS（尤其 macOS 26/27）上、开启 TUN 虚拟网卡后，后台长时间占用 40–50% CPU、明显耗电的问题成因与修复方案。

## 现象

- 代理已连接、TUN 已开启，主窗口关闭后仅保留菜单栏托盘图标
- 活动监视器中 `FlClash` 主进程 CPU 持续偏高（约 40–50%），而非接近 0%
- 笔记本续航明显下降
- 与上游 issue [#1644](https://github.com/chen08209/FlClash/issues/1644) 描述一致

## 根因概览

问题并非单一 bug，而是多条**每秒执行的热路径**叠加：

| # | 问题 | 频率 | 主要影响 |
|---|------|------|----------|
| 1 | 托盘标题重复调用 `setTitle` | 每秒 | macOS `NSStatusItem` 强制重绘 |
| 2 | `trayTitleState` 无条件订阅流量 | 每秒 | 触发托盘监听器与 Dart 侧更新 |
| 3 | 隐藏窗口时仍轮询流量/运行时长 | 每秒 2 次 IPC | 跨进程通信 + Provider 更新 |
| 4 | 高频 IPC 写日志 | 每秒 4 条日志 | 日志列表复制与 UI 刷新 |
| 5 | TUN 下每条连接推送都解析 JSON | 每条连接 | 窗口不可见时仍解析请求列表 |
| 6 | 原生 `NSTextField` 触发重绘自循环 | 每次 `setTitle` | 多显示器场景下菜单栏 CPU 风暴 |

其中 **1、2、6** 与菜单栏托盘直接相关，是 macOS 上最突出的瓶颈；**3–5** 在窗口隐藏、TUN 高连接数时进一步放大开销。

---

## 修复详情

### 1. 托盘标题去重（Dart）

**文件：** `lib/common/tray.dart`

**问题：**  
`updateTrayTitle()` 在 macOS 上每秒被调用。即使 `showTrayTitle = false`（标题应为空），仍会调用 `trayManager.setTitle('')`。在较新 macOS 上，**即使传入相同字符串**，`NSStatusItem.setTitle` 也会触发完整的菜单栏 replicant 重绘，导致 CPU 被持续占用。

**修复：**

- 增加 `_lastTrayTitle` 缓存上一次写入的标题
- 新标题与缓存相同时，直接 `return`，不调用原生接口
- `destroy()` 时重置缓存，避免托盘销毁后状态残留

**效果：**

- 关闭「显示托盘流量」后，只在切换设置时清空一次标题，之后零调用
- 开启显示时，仅在网速字符串实际变化时才更新

---

### 2. 关闭托盘流量时切断数据订阅（Dart）

**文件：** `lib/providers/state.dart`

**问题：**  
`trayTitleState` provider 无条件 `watch(trafficsProvider)`，而流量数据每秒更新一次。即使 `showTrayTitle = false`，该 provider 仍每秒重建，`TrayManager` 中的 `ref.listenManual(trayTitleStateProvider, …)` 也会每秒触发，进而调用上面的 `updateTrayTitle()`。

**修复：**

```dart
if (!showTrayTitle) {
  return const TrayTitleState(showTrayTitle: false, traffic: Traffic());
}
// 仅在 showTrayTitle 为 true 时才订阅 trafficsProvider
```

**效果：** 关闭托盘网速显示后，整条「流量 → provider → 监听器 → setTitle」链路完全静默。

---

### 3. 窗口隐藏时暂停每秒轮询（Dart）

**文件：** `lib/providers/action.dart`、`lib/common/render.dart`

**问题：**  
`SetupAction._handleStart()` 里有一个 `Timer.periodic(Duration(seconds: 1))`，每秒调用 `updateRunTime()` 和 `updateTraffic()`。每次调用都会通过 socket/FFI 向 Go 内核发起 IPC，并更新 Riverpod 状态。主窗口隐藏、用户也看不到这些数据时，轮询仍在空转。

**修复：**

- 在 `Render` 类上暴露 `bool get isPaused`（窗口隐藏时 `_isPaused == true`）
- 定时器回调中增加条件：若 `render?.isPaused == true` 且 `showTrayTitle == false`，则跳过本轮更新
- 窗口重新显示后，下一秒自动恢复轮询

**效果：** 典型后台场景（关窗口、不显示托盘网速）下，每秒减少 2 次 IPC 往返及关联的 Provider 更新。

**注意：** 若用户开启了「显示托盘网速」，隐藏窗口时仍会轮询流量（托盘标题需要数据）。

---

### 4. 静默高频 IPC 日志（Dart）

**文件：** `lib/core/interface.dart`

**问题：**  
`CoreHandlerInterface._invoke()` 对每个 IPC 方法在调用前后各写一条日志。`getTraffic` 与 `getTotalTraffic` 每秒各被调用一次，合计 **每秒 4 条日志**。日志写入会复制最多 500 条的 `FixedList`，并触发日志 UI 相关状态更新，形成额外 CPU 开销。

**修复：**

- 定义 `_silentMethods` 集合，包含 `ActionMethod.getTraffic` 与 `ActionMethod.getTotalTraffic`
- 上述方法的 `onStart` / `onEnd` 日志回调直接跳过
- 其他 IPC 方法日志行为不变

---

### 5. 窗口隐藏时跳过连接推送解析（Dart）

**文件：** `lib/core/event.dart`

**问题：**  
TUN 模式下，Go 内核每建立一条连接就推送一条 `CoreEventType.request` 事件。Dart 侧无条件执行 `TrackerInfo.fromJson(event.data)` 并更新 500 条容量的请求列表。主窗口隐藏、连接页不可见时，这些解析与状态写入纯属浪费。

**修复：**

- 在 `request` 事件分支中，若 `render?.isPaused == true`，直接 `break`，不解析 JSON
- 窗口可见时行为与修复前完全一致

---

### 6. 原生托盘重绘自循环（Swift，fork 专用）

**文件：** `plugins/tray_manager/packages/tray_manager/macos/Classes/TrayIcon.swift`

**问题：**  
`tray_manager` 插件用 `NSTextField` 显示托盘网速文字。在较新 macOS、尤其开启「显示器具有独立空间」的多显示器配置下，`NSTextField` 的绘制会经过 AppKit appearance 机制，触发 `NSStatusItem` replicant 反复标记 dirty → 重绘 → 再 dirty 的自循环。即使 Dart 侧减少了 `setTitle` 调用，开启托盘网速且外接显示器时仍可能出现 CPU 峰值。

**修复：**

- 新增自绘 `SpeedTextView`（继承 `NSView`，在 `draw(_:)` 中绘制 attributed string），替代 `NSTextField`
- `setTitle()` 仅在文字可见性变化（空 ↔ 非空）时调用 `button.sizeToFit()`，避免每秒触发布局
- `setImage()` 同理，仅在图标从隐藏变为显示时 `sizeToFit()`

**说明：** 此改动位于 `tray_manager` 子模块。上游 FlClash 仍以 git submodule 引用原作者仓库，**官方 PR（`fix-macos-cpu-drain` 分支）仅包含上述 1–5 的 Dart 修复**。完整修复需在本 fork 中将 `tray_manager` 以内联目录形式保留该补丁，或单独向 `chen08209/tray_manager` 提 PR。

---

## 未改动的相关项

### `find-process-mode`

Clash 配置中的「查找进程」(`find-process-mode`) 在 TUN 下会增加内核侧开销。这是**用户可配置项**，无需改代码：在 **设置 → 常规** 中关闭「查找进程」即可进一步降低 CPU。

### 上游 `tray_manager` submodule

官方仓库的 `.gitmodules` 仍指向 `chen08209/tray_manager`。Dart 侧修复（1–5）可独立合入上游；原生补丁（6）需子模块仓库配合更新。

---

## 修改文件清单

| 文件 | 类型 | 说明 |
|------|------|------|
| `lib/common/tray.dart` | Dart | 托盘标题去重 |
| `lib/providers/state.dart` | Dart | 条件订阅流量 |
| `lib/providers/action.dart` | Dart | 隐藏窗口时暂停轮询 |
| `lib/common/render.dart` | Dart | 暴露 `isPaused` |
| `lib/core/interface.dart` | Dart | 静默高频 IPC 日志 |
| `lib/core/event.dart` | Dart | 隐藏窗口时跳过 request 解析 |
| `plugins/tray_manager/.../TrayIcon.swift` | Swift | 自绘文本视图、减少 layout（fork 专用） |

Dart 侧合计约 **38 行**改动，均为最小 diff，不改变窗口可见时的功能行为。

---

## 验证方法

1. 安装修复版 DMG，连上节点并开启 TUN
2. 关闭「显示托盘流量」（或开启以分别验证两条路径）
3. 关闭主窗口，保留托盘图标
4. 打开 **活动监视器**，观察 `FlClash` 进程 CPU

**预期：**

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 关窗口、不显示托盘网速 | ~40–50% CPU | 接近 0% |
| 关窗口、显示托盘网速 | 偏高 | 明显降低；网速变化时才更新标题 |
| 主窗口打开 | 正常 | 与修复前一致 |

---

## 分支与 PR

- **本 fork 完整修复：** 分支 `macos-battery-fix` / `main`（含 Dart + Swift + CI）
- **上游 PR（仅 Dart）：** 分支 `fix-macos-cpu-drain` → `chen08209/FlClash`

---

## 架构示意

```
每秒定时器 (SetupAction)
    ├─ updateRunTime()  ──IPC──► Go 内核
    └─ updateTraffic()  ──IPC──► Go 内核
            │
            ▼
    trafficsProvider 更新
            │
            ▼
    trayTitleStateProvider  ──listen──► Tray.updateTrayTitle()
            │                                    │
            │                                    ▼
            │                          trayManager.setTitle()  [macOS 原生]
            │                                    │
            │                                    ▼
            │                          NSStatusItem 重绘 (CPU 热点)

TUN 连接建立
    └─ CoreEventType.request ──► TrackerInfo.fromJson() ──► requestsProvider
```

修复策略：在**数据无人消费**或**输出值未变化**时，截断上述链路的各环节，避免无意义的 IPC、状态更新与原生 UI 重绘。
