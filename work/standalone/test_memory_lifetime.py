"""Smooth-owned lifetime checks in isolated LuaJIT states; no game attachment.

Weak observers and full collections distinguish live references from GC lag.
No foreign native reader or game process is accessed.
"""
import json
from pathlib import Path
import tempfile
import unittest

from lua_test_vm import VM

SOURCE = Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')

def bootstrap(vm, tmp, source=SOURCE, boot_pause=0, gc_pause=0):
    home = Path(tmp)/'CowboyBingus/Helldivers2'
    (home/'SmoothBoot').mkdir(parents=True)
    (home/'Logs').mkdir()
    (home/'SmoothBoot/config.txt').write_text(
        f'enabled=yes\nthrottle=no\nwriters=\ngc_pause={gc_pause}\n'
        f'boot_pause_s={boot_pause}\n', encoding='utf-8')
    vm.run('os.getenv=function(k) if k=="LOCALAPPDATA" then return '
           +json.dumps(tmp.replace('\\', '/'))+' end end;'
           'clock=1000;os.clock=function()return clock end;'
           'CowboyBingusModLoader={};update=function()return false,nil,17,nil end;'
           'function step(n)for i=1,n do clock=clock+1/120;update(1/120)end end;'
           'function full_gc()collectgarbage("collect");collectgarbage("collect")end;'
           'function count(t)local n=0;for _ in pairs(t)do n=n+1 end;return n end')
    vm.run(source)


class MemoryLifetime(unittest.TestCase):
    def test_boot_pause_drops_restored_foreign_state(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                vm = VM(game)
                try:
                    bootstrap(vm, tmp, boot_pause=1)
                    vm.run('''
                        observed=setmetatable({},{__mode='v'})
                        AuditMod={frames=0,stopped=false,payload=string.rep('a',1024*1024)}
                        observed[1]=AuditMod
                        step(30);assert(AuditMod.stopped,'boot pause path was not reached')
                        step(150);assert(not AuditMod.stopped,'pause was not restored')
                        AuditMod=nil;full_gc()
                        assert(observed[1]==nil,'released boot state remains rooted by Smooth')
                    ''')
                finally:
                    vm.close()


    def test_steady_update_heap_has_no_linear_retained_growth(self):
        for game in (False, True):
            for pause in (0, 400):
                with self.subTest(game=game,gc_pause=pause), tempfile.TemporaryDirectory() as tmp:
                    vm = VM(game)
                    try:
                        bootstrap(vm, tmp, gc_pause=pause)
                        vm.run('''
                            step(20000);full_gc()
                            local low,high=math.huge,0
                            for batch=1,5 do
                                step(20000);full_gc()
                                local kb=collectgarbage('count')
                                low=math.min(low,kb);high=math.max(high,kb)
                            end
                            assert(high-low<128,'steady retained heap grew: '..(high-low)..' KiB')
                        ''')
                    finally:
                        vm.close()

    def test_discarded_render_closures_are_not_rooted_by_discovery(self):
        for game in (False, True):
            with self.subTest(game=game), tempfile.TemporaryDirectory() as tmp:
                vm = VM(game)
                try:
                    bootstrap(vm, tmp)
                    vm.run('''
                        local seen=setmetatable({},{__mode='v'})
                        for i=1,512 do
                            local payload=string.rep(tostring(i),1024)
                            render=function()return payload end
                            seen[i]=render;step(1)
                        end
                        render=nil;step(1);full_gc()
                        assert(count(seen)==0,'discarded render callbacks retained: '..count(seen))
                    ''')
                finally:
                    vm.close()


if __name__=='__main__':
    unittest.main()
