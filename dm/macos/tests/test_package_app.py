"""Packaging failure recovery and mixed cached shader targets; no game files needed."""
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from package_app import PackageError, build_app, shader_inventory


class Profile:
    id = 'fixture'

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

    def test_signature_failure_keeps_previous_app_and_removes_staging(self):
        repo = self.root / 'repo'; (repo / 'dm/host').mkdir(parents=True)
        (repo / 'dm/host/dmhost_app').write_bytes(b'fixture host')
        profile = Profile(self.root)
        (self.root / 'dmsh_chain.h').write_text('#define DMSH_CHAIN "fixture"\n')
        for name in ('shader_map.tsv', 'c1_full.tsv', 'pso_manifest.tsv'):
            (self.root / name).write_text('# fixture\n')
        patched = self.root / 'patched'; patched.mkdir()
        for suffix in ('patched.bin', 'fixups.tsv', 'gates.tsv', 'params.tsv', 'cuts.tsv', 'obs.tsv'):
            (patched / f'main.{suffix}').write_text('fixture')
        romfs = self.root / 'RomFS'; romfs.mkdir()
        (romfs / 'resource').write_text('fixture resource')
        font = self.root / 'font.ttf'; font.write_bytes(b'fixture font')
        out = self.root / "玩家's App.app"; (out / 'Contents').mkdir(parents=True)
        with (out / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'org.nxnative.fixture'}, f)
        (out / 'previous-build').write_text('keep me')

        def run(cmd, log, env=None, cwd=None, on_line=None):
            if cmd[0] == 'python-fixture': Path(cmd[-1]).write_bytes(b'font')
            if cmd[0] == 'codesign':
                with (Path(cmd[-1]) / 'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
                self.assertTrue(info['GCSupportsControllerUserInteraction'])
                self.assertEqual(info['GCSupportedGameControllers'], [{'ProfileName': 'ExtendedGamepad'}])
                raise RuntimeError('signature failed')

        with patch('package_app.subprocess.check_output', return_value='arm64'):
            with self.assertRaisesRegex(RuntimeError, 'signature failed'):
                build_app(repo, self.root, out, profile, patched, romfs, self.msl,
                          'Fixture', 'org.nxnative.fixture', '1.0', font, None, None,
                          {'FONT_PY': 'python-fixture', 'STD_FONT': str(font)}, run, lambda _: False)
        self.assertEqual((out / 'previous-build').read_text(), 'keep me')
        self.assertTrue((romfs / 'resource').is_file())
        self.assertEqual(list(self.root.glob('.nxnative-mac-*')), [])


if __name__ == '__main__': unittest.main()
