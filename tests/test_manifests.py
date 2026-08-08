import json
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VARIANTS = {
    'nvidia': {
        'slug': 'ollama',
        'version': 'v0.32.6-reefy.1',
        'image': 'ollama/ollama:0.32.6',
        'gpu': True,
        'devices': [],
        'env': {},
    },
    'amd': {
        'slug': 'ollama-rocm',
        'version': 'v0.32.6-reefy.1',
        'image': 'ollama/ollama:0.32.6-rocm',
        'gpu': False,
        'devices': ['amd.com/gpu=all'],
        'env': {},
    },
    'intel': {
        'slug': 'ollama-intel',
        'version': 'v0.32.6-reefy.2',
        'image': 'ollama/ollama:0.32.6',
        'gpu': False,
        'devices': ['intel.com/gpu=all'],
        'env': {
            'OLLAMA_IGPU_ENABLE': '1',
            'OLLAMA_VULKAN': '1',
        },
    },
}


def load_manifest(variant):
    return json.loads((ROOT / variant / 'app.json').read_text())


class ManifestTests(unittest.TestCase):
    def test_variants_are_consistent_and_hardware_specific(self):
        manifests = {}
        for variant, expected in VARIANTS.items():
            manifest = load_manifest(variant)
            manifests[variant] = manifest
            self.assertEqual(manifest['slug'], expected['slug'])
            self.assertEqual(manifest['version'], expected['version'])
            self.assertEqual(manifest['image'], expected['image'])
            self.assertEqual(manifest['upstream_image'], 'docker.io/' + expected['image'])
            self.assertEqual(manifest['gpu'], expected['gpu'])
            self.assertEqual(manifest.get('devices', []), expected['devices'])
            self.assertEqual(manifest['env'], expected['env'])
            self.assertEqual(manifest['default_port'], 11434)
            self.assertEqual(
                manifest['volumes']['models']['mount'], '/root/.ollama')

        self.assertEqual(
            len({manifest['slug'] for manifest in manifests.values()}), 3)

    def test_icons_are_square_512_png_files(self):
        for variant in VARIANTS:
            path = ROOT / variant / 'icon.png'
            with self.subTest(variant=variant), path.open('rb') as stream:
                self.assertEqual(stream.read(8), b'\x89PNG\r\n\x1a\n')
                length = struct.unpack('>I', stream.read(4))[0]
                self.assertEqual(stream.read(4), b'IHDR')
                self.assertEqual(length, 13)
                width, height = struct.unpack('>II', stream.read(8))
                self.assertEqual((width, height), (512, 512))

    def test_repository_text_uses_plain_hyphens(self):
        for path in ROOT.rglob('*'):
            if path.is_file() and path.suffix in {'.json', '.md', '.py', '.yml'}:
                self.assertNotIn('\u2014', path.read_text(), str(path))


if __name__ == '__main__':
    unittest.main()
