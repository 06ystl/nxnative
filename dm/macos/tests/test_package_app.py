"""Packaging failure recovery and mixed cached shader targets; no game files needed."""
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from package_app import PackageError, build_app, shader_inventory, validate_shader_inputs, dmsh_chain


class Profile:
    id = 'fixture'
    rows = []

    def __init__(self, folder): self.folder = folder
    def table(self, name): return self.folder / name
    def words(self, key): return ['main']
    def get(self, key): return 'public.app-category.games'


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.msl = self.root / 'msl'; self.libs = self.msl / 'b-fixture'
        self.libs.mkdir(parents=True)
        self.library('a_b', '26.0')

    def library(self, name, version, platform='macosx'):
        p = self.libs / f'{name}.metallib'
        p.write_bytes(b'MTLB\x00air64_v28-apple-' + platform.encode() + version.encode() + b'\x00')
        if name.endswith('_b'): p.with_suffix('.json').write_text('{}')
        return p

    def test_newer_cached_library_raises_minimum_and_fetch_needs_no_json(self):
        self.library('b_b', '27.1.0')
        self.library('a_bf', '26.0')
        libraries, minimum = shader_inventory(self.msl, 'fixture')
        self.assertEqual(minimum, '27.1')
        self.assertEqual(len(libraries), 3)

    def test_ios_library_is_rejected(self):
        self.library('a_b', '26.0', 'ios')
        with self.assertRaisesRegex(PackageError, 'macOS AIR target'):
            shader_inventory(self.msl, 'fixture')

    def test_required_os_patch_version_is_preserved(self):
        self.library('a_b', '26.0.1')
        self.assertEqual(shader_inventory(self.msl, 'fixture')[1], '26.0.1')

    def test_missing_reflection_is_rejected(self):
        (self.libs / 'a_b.json').unlink()
        with self.assertRaisesRegex(PackageError, 'reflection'):
            shader_inventory(self.msl, 'fixture')

    def test_profile_and_tables_must_match_the_shader_inputs(self):
        profile = Profile(self.root)
        dmsh_chain.write_stamp(self.libs, profile.id, dmsh_chain.inputs(profile))
        for name in ('c1_full.tsv', 'cb_extent.tsv'):
            profile.table(name).write_text(dmsh_chain.table_head(self.libs) + ' 2026-10-24T00:00:00+08:00\n')
        validate_shader_inputs(self.msl, 'fixture', profile)
        profile.table('cb_extent.tsv').write_text('# previous shader inputs\n')
        with self.assertRaisesRegex(PackageError, 'does not name the shader library inputs'):
            validate_shader_inputs(self.msl, 'fixture', profile)
        dmsh_chain.write_stamp(self.libs, 'another-game', dmsh_chain.inputs(profile))
        with self.assertRaisesRegex(PackageError, 'do not match game profile'):
            validate_shader_inputs(self.msl, 'fixture', profile)

    def packaging_fixture(self, fail_signature=False, external_ui=False, fail_swap=False):
        repo = self.root / 'repo'; (repo / 'dm/host').mkdir(parents=True)
        (repo / 'dm/host/dmhost_app').write_bytes(b'fixture host')
        license_file = repo / 'dm/third_party/dualsense-trigger/LICENSE'
        license_file.parent.mkdir(parents=True); license_file.write_text('fixture trigger license')
        profile = Profile(self.root)
        (repo / 'dm/gfx/nvn').mkdir(parents=True)
        (repo / 'dm/gfx/nvn/dmsh_chain.h').write_text('#define DMSH_CHAIN "fixture"\n')
        for name in ('shader_map.tsv', 'c1_full.tsv', 'pso_manifest.tsv'):
            (self.root / name).write_text('# fixture\n')
        dmsh_chain.write_stamp(self.libs, profile.id, dmsh_chain.inputs(profile))
        for name in ('c1_full.tsv', 'cb_extent.tsv'):
            profile.table(name).write_text(dmsh_chain.table_head(self.libs) + ' 2026-10-24T00:00:00+08:00\n')
        patched = self.root / 'patched'; patched.mkdir()
        for suffix in ('patched.bin', 'fixups.tsv', 'gates.tsv', 'cuts.tsv', 'obs.tsv'):
            (patched / f'main.{suffix}').write_text('fixture')
        romfs = self.root / 'RomFS'; romfs.mkdir()
        (romfs / 'resource').write_text('fixture resource')
        font = self.root / 'font.ttf'; font.write_bytes(b'fixture font')
        out = self.root / "玩家's App.app"; (out / 'Contents').mkdir(parents=True)
        with (out / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'org.nxnative.fixture'}, f)
        (out / 'previous-build').write_text('keep me')
        ui = None
        ui_out = out.parent/'patches/dualsense-ui'
        if external_ui:
            ui = self.root/'new-ui'; (ui/'romfs').mkdir(parents=True)
            (ui/'manifest.tsv').write_text('game\tfixture\n')
            (ui/'romfs/button').write_text('new PS5 icon')
            (ui_out/'romfs').mkdir(parents=True)
            (ui_out/'manifest.tsv').write_text('game\tfixture\n')
            (ui_out/'romfs/button').write_text('old PS5 icon')

        def run(cmd, log, env=None, cwd=None, on_line=None):
            if cmd[0] == 'python-fixture': Path(cmd[-1]).write_bytes(b'font')
            if cmd[0] == 'cp': shutil.copytree(cmd[-2], cmd[-1])
            if cmd[0] == 'codesign':
                self.assertEqual((Path(cmd[-1]) / 'Contents/Resources/licenses/dualsense-trigger.txt').read_text(), 'fixture trigger license')
                with (Path(cmd[-1]) / 'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
                self.assertTrue(info['GCSupportsControllerUserInteraction'])
                self.assertEqual(info['GCSupportedGameControllers'], [{'ProfileName': 'ExtendedGamepad'}])
                self.assertFalse((Path(cmd[-1])/'Contents/Resources/controller-ui').exists())
                if external_ui: self.assertEqual((ui_out/'romfs/button').read_text(), 'old PS5 icon')
                if fail_signature: raise RuntimeError('signature failed')

        rename = Path.rename
        def rename_candidate(path, target):
            if fail_swap and path.name == out.name and path.parent.name.startswith('.nxnative-mac-'):
                raise OSError('app swap failed')
            return rename(path, target)
        with patch('package_app.subprocess.check_output', return_value='arm64'), \
                patch.object(Path, 'rename', rename_candidate):
            build_app(repo, self.root, out, profile, patched, romfs, self.msl,
                      'Fixture', 'org.nxnative.fixture', '1.0', font, None, None,
                      {'FONT_PY': 'python-fixture', 'STD_FONT': str(font)}, run, lambda _: False,
                      controller_ui=ui)
        return out, romfs, ui_out

    def test_signature_failure_keeps_previous_app_and_removes_staging(self):
        with self.assertRaisesRegex(RuntimeError, 'signature failed'):
            self.packaging_fixture(fail_signature=True)
        out = self.root/"玩家's App.app"
        self.assertEqual((out / 'previous-build').read_text(), 'keep me')
        self.assertTrue((self.root/'RomFS/resource').is_file())
        self.assertEqual(list(self.root.glob('.nxnative-mac-*')), [])

    def test_external_patch_is_installed_beside_the_signed_app(self):
        out, _, ui = self.packaging_fixture(external_ui=True)
        self.assertEqual((ui/'romfs/button').read_text(), 'new PS5 icon')
        self.assertFalse((out/'Contents/Resources/controller-ui').exists())
        self.assertFalse((out/'previous-build').exists())
        self.assertEqual(list(self.root.glob('.nxnative-mac-*')), [])

    def test_app_swap_failure_restores_both_previous_app_and_external_patch(self):
        with self.assertRaisesRegex(OSError, 'app swap failed'):
            self.packaging_fixture(external_ui=True, fail_swap=True)
        self.assertEqual((self.root/"玩家's App.app/previous-build").read_text(), 'keep me')
        self.assertEqual((self.root/'patches/dualsense-ui/romfs/button').read_text(), 'old PS5 icon')
        self.assertEqual(list(self.root.glob('.nxnative-mac-*')), [])


if __name__ == '__main__': unittest.main()
