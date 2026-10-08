"""Isolated LuaJIT VMs; never attach to the running game."""
import ctypes
import os
import lupa.luajit21 as luajit

DLL = os.environ.get("HD2_LUA_DLL", r"D:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\bin\lua51.dll")

class VM:
    def __init__(self, game):
        self.game=game
        if not game:
            self.rt=luajit.LuaRuntime(unpack_returned_tuples=True)
            return
        self.dll=ctypes.CDLL(DLL)
        for name,args in {
            'luaL_openlibs':[ctypes.c_void_p],
            'luaL_loadbuffer':[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_size_t,ctypes.c_char_p],
            'lua_pcall':[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int],
            'lua_tolstring':[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_size_t)],
            'lua_settop':[ctypes.c_void_p,ctypes.c_int],
            'lua_close':[ctypes.c_void_p],
        }.items():getattr(self.dll,name).argtypes=args
        self.dll.luaL_newstate.restype=ctypes.c_void_p
        self.dll.lua_tolstring.restype=ctypes.c_char_p
        self.state=self.dll.luaL_newstate()
        self.dll.luaL_openlibs(self.state)

    def run(self, code):
        if not self.game:return self.rt.execute(code)
        data=code.encode('utf-8')
        rc=self.dll.luaL_loadbuffer(self.state,data,len(data),b'@private/smooth-test.lua')
        if not rc:rc=self.dll.lua_pcall(self.state,0,1,0)
        value=self.dll.lua_tolstring(self.state,-1,None)
        result=value.decode('utf-8') if value else None
        self.dll.lua_settop(self.state,0)
        if rc:raise RuntimeError(result)
        return result

    def close(self):
        if self.game:self.dll.lua_close(self.state)
