"""A clean install must not acquire minutes of extra delay after config reload."""
import pathlib
import tempfile
import unittest
import lupa.luajit21 as luajit

SOURCE = pathlib.Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')

class StartupDefaults(unittest.TestCase):
    def test_first_install_then_restart_releases_three_writers_within_30_seconds(self):
        with tempfile.TemporaryDirectory(prefix='sb-startup-') as tmp:
            for launch in range(2):
                rt = luajit.LuaRuntime()
                rt.globals().os.getenv = lambda key: tmp if key == 'LOCALAPPDATA' else None
                now = [0.0]
                rt.globals().os.clock = lambda: now[0]
                rt.execute('CowboyBingusModLoader={}; base_calls=0; ticks={}; update=function() base_calls=base_calls+1 end')
                for name in ('gp20_ultimatum_ammo', 'p33_missile_pistol_ammo', 'p34_breacher_ammo'):
                    rt.execute('''
                        local name=...
                        local previous=update
                        ticks[name]=0
                        update=assert(loadstring('local previous,name=...; return function(...) ticks[name]=ticks[name]+1; return previous(...) end',
                            '-- HD2-Addon: mods/codex/'..name))(previous,name)
                    ''',name)
                rt.execute(SOURCE)
                rt.execute("update=assert(loadstring('local previous=...; return function(...) return previous(...) end', '-- HD2-Addon: mods/patpatpatrick/mod_lag_finder'))(update)")
                for frame in range(1800):
                    now[0] = (frame+1)/60
                    rt.globals().update(1/60)
                log = (pathlib.Path(tmp)/'CowboyBingus/Helldivers2/Logs/SmoothBoot.log').read_text(encoding='utf-8')
                self.assertIn('3 held in total',log,'fixture did not exercise writer withholding')
                self.assertEqual(rt.globals().base_calls,1800,'base callback lost during initialization')
                for name in ('gp20_ultimatum_ammo', 'p33_missile_pistol_ammo', 'p34_breacher_ammo'):
                    self.assertGreater(rt.globals().ticks[name],0,f'{name} still withheld after 30s on launch {launch+1}')

if __name__ == '__main__': unittest.main()
