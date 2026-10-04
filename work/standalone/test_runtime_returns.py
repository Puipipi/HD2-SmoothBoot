"""Exercise real Smooth callbacks in modern and game LuaJIT; no game inputs."""
import json
from pathlib import Path
import tempfile
import unittest

from test_c4_ui_scope import VM

SOURCE = Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')


class RuntimeReturns(unittest.TestCase):
    def run_case(self, game, body, enabled=True, writers=''):
        with tempfile.TemporaryDirectory(prefix='sb-returns-') as tmp:
            home = Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text(
                f'enabled={"yes" if enabled else "no"}\nthrottle=no\n'
                f'boot_pause_s=0\nhud=off\nwriters={writers}\nwriter_release_s=0\n',
                encoding='utf-8')
            vm = VM(game)
            try:
                vm.run('local getenv=os.getenv; os.getenv=function(k) if k=="LOCALAPPDATA" '
                       'then return '+json.dumps(tmp.replace('\\', '/'))+
                       ' end return getenv(k) end; CowboyBingusModLoader={}; '
                       'values={n=0}; base_calls=0; '
                       'update=function(...) base_calls=base_calls+1; '
                       'if fail then error(fault,0) end; return unpack(values,1,values.n) end')
                vm.run(SOURCE)
                return vm.run(body)
            finally:
                vm.close()

    def test_main_wrapper_preserves_exact_return_arity(self):
        for game in (False, True):
            for enabled in (False, True):
                with self.subTest(game=game, enabled=enabled):
                    self.run_case(game, '''
                        local patterns={{n=0},{n=1},{n=2,[1]=7},
                                        {n=4,[1]=false,[3]=9},{n=5,[2]='ok',[4]=42}}
                        local function check(...)
                            assert(select('#',...)==values.n,'callback return arity changed')
                            for i=1,values.n do
                                assert(select(i,...)==values[i],'callback return value changed')
                            end
                        end
                        for _,v in ipairs(patterns) do values=v; check(update(0.016)) end
                        assert(base_calls==#patterns,'callback count changed')
                    ''', enabled)

    def test_adopted_head_preserves_nil_results_and_single_execution(self):
        for game in (False, True):
            with self.subTest(game=game):
                self.run_case(game, '''
                    values={n=4,[1]=11,[3]=false}
                    addon_calls=0
                    update=assert(loadstring([[local previous_update=...; return function(...)
                        addon_calls=addon_calls+1; return previous_update(...) end]],
                        '@mods/test/returning_addon'))(update)
                    local function check(...)
                        assert(select('#',...)==4,'adopted return arity changed')
                        assert(select(1,...)==11 and select(2,...)==nil
                               and select(3,...)==false and select(4,...)==nil)
                    end
                    for i=1,241 do check(update(0.016)) end
                    assert(base_calls==241 and addon_calls==241,'adoption duplicated callback')
                ''')

    def test_writer_gate_preserves_returns_in_both_states(self):
        for game in (False, True):
            for opened in (False, True):
                with self.subTest(game=game, opened=opened):
                    self.run_case(game, '''
                        local sb=update
                        writer_calls=0
                        update=assert(loadstring([[local previous_update=...; return function(...)
                            writer_calls=writer_calls+1; return previous_update(...) end]],
                            '@mods/test/p33_missile'))(sb)
                        update(0.016)
                        local WH
                        for i=1,100 do local n,v=debug.getupvalue(sb,i); if not n then break end
                            if n=='WH' then WH=v end end
                        local held=assert(WH.held['mods/test/p33_missile'])
                        held.ctl.open='''+str(opened).lower()+'''
                        values={n=4,[1]=false,[3]='gate'}
                        local function check(...)
                            assert(select('#',...)==4,'gate return arity changed')
                            assert(select(1,...)==false and select(2,...)==nil
                                   and select(3,...)=='gate' and select(4,...)==nil)
                        end
                        local before=writer_calls
                        for i=1,10 do check(held.gate(0.016)) end
                        assert(writer_calls-before=='''+('10' if opened else '0')+''')
                    ''', writers='p33_missile')

    def test_error_policy_and_recovery(self):
        for game in (False, True):
            for enabled in (False, True):
                with self.subTest(game=game, enabled=enabled):
                    self.run_case(game, '''
                        fault={}; fail=true
                        local good,err=pcall(update,0.016)
                        '''+('assert(good and HD2SmoothBoot.errors==1)' if enabled else
                             'assert(not good and err==fault,"disabled error identity changed")')+'''
                        fail=false; values={n=1,[1]=77}
                        assert(update(0.016)==77,'inside guard remained set after error')
                        assert(base_calls==2)
                    ''', enabled)

    def test_writer_gate_recovers_after_errors_and_cycles(self):
        for game in (False,True):
            for opened in (False,True):
                with self.subTest(game=game,opened=opened):
                    self.run_case(game, '''
                        local sb=update
                        update=assert(loadstring([[local previous_update=...;return function(...)
                            if writer_fail then error(fault,0) end; return previous_update(...) end]],
                            '@mods/test/p33_missile'))(sb)
                        update(0.016)
                        local WH
                        for i=1,100 do local n,v=debug.getupvalue(sb,i);if not n then break end
                            if n=='WH' then WH=v end end
                        local held=assert(WH.held['mods/test/p33_missile'])
                        local slot
                        for i=1,100 do local n=debug.getupvalue(held.gate,i);if not n then break end
                            if n=='previous_update' then slot=i end end
                        assert(slot,'profiler-compatible downstream slot lost')
                        held.ctl.open='''+str(opened).lower()+'''
                        fault={};writer_fail=true
                        debug.setupvalue(held.gate,slot,function()error(fault,0)end)
                        local ok,err=pcall(held.gate,0.016)
                        assert(not ok and err==fault,'writer error identity changed')
                        writer_fail=false
                        debug.setupvalue(held.gate,slot,function(...)return held.gate(...)end)
                        assert(pcall(held.gate,0.016),'cycle guard threw')
                        assert(held.ctl._cyc,'cycle was not intercepted')
                        debug.setupvalue(held.gate,slot,function()return 42,nil end)
                        local function check(...)
                            assert(select('#',...)==2 and (...)==42,'gate stayed busy after recovery')
                        end
                        check(held.gate(0.016))
                    ''',writers='p33_missile')

    def test_idle_dispatch_allocation_is_bounded(self):
        for game in (False,True):
            for enabled in (False,True):
                with self.subTest(game=game,enabled=enabled):
                    self.run_case(game, '''
                        jit.off();values={n=2,[1]=7,[2]=9}
                        for i=1,1000 do update(0.016) end
                        collectgarbage('collect');collectgarbage('stop')
                        local before=collectgarbage('count')
                        for i=1,10000 do update(0.016) end
                        local kib=collectgarbage('count')-before
                        collectgarbage('restart')
                        -- Generous budget includes periodic discovery/logging; 3.0.39
                        -- consumed over 1 MiB here from per-frame tables/closures.
                        assert(kib<400,'idle dispatcher recreated per-frame allocations: '..kib)
                    ''',enabled)


if __name__ == '__main__':
    unittest.main()
