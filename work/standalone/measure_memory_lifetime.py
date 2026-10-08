"""Measure retained Lua heap in isolated VMs, never the running game."""
import argparse
import json
from pathlib import Path
import re
import tempfile

from lua_test_vm import VM
from test_memory_lifetime import bootstrap


def measure(source, game):
    with tempfile.TemporaryDirectory() as tmp:
        vm = VM(game)
        try:
            bootstrap(vm, tmp, source=source, boot_pause=1)
            vm.run('''
                observed=setmetatable({},{__mode='v'})
                AuditMod={frames=0,stopped=false,payload=string.rep('a',1024*1024)}
                observed[1]=AuditMod;step(30);assert(AuditMod.stopped)
                step(150);assert(not AuditMod.stopped)
                AuditMod=nil;full_gc()
            ''')
            boot_count=int(vm.run('return tostring(count(observed))'))
            boot_heap=float(vm.run("return tostring(collectgarbage('count'))"))
            vm.run('''
                step(20000);full_gc();heap={}
                for batch=1,5 do
                    step(20000);full_gc()
                    heap[#heap+1]=collectgarbage('count')
                end
            ''')
            steady=[float(v) for v in vm.run("return table.concat(heap,',')").split(',')]
            return dict(runtime='game-lua51.dll-isolated' if game else 'lupa-luajit21',
                        boot_state_retained=boot_count,boot_heap_kib=boot_heap,
                        steady_after_gc_kib=steady,steady_range_kib=max(steady)-min(steady))
        finally:
            vm.close()


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',type=Path,default=Path(__file__).with_name('smoothboot.lua'))
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    source=args.source.read_text(encoding='utf-8-sig')
    result=dict(version=re.search(r"version='([\d.]+)'",source).group(1),
                source=str(args.source.resolve()),live_game=False,
                cases=[measure(source,game) for game in (False,True)])
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))
