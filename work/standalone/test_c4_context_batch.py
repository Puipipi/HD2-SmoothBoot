"""C4 context validation contracts; native memory belongs to this test process."""
from pathlib import Path
import unittest
import lupa.luajit21 as luajit

class GuardBatch(unittest.TestCase):
    def setUp(self):
        self.rt=luajit.LuaRuntime(unpack_returned_tuples=True)
        source=Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')
        block=source[source.index('-- BEGIN C4 CONTEXT BATCH'):source.index('-- END C4 CONTEXT BATCH')]
        self.rt.execute('M={};cfg={enabled=true,c4_context_batch=true};excludes={};log=function()end;'
                        'function is_excluded()return false end;function function_chunk()return "" end;'
                        'C4Batch={signature=function()end}')
        self.rt.globals().batch=self.rt.execute(block+'\nreturn M.c4_context_batch.guard_batch')
        self.rt.execute(r'''
          ffi=require('ffi');ffi.cdef[[void *GetCurrentProcess(void);
          int ReadProcessMemory(void *,const void *,void *,size_t,size_t *);]]
          k=ffi.load('kernel32');process=k.GetCurrentProcess()
          memory=ffi.new('uint8_t[8192]');address=tonumber(ffi.cast('uintptr_t',memory))
          buffer=ffi.new('uint8_t[4096]');count=ffi.new('size_t[1]')
          api={};reads=0;fail_large=false;short_large=false;fail_all=false
          function api.read(at,n)
            reads=reads+1;assert(n>0 and n<=4096)
            if fail_all or fail_large and n>4 then return nil end
            if short_large and n>4 then return 'x' end
            count[0]=0
            if k.ReadProcessMemory(process,ffi.cast('const void *',at),buffer,n,count)==0 or
               tonumber(count[0])~=n then return nil end
            return ffi.string(buffer,n)
          end
          guards={}
          for i=0,199 do
            memory[i*8]=i%256
            guards[#guards+1]={at=address+i*8,bytes=api.read(address+i*8,4)}
          end
          function original()
            local count,total=0,0
            for _,g in ipairs(guards)do
              local n=#g.bytes;count=count+1;total=total+n
              assert(count<=768 and total<=32768,'snapshot_validation_budget')
              local b=assert(api.read(g.at,n),'read_unavailable')
              assert(#b==n,'short_read')
              if b~=g.bytes then return false end
            end
            return true
          end
          check=batch.new(guards,api)
        ''')

    def test_reduces_calls_and_reads_fresh_each_validation(self):
        self.rt.execute('reads=0;assert(original());assert(reads==200);reads=0;assert(check());assert(reads==1);'
                        'reads=0;assert(check());assert(reads==1);memory[800]=255;assert(not check());assert(not original())')

    def test_all_original_fields_and_original_error_order(self):
        self.rt.execute('for i=0,199 do local before=memory[i*8];memory[i*8]=255;'
                        'assert(check()==original());memory[i*8]=before end')

    def test_unwatched_gap_changes_are_ignored(self):
        self.rt.execute('memory[5]=255;assert(original());assert(check())')

    def test_large_failure_or_short_result_falls_back(self):
        self.rt.execute('fail_large=true;reads=0;assert(check());assert(reads==201);'
                        'fail_large=false;short_large=true;assert(check());short_large=false')

    def test_original_field_read_failure_is_preserved(self):
        self.rt.execute("fail_all=true;local a,e=pcall(check);assert(not a and e:find('read_unavailable'));"
                        "local a,e=pcall(original);assert(not a and e:find('read_unavailable'))")

    def test_growth_replacement_address_and_size_changes(self):
        self.rt.execute('assert(check());guards[#guards+1]={at=address+2000,bytes=api.read(address+2000,4)};'
                        'assert(check());memory[2000]=1;assert(not check());'
                        'guards[#guards]={at=address+2100,bytes=api.read(address+2100,8)};assert(check());'
                        'guards[#guards].at=address+2200;assert(check());memory[2207]=1;assert(not check())')

    def test_sparse_reads_do_not_exceed_original_budget(self):
        self.rt.execute("guards={};for i=0,199 do guards[i+1]={at=address+i*32,bytes=api.read(address+i*32,4)}end;"
                        "local ck=batch.new(guards,api);reads=0;assert(ck());assert(reads==200)")

    def test_duplicate_overlapping_guards_preserved(self):
        self.rt.execute('guards={ {at=address,bytes=api.read(address,8)}, {at=address,bytes=api.read(address,4)} };'
                        'local ck=batch.new(guards,api);assert(ck());guards[2].bytes=string.rep("x",4);'
                        'assert(not ck());assert(not original())')

    def test_near_budget_uses_original_reads_without_extra_retry(self):
        self.rt.execute('guards={};for i=1,768 do guards[i]={at=address,bytes=api.read(address,4)}end;'
                        'local ck=batch.new(guards,api);reads=0;assert(ck());assert(reads==768);'
                        'guards={};for i=1,8 do guards[i]={at=address,bytes=api.read(address,4096)}end;'
                        'local total=0;local ck=batch.new(guards,api,function(n)total=total+n end);'
                        'assert(ck());assert(total==32768);fail_all=true;reads=0;'
                        'local ok=pcall(ck);assert(not ok and reads==1)')

if __name__=='__main__':unittest.main()


