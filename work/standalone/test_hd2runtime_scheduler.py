"""Unchanged HD2Runtime 0.28.1 scheduler with synthetic watches and metrics.

Fixture: resource d94c7a78c742648e in deployed layer 336, SHA256
recorded beside the fixture. Tests invoke no game reads, writes or inputs.
"""
import json
from pathlib import Path
import tempfile
import unittest

from lua_test_vm import VM

HERE=Path(__file__).parent
SOURCE=(HERE/'smoothboot.lua').read_text('utf-8')
SCHEDULER=(HERE/'fixtures/hd2runtime_scheduler_0_28_1.lua').read_text('utf-8')


class HD2RuntimeScheduler(unittest.TestCase):
    def test_exact_tick_counts_returns_and_cancel_in_either_load_order(self):
        for game in (False,True):
            for first in (False,True):
                for enabled in (False,True):
                    with self.subTest(game=game,runtime_first=first,enabled=enabled), tempfile.TemporaryDirectory() as tmp:
                        home=Path(tmp)/'CowboyBingus/Helldivers2'
                        (home/'SmoothBoot').mkdir(parents=True);(home/'Logs').mkdir()
                        (home/'SmoothBoot/config.txt').write_text(
                            f'enabled={"yes" if enabled else "no"}\nthrottle=no\n'
                            'boot_pause_s=0\nwriters=\nhud=off\n',encoding='utf-8')
                        vm=VM(game)
                        try:
                            vm.run('os.getenv=function(k) if k=="LOCALAPPDATA" then return '
                                   +json.dumps(tmp.replace('\\','/'))+' end end;CowboyBingusModLoader={};')
                            vm.run('''
                                ticks=0;game_calls=0;watch_ticks=0;elapsed_dt=0
                                package.preload['hd2runtime/runtime/metrics']=function()return {
                                    count=function(k)if k=='scheduler.ticks'then ticks=ticks+1 end end,
                                    now=function()return 0 end,elapsed=function()end}end
                                package.preload['hd2runtime/runtime/diagnostics']=function()
                                    return {telemetry_state={enabled=false}}end
                                package.preload['hd2runtime/runtime/log']=function()
                                    return {emit=function()end}end
                                update=function(dt,a,b)
                                    assert(dt==0.016 and a==false and b==19,'forwarded arguments changed')
                                    game_calls=game_calls+1;return false,nil,23,nil
                                end
                            ''')
                            vm.run('scheduler=assert(loadstring([====['+SCHEDULER+
                                   ']====],"@hd2runtime/runtime/scheduler"))()')
                            watch='''
                                watch={status='active',cancel=function()watch.status='cancelled'end,
                                    tick=function(dt)watch_ticks=watch_ticks+1;elapsed_dt=elapsed_dt+dt end}
                                scheduler.attach(watch)
                            '''
                            if first:vm.run(watch)
                            vm.run(SOURCE)
                            if not first:vm.run(watch)
                            vm.run('''
                                local function frame()
                                    local function check(...)
                                        assert(select('#',...)==4,'scheduler return arity changed')
                                        assert(select(1,...)==false and select(3,...)==23)
                                    end
                                    check(update(0.016,false,19))
                                end
                                for i=1,240 do frame()end
                                assert(game_calls==240 and ticks==240 and watch_ticks==240,'duplicate or missing tick')
                                assert(math.abs(elapsed_dt-240*0.016)<0.00001,'elapsed time changed')
                                watch.cancel();frame()
                                assert(scheduler.active()==0,'cancelled watch retained')
                                scheduler.attach({status='active',cancel=function()end,
                                    tick=function()watch_ticks=watch_ticks+1 end})
                                for i=1,240 do frame()end
                                assert(game_calls==481 and watch_ticks==481 and ticks==481,'reattach duplicated dispatch')
                                assert(not HD2SmoothBoot.reentry_cycles,'ordinary Runtime scheduler triggered a cycle')
                            ''')
                        finally:vm.close()


if __name__=='__main__':unittest.main()
