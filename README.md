# HD2 SmoothBoot

开发源码快照：**3.0.3，后续优化与完整实际游戏验收尚未完成。**
Development snapshot: **3.0.3; pending optimization and full in-game acceptance.**

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
