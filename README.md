# HD2 SmoothBoot

开发候选：**3.0.11，已运行舰船和任务场景，完整玩法验收及偶发掉帧定位尚未完成。**
Development candidate: **3.0.11; ship and mission runtime checked, full gameplay acceptance and intermittent hitch diagnosis pending.**

运行游戏后，日志收集器自动生成在
`%LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot\Collect-Logs.bat`。
这是运行配置目录，不是管理器安装目录。关闭游戏后双击，输入 C，日志 ZIP 会出现在桌面。
3.0.11 补收看门狗日志及 MDL 配置；安装包仍不包含独立 BAT 文件。

3.0.10 的深度快照默认关闭修复保持有效（只有 `snapshot=yes` 才开启）。
3.0.11 修正接管新链时漏掉下游首帧的问题，并验证多次接管不会重复执行回调。
相关十二项测试、sb2、sb5、LuaJIT/FFI 审计通过；模拟测试不能代替游戏完整功能验证。

3.0.11 本地候选包在 `dist/HD2-SmoothBoot-3.0.11-candidate.zip`，未上传。
历史 3.0.3 可直接导入管理器的 ZIP 在本地 `dist/HD2-SmoothBoot-3.0.3-dev.zip`，线上在
[测试 Release](https://github.com/YC426/HD2-SmoothBoot/releases/tag/v3.0.3-dev.20261002)。
不要将 GitHub 自动生成的 Source code ZIP 当作模组安装包。

用于调节 Lua 模组初始化和运行调度。后续重点是 C4 快速投掷/引爆、尸体自动清理、
舰船与任务初始化速度，以及常态开销。当前不能宣称这些问题已修复或全部功能兼容。
看门狗重复 hook 计时与自身日志不同，需要真实游戏对照数据解释。

## Local validation / 本地检查

```powershell
python -m pip install -r requirements-dev.txt
python -B work/standalone/build_sb.py --validate-only
python -B work/standalone/test_sb2.py
python -B work/standalone/test_sb3_autopause.py
python -B work/standalone/test_sb5_interdict.py
```

编译审计使用游戏所用的 LuaJIT，拒绝全局 user32 FFI 声明冲突；模拟测试不证明实机
功能。`test_sb6_ffi.py` 是 Windows 集成检查，需要本地已安装的 Clickable Scrollbars
接口作为只读参考；未将第三方模组源码上传。

本次检查：编译/FFI 审计及 sb2、sb3、sb5 通过。保留的旧测试
`test_smoothboot.py` 有 6 项失败（旧节流/错误包裹预期），
`test_sb4_writerhold.py` 要求 2.17.1，遇到本快照 3.0.3 时失败。
这些结果不能认作已通过；后续性能与行为诊断需结合实际游戏重新核对预期。

## Packaging / 构建安装包

先按 THIRD_PARTY_NOTICES.md 提供外部封装工具，再运行
`python -B work/standalone/build_sb.py`。构建不会部署游戏文件。
本快照新增构建工具的 `--validate-only` 入口，运行期 Lua 源码与原工作区逐字节一致。

本仓库具有独立 `.git` 和提交历史。原综合工作区保存实机证据、历史包和第三方只读
参考。后续开发应在本仓库提交；两处不自动同步，部署前须核对源码差异。
