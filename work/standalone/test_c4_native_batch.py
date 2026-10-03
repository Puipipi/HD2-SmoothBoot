"""Fresh native-code verification contracts, reading owned process memory only."""
from pathlib import Path
import unittest
import lupa.luajit21 as luajit

class NativeBatch(unittest.TestCase):
    def setUp(self):
        self.rt=luajit.LuaRuntime(unpack_returned_tuples=True)
        source=Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')
        block=source[source.index('-- BEGIN C4 NATIVE BATCH'):source.index('-- END C4 NATIVE BATCH')]
        self.rt.execute('M={};cfg={};excludes={};log=function()end;C4Batch={};'
                        'function function_chunk()return "" end;function is_excluded()return false end')
        self.rt.execute(block+'\nbatch=M.c4_native_batch.guard_batch')
        self.rt.execute(r'''
ffi=require('ffi');ffi.cdef[[void *GetCurrentProcess(void);
int ReadProcessMemory(void *,const void *,void *,size_t,size_t *);]]
k=ffi.load('kernel32');proc=k.GetCurrentProcess();mem=ffi.new('uint8_t[65536]')
base=tonumber(ffi.cast('uintptr_t',mem));buffer=ffi.new('uint8_t[4096]');count=ffi.new('size_t[1]')
calls=0;fail_large=false;short_large=false;fail_all=false;guards={}
function read(at,n)
 calls=calls+1
 if fail_all or fail_large and n>31 then error('compat_read_unavailable:'..at)end
 if short_large and n>31 then return 'x' end
 count[0]=0
 assert(k.ReadProcessMemory(proc,ffi.cast('const void *',base+at),buffer,n,count)~=0,'compat_read_unavailable')
 assert(tonumber(count[0])==n,'compat_short_read');return ffi.string(buffer,n)
end
for i=0,199 do local at=4096+i*64;mem[at]=i%256;guards[i+1]={at=at,bytes=read(at,31),label='guard'..i}end
function original()
 for _,g in ipairs(guards)do assert(read(g.at,#g.bytes)==g.bytes,'compat_live_code_changed:'..g.label)end
end
check=batch.make(guards,read)
''')

    def test_fresh_per_invocation_and_reduced_reads(self):
        self.rt.execute('calls=0;original();assert(calls==200);calls=0;check();assert(calls==4);'
                        'calls=0;check();assert(calls==4);mem[4096]=255;assert(not pcall(check))')

    def test_every_guard_mutation_keeps_original_failure_label(self):
        self.rt.execute("for _,g in ipairs(guards)do local old=mem[g.at];mem[g.at]=255;"
                        "local a,e=pcall(original);local b,f=pcall(check);assert(a==b and not a);"
                        "assert(e:match('compat_live_code_changed:.*')==f:match('compat_live_code_changed:.*'));mem[g.at]=old end")

    def test_unobserved_gap_is_not_a_guard(self):
        self.rt.execute('mem[4096+40]=255;original();check()')

    def test_larger_read_failure_and_short_read_use_original_fields(self):
        self.rt.execute('fail_large=true;check();fail_large=false;short_large=true;check()')

    def test_original_failure_error_and_order_preserved(self):
        self.rt.execute("fail_all=true;local a,e=pcall(original);local b,f=pcall(check);"
                        "assert(not a and not b);assert(e:match('compat_read_unavailable:.*')==f:match('compat_read_unavailable:.*'))")

    def test_growth_replacement_address_and_length(self):
        self.rt.execute('check();guards[201]={at=20000,bytes=read(20000,8),label="seat"};check();'
                        'mem[20000]=1;assert(not pcall(check));mem[20000]=0;'
                        'guards[201]={at=22000,bytes=read(22000,16),label="seat2"};check();'
                        'guards[201].at=23000;check();guards[201].bytes=read(23000,4);check();'
                        'mem[23000]=1;assert(not pcall(check))')

    def test_sparse_page_fields_stay_individual(self):
        self.rt.execute('guards={{at=4096,bytes=read(4096,4),label="a"},'
                        '{at=8000,bytes=read(8000,4),label="b"}};check=batch.make(guards,read);'
                        'calls=0;check();assert(calls==2)')

    def test_page_boundaries_and_duplicate_guards(self):
        self.rt.execute('guards={{at=8190,bytes=read(8190,8),label="cross"},'
                        '{at=8190,bytes=read(8190,4),label="duplicate"},'
                        '{at=8200,bytes=read(8200,8),label="next"}};check=batch.make(guards,read);'
                        'check();mem[8191]=255;assert(not pcall(check))')

if __name__=='__main__':unittest.main()
