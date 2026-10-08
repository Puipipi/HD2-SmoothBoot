"""Real Smooth scheduling over HUD/update-bus layouts; owned simulated work only."""
import json
from pathlib import Path
import tempfile
import unittest
from lua_test_vm import VM

SOURCE = Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')
CHUNKS = ['mods/codex/gun_calibration', 'mods/combat/enemy_hp',
          'mods/EquippedStratagems/NativeStratagemRadial', 'mods/aggro_counter/aggro_counter']


class FrameCritical(unittest.TestCase):
    def run_case(self, game, chunk, layout='below', cost=0.005, expect_full=True):
        with tempfile.TemporaryDirectory(prefix='sb-hud-chain-') as tmp:
            home = Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text(
                'throttle=auto\ngrace_s=0\nbusy_ms=1\nmax_skip=2\n'
                'trip_ms=20\ntrip_n=1\npause_s=5\nboot_pause_s=0\nwriters=\n', encoding='utf-8')
            vm=VM(game)
            try:
                vm.run('local getenv=os.getenv; os.getenv=function(k) if k=="LOCALAPPDATA" then return '+
                       json.dumps(tmp.replace('\\','/'))+' end return getenv(k) end; '
                       'clock=0; os.clock=function() return clock end; '
                       'CowboyBingusModLoader={}; calls=0; draws=0; render_dt=nil; base_calls=0; '
                       'update=function() base_calls=base_calls+1 end; '
                       'render=function() if render_dt then draws=draws+1; render_dt=nil end end')
                layer = '''
                    update=assert(loadstring([[local original=...; return function(dt,...)
                        calls=calls+1; clock=clock+'''+str(cost)+'''; render_dt=dt
                        return original(dt,...) end]], '@'''+chunk+'''.lua'))(update)
                '''
                if layout in ('above','late'):
                    vm.run(SOURCE)
                    if layout=='late':
                        vm.run('for i=1,30 do clock=clock+1/60; update(1/60) end; base_calls=0')
                    vm.run(layer)
                else:
                    vm.run(layer)
                    if layout=='deep-bus':
                        vm.run('''
                            for i=1,25 do update=assert(loadstring([[local previous_update=...;
                                return function(...) return previous_update(...) end]],
                                '@mods/test/innocent'..i))(update) end
                            local BUS={base=update,jobs={}}
                            update=assert(loadstring([[local BUS=...; return function(...)
                                local ok=pcall(BUS.base,...); for _,job in pairs(BUS.jobs) do job() end
                                if not ok then error('base failed') end end]],
                                '@mods/test/update_bus'))(BUS)
                        ''')
                    vm.run(SOURCE)
                result=vm.run('''
                    for i=1,180 do clock=clock+1/60; update(1/60); render() end
                    return tostring(calls)..','..tostring(draws)..','..tostring(base_calls)
                ''')
                counts=list(map(int,result.split(',')))
                if expect_full: self.assertEqual(counts,[180,180,180], 'HUD/base callbacks skipped or duplicated')
                else: self.assertLess(counts[0],180, 'unprotected scanner throttle was disabled')
            finally: vm.close()

    def test_huds_below_above_and_under_deep_bus_keep_full_frame_rate(self):
        for game in (False,True):
            for chunk in CHUNKS:
                for layout in ('below','above','late','deep-bus'):
                    with self.subTest(game=game,chunk=chunk,layout=layout):
                        self.run_case(game,chunk,layout)

    def test_hud_chain_is_not_paused_by_chain_breaker(self):
        for game in (False,True):
            with self.subTest(game=game):
                self.run_case(game,CHUNKS[0],cost=0.030)

    def test_unprotected_scanner_still_throttles(self):
        for game in (False,True):
            with self.subTest(game=game):
                self.run_case(game,'mods/test/expensive_scanner',expect_full=False)


if __name__=='__main__': unittest.main()
