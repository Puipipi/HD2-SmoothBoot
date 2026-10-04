# HD2 SmoothBoot

English / [简体中文](README_cn.md)

SmoothBoot is a **chain governor** for Helldivers 2 Lua mods on the Bingus shared
loader (API 1). Every HD2 Lua mod shares a single `update` chain; SmoothBoot wraps
it once and decides how often each callback actually runs, holds known FFI writers
out of the chain until the engine is calm, and keeps frame-critical (drawing)
callbacks on every frame.

It is one mod, not a loader. It runs on top of whatever API 1 loader you already
use and never touches other mods' files or configuration.

```
mods/... → your HUD mod → another mod → SmoothBoot (governor) → the rest of the chain
```

**Current release: 3.0.45** — maintenance release, 2026-10-04. See
[release notes](RELEASE-NOTES-3.0.45.md) and the [change log](CHANGELOG.md).

Development candidate **3.0.46** guards the original-chain re-entry path. Its
bounded-cycle regression and unchanged HD2Runtime 0.28.1 scheduler replay pass
under both LuaJIT runtimes. Live crash attribution and Runtime performance
acceptance remain open; see [candidate notes](RELEASE-NOTES-3.0.46.md).

## Status: what is verified, and what is not

Confidence is not uniform, so it is stated here rather than implied.

| Claim | Evidence |
|---|---|
| Loads and runs in a 46-mod chain | Live log: `ready v3.0.45`, chain inventory of 44 links, zero Smooth callback errors in a 530.7 s capture |
| Gameplay unaffected | User-reported normal: mission, death/respawn, return to ship, armory, Esc, ship hotkeys (2026-10-04) |
| Offline discipline | 106 regression checks across two LuaJIT runtimes plus 5 standalone scripts; the build refuses to package unless the source compiles under LuaJIT and declares no `user32` symbol |
| Profiler attribution | Held-writer work is labelled `writer name [SB gate]` instead of being charged to SmoothBoot; deterministic replay with the **unchanged** Mod Lag Watchdog source moves a synthetic 79.09 ms/s back to its owners |
| SmoothBoot's own cost | Paired in-session A/B (`enabled=yes` vs `enabled=no`): 3.0–3.4 ms/s either way ≈ 0.04% of a 128 FPS frame budget. A profiler's *opening* row for SmoothBoot measured 16–27× our own instrumented total, because each gate is counted again |
| Pre-animation black screen | Measured **not** caused by mods or by the loader: in the first 12 s the process used 0.8 s CPU and read 44 MB (waiting on anti-cheat/DRM); loader log lines all arrive at +17.5 s |

**Not verified, and not claimed:** a C4-held FPS fix (the remaining gap is
reported upstream to the C4 mod's author), shorter black screens, universal
compatibility, per-mod independent scheduling, long multi-hour sessions, or
multiplayer.

## Install

1. Needs an API 1 loader: **MDL 1.4.4+** or **Bingus Shared Loader v15+**.
2. Download `HD2-SmoothBoot-3.0.45.zip` from
   [Releases](https://github.com/Puipipi/HD2-SmoothBoot/releases) and import it into
   your mod manager (HD2 Arsenal, MDL, …). **Do not** use GitHub's auto-generated
   *Source code* ZIP — it is not an installable addon.
3. Enable **one** SmoothBoot only, and put it **at the bottom of the mod list**
   (lowest priority) so it can wrap the whole chain.
4. Deploy. Configuration lives in
   `%LOCALAPPDATA%\CowboyBingus\Helldivers2\SmoothBoot\config.txt`; it is created
   on first run and never overwritten afterwards.

`Collect-Logs.bat` is generated next to `config.txt` on first run (log collection
and an interactive `exclude=` picker). The installation ZIP deliberately contains
no loose `.bat`/`.ps1`/`.exe`.

## Configuration

Every key is optional; the shipped default is used when a key is absent. Most keys
are re-read while the game runs (about every 10 seconds).

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `yes` | Master switch. `no` forwards every callback untouched (the wrapper stays installed). |
| `throttle` | `auto` | `auto` = adaptive skipping, `yes` = always allow skipping, `no` = never skip. |
| `busy_ms`, `busy_pct`, `idle_ms`, `max_skip` | `12`, `30`, `1.5`, `2` | Skipping engages only above `max(busy_ms, busy_pct% of frame time)`, releases when the chain is cheap again, and never skips more than `max_skip` frames in a row. |
| `writers` | 12 fragments | Mods known to write FFI structures; held out of the update chain while the engine rebuilds tables. Empty = hold nothing. |
| `writer_release_s`, `writer_stagger_s`, `writer_norelease` | `10`, `8`, `m103_frv` | How long writers are held at boot, the minimum interval between releases, and writers that are never released. Holds are conservative by design: releasing into a table rebuild is what crashes the client. |
| `exclude` | `lte/helmet_cape_passives` | Comma-separated fragments of mods that must **not** be managed. Only mods below SmoothBoot on the update chain can be excluded (see Limits). |
| `ui_chunks`, `ui_mods` | see file | Extra fragments to treat as frame-critical (HUD/drawing). Automatic detection usually makes this unnecessary. |
| `boot_pause_s`, `boot_skip`, `boot_s`, `grace_s`, `boot_freeze_s` | `10`, `1`, `0`, `60`, off | Boot behaviour: stand the known state machines still while the engine rebuilds, skip nothing during the loading grace, optional full freeze. |
| `c4_read_pool` | `yes` | Verified C4 1.11 native read-buffer reuse (every read is still fresh; no data is cached). |
| `c4_context_batch`, `c4_input_batch`, `c4_native_batch`, `c4_idle_batch` | `no` | Opt-in batching of C4 context/input/native verification and the idle reload read. Each is validated against the original bytecode and restores the original method when disabled or excluded. |
| `c4_read_profile`, `c4_cpu_profile` | `no` | Diagnostics. The CPU sampler flushes JIT traces, so never compare FPS with it running. |
| `gc_pause`, `gc_stepmul` | `400`, `0` | Optional GC tuning for the whole mod ecosystem; engine defaults when 0. |
| `snapshot`, `diag` | `no`, `no` | Extra diagnostics: closure-graph snapshots and per-30 s `diag` / self-timing lines. |
| `peer_suspend` | `yes` | If another chain manager (MDL) is present, leave its settings alone. |

## Limits and expected log messages

- **Whole-chain protection, not per-mod scheduling.** When a drawing callback is
  detected, its entire enclosing chain runs every frame. That is deliberate: the
  alternative is guessing which mod inside the chain is the renderer.
- **`exclude=` cannot reach everything.** It only affects mods *below* SmoothBoot
  that are on the update chain. A mod that hooks menus, native rendering or its
  own timer is not chain-managed and cannot be silenced this way; the log lists
  those separately as `chain sources NOT managed`.
- **A mod that re-wraps `update` at runtime can stay above SmoothBoot.** We adopt
  a later wrapper back only when it keeps us in a function upvalue. If its
  previous hook lives elsewhere (a table field, a native callback) the log says so
  and no mod-order change will help — SmoothBoot refuses to yank the slot because
  that has knocked other mods off the chain.
- **Expected log lines, not errors:** `rehooks: <mod> xN` (that mod reinstalls its
  own hook; we re-adopt it), `first frame reached, head=<mod>` (something wraps
  above us), `<mod> [SB gate]` (a held writer's work, attributed correctly).
- Writer holds make boot conservative. The source notes measured in one task
  window: 1 s releases → 33 FPS, 8 s releases → 69.8 FPS; the shipped default
  stays at the conservative end.

## Checks (no game required)

```powershell
python -B work/standalone/build_sb.py --validate-only          # LuaJIT compile + no user32
python -m unittest discover -s work/standalone -p 'test_*.py'  # 106 checks (test_sb4_writerhold targets 2.17.1 and is expected to error)
python -B work/standalone/test_sb2.py                          # writer / auto-pause regressions
python -B work/standalone/test_sb3_autopause.py
python -B work/standalone/test_sb5_interdict.py
python -B work/standalone/test_startup_defaults.py
python -B work/standalone/test_sb6_ffi.py                      # needs a local Clickable Scrollbars reference
```

Simulations and offline checks are not live acceptance; they are the price of
entry, not proof.

## Repository layout

| Path | Contents |
|---|---|
| `work/standalone/smoothboot.lua` | The whole mod: plain Lua source, no compiled natives. |
| `work/standalone/build_sb.py` | Build gate + packager (refuses a build that fails the LuaJIT or `user32` rule). |
| `work/standalone/test_*.py` | Offline suites; `fixtures/` holds extracted original bytecode for differential tests. |
| `docs/automatic-throttling.md` | How adaptive skipping decides, and why the release gate exists. |
| `dist/` | Built, manager-importable ZIPs. |
| `RELEASE-NOTES-*.md` | Per-release notes. |
| `CHANGELOG.md` | Candidate-by-candidate history. |
| `THIRD_PARTY_NOTICES.md` | Third-party dependencies and their status. |

## Reporting a problem

Run `Collect-Logs.bat` (next to `config.txt`) and attach the ZIP it puts on your
desktop. It contains `SmoothBoot.log`, the watchdog log, your `config.txt` and the
mod list — the four things needed to tell a scheduling problem from an unrelated
one. Please also say whether SmoothBoot is the bottom entry in your mod list, and
which loader version you run.

## Provenance and credits

- The `AimInputState`, `ContextReader` and C4 `AutoReload` contracts used by the
  opt-in C4 adapters are adapted from the MIT-licensed
  [HD2 C4 Quick Actions](https://github.com/etxp/HD2-C4-Quick-Actions); its
  copyright and permission notice is retained in the runtime source.
- Profiler-attribution measurements were taken with the **unchanged** Mod Lag
  Watchdog source; no third-party file is modified.
- The Bingus addon packaging helpers are third-party and are deliberately **not**
  redistributed here — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

No license grant for this project's own code is made by this repository; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Ask the author before
redistributing or bundling it.
