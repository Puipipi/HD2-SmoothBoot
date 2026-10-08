"""Bound actual Smooth re-entry in both LuaJITs; no game process operations."""
import json
from pathlib import Path
import tempfile
import unittest

from lua_test_vm import VM

SOURCE = Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')


class ChainReentryGuard(unittest.TestCase):
    def test_redispatch_is_bounded_and_next_frame_recovers(self):
        for game in (False, True):
            for enabled in (False, True):
                with self.subTest(game=game, enabled=enabled), tempfile.TemporaryDirectory() as tmp:
                    home = Path(tmp)/'CowboyBingus/Helldivers2'
                    (home/'SmoothBoot').mkdir(parents=True)
                    (home/'Logs').mkdir()
                    (home/'SmoothBoot/config.txt').write_text(
                        f'enabled={"yes" if enabled else "no"}\nthrottle=no\n'
                        'boot_pause_s=0\nwriters=\nhud=off\n', encoding='utf-8')
                    vm = VM(game)
                    try:
                        vm.run('os.getenv=function(k) if k=="LOCALAPPDATA" then return '
                               +json.dumps(tmp.replace('\\', '/'))+' end end; CowboyBingusModLoader={};')
                        vm.run('''
                            depth=0; max_depth=0; base_calls=0; redispatch=true
                            update=function(...)
                                base_calls=base_calls+1
                                depth=depth+1;max_depth=math.max(max_depth,depth)
                                if depth>20 then depth=depth-1;error('unbounded redispatch',0)end
                                if redispatch then local r=update(...);depth=depth-1;return r end
                                depth=depth-1;return false,nil,17,nil
                            end
                        ''')
                        vm.run(SOURCE)
                        vm.run('''
                            pcall(update,0.016)
                            -- Bounded, not swallowed: the legal nested dispatch runs until the
                            -- reentry cap (default 3), so the member is entered 3 times and the
                            -- recursion stops exactly there.
                            assert(max_depth>=2,'legal nested pass-through was swallowed: '..max_depth)
                            -- passthrough_depth counts our shells (cap 3); the member below is
                            -- entered once per shell, so its own depth reaches cap+1.
                            assert(max_depth<=4,'reentry cap exceeded: '..max_depth)
                            assert(base_calls>=2,'nested dispatch never reached the original chain')
                            local sb=rawget(_G,'HD2SmoothBoot')
                            assert(type(sb)=='table' and (sb.reentry_cycles or 0)>=1,'cycle was not counted')
                            redispatch=false; depth=0
                            local function check(...)
                                assert(select('#',...)==4,'return arity lost after cycle')
                                assert(select(1,...)==false and select(3,...)==17)
                            end
                            check(update(0.016))
                        ''')
                        self.assertIn('re-entry cycle', (home/'Logs/SmoothBoot.log').read_text('utf-8'))
                    finally:
                        vm.close()

    def test_passthrough_error_resets_guard_and_preserves_identity(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                home=Path(tmp)/'CowboyBingus/Helldivers2'
                (home/'SmoothBoot').mkdir(parents=True);(home/'Logs').mkdir()
                (home/'SmoothBoot/config.txt').write_text(
                    'enabled=no\nthrottle=no\nboot_pause_s=0\nwriters=\nhud=off\n',encoding='utf-8')
                vm=VM(game)
                try:
                    vm.run('os.getenv=function(k) if k=="LOCALAPPDATA" then return '
                           +json.dumps(tmp.replace('\\','/'))+' end end;CowboyBingusModLoader={};')
                    vm.run('''
                        calls=0;fault={};failure=true
                        update=function(...)
                            calls=calls+1
                            if failure then
                                if calls%2==1 then return update(...)end
                                error(fault,0)
                            end
                            return 31,nil
                        end
                    ''')
                    vm.run(SOURCE)
                    vm.run('''
                        for i=1,2 do
                            local ok,err=pcall(update,0.016)
                            assert(not ok and err==fault,'error identity changed')
                        end
                        failure=false
                        local function check(...)assert(select('#',...)==2 and (...)==31)end
                        check(update(0.016))
                    ''')
                finally:
                    vm.close()


if __name__=='__main__':unittest.main()
