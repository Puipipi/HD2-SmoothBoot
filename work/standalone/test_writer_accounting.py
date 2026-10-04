"""Writer gate ownership stays visible without losing measurement probes."""
import pathlib
import tempfile
import unittest
import lupa.luajit21 as luajit

SOURCE = pathlib.Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')


class WriterAccounting(unittest.TestCase):
    def test_gate_reports_delegated_work_owner_and_adapter_label(self):
        with tempfile.TemporaryDirectory(prefix='sb-owner-') as tmp:
            home = pathlib.Path(tmp) / 'CowboyBingus/Helldivers2'
            (home / 'SmoothBoot').mkdir(parents=True)
            (home / 'Logs').mkdir()
            (home / 'SmoothBoot/config.txt').write_text(
                'throttle=no\nboot_pause_s=0\nhud=off\nwriters=p33_missile\nwriter_release_s=0\n', encoding='utf-8')
            rt = luajit.LuaRuntime()
            rt.globals().os.getenv = lambda key: tmp if key == 'LOCALAPPDATA' else None
            rt.execute('CowboyBingusModLoader={}; writes=0; base=0; '
                       'update=function(...)base=base+1;return 123,nil,456,nil end')
            rt.execute(SOURCE)
            rt.execute('''
                local sb=update
                update=assert(loadstring([[local previous_update=...;return function(...)
                    writes=writes+1;return previous_update(...)end]],'@mods/test/p33_missile.lua'))(sb)
                local caller=update
                update=assert(loadstring([[local previous_update=...;return function(...)
                    return previous_update(...)end]],'@mods/test/innocent.lua'))(caller)
                update(0.016)
                local WH
                for i=1,100 do local n,v=debug.getupvalue(sb,i);if not n then break end
                    if n=='WH' then WH=v end end
                local held=assert(WH.held['mods/test/p33_missile.lua'])
                gate_source=debug.getinfo(held.gate,'S').source
                held.ctl.open=true
                local before=writes
                result=select('#',update(0.016))
                released=writes-before
            ''')
            self.assertEqual(rt.globals().gate_source, '@mods/test/p33_missile [SB gate]')
            self.assertEqual(rt.globals().released, 1)
            self.assertEqual(rt.globals().result, 4)


if __name__ == '__main__':
    unittest.main()
