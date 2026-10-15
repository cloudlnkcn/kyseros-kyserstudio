import json
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION = 'v10.25.5-kyseros.1'
SOURCE = 'https://github.com/cloudlnkcn/kyserai'
SOURCE_REF = 'v10.25.5'
IMAGE_BASE = 'kyserai'
VARIANTS = {
    'nvidia': {
        'slug': 'kyserai',
        'image_tag': 'v10.25.5-nvidia',
        'gpu': True,
        'devices': [],
        'env': {},
    },
    'amd': {
        'slug': 'kyserai-rocm',
        'image_tag': 'v10.25.5-amd',
        'gpu': False,
        'devices': ['amd.com/gpu=all'],
        'env': {},
    },
    'intel': {
        'slug': 'kyserai-intel',
        'image_tag': 'v10.25.5-intel',
        'gpu': False,
        'devices': ['intel.com/gpu=all'],
        'env': {},
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
            self.assertEqual(manifest['version'], VERSION)
            self.assertEqual(manifest['image'], f'{IMAGE_BASE}:{expected["image_tag"]}')
            self.assertEqual(manifest['source'], SOURCE)
            self.assertEqual(manifest['source_ref'], SOURCE_REF)
            self.assertEqual(manifest['gpu'], expected['gpu'])
            self.assertEqual(manifest.get('devices', []), expected['devices'])
            self.assertEqual(manifest['env'], expected['env'])
            self.assertEqual(manifest['default_port'], 13305)
            self.assertEqual(
                manifest['volumes']['data']['mount'], '/var/lib/kyserai')
            self.assertEqual(manifest['volumes']['data']['uid'], 0)
            self.assertEqual(manifest['icon'], 'icon.png')
            self.assertIn('llm', manifest['tags'])

        self.assertEqual(
            len({manifest['slug'] for manifest in manifests.values()}), 3)

    def test_manifests_do_not_wrap_ollama(self):
        for variant in VARIANTS:
            text = (ROOT / variant / 'app.json').read_text()
            self.assertNotIn('ollama', text.lower(), str(variant))
            self.assertTrue(
                load_manifest(variant)['image'].startswith(f'{IMAGE_BASE}:'))

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

    def test_dockerfile_builds_kyserai_from_named_context(self):
        dockerfile = (ROOT / 'Dockerfile').read_text()
        self.assertIn('COPY --from=kyserai . /app', dockerfile)
        self.assertIn('ARG GPU_VARIANT=nvidia', dockerfile)
        for variant in VARIANTS:
            self.assertIn(variant, dockerfile)
        self.assertIn('EXPOSE 13305', dockerfile)

    def test_repository_text_uses_plain_hyphens(self):
        for path in ROOT.rglob('*'):
            if path.is_file() and path.suffix in {'.json', '.md', '.py', '.yml'}:
                self.assertNotIn('\u2014', path.read_text(), str(path))


if __name__ == '__main__':
    unittest.main()
