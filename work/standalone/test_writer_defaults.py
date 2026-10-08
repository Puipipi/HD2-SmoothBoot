"""The default writer-hold list must keep the writers we have evidence for.

`m103_frv` and `stratagem_cooldown` both appear in the watchdog's 34.5 s freeze attribution
(2026-10-06) and both write game record fields (stratagem/vehicle records), so both belong in
the default `writers=` fragment list. The module logs `config check: writers fragment(s) not
on chain` when a fragment is missing, so listing a mod the user does not run is harmless.

    python -m unittest test_writer_defaults
"""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parent / 'smoothboot.lua').read_text(encoding='utf-8')
DEFAULT = re.search(r"writers='([^']*)'", SOURCE).group(1).split(',')
EMITTED = re.search(r"w:write\('writers=([^'\\]*)", SOURCE).group(1).split(',')
NORELEASE = re.search(r"writer_norelease='([^']*)'", SOURCE).group(1).split(',')


class WriterDefaults(unittest.TestCase):
    def test_evidenced_writers_are_in_the_default_list(self):
        for name in ('m103_frv', 'stratagem_cooldown'):
            self.assertIn(name, DEFAULT, 'default writers= lost %s' % name)

    def test_emitted_template_never_invents_a_name(self):
        # the template may lag behind the defaults table; it must never list something the
        # defaults do not know about.
        self.assertTrue(set(EMITTED) <= set(DEFAULT),
                        'emitted writers= has names absent from the defaults: %s'
                        % (set(EMITTED) - set(DEFAULT)))

    def test_norelease_still_covers_the_freeze_attributed_mod(self):
        self.assertIn('m103_frv', NORELEASE)


if __name__ == '__main__':
    unittest.main(verbosity=2)
