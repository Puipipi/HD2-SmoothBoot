# -*- coding: utf-8 -*-
"""SmoothBoot sandbox tests: controllable os.clock + fake chain, run under
multiple lupa runtimes. Verifies the four behaviours the handoff doc lists:
  T1 boot throttle   - during boot_s the chain runs at most every boot_skip-th frame
  T2 pcall guard     - a chain error becomes a counter/log line, wrapper never throws
  T3 adaptive skip   - busy chain raises skip toward max_skip, cheap chain drops to 1
  T4 passthrough     - chain return values are forwarded untouched
"""
import os
import shutil
import sys
import tempfile

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "smoothboot.lua"), encoding="utf-8").read()

FAKE_LOCALAPPDATA = None  # set per case


def make_config(**kv):
    home = os.path.join(FAKE_LOCALAPPDATA, "CowboyBingus", "Helldivers2", "SmoothBoot")
    os.makedirs(home, exist_ok=True)
    lines = ["enabled=yes", "boot_skip=%s" % kv.get("boot_skip", 4),
             "boot_s=%s" % kv.get("boot_s", 1), "busy_ms=%s" % kv.get("busy_ms", 4),
             "idle_ms=%s" % kv.get("idle_ms", 1.5), "max_skip=%s" % kv.get("max_skip", 8)]
    with open(os.path.join(home, "config.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")


def new_runtime(mod, clock):
    rt = mod.LuaRuntime()
    g = rt.globals()

    def getenv(name):
        if name == "LOCALAPPDATA":
            return FAKE_LOCALAPPDATA
        return None

    def execute(cmd):
        return 0  # sandbox: no real mkdir

    g.os["clock"] = clock
    g.os["getenv"] = getenv
    g.os["execute"] = execute
    return rt


def setup_case(mod, cost_ms=0.0, err=False, config=None):
    """Fresh runtime with a fake chain installed as _G.update, SmoothBoot loaded.

    Returns (rt, wrapper, state, advance) where advance(seconds) moves the fake clock.
    """
    global FAKE_LOCALAPPDATA
    FAKE_LOCALAPPDATA = tempfile.mkdtemp(prefix="sb_test_")
    make_config(**(config or {}))
    clock = {"t": 1000.0}

    def read_clock():
        return clock["t"]

    def advance(seconds):
        clock["t"] += seconds

    rt = new_runtime(mod, read_clock)
    g = rt.globals()
    rt.execute(
        """
        chain_state = {calls = 0, ret = nil}
        function chain(a, b)
            chain_state.calls = chain_state.calls + 1
            advance_cost()
            if chain_err then error('boom from chain') end
            return nil, 'x', 42
        end
        update = chain
        """
    )
    g["advance_cost"] = lambda: advance(cost_ms / 1000.0)
    g["chain_err"] = err
    rt.execute(SRC)
    state = g["HD2SmoothBoot"]
    return rt, g["update"], state, advance, g["chain_state"]


def run_frames(wrapper, advance, frames, frame_dt=0.05):
    for _ in range(frames):
        advance(frame_dt)
        wrapper(0.016)


def case_boot_throttle(mod):
    rt, wrapper, state, advance, chain = setup_case(
        mod, cost_ms=0.1, config={"boot_skip": 4, "boot_s": 1})
    # step exactly 19 frames inside the 1s boot window (frame_dt=0.05)
    for _ in range(19):
        advance(0.05)
        wrapper(0.016)
    in_window_calls = int(chain["calls"])
    assert in_window_calls == 4, "boot window: expected 4 of 19 frames to run, got %d" % in_window_calls
    # after the window a cheap chain must drop the skip to 1 (every frame)
    for _ in range(30):
        advance(0.05)
        wrapper(0.016)
    total = int(chain["calls"])
    # 4 calls in the window + all 30 post-window frames once skip has stepped 4->3->2->1
    assert total == 34, "post-boot skip should reach 1: expected 34 total calls, got %d" % total
    shutil.rmtree(FAKE_LOCALAPPDATA, ignore_errors=True)
    return "boot throttle: 4/19 in window -> every frame after (%d total)" % total


def case_pcall_guard(mod):
    rt, wrapper, state, advance, chain = setup_case(
        mod, cost_ms=0.1, err=True, config={"boot_skip": 1, "boot_s": 1})
    for _ in range(10):
        advance(0.05)
        wrapper(0.016)  # must not raise
    assert int(chain["calls"]) == 10, "chain should keep being invoked after errors"
    errors = int(state["errors"])
    assert errors == 10, "expected 10 counted errors, got %d" % errors
    shutil.rmtree(FAKE_LOCALAPPDATA, ignore_errors=True)
    return "pcall guard: 10 errors counted, wrapper never raised, chain alive"


def case_adaptive_skip(mod):
    rt, wrapper, state, advance, chain = setup_case(
        mod, cost_ms=6.0, config={"boot_skip": 4, "boot_s": 1, "busy_ms": 4, "max_skip": 8})
    for _ in range(25):  # leave boot window
        advance(0.05)
        wrapper(0.016)
    base = int(chain["calls"])
    for _ in range(200):  # busy chain: skip should climb to 8 and stay
        advance(0.05)
        wrapper(0.016)
    added = int(chain["calls"]) - base
    assert 20 <= added <= 34, "busy chain: expected ~25 of 200 frames (skip 8), got %d" % added
    shutil.rmtree(FAKE_LOCALAPPDATA, ignore_errors=True)
    return "adaptive up: busy chain throttled to ~1/8 frames (%d/200)" % added


def case_passthrough(mod):
    rt, wrapper, state, advance, chain = setup_case(
        mod, cost_ms=0.1, config={"boot_skip": 1, "boot_s": 1})
    advance(0.05)
    ret = wrapper(7, 8)
    assert tuple(ret) == (None, "x", 42), "return values not forwarded: %r" % (ret,)
    shutil.rmtree(FAKE_LOCALAPPDATA, ignore_errors=True)
    return "passthrough: (nil,'x',42) forwarded intact"


CASES = [case_boot_throttle, case_pcall_guard, case_adaptive_skip, case_passthrough]
RUNTIMES = [(lupa.lua51, "lua51"), (lupa.lua53, "lua53")]

if __name__ == "__main__":
    failures = 0
    for mod, name in RUNTIMES:
        for case in CASES:
            try:
                msg = case(mod)
                print("PASS [%s] %s" % (name, msg))
            except AssertionError as e:
                failures += 1
                print("FAIL [%s] %s: %s" % (name, case.__name__, e))
            except Exception as e:
                failures += 1
                print("ERROR [%s] %s: %r" % (name, case.__name__, e))
    print("result: %d failure(s)" % failures)
    sys.exit(1 if failures else 0)
