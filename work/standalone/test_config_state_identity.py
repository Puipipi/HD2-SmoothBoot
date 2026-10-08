"""Exercise configuration and boot-state identity through the full runtime."""
from pathlib import Path
import tempfile
import unittest

from lua_test_vm import VM
from test_memory_lifetime import SOURCE, bootstrap


class ConfigStateIdentity(unittest.TestCase):
    def test_gc_defaults_leave_engine_policy_and_explicit_settings_intact(self):
        for game in (False, True):
            for explicit in (None, 400):
                with self.subTest(game=game,explicit=explicit), tempfile.TemporaryDirectory() as tmp:
                    vm=VM(game)
                    try:
                        bootstrap(vm,tmp,source='')
                        cfg=Path(tmp)/'CowboyBingus/Helldivers2/SmoothBoot/config.txt'
                        if explicit is None:cfg.unlink()
                        else:cfg.write_text('gc_pause=400\ngc_stepmul=0\nexclude=lte/helmet_cape_passives\n',encoding='utf-8')
                        original=cfg.read_bytes() if cfg.exists() else None
                        vm.run('''
                            gc_tuning={}
                            local original=collectgarbage
                            collectgarbage=function(kind,value)
                                if kind=='setpause' or kind=='setstepmul' then
                                    gc_tuning[kind]=value
                                end
                                return original(kind,value)
                            end
                        ''')
                        vm.run(SOURCE)
                        if explicit is None:
                            vm.run("assert(next(gc_tuning)==nil,'new install changed shared GC policy')")
                            self.assertIn('gc_pause=0\n',cfg.read_text(encoding='utf-8'))
                        else:
                            vm.run("assert(gc_tuning.setpause==400 and gc_tuning.setstepmul==nil)")
                            self.assertEqual(cfg.read_bytes(),original)
                    finally:vm.close()

    def test_unprintable_foreign_error_does_not_escape_enabled_governor(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                vm=VM(game)
                try:
                    bootstrap(vm,tmp,source='')
                    vm.run('''
                        fault=setmetatable({},{__tostring=function()error('cannot print error')end})
                        update=function()error(fault,0)end
                    ''')
                    vm.run(SOURCE)
                    vm.run('''
                        for i=1,5 do
                            local ok=pcall(update,1/120)
                            assert(ok,'error formatting raised outside chain protection')
                        end
                        assert(HD2SmoothBoot.errors==5,'original errors were not counted')
                    ''')
                finally:vm.close()

    def test_private_windows_bindings_survive_conflicting_plain_declarations(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                vm=VM(game)
                try:
                    bootstrap(vm,tmp,source='')
                    home=Path(tmp)/'CowboyBingus/Helldivers2'
                    (home/'SmoothBoot/config.txt').unlink()
                    (home/'SmoothBoot').rmdir();(home/'Logs').rmdir()
                    home.rmdir();home.parent.rmdir()
                    # Incompatible argument types reject our strings BEFORE a
                    # native call. Never call Windows through a malformed ABI.
                    vm.run('''
                        local ffi=require('ffi')
                        ffi.cdef[[void *GetModuleHandleA(int);
                                  void *GetProcAddress(int,int);]]
                        poisoned_plain_type=tostring(ffi.typeof(ffi.load('kernel32').GetModuleHandleA))
                        local original_open=io.open
                        io.open=function(path,...)
                            if path=='SmoothBoot.log' then
                                path=os.getenv('LOCALAPPDATA')..'/fallback.log'
                            end
                            return original_open(path,...)
                        end
                    ''')
                    vm.run(SOURCE)
                    self.assertTrue((home/'SmoothBoot/config.txt').is_file(),
                                    'foreign plain C declaration blocked our directories')
                    self.assertTrue((home/'SmoothBoot/Collect-Logs.bat').is_file())
                    vm.run('''
                        local ffi=require('ffi')
                        assert(tostring(ffi.typeof(ffi.load('kernel32').GetModuleHandleA))==poisoned_plain_type,
                               'foreign declaration was overwritten')
                    ''')
                finally:vm.close()

    def test_underscore_exclusion_does_not_match_separate_words(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                vm=VM(game)
                try:
                    bootstrap(vm,tmp,source='')
                    cfg=Path(tmp)/'CowboyBingus/Helldivers2/SmoothBoot/config.txt'
                    with cfg.open('a',encoding='utf-8') as out:
                        out.write('exclude=ALPHA_BETA,lte/helmet_cape_passives\n')
                    vm.run('''
                        for _,name in ipairs({'alpha','beta','alpha_beta'}) do
                            update=assert(loadstring([[local previous=...;
                                return function(...)return previous(...)end]],
                                '@mods/test/'..name))(update)
                        end
                    ''')
                    vm.run(SOURCE)
                    vm.run('''
                        step(1)
                        local names=HD2SmoothBoot.find_excluded_below()
                        assert(#names==1 and names[1]=='mods/test/alpha_beta',
                            'underscore fragment split into unrelated matches: '..table.concat(names,','))
                    ''')
                finally:vm.close()

    def test_boot_pause_restores_replacement_under_the_same_global_name(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                vm=VM(game)
                try:
                    bootstrap(vm,tmp,boot_pause=1)
                    vm.run('''
                        ReloadingMod={frames=0,stopped=false}
                        local old=ReloadingMod
                        step(30);assert(old.stopped,'original state was not paused')
                        ReloadingMod={frames=0,stopped=false}
                        step(30);assert(ReloadingMod.stopped,'replacement was not paused')
                        step(90)
                        assert(not old.stopped,'original state did not restore')
                        assert(not ReloadingMod.stopped,'replacement state remained paused forever')
                        local seen=setmetatable({old,ReloadingMod},{__mode='v'})
                        old=nil;ReloadingMod=nil;full_gc()
                        assert(count(seen)==0,'restored replacement states remain rooted')
                    ''')
                finally:vm.close()

    def test_configured_reentry_cap_is_read_and_clamped(self):
        for game in (False, True):
            for setting,cap in ((1,1),(5,5),(99,16),(0,1),(1.9,1)):
                with self.subTest(game=game,setting=setting), tempfile.TemporaryDirectory() as tmp:
                    vm=VM(game)
                    try:
                        bootstrap(vm,tmp,source='')
                        cfg=Path(tmp)/'CowboyBingus/Helldivers2/SmoothBoot/config.txt'
                        with cfg.open('a',encoding='utf-8') as out:out.write(f'reentry_max={setting}\n')
                        vm.run('''
                            depth=0;max_depth=0;redispatch=true
                            update=function(...)
                                depth=depth+1;max_depth=math.max(max_depth,depth)
                                if depth>20 then depth=depth-1;error('unbounded dispatch')end
                                if redispatch then
                                    local result=update(...);depth=depth-1;return result
                                end
                                depth=depth-1;return 29,nil
                            end
                        ''')
                        vm.run(SOURCE)
                        vm.run(f'''
                            update(1/120)
                            assert(max_depth=={cap+1},'configured cap ignored: '..max_depth)
                            assert(HD2SmoothBoot.reentry_cycles==1,'cycle was not recorded')
                            redispatch=false
                            local function check(...)
                                assert(select('#',...)==2 and (...)==29,'recovery lost results')
                            end
                            check(update(1/120))
                        ''')
                    finally:vm.close()


if __name__=='__main__':unittest.main()
