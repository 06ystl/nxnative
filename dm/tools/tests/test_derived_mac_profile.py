"""A derived game version must not inherit build-specific Mac addresses."""
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts'))
sys.path.insert(0, str(REPO / 'dm/games'))
import build_ipa_from_nsp as nsp
import game


class DerivedMacProfile(unittest.TestCase):
    def test_only_matching_main_adapters_survive(self):
        original = game.load('01007EF00011E000')
        known = original.values('mac_bow_state')[0][0]
        for build, keep in [(known, True), ('12' * 16, False)]:
            with self.subTest(build=build), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                src = root / 'source' / original.id; src.mkdir(parents=True)
                (src / 'game.tsv').write_text((original.dir / 'game.tsv').read_text())
                exe = root / 'extracted/ExeFS'; exe.mkdir(parents=True)
                (exe / 'main').write_bytes(bytes(0x40) + bytes.fromhex(build))
                dst = root / 'derived' / original.id
                with mock.patch.object(nsp, 'nacp', SimpleNamespace(version=lambda _: 'fixture'), create=True):
                    nsp.derive_profile(game.Game(src), dst, 'v999', exe.parent, ['main'])
                derived = game.Game(dst)
                for key in ['mac_audio_events', 'mac_bow_state', 'mac_shield_state', 'mac_resolution_patch', 'mac_cheat_patch', 'mac_frame_step', 'mac_frame_guard']:
                    self.assertEqual(bool(derived.values(key)), keep, key)
                header = game.header(derived)
                self.assertIn('DM_GAME_MAC_BOW_STATE', header)
                self.assertIn('DM_GAME_MAC_SHIELD_STATE', header)
                if not keep:
                    self.assertIn('#define DM_GAME_MAC_BOW_STATE {0}', header)
                    self.assertIn('#define DM_GAME_MAC_SHIELD_STATE {0}', header)


if __name__ == '__main__': unittest.main()
