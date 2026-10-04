# HD2 SmoothBoot

开发候选 **3.0.46** 已补上原链直通路径的重入保护，并通过两套 LuaJIT 的递归
回归及 HD2Runtime 0.28.1 原始调度器回放。实机崩溃归因和 Runtime 性能验收仍待
完成；详见 [候选说明](RELEASE-NOTES-3.0.46.md)。下方 3.0.45 验收记录属于历史版本。

[English](README.md) / 简体中文

SmoothBoot 是 Helldivers 2 Lua 模组的**链条调度器（chain governor）**，运行在 Bingus 共享加载器（API 1）之上。
HD2 的所有 Lua 模组共用同一条 `update` 链；SmoothBoot 只包一层，决定每个回调实际多久跑一次，
把已知的 FFI 写入型模组在引擎重建表期间暂时移出链条，并保证帧关键（绘制类）回调每帧都执行。

**它是一个模组，不是加载器。** 它跑在你已有的 API 1 加载器之上，不改动任何第三方文件或配置。

```
mods/... → 你的 HUD 模组 → 另一个模组 → SmoothBoot（调度器）→ 链条其余部分
```

**当前版本：3.0.45**（维护版，2026-10-04）。见[发布说明](RELEASE-NOTES-3.0.45.md)与[变更记录](CHANGELOG.md)。

## 状态：哪些已验证，哪些没有

结论的可信度不一致，所以逐条写清，而不是含糊带过。

| 结论 | 依据 |
|---|---|
| 能在 46 个模组的链里正常加载运行 | 实机日志：`ready v3.0.45`、链清单 44 个链接；连续 530.7 秒采集中 Smooth 回调错误计数为 0 |
| 不影响游戏功能 | 用户报告正常：任务、死亡/复活、返舰船、军械库、Esc、舰船快捷键（2026-10-04） |
| 离线门槛 | 两套 LuaJIT 运行库共 106 项回归检查 + 5 个独立脚本；源码若不能通过 LuaJIT 编译或声明了 `user32` 符号，构建直接拒绝打包 |
| 性能归属 | 被托管的写入模组工作现在显示为 `模组名 [SB gate]`，不再算到 SmoothBoot 头上；用**未改动**的 Mod Lag Watchdog 源码重放，合成的 79.09 ms/s 被还给原属模组 |
| SmoothBoot 自身开销 | 同一局内 `enabled=yes` 与 `enabled=no` 配对对照：两种状态都是 3.0–3.4 ms/s，约合 128 FPS 帧预算的 0.04%。性能面板给我们的**开局行**实测高估 16–27 倍（每道门被重复计数） |
| 片头前黑屏 | 实测**与模组、加载器都无关**：前 12 秒进程只用了 0.8 秒 CPU、读盘 44 MB（在等反作弊/DRM）；加载器日志行全部在 +17.5 秒才出现 |

**未验证、也不做承诺：** C4 持械帧率修复（剩余差距已转报 C4 原作者）、缩短黑屏、与所有模组组合的兼容性、
逐模组独立调度、数小时长时运行、多人模式。

## 安装

1. 需要 API 1 加载器：**MDL 1.4.4+** 或 **Bingus Shared Loader v15+**。
2. 从 [Releases](https://github.com/Puipipi/HD2-SmoothBoot/releases) 下载 `HD2-SmoothBoot-3.0.45.zip`，
   导入模组管理器（HD2 Arsenal、MDL 等）。**不要**用 GitHub 自动生成的 *Source code* ZIP，那不是可安装的 addon。
3. **只启用一个** SmoothBoot，并把它放在模组列表**最底部**（最低优先级），这样它才能包住整条链。
4. 部署。配置位于 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot\config.txt`，
   首次运行时生成，之后不会被覆盖。

`Collect-Logs.bat` 会在首次运行时生成在 `config.txt` 同目录（收集日志 + 交互式 `exclude=` 选择器）。
安装 ZIP 里**故意不含**裸露的 `.bat`/`.ps1`/`.exe`。

## 配置

所有键都可选；不写就用自带默认值。多数键在游戏运行中也会生效（约每 10 秒重读一次）。

| 键 | 默认 | 含义 |
|---|---|---|
| `enabled` | `yes` | 总开关。`no` 时所有回调原样转发（包装层仍在）。 |
| `throttle` | `auto` | `auto` 自适应跳帧；`yes` 始终允许跳；`no` 从不跳。 |
| `busy_ms`、`busy_pct`、`idle_ms`、`max_skip` | `12`、`30`、`1.5`、`2` | 只有超过 `max(busy_ms, 帧时间的 busy_pct%)` 才开始跳；链条变便宜后释放；连续最多跳 `max_skip` 帧。 |
| `writers` | 12 个片段 | 已知写 FFI 结构的模组；引擎重建表期间被移出 update 链。留空 = 不托管任何写入模组。 |
| `writer_release_s`、`writer_stagger_s`、`writer_norelease` | `10`、`8`、`m103_frv` | 开局托管时长、放行的最小间隔，以及永不释放的写入模组。托管的保守性是有意的：在表重建期间放行正是客户端崩溃的原因。 |
| `exclude` | `lte/helmet_cape_passives` | 逗号分隔的**不托管**模组片段。只有位于 SmoothBoot **下方且在 update 链上**的模组才能被排除（见"限制"）。 |
| `ui_chunks`、`ui_mods` | 见文件 | 额外指定为帧关键的片段（HUD/绘制）。有自动识别后通常不需要。 |
| `boot_pause_s`、`boot_skip`、`boot_s`、`grace_s`、`boot_freeze_s` | `10`、`1`、`0`、`60`、关 | 启动期行为：引擎重建期间让已知状态机停住、加载宽限期内不跳帧、可选的完全冻结。 |
| `c4_read_pool` | `yes` | 已核对的 C4 1.11 原生读取缓冲复用（每次仍是新读取，不缓存数据）。 |
| `c4_context_batch`、`c4_input_batch`、`c4_native_batch`、`c4_idle_batch` | `no` | 可选：C4 上下文/按键/原生校验与空闲装填读取的分块。每一项都与原始字节码对照验证，关闭或加入排除名单即还原原实现。 |
| `c4_read_profile`、`c4_cpu_profile` | `no` | 诊断用。CPU 采样会清空 JIT 轨迹，开着它不要比较帧率。 |
| `gc_pause`、`gc_stepmul` | `400`、`0` | 可选的全局 GC 调参；为 0 时使用引擎默认。 |
| `snapshot`、`diag` | `no`、`no` | 额外诊断：闭包图快照，以及每 30 秒的 `diag` / 自计时行。 |
| `peer_suspend` | `yes` | 检测到另一个链管理器（MDL）时，不干预它的设置。 |

## 限制与"正常"日志行

- **整链保护，不是逐模组调度。** 一旦识别到绘制类回调，它所在的**整条链**每帧都执行。这是刻意的：
  另一种做法是猜链条里哪个模组才是渲染方。
- **`exclude=` 管不到所有模组。** 它只对 SmoothBoot **下方且在 update 链上**的模组生效。
  挂在菜单、原生渲染或自己计时器上的模组不经过 update 链，无法用这种方式静默；日志会把它们单独列为
  `chain sources NOT managed`。
- **运行期重包 `update` 的模组可能待在我们上方。** 只有当后来者把我们保存在**函数 upvalue**里时，
  我们才能把它接管回来。若它的"上一个钩子"存在别处（表字段、原生回调），日志会写明，
  且**调整顺序也没用**——我们不会硬抢这个槽位，因为历史上那样做会把别的模组挤出链条。
- **这些是正常日志，不是错误：** `rehooks: <模组> xN`（该模组反复重装自己的钩子，我们重新接管）、
  `first frame reached, head=<模组>`（有东西包在我们上方）、`<模组> [SB gate]`（被托管写入模组的工作，归属正确）。
- 写入托管让启动期偏保守。源码注释里记录过一次任务内测量：1 秒放行 → 33 FPS，8 秒放行 → 69.8 FPS；
  自带默认值停在保守的一端。

## 离线检查（不需要游戏）

```powershell
python -B work/standalone/build_sb.py --validate-only          # LuaJIT 编译 + 无 user32
python -m unittest discover -s work/standalone -p 'test_*.py'  # 106 项（test_sb4_writerhold 针对 2.17.1，预期是导入错误）
python -B work/standalone/test_sb2.py                          # 写入托管 / 自动暂停回归
python -B work/standalone/test_sb3_autopause.py
python -B work/standalone/test_sb5_interdict.py
python -B work/standalone/test_startup_defaults.py
python -B work/standalone/test_sb6_ffi.py                      # 需要本机有 Clickable Scrollbars 作为只读参考
```

模拟与离线检查不是实机验收；它们是入场券，不是证据。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `work/standalone/smoothboot.lua` | 整个模组：纯 Lua 源码，无编译原生代码。 |
| `work/standalone/build_sb.py` | 构建门槛 + 打包器（LuaJIT 或 `user32` 规则不过就拒绝打包）。 |
| `work/standalone/test_*.py` | 离线测试；`fixtures/` 存放用于差分测试的原始字节码摘录。 |
| `docs/automatic-throttling.md` | 自适应跳帧如何决策，以及为什么需要放行门。 |
| `dist/` | 构建好的、可直接导入管理器的 ZIP。 |
| `RELEASE-NOTES-*.md` | 各版本发布说明。 |
| `CHANGELOG.md` | 逐候选版本的历史记录。 |
| `THIRD_PARTY_NOTICES.md` | 第三方依赖及其状态。 |

## 反馈问题

运行 `Collect-Logs.bat`（在 `config.txt` 同目录），把桌面上生成的 ZIP 附上。里面有
`SmoothBoot.log`、watchdog 日志、你的 `config.txt` 和模组列表——判断"调度问题"还是"无关问题"所需的四样东西。
另外请说明 SmoothBoot 是否在你模组列表的最底部，以及你使用的加载器版本。

## 来源与致谢

- 可选 C4 适配器使用的 `AimInputState`、`ContextReader` 与 C4 `AutoReload` 契约改编自 MIT 许可的
  [HD2 C4 Quick Actions](https://github.com/etxp/HD2-C4-Quick-Actions)，其版权与许可声明保留在运行源码中。
- 性能归属测量使用**未改动**的 Mod Lag Watchdog 源码，未修改任何第三方文件。
- Bingus addon 打包辅助工具属第三方，本仓库**有意不重新分发**——见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可

本仓库未对本项目自身代码授予任何许可；见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
重新分发或打包前请先联系作者。
