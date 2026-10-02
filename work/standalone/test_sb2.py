# -*- coding: utf-8 -*-
"""SmoothBoot 2.0 sandbox tests.

Covers the 1.0 regression set (boot throttle, pcall guard, adaptive skip,
passthrough) plus the 2.0 rules: dormant without Bingus loader, exclusion
semantics for chain heads, circuit breaker, per-mod error attribution, and
scene-aware menu throttling.
"""
import os
import shutil
import sys
import tempfile

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "smoothboot.lua"), encoding="utf-8").read()

FAKE_LA = None


def make_config(**kv):
    home = os.path.join(FAKE_LA, "CowboyBingus", "Helldivers2", "SmoothBoot")
    os.makedirs(os.path.join(FAKE_LA, "CowboyBingus", "Helldivers2", "Logs"), exist_ok=True)
    os.makedirs(home, exist_ok=True)
    base = dict(enabled="yes", throttle=kv.get("throttle", "yes"), ui_mods="", boot_skip=kv.get("boot_skip", 4), boot_s=kv.get("boot_s", 1),
                grace_s=kv.get("grace_s", 0), boot_freeze_s=kv.get("boot_freeze_s", 0),
                busy_ms=kv.get("busy_ms", 4), idle_ms=kv.get("idle_ms", 1.5),
                max_skip=kv.get("max_skip", 8), menu_skip=kv.get("menu_skip", 8),
                trip_ms=kv.get("trip_ms", 50), trip_n=kv.get("trip_n", 3),
                pause_s=kv.get("pause_s", 5), exclude=kv.get("exclude", ""))
    with open(os.path.join(home, "config.txt"), "w") as f:
        f.write("\n".join("%s=%s" % (k, v) for k, v in base.items()) + "\n")


def new_runtime(mod, clock, with_loader=True, with_stingray=False, worlds=None):
    rt = mod.LuaRuntime()
    g = rt.globals()
    g.os["clock"] = clock
    g.os["getenv"] = lambda name: FAKE_LA if name == "LOCALAPPDATA" else None
    g.os["execute"] = lambda cmd: 0
    if with_loader:
        rt.execute("CowboyBingusModLoader = { api = 1, version = 18 }")
    if with_stingray:
        wl = "{" + ",".join('"%s"' % w for w in (worlds or [])) + "}"
        rt.execute("""
            __worlds = %s
            stingray = { Application = {
                worlds = function() return __worlds end,
                main_world = function() return __worlds[1] end,
            } }
        """ % wl)
    return rt


def setup_case(mod, cost_ms=0.0, err=False, config=None, with_loader=True,
               with_stingray=False, worlds=None):
    global FAKE_LA
    FAKE_LA = tempfile.mkdtemp(prefix="sb2_")
    make_config(**(config or {}))
    clock = {"t": 1000.0}
    rt = new_runtime(mod, lambda: clock["t"], with_loader, with_stingray, worlds)
    g = rt.globals()
    rt.execute("mkchunk = loadstring or load")
    rt.execute("""
        chain_state = { calls = 0 }
        function chain(a, b)
            chain_state.calls = chain_state.calls + 1
            advance_cost()
            if chain_err then error('boom from chain') end
            return nil, 'x', 42
        end
        update = chain
    """)
    g["advance_cost"] = lambda: clock.__setitem__("t", clock["t"] + cost_ms / 1000.0)
    g["chain_err"] = err
    rt.execute(SRC)
    state = g["HD2SmoothBoot"]
    return rt, g, g["update"], state, lambda s: clock.__setitem__("t", clock["t"] + s), g["chain_state"]


def read_log():
    p = os.path.join(FAKE_LA, "CowboyBingus", "Helldivers2", "Logs", "SmoothBoot.log")
    if not os.path.exists(p):
        return ""
    return open(p, encoding="utf-8", errors="replace").read()


# ---------- 1.0 regression ----------

def case_loading_fullspeed(mod):
    # 2.1.1: the old boot throttle is gone - the loading grace runs the chain
    # at full speed so mods finish their init scans as fast as they can
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=0.1, config={"grace_s": 60})
    for _ in range(40):
        adv(0.05); wrapper(0.016)
    assert int(chain["calls"]) == 40, "grace: %d" % chain["calls"]
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "loading grace keeps chain at full speed"


def case_pcall_guard(mod):
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=0.1, err=True, config={"boot_skip": 1, "grace_s": 0})
    for _ in range(10):
        adv(0.05); wrapper(0.016)
    assert int(chain["calls"]) == 10 and int(state["errors"]) == 10
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "pcall guard regression ok"


def case_adaptive_skip(mod):
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=6.0, config={"boot_skip": 4, "boot_s": 1, "grace_s": 0})
    for _ in range(25):
        adv(0.05); wrapper(0.016)
    base = int(chain["calls"])
    for _ in range(200):
        adv(0.05); wrapper(0.016)
    added = int(chain["calls"]) - base
    assert 20 <= added <= 34, "busy throttle %d" % added
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "adaptive skip regression ok"



def case_multi_adopt(mod):
    # real mods wrap with a local previous (upvalue); two of them load after us
    # and both get adopted - the splice must keep them both on the chain
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=0.1, config={"grace_s": 0, "boot_skip": 1})
    rt.execute("""
        __A_state = { calls = 0 }
        __B_state = { calls = 0 }
        local mk = loadstring or load
        _FA = mk('local p = ... return function(...) __A_state.calls = __A_state.calls + 1 return p(...) end',
                      '-- HD2-Addon: mods/cowboybingus/clickable_scrollbars')
        _FB = mk('local p = ... return function(...) __B_state.calls = __B_state.calls + 1 return p(...) end',
                      '-- HD2-Addon: mods/patpatpatrick/helmet_headlamp')
        update = _FA(update)
    """)
    for _ in range(5):
        adv(0.05); g["update"](0.016)      # A becomes head, gets adopted first
    rt.execute("update = _FB(update)")
    for _ in range(35):
        adv(0.05); g["update"](0.016)      # B covers, gets spliced on top of A
    log = read_log()
    assert log.count("adopted chain head back") == 2, log[-300:]
    a, b = int(g["__A_state"]["calls"]), int(g["__B_state"]["calls"])
    assert a >= 20 and b >= 34, "both mods must keep running (A=%d B=%d)" % (a, b)
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "multi-adopt splice keeps both mods on the chain (A=%d B=%d)" % (a, b)



def case_auto_ui_protect(mod):
    # throttle=auto: engages on a busy chain when no UI mod runs, stands down
    # the moment a UI mod registers its global
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=20.0,
        config={"throttle": "auto", "grace_s": 0, "busy_ms": 12, "boot_skip": 1})
    for _ in range(90):
        adv(0.05); wrapper(0.016)
    busy = int(chain["calls"])
    rt.execute("HD2MultiPerk = { version = 'x' }")
    adv(11)
    for _ in range(60):
        adv(0.05); wrapper(0.016)
    ui = int(chain["calls"]) - busy
    assert busy <= 80, "no-UI phase must throttle: %d" % busy
    assert ui >= 55, "UI phase must run full speed: %d" % ui
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "auto mode: %d/90 throttled, 60/60 protected with UI present" % busy


def case_passthrough(mod):
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=0.1, config={"boot_skip": 1, "grace_s": 0})
    adv(0.05)
    assert tuple(wrapper(7, 8)) == (None, "x", 42)
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "passthrough regression ok"


# ---------- 2.0 rules ----------

def case_dormant(mod):
    rt, g, wrapper, state, adv, chain = setup_case(mod, with_loader=False)
    assert "dormant" in str(state["status"]), state["status"]
    assert rt.execute("return update == chain"), "update must stay the raw chain without Bingus loader"
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "dormant without Bingus loader: update untouched"


def case_exclude(mod):
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=0.1, config={"boot_skip": 4, "boot_s": 1, "grace_s": 0, "exclude": "foo/bar"})
    rt.execute("""
        __gov = update
        __X_state = { calls = 0 }
        update = mkchunk('__X_state.calls = __X_state.calls + 1  return __gov(...)',
                         '-- HD2-Addon: mods/foo/bar/nice')
    """)
    for _ in range(60):
        adv(0.05); g["update"](0.016)
    assert rt.execute("return update ~= __gov"), "excluded head must stay the head"
    assert int(g["__X_state"]["calls"]) == 60, "excluded head must run full speed: %d" % g["__X_state"]["calls"]
    assert "excluded by config: mods/foo/bar" in read_log()
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "excluded head stays above, unmanaged and full speed"


def case_non_bingus_head(mod):
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=0.1, config={"boot_skip": 4, "boot_s": 1, "grace_s": 0})
    rt.execute("""
        __gov2 = update
        __F_state = { calls = 0 }
        update = mkchunk('__F_state.calls = __F_state.calls + 1  return __gov2(...)',
                         'some-foreign-bootpatch')
    """)
    for _ in range(60):
        adv(0.05); g["update"](0.016)
    assert rt.execute("return update ~= __gov2"), "foreign head must stay the head"
    assert int(g["__F_state"]["calls"]) == 60, "foreign head full speed: %d" % g["__F_state"]["calls"]
    assert "non-Bingus update wrapper" in read_log()
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "non-Bingus head stays above, unmanaged"


def case_breaker(mod):
    rt, g, wrapper, state, adv, chain = setup_case(
        mod, cost_ms=60.0, config={"boot_skip": 1, "grace_s": 0, "trip_ms": 50, "trip_n": 3, "pause_s": 5})
    for _ in range(25):   # leave boot window
        adv(0.05); wrapper(0.016)
    base = int(chain["calls"])
    for _ in range(30):   # every call is 60ms -> breaker opens after 3
        adv(0.05); wrapper(0.016)
    # paused window: chain gets no calls even though frames pass
    frozen = int(chain["calls"])
    for _ in range(20):
        adv(0.05); wrapper(0.016)
    assert int(chain["calls"]) == frozen, "chain must be paused after breaker trips"
    # after pause_s the chain resumes (skip may keep some frames gated)
    adv(6.0)
    for _ in range(4):
        wrapper(0.016)
    assert int(chain["calls"]) >= frozen + 1, "chain resumes after pause"
    # the buffered OPEN line is drained once the breaker window closes
    assert "breaker OPEN" in read_log(), "OPEN line must flush after the pause"
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "breaker opens, pauses, resumes, buffered OPEN drains"


def case_error_attribution(mod):
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=0.1, config={"boot_skip": 1, "grace_s": 0})
    # replace the chain with one whose chunk name is a Bingus declaration
    rt.execute("_G['HD2SmoothBoot'] = nil")
    rt.execute("update = mkchunk(\"error('kapow')\", '-- HD2-Addon: mods/dsh/ac8_rack_backpack')")
    rt.execute(SRC)
    wrapper2 = rt.globals()["update"]
    for _ in range(10):
        adv(0.05); wrapper2(0.016)
    log = read_log()
    assert "[mods/dsh/ac8_rack_backpack]" in log, log[-400:]
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "errors attributed to mods/dsh/ac8_rack_backpack"


def case_adopt(mod):
    rt, g, wrapper, state, adv, chain = setup_case(mod, cost_ms=20.0, config={"boot_skip": 4, "boot_s": 90, "grace_s": 0})
    rt.execute("""
        __X_state = { calls = 0 }
        local mk = loadstring or load
        local factory = mk('local p = ...  return function(...) '
            .. '__X_state.calls = __X_state.calls + 1  return p(...) end',
            '-- HD2-Addon: mods/dsh/k9_p_l20')
        update = factory(update)
    """)
    for _ in range(60):
        adv(0.05); g["update"](0.016)
    log = read_log()
    assert "adopted chain head back from mods/dsh/k9_p_l20" in log, log[-400:]
    assert not rt.execute("return update == __X"), "governor must be the head again"
    xc = int(g["__X_state"]["calls"]); bc = int(chain["calls"])
    assert 8 <= xc <= 20, "covered mod must be throttled (busy chain): %d" % xc
    # xc includes the transition frame where the engine still called X as head
    # The adoption frame now forwards the below-chain too; no lost first input.
    assert bc == xc, "no double-run: base chain once per governed call (%d vs %d)" % (bc, xc)
    shutil.rmtree(FAKE_LA, ignore_errors=True)
    return "adopt: takes head back, throttles the busy late mod (%d/60), no double-run" % xc


CASES = [case_loading_fullspeed, case_pcall_guard, case_adaptive_skip, case_passthrough,
         case_dormant, case_exclude, case_non_bingus_head, case_breaker,
         case_error_attribution, case_adopt, case_multi_adopt, case_auto_ui_protect]
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
