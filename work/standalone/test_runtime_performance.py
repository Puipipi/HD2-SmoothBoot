"""Real wrapper regression: a watchdog repeatedly publishes the same head."""
import pathlib
import tempfile
import unittest
import lupa.luajit21 as luajit

SOURCE=pathlib.Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')

class RuntimePerformance(unittest.TestCase):
    def test_gate_maintenance_preserves_watchdog_measurement_probes(self):
        for restored_writer in (False, True):
            with self.subTest(restored_writer=restored_writer), tempfile.TemporaryDirectory(prefix='sb-probe-') as tmp:
                home=pathlib.Path(tmp)/'CowboyBingus/Helldivers2'
                (home/'SmoothBoot').mkdir(parents=True)
                (home/'Logs').mkdir()
                (home/'SmoothBoot/config.txt').write_text(
                    'throttle=no\nboot_pause_s=0\nhud=off\nwriters=p33_missile\nwriter_release_s=0\n',encoding='utf-8')
                rt=luajit.LuaRuntime()
                rt.globals().os.getenv=lambda key: tmp if key=='LOCALAPPDATA' else None
                rt.execute('CowboyBingusModLoader={}; base_calls=0; writer_calls=0; probe_calls=0; below_probe_calls=0; update=function() base_calls=base_calls+1; return 123 end')
                rt.execute(SOURCE)
                rt.globals().restore_writer=restored_writer
                rt.execute('''
                    local sb=update
                    local writer=assert(loadstring([[local previous_update=...; return function(...)
                        writer_calls=writer_calls+1; return previous_update(...) end]],
                        '@mods/test/p33_missile'))(sb)
                    local caller=assert(loadstring([[local previous_update=...; return function(...)
                        return previous_update(...) end]], '@mods/test/innocent'))(writer)
                    update=caller
                    update(0.016)
                    local WH
                    for i=1,100 do local n,v=debug.getupvalue(sb,i); if not n then break end
                        if n=='WH' then WH=v end end
                    local held=assert(WH.held['mods/test/p33_missile'])
                    assert(held.caller==caller)
                    local lower=assert(loadstring([[local target=...; return function(...)
                        below_probe_calls=below_probe_calls+1; return target(...) end]],
                        '@mods/patpatpatrick/mod_lag_finder'))(held.next)
                    for i=1,100 do local n=debug.getupvalue(held.gate,i); if not n then break end
                        if n=='previous_update' then debug.setupvalue(held.gate,i,lower) end end
                    local target=restore_writer and held.writer or held.gate
                    local probe=assert(loadstring([[local target=...; return function(...)
                        probe_calls=probe_calls+1; return target(...) end]],
                        '@mods/patpatpatrick/mod_lag_finder'))(target)
                    debug.setupvalue(held.caller,held.slot,probe)
                    -- Reach maintenance without executing the closed writer after restoration.
                    for i=2,119 do held.gate(0.016) end
                    sb(0.016)
                    local below_before=below_probe_calls
                    bad_returns=0
                    for i=1,241 do if update(0.016)~=123 then bad_returns=bad_returns+1 end end
                    held.ctl.open=true
                    local before=writer_calls
                    for i=1,120 do if update(0.016)~=123 then bad_returns=bad_returns+1 end end
                    released_calls=writer_calls-before
                    measured_below=below_probe_calls-below_before
                ''')
                self.assertEqual(rt.globals().probe_calls,361,'maintenance detached the profiler')
                self.assertEqual(rt.globals().released_calls,120,'released writer lost or duplicated')
                self.assertEqual(rt.globals().measured_below,361,'opening the gate bypassed downstream probes')
                self.assertEqual(rt.globals().base_calls,481)
                self.assertEqual(rt.globals().bad_returns,0)

    def test_diag_alone_does_not_enable_deep_snapshots(self):
        with tempfile.TemporaryDirectory(prefix='sb-snapshot-off-') as tmp:
            home=pathlib.Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text('diag=yes\nthrottle=no\nboot_pause_s=0\nhud=off\nwriters=\n',encoding='utf-8')
            rt=luajit.LuaRuntime()
            rt.globals().os.getenv=lambda key: tmp if key=='LOCALAPPDATA' else None
            rt.execute("CowboyBingusModLoader={}; HD2VehicleCooldown={status='complete'}; update=function() end")
            rt.execute(SOURCE)
            rt.execute('for i=1,3600 do update(0.016) end')
            log=(home/'Logs/SmoothBoot.log').read_text(encoding='utf-8')
            self.assertIn('stats frames=3600',log)
            self.assertNotIn('runtime state ',log)
            self.assertNotIn('runtime C4 ',log)

    def test_multiple_adoptions_preserve_each_callback_once_per_frame(self):
        with tempfile.TemporaryDirectory(prefix='sb-adopt-') as tmp:
            home=pathlib.Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text('throttle=no\nboot_pause_s=0\nhud=off\nwriters=\nwriter_release_s=0\n',encoding='utf-8')
            rt=luajit.LuaRuntime()
            rt.globals().os.getenv=lambda key: tmp if key=='LOCALAPPDATA' else None
            rt.execute('CowboyBingusModLoader={}; base_calls=0; ticks={}; update=function() base_calls=base_calls+1; return 123 end')
            rt.execute(SOURCE)
            rt.execute('''
                bad_returns=0
                for layer=1,3 do
                    ticks[layer]=0
                    update=assert(loadstring([[local previous,layer=...;
                        return function(...) ticks[layer]=ticks[layer]+1; return previous(...) end]],
                        '-- HD2-Addon: mods/test/layer'..layer))(update,layer)
                    for frame=1,20 do
                        if update(0.016)~=123 then bad_returns=bad_returns+1 end
                    end
                end
            ''')
            self.assertEqual(rt.globals().bad_returns,0,'transition lost return value')
            self.assertEqual(rt.globals().base_calls,60)
            self.assertEqual([rt.globals().ticks[i] for i in (1,2,3)],[60,40,20])

    def test_c4_observer_reaches_tick_under_watchdog_metadata(self):
        with tempfile.TemporaryDirectory(prefix='sb-c4-graph-') as tmp:
            home=pathlib.Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text('diag=yes\nsnapshot=yes\nthrottle=no\nboot_pause_s=0\nhud=off\nwriters=\n',encoding='utf-8')
            rt=luajit.LuaRuntime()
            rt.globals().os.getenv=lambda key: tmp if key=='LOCALAPPDATA' else None
            rt.execute('''
                CowboyBingusModLoader={}
                local metadata={}
                for i=1,64 do
                    metadata[i]={}
                    for j=1,64 do metadata[i][j]={} end
                end
                local c4=assert(loadstring([[
                    local bindings={status='ready',armed=false,registered={deploy=true}}
                    local gameplay_guard={status='gameplay',latest={controls_allowed=true}}
                    local gate={owned=false,status='no_local_c4'}
                    local actions={fault=false}
                    local function tick()
                        return bindings.status,gameplay_guard.status,gate.status,actions.fault
                    end
                    local function pass(...) return tick(),... end
                    return function(...) return pass(...) end
                ]], '-- HD2-Addon: mods/etxp/c4_boundary_probe'))()
                update=assert(loadstring([[
                    local metadata,previous_update=...
                    return function(...) if metadata then return previous_update(...) end end
                ]], '-- HD2-Addon: mods/patpatpatrick/mod_lag_finder'))(metadata,c4)
            ''')
            rt.execute(SOURCE)
            rt.execute('for i=1,1800 do update(0.016) end')
            log=(home/'Logs/SmoothBoot.log').read_text(encoding='utf-8')
            self.assertIn('runtime C4 bindings: armed=false',log)
            self.assertIn('status=no_local_c4',log)

    def test_c4_diagnostics_observe_guard_without_calling_it(self):
        with tempfile.TemporaryDirectory(prefix='sb-c4-') as tmp:
            home=pathlib.Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text('diag=yes\nsnapshot=yes\nthrottle=no\nboot_pause_s=0\nhud=off\nwriters=\n',encoding='utf-8')
            rt=luajit.LuaRuntime()
            rt.globals().os.getenv=lambda key: tmp if key=='LOCALAPPDATA' else None
            rt.execute('''
                CowboyBingusModLoader={}; field_calls=0
                update=assert(loadstring([[
                    local bindings={status='unavailable',reason='registration_rejected'}
                    local gameplay_guard={status='native_game_ui_active',latest={controls_allowed=false}}
                    gameplay_guard.fields=function() field_calls=field_calls+1; error('must not be called') end
                    local function tick() return bindings.status,gameplay_guard.status end
                    return function(...) tick(); return ... end
                ]], '-- HD2-Addon: mods/etxp/c4_boundary_probe'))()
            ''')
            rt.execute(SOURCE)
            rt.execute('for i=1,1800 do update(0.016) end')
            log=(home/'Logs/SmoothBoot.log').read_text(encoding='utf-8')
            self.assertIn('runtime C4 bindings: reason=registration_rejected, status=unavailable',log)
            self.assertIn('latest.controls_allowed=false',log)
            self.assertEqual(rt.globals().field_calls,0)

    def test_stable_reheading_function_is_identified_once(self):
        with tempfile.TemporaryDirectory(prefix='sb-perf-') as tmp:
            home=pathlib.Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text('throttle=no\nboot_pause_s=0\nhud=off\nwriters=\nwriter_release_s=0\n',encoding='utf-8')
            rt=luajit.LuaRuntime()
            rt.globals().os.getenv=lambda key: tmp if key=='LOCALAPPDATA' else None
            rt.execute('CowboyBingusModLoader={}; base_calls=0; update=function() base_calls=base_calls+1 end')
            rt.execute(SOURCE)
            rt.execute('''
                head_calls=0; info_calls=0
                local original_info=debug.getinfo
                local previous=update
                test_head=assert(loadstring('local previous=...; return function(...) head_calls=head_calls+1; return previous(...) end',
                    '-- HD2-Addon: mods/test/reheading'))(previous)
                debug.getinfo=function(f,...) if f==test_head then info_calls=info_calls+1 end; return original_info(f,...) end
                for i=1,600 do update=test_head; update(0.016) end
            ''')
            self.assertLessEqual(rt.globals().info_calls,3,'same function re-parsed every frame')
            self.assertEqual(rt.globals().head_calls,600,'head callback duplicated or dropped')
            self.assertEqual(rt.globals().base_calls,600,'base callback duplicated or dropped')

if __name__=='__main__': unittest.main()
