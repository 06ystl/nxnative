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


class CheatProfileTests(unittest.TestCase):
    def test_cheat_metadata_is_restricted_to_verified_builds_and_unique_words(self):
        base = game.load('01007EF00011E000')
        for field, value in [(0, '0'*32), (1, 'health,all'), (2, '3'), (3, '-1'), (4, '0x100000000')]:
            with self.subTest(field=field):
                profile = copy.deepcopy(base)
                row = profile.values('mac_cheat_patch')[0].copy(); row[field] = value
                profile.rows = [(k,v) for k,v in profile.rows if k != 'mac_cheat_patch']
                profile.rows.append(('mac_cheat_patch', row))
                with self.assertRaises(ValueError): game.header(profile)
        profile = copy.deepcopy(base)
        profile.rows.append(('mac_cheat_patch', profile.values('mac_cheat_patch')[0].copy()))
        with self.assertRaisesRegex(ValueError, 'duplicate'): game.header(profile)

    def test_all_profiles_generate_cheat_tables(self):
        for profile in game.all_games():
            self.assertIn('#define DM_GAME_MAC_CHEAT_PATCHES ', game.header(profile))


class TimingProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = copy.deepcopy(game.load('01007EF00011E000'))
        self.row = self.profile.values('mac_frame_step')[0].copy()

    def test_profiles_without_adapter_keep_empty_table(self):
        for profile in game.all_games():
            if not profile.values('mac_frame_step'):
                self.assertIn('#define DM_GAME_MAC_FRAME_STEP {0}', game.header(profile))

    def test_duplicate_adapter_is_rejected(self):
        self.profile.rows.append(('mac_frame_step', self.row))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            game.header(self.profile)

    def test_unverified_build_and_invalid_fields_are_rejected(self):
        for field, value in [(0, '0'*32), (1, '3'), (2, '-1'), (3, '4096'), (4, '3'), (5, '0')]:
            with self.subTest(field=field, value=value):
                profile = copy.deepcopy(self.profile)
                row = self.row.copy(); row[field] = value
                profile.rows = [(k,v) for k,v in profile.rows if k != 'mac_frame_step']
                profile.rows.append(('mac_frame_step', row))
                with self.assertRaises(ValueError):
                    game.header(profile)


if __name__ == '__main__':
    unittest.main()
