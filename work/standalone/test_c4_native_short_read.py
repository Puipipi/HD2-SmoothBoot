"""Native single-chunk reads must stay fresh and preserve the original contract."""
from pathlib import Path
import unittest
import lupa.luajit21 as luajit


class NativeShortRead(unittest.TestCase):
    def setUp(self):
        self.rt=luajit.LuaRuntime(unpack_returned_tuples=True)
        source=Path(__file__).with_name('smoothboot.lua').read_text(encoding='utf-8')
        block=source[source.index('-- BEGIN C4 NATIVE BATCH'):source.index('-- END C4 NATIVE BATCH')]
        self.rt.execute('M={};cfg={};excludes={};log=function()end;C4Batch={};'
                        'function function_chunk()return "" end;function is_excluded()return false end')
        self.rt.execute(block+'\nmake_short=M.c4_native_batch.make_short_reader')
        self.rt.execute(r'''
ffi=require('ffi');memory=ffi.new('uint8_t[16384]');memory[64]=42
api={};game=0;calls=0;bad=nil
function api.read(at,n)
 calls=calls+1
 if bad=='nil' then return nil elseif bad=='short' then return ''
 elseif bad=='table' then return {'a','b','c','d'}end
 return ffi.string(memory+at,n)
end
original=(function()
 local api,game=api,game
 local function read(rva,n)
  assert(rva>=0 and n>0 and rva+n<=0x10000000,'compat_read_bounds')
  local parts={}
  for at=0,n-1,4096 do
   local count=math.min(4096,n-at)
   local b=assert(api.read(game+rva+at,count),'compat_read_unavailable:'..string.format('%x',rva+at))
   assert(#b==count,'compat_short_read');parts[#parts+1]=b
  end
  return table.concat(parts)
 end
 return read
end)()
function replace_cell(name,value)
 for i=1,16 do if debug.getupvalue(original,i)==name then debug.setupvalue(original,i,value);return end end
 error('missing original cell')
end
function allocation(f)
 collectgarbage('collect');collectgarbage('stop')
 local before=collectgarbage('count')
 for i=1,1000 do f(64,4)end
 local delta=collectgarbage('count')-before;collectgarbage('restart');return delta
end
''')

    def test_single_chunk_avoids_transient_parts_allocation(self):
        self.rt.execute("assert(type(make_short)=='function','missing allocation-reducing native reader');"
                        "short=make_short(original);local baseline=allocation(original);local candidate=allocation(short);"
                        "assert(candidate<baseline/2,'short reads still allocate temporary parts tables')")

    def test_fresh_bytes_and_large_chunk_contract(self):
        self.rt.execute('short=make_short(original);for _,n in ipairs({1,4,4096,4097,8192})do '
                        'calls=0;local a=original(64,n);local expected=calls;calls=0;'
                        'assert(short(64,n)==a and calls==expected)end;'
                        'memory[64]=43;assert(short(64,4):byte(1)==43)')

    def test_bounds_nil_short_failures_match_original(self):
        self.rt.execute(r'''
short=make_short(original)
for _,args in ipairs({{-1,4},{0,0},{0x10000000,4},{0,4}})do
 for _,mode in ipairs({'nil','short'})do
  bad=mode;local a,e=pcall(original,args[1],args[2]);local b,f=pcall(short,args[1],args[2])
  assert(not a and not b);assert(e:match('compat_[%w_:]+')==f:match('compat_[%w_:]+'))
 end
end
''')

    def test_api_and_module_upvalue_changes_are_observed(self):
        self.rt.execute("short=make_short(original);replace_cell('game',32);"
                        "memory[96]=77;assert(short(64,4)==original(64,4));"
                        "replace_cell('api',{read=function(at,n)assert(at==96);return string.rep('z',n)end});"
                        "assert(short(64,4)=='zzzz')")

    def test_api_read_replacement_is_observed_without_retry(self):
        self.rt.execute("short=make_short(original);api.read=function(at,n)calls=calls+1;return string.rep('x',n)end;"
                        "calls=0;assert(short(64,4)=='xxxx' and calls==1)")

    def test_nonstring_return_uses_original_concat_semantics(self):
        self.rt.execute("short=make_short(original);bad='table';calls=0;local a=pcall(original,64,4);"
                        "local b=pcall(short,64,4);assert(not a and not b and calls==2)")


if __name__=='__main__':unittest.main()
