import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('check_shaders', Path(__file__).parents[1] / 'tools/check_shaders.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ShaderCompatibility(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / 'b-test'
        self.folder.mkdir()
        self.info = self.root / 'Info.plist'
        self.info.write_bytes(plistlib.dumps({'MinimumOSVersion': '17.0'}))
        self.library = self.folder / 'abc_b.metallib'
        self.library.write_bytes(b'MTLB\0air64_v26-apple-ios17.0.0\0')
        self.library.with_suffix('.json').write_text(json.dumps({'chain': 'test'}))

    def test_ios17_library(self):
        self.assertEqual(module.check(self.folder, self.info), (1, '17.0'))

    def test_old_ios18_cache_is_rejected(self):
        self.library.write_bytes(b'MTLB\0air64-apple-ios18.0.0\0')
        with self.assertRaisesRegex(ValueError, 'newer iOS'):
            module.check(self.folder, self.info)

    def test_variants_must_also_support_minimum(self):
        (self.folder / 'abc_bf.metallib').write_bytes(b'MTLB\0air64-apple-ios26.0.0\0')
        with self.assertRaisesRegex(ValueError, 'newer iOS'):
            module.check(self.folder, self.info)

    def test_macos_library_is_rejected(self):
        self.library.write_bytes(b'MTLB\0air64-apple-macosx26.0.0\0')
        with self.assertRaisesRegex(ValueError, 'iOS AIR target'):
            module.check(self.folder, self.info)

    def test_reflection_chain_must_match(self):
        self.library.with_suffix('.json').write_text(json.dumps({'chain': 'old'}))
        with self.assertRaisesRegex(ValueError, 'chain mismatch'):
            module.check(self.folder, self.info)

    def test_missing_base_library(self):
        self.library.unlink()
        with self.assertRaisesRegex(ValueError, 'No base shader'):
            module.check(self.folder, self.info)

    def test_vulkan_library_uses_platform_target_without_nvn_reflection(self):
        folder = self.root / 'vk'
        folder.mkdir()
        library = folder / 'vk_shaders.metallib'
        library.write_bytes(b'MTLB\0air64-apple-ios17.0.0\0')
        self.assertEqual(module.check(folder, self.info, 'vulkan'), (1, '17.0'))
        library.write_bytes(b'MTLB\0air64-apple-ios26.0.0\0')
        with self.assertRaisesRegex(ValueError, 'newer iOS'):
            module.check(folder, self.info, 'vulkan')


if __name__ == '__main__':
    unittest.main()
