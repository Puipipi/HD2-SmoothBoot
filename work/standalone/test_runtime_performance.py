"""Real wrapper regression: a watchdog repeatedly publishes the same head."""
import pathlib
import tempfile
import unittest
import lupa.luajit21 as luajit

SOURCE=pathlib.Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')

class RuntimePerformance(unittest.TestCase):
    def test_c4_observer_reaches_tick_under_watchdog_metadata(self):
        with tempfile.TemporaryDirectory(prefix='sb-c4-graph-') as tmp:
            home=pathlib.Path(tmp)/'CowboyBingus/Helldivers2'
            (home/'SmoothBoot').mkdir(parents=True)
            (home/'Logs').mkdir()
            (home/'SmoothBoot/config.txt').write_text('diag=yes\nthrottle=no\nboot_pause_s=0\nhud=off\nwriters=\n',encoding='utf-8')
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
            (home/'SmoothBoot/config.txt').write_text('diag=yes\nthrottle=no\nboot_pause_s=0\nhud=off\nwriters=\n',encoding='utf-8')
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
