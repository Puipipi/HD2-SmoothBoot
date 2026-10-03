"""Opt-in CPU sampler must be bounded, inert by default, and always stop."""
from pathlib import Path
import unittest
import lupa.luajit21 as luajit

class CPUProfile(unittest.TestCase):
    def setUp(self):
        self.rt=luajit.LuaRuntime(unpack_returned_tuples=True)
        source=Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')
        block=source[source.index('-- BEGIN C4 CPU PROFILE'):source.index('-- END C4 CPU PROFILE')]
        self.rt.execute('M={};cfg={enabled=true,c4_cpu_profile=false};messages={};'
                        'log=function(s)messages[#messages+1]=s end;starts=0;stops=0;bad_start=false;bad_dump=false;'
                        'fake={start=function(mode,cb) starts=starts+1;if bad_start then error("failed")end;callback=cb end,'
                        'stop=function()stops=stops+1 end,'
                        'dumpstack=function()if bad_dump then error("failed dump")end;return "mods/etxp/c4_boundary_probe:2840;" end};'
                        'package.loaded["jit.profile"]=fake')
        self.rt.execute(block+'\ncpu=M.c4_cpu_profile')

    def test_default_off_and_bounded_single_run(self):
        self.rt.execute('cpu.poll(1);assert(starts==0);cfg.c4_cpu_profile=true;cpu.poll(10);assert(starts==1);'
                        'callback(nil,3,"I");cpu.poll(54);assert(stops==0);cpu.poll(55);assert(stops==1);'
                        'cpu.poll(100);assert(starts==1);cfg.c4_cpu_profile=false;cpu.poll(101);'
                        'cfg.c4_cpu_profile=true;cpu.poll(102);assert(starts==2);cpu.stop("test")')

    def test_hot_disable_and_global_disable_stop(self):
        self.rt.execute('cfg.c4_cpu_profile=true;cpu.poll(10);cfg.c4_cpu_profile=false;cpu.poll(11);'
                        'assert(stops==1 and not cpu.running);cfg.c4_cpu_profile=true;cpu.poll(12);'
                        'cfg.enabled=false;cpu.poll(13);assert(stops==2 and not cpu.running)')

    def test_failed_start_stops_and_does_not_retry_every_frame(self):
        self.rt.execute('bad_start=true;cfg.c4_cpu_profile=true;cpu.poll(10);cpu.poll(11);'
                        'assert(starts==1 and stops==1 and not cpu.running)')

    def test_dump_failure_cannot_escape_callback(self):
        self.rt.execute('cfg.c4_cpu_profile=true;cpu.poll(10);bad_dump=true;callback(nil,1,"G");'
                        'assert(cpu.errors==1);cpu.stop("test");assert(stops==1)')

    def test_samples_and_vm_states_are_reported(self):
        self.rt.execute('cfg.c4_cpu_profile=true;cpu.poll(10);callback(nil,5,"I");callback(nil,2,"G");'
                        'cpu.stop("test");local text=table.concat(messages," ");'
                        'assert(text:find("samples=7",1,true) and text:find("G=2",1,true) and text:find("I=5",1,true))')

    def test_unique_stacks_are_bounded(self):
        self.rt.execute('cfg.c4_cpu_profile=true;cpu.poll(10);local i=0;fake.dumpstack=function()i=i+1;return tostring(i)end;'
                        'for n=1,800 do callback(nil,1,"I")end;assert(cpu.unique<=512);cpu.stop("test")')

if __name__=='__main__':unittest.main()
