"""Compatibility with the mods the manager loads first, in the observed order.

Load order measured from BingusSharedLoader.log on 2026-10-06:
    #13 mods/codex/smoothboot
    #14 mods/skyeshade/hd2runtime
    #15 mods/junze/hd2_scanner
so both priority loaders sit *above* SmoothBoot and reach the original chain through its
pass-through shell.

Three properties are asserted (all measured, not assumed):
  1. steady state - every layer above us runs exactly once per engine frame. Measured over
     400 frames in work/standalone/measure_double_drive.py: scanner 1, runtime 1, chain 1.
  2. a nested dispatch from inside our own call (a member holding a reference to us and
     calling it again while we are still running) still delivers the chain's return values.
     The old boolean guard swallowed it and returned nothing, which starved the menu /
     mission / quit paths in game; the layer counts are therefore 2 for that scenario.
  3. a runaway loop is still broken, counted and logged with depth and cap.

    python -m unittest test_priority_loaders_above
"""
import json
from pathlib import Path
import tempfile
import unittest

from lua_test_vm import VM

SOURCE = Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')

# runtime-like loader: wraps update, forwards to its previous exactly once per frame.
RUNTIME = r'''
runtime_ticks=0
local prev=update
update=function(...)
    runtime_ticks=runtime_ticks+1
    return prev(...)
end
'''

# scanner-like loader above it: same shape, one forward per frame.
SCANNER = r'''
scanner_ticks=0
local prev=update
update=function(...)
    scanner_ticks=scanner_ticks+1
    return prev(...)
end
'''


def make_vm(tmp, config_extra=''):
    home = Path(tmp) / 'CowboyBingus/Helldivers2'
    (home / 'SmoothBoot').mkdir(parents=True)
    (home / 'Logs').mkdir()
    (home / 'SmoothBoot/config.txt').write_text(
        'enabled=yes\nthrottle=no\nboot_pause_s=0\nwriters=\nhud=off\n' + config_extra,
        encoding='utf-8')
    vm = VM(True)
    vm.run('os.getenv=function(k) if k=="LOCALAPPDATA" then return '
           + json.dumps(tmp.replace('\\', '/')) + ' end end; CowboyBingusModLoader={};')
    return vm


class PriorityLoadersAbove(unittest.TestCase):
    def test_every_layer_above_us_runs_once_per_frame_in_steady_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            vm = make_vm(tmp)
            try:
                vm.run('chain_ticks=0; update=function(...) chain_ticks=chain_ticks+1; return false,nil,17,nil end')
                vm.run(SOURCE)
                vm.run(RUNTIME)
                vm.run(SCANNER)
                vm.run('''
                    local worst_s,worst_r,worst_c=0,0,0
                    for frame=1,300 do
                        local s,r,c=scanner_ticks,runtime_ticks,chain_ticks
                        update(0.016)
                        worst_s=math.max(worst_s,scanner_ticks-s)
                        worst_r=math.max(worst_r,runtime_ticks-r)
                        worst_c=math.max(worst_c,chain_ticks-c)
                    end
                    assert(worst_s==1,'scanner driven '..worst_s..'x per frame')
                    assert(worst_r==1,'runtime driven '..worst_r..'x per frame')
                    assert(worst_c==1,'chain driven '..worst_c..'x per frame')
                ''')
            finally:
                vm.close()

    def test_nested_dispatch_from_inside_returns_chain_values(self):
        """RED on the old boolean guard: the nested call returned nothing."""
        with tempfile.TemporaryDirectory() as tmp:
            vm = make_vm(tmp)
            try:
                vm.run('''
                    inner_calls=0; nested_arity=nil; nested_value_ok=nil
                    update=function(...)
                        inner_calls=inner_calls+1
                        if inner_calls==1 then
                            local a,b,c,d=rawget(_G,'update')(...)   -- dispatch while inside us
                            nested_arity=select('#',a,b,c,d)
                            nested_value_ok=(c==17)
                        end
                        return false,nil,17,nil
                    end
                ''')
                vm.run(SOURCE)
                vm.run(RUNTIME)
                vm.run(SCANNER)
                vm.run('''
                    local n=select('#',update(0.016))
                    assert(n==4,'arity lost through priority loaders: '..n)
                    assert(inner_calls>=2,'nested dispatch never ran: '..inner_calls)
                    assert(nested_arity==4,
                           'nested dispatch got '..tostring(nested_arity)..' values (swallowed?)')
                    assert(nested_value_ok==true,'nested dispatch lost the chain result')
                    assert(scanner_ticks==2 and runtime_ticks==2,
                           'loaders ticked wrong for a nested dispatch: scanner='..scanner_ticks..
                           ' runtime='..runtime_ticks)
                    local sb=rawget(_G,'HD2SmoothBoot')
                    assert((sb.reentry_cycles or 0)==0,
                           'cap hit on a legal nested dispatch: '..tostring(sb.reentry_cycles))
                ''')
            finally:
                vm.close()

    def test_runaway_loop_is_broken_counted_and_logged(self):
        with tempfile.TemporaryDirectory() as tmp:
            vm = make_vm(tmp, 'reentry_max=3\n')
            try:
                vm.run('''
                    depth=0; max_depth=0
                    update=function(...)
                        depth=depth+1; max_depth=math.max(max_depth,depth)
                        if depth>50 then depth=depth-1; error('RUNAWAY',0) end
                        local r=rawget(_G,'update')(...)
                        depth=depth-1
                        return r
                    end
                ''')
                vm.run(SOURCE)
                vm.run('pcall(update,0.016)')
                vm.run('''
                    assert(max_depth<=4,'cap not enforced: '..max_depth)
                    local sb=rawget(_G,'HD2SmoothBoot')
                    assert(sb and (sb.reentry_cycles or 0)>=1,'cycle not counted')
                ''')
                log = (Path(tmp) / 'CowboyBingus/Helldivers2/Logs/SmoothBoot.log').read_text('utf-8')
                self.assertIn('re-entry cycle', log)
                self.assertIn('reentry_max 3', log)
            finally:
                vm.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
