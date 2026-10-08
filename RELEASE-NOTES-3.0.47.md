# 3.0.47 — development candidate / 开发候选

## What changed / 改动

- Original-chain pass-through: **bounded depth** (`reentry_max`, default 3, clamp 1..16) instead of a boolean latch.
- A legal second dispatch inside the same engine call is forwarded and returns the chain's values; a runaway loop is still broken, counted (`M.reentry_cycles`) and logged with depth + cap.
- Arity, trailing nils and error identity preserved on every path.

## Why / 原因

3.0.46 returned **nothing** to a second dispatch. On 2026-10-06 the deployed 3.0.46 candidate was followed by in-game symptoms: ESC menu opening only after a long stall, joining another host's mission ending back on your own ship ("host left" while the host was playing), and the ESC quit action never completing. The priority loaders (`#14 mods/skyeshade/hd2runtime`, `#15 mods/junze/hd2_scanner`, both above `#13 mods/codex/smoothboot`) reach the chain through this shell, so the swallow sat in their hot path.

## Verification / 验证

- Offline: `test_chain_reentry_guard.py`, `test_priority_loaders_above.py`, `test_hd2runtime_scheduler.py` pass; full suite 114 tests with one **pre-existing** unrelated import error (`test_sb4_writerhold.py` pins the old `2.17.1` source version).
- Recorded open finding: a loader above us is entered **twice per engine frame** (engine entry plus the governor driving `head_above`).
- **Not live-accepted.** In-game A/B (3.0.45 vs 3.0.47) still has to be run by the user.
