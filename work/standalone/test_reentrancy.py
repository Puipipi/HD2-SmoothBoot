"""Re-entrancy: a chain member that forwards the call back through `update`.

Reported by a user: the pass-through path (role 2 - an adopted chain calling back
into the wrapper) has no re-entrancy guard, so a member that re-dispatches via
the global `update` can recurse without bound and exhaust the C stack.

The crash it would explain: `ntdll.dll+0x393c4`, instruction `push r14` - a push
hitting the stack guard page, i.e. stack exhaustion, not a wild write.

    python -m unittest discover -s work/standalone -p 'test_reentrancy.py'
"""
import pathlib
import tempfile
import unittest

import lupa.luajit21 as luajit

from test_runtime_tools import SOURCE


def start_with_chain(root, chain_source, frames=3):
    """Load the module with a pre-existing chain, then drive it."""
    runtime = luajit.LuaRuntime()
    runtime.globals().os.getenv = lambda key: str(root) if key == 'LOCALAPPDATA' else None
    runtime.execute('CowboyBingusModLoader = {}; ' + chain_source)
    runtime.execute(SOURCE)
    return runtime


class Reentrancy(unittest.TestCase):
    def test_member_that_redispatches_through_update_is_broken_not_recursed(self):
        """A member calling `update` again must be stopped by a depth guard."""
        with tempfile.TemporaryDirectory(prefix='sb-reentry-') as tmp:
            root = pathlib.Path(tmp)
            runtime = start_with_chain(root, r'''
                depth = 0
                max_depth = 0
                update = function(...)
                    depth = depth + 1
                    if depth > max_depth then max_depth = depth end
                    if depth > 200 then
                        depth = depth - 1
                        error('runaway recursion: depth exceeded 200')
                    end
                    local r = rawget(_G, 'update')(...)      -- re-dispatch
                    depth = depth - 1
                    return r
                end
            ''')
            runtime.execute(r'ours = update')
            runtime.execute(r'pcall(function() return ours(0.016) end)')
            max_depth = runtime.eval('max_depth')
            log = (root / 'CowboyBingus/Helldivers2/Logs/SmoothBoot.log').read_text(encoding='utf-8')
            self.assertLess(max_depth, 200,
                            'the chain re-entered the wrapper %d times: no re-entrancy guard' % max_depth)
            self.assertIn('cycle', log.lower(),
                          'the wrapper must log that it broke a re-entrancy cycle')

    def test_peer_runtime_that_redispatches_is_broken_too(self):
        """Same shape, but the re-dispatching wrapper is named like the MDL runtime."""
        with tempfile.TemporaryDirectory(prefix='sb-reentry-') as tmp:
            root = pathlib.Path(tmp)
            runtime = start_with_chain(root, r'''
                depth = 0
                max_depth = 0
                local mdl = assert(loadstring([[
                    local depth_ref, bump = ...
                    return function(...)
                        bump()
                        return rawget(_G, 'update')(...)
                    end
                ]], '@mods/mdl/runtime.lua'))
                update = mdl(function() depth = depth + 1 end,
                             function() if depth > max_depth then max_depth = depth end
                                        if depth > 200 then error('runaway recursion') end
                                        depth = depth - 1 end)
            ''')
            runtime.execute(r'ours = update')
            runtime.execute(r'pcall(function() return ours(0.016) end)')
            max_depth = runtime.eval('max_depth')
            self.assertLess(max_depth, 200,
                            'peer runtime re-entered the wrapper %d times' % max_depth)


if __name__ == '__main__':
    unittest.main()
