"""Peer-loader compatibility: another chain manager (MDL) must be detected and deferred to.

Coverage gap found on 2026-10-06: the source has three peer paths
  * a chain member whose name contains `mods/mdl`            (L3471-3475)
  * the global `MDL` table appearing later                   (L3575-3579)
  * `peer_active and cfg.peer_suspend` -> automatic throttling off, pcall/breaker stay (L3630-3639)
and the suite only ever set `MDL={}` to avoid them - nothing asserted the behaviour.

Uses test_sb2's harness (fake clock, adaptive-skip cost model). `make_config` is patched so
`peer_suspend` can be written into the config file before the module loads.

    python -m unittest test_peer_mdl
"""
import os
import shutil
import unittest

import lupa

import test_sb2 as H

FRAMES = 200
PEER_WRAP = r'''
    local mk = loadstring or load
    _PEER = mk('local p = ... return function(...) peer_calls = (peer_calls or 0) + 1 return p(...) end',
               '@mods/mdl/runtime.lua')
    update = _PEER(update)
'''

_orig_make_config = H.make_config


def make_config_with_peer(**kv):
    _orig_make_config(**kv)
    path = os.path.join(H.FAKE_LA, 'CowboyBingus', 'Helldivers2', 'SmoothBoot', 'config.txt')
    with open(path, 'a') as handle:
        handle.write('peer_suspend=%s\n' % kv.get('peer_suspend', 'yes'))


H.make_config = make_config_with_peer


class PeerMdl(unittest.TestCase):
    def _setup(self, peer_suspend='yes'):
        config = {"boot_skip": 4, "boot_s": 1, "grace_s": 0, "throttle": "yes",
                  "peer_suspend": peer_suspend}
        return H.setup_case(lupa.luajit21, cost_ms=6.0, config=config)

    def _frames(self, g, adv, count):
        for _ in range(count):
            adv(0.05)
            g["update"](0.016)

    def test_baseline_adaptive_skip_reduces_chain_executions(self):
        rt, g, wrapper, state, adv, chain = self._setup()
        try:
            self._frames(g, adv, FRAMES)
            calls = int(chain["calls"])
            self.assertLess(calls, FRAMES * 0.6,
                            'baseline should be throttled, got %d/%d' % (calls, FRAMES))
        finally:
            shutil.rmtree(H.FAKE_LA, ignore_errors=True)

    def test_peer_by_chain_name_suspends_automatic_throttling(self):
        rt, g, wrapper, state, adv, chain = self._setup()
        try:
            self._frames(g, adv, 25)
            rt.execute(PEER_WRAP)                 # peer loader appears above us
            self._frames(g, adv, 40)              # detection + transition frames
            mark = int(chain["calls"])
            self._frames(g, adv, FRAMES)          # measured window
            added = int(chain["calls"]) - mark
            self.assertGreaterEqual(added, FRAMES * 0.9,
                                    'peer present but throttling still skipped: %d/%d' % (added, FRAMES))
            log = H.read_log()
            self.assertIn('peer loader detected', log)
            self.assertIn('throttling suspended', log)
        finally:
            shutil.rmtree(H.FAKE_LA, ignore_errors=True)

    def test_peer_detected_through_the_global_mdl_table(self):
        # The global-MDL probe sits inside the 10-second config re-read block (source line
        # 3566-3581), so detection lands on the next config tick - measured 2026-10-06:
        # 55/200 when the measured window started immediately, hence the 260-frame wait
        # (adv(0.05) x 260 = 13 s) before the window below.
        rt, g, wrapper, state, adv, chain = self._setup()
        try:
            self._frames(g, adv, 10)
            rt.execute('MDL = {}')                # loader present but not on our chain
            self._frames(g, adv, 260)             # cross the config re-read cadence
            mark = int(chain["calls"])
            self._frames(g, adv, FRAMES)
            added = int(chain["calls"]) - mark
            self.assertGreaterEqual(added, FRAMES * 0.9,
                                    'global MDL not honoured after the config tick: %d/%d'
                                    % (added, FRAMES))
            self.assertIn('peer loader present (global MDL)', H.read_log())
        finally:
            shutil.rmtree(H.FAKE_LA, ignore_errors=True)

    def test_peer_on_the_chain_is_frame_critical_so_skipping_stays_suspended(self):
        # Root cause measured 2026-10-06 (measure_peer_suspend_no.py): a peer wrapper on our
        # chain is classified as a frame-critical callback, and that rule ("chain skipping and
        # pausing suspended") intentionally outranks peer_suspend. Both peer_suspend values
        # therefore run the chain at full speed - correct behaviour, not a defect.
        rt, g, wrapper, state, adv, chain = self._setup(peer_suspend='no')
        try:
            self._frames(g, adv, 25)
            rt.execute(PEER_WRAP)
            self._frames(g, adv, 40)
            mark = int(chain["calls"])
            self._frames(g, adv, FRAMES)
            added = int(chain["calls"]) - mark
            self.assertGreaterEqual(added, FRAMES * 0.9,
                                    'frame-critical peer must stay unthrottled, got %d/%d'
                                    % (added, FRAMES))
            self.assertIn('frame-critical callbacks present', H.read_log())
        finally:
            shutil.rmtree(H.FAKE_LA, ignore_errors=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
