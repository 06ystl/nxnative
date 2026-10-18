"""Build-specific resolution metadata must be safe before it reaches the loader."""
import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'games'))
import game


class ResolutionProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = copy.deepcopy(game.load('01007EF00011E000'))
        self.site = self.profile.values('mac_resolution_patch')[0].copy()

    def test_all_profiles_emit_presets_or_empty_table(self):
        for profile in game.all_games():
            header = game.header(profile)
            self.assertIn('#define DM_GAME_MAC_RESOLUTION_PATCHES ', header)
            if not profile.values('mac_resolution_patch'):
                self.assertIn('#define DM_GAME_MAC_RESOLUTION_PATCHES {0}', header)

    def test_unknown_build_is_rejected(self):
        self.site[0] = '0' * 32
        self.profile.rows.append(('mac_resolution_patch', self.site))
        with self.assertRaisesRegex(ValueError, 'known main build'):
            game.header(self.profile)

    def test_duplicate_site_is_rejected(self):
        self.profile.rows.append(('mac_resolution_patch', self.site))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            game.header(self.profile)

    def test_invalid_offsets_and_instruction_widths_are_rejected(self):
        for field, value in [(1, '-4'), (1, '3'), (2, '0x100000000'), (3, '-1'), (4, '0x100000000')]:
            with self.subTest(field=field, value=value):
                profile = copy.deepcopy(self.profile)
                row = self.site.copy(); row[field] = value
                profile.rows = [(k, v) for k, v in profile.rows if k != 'mac_resolution_patch']
                profile.rows.append(('mac_resolution_patch', row))
                with self.assertRaisesRegex(ValueError, 'invalid'):
                    game.header(profile)

    def test_incomplete_row_is_rejected(self):
        self.profile.rows.append(('mac_resolution_patch', self.site[:-1]))
        with self.assertRaisesRegex(ValueError, 'requires'):
            game.header(self.profile)


if __name__ == '__main__':
    unittest.main()
