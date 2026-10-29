import json
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION = 'v10.26.3-kyseros.1'
SOURCE = 'https://github.com/cloudlnkcn/kyserai'
SOURCE_REF = 'v10.26.3'
IMAGE = f'kyserai:{VERSION}'
# One shared image; the accelerator association lives in each
# variant's CDI request, matched to the Kyseros provider repo
# (kyseros-nvidia / kyseros-amd / kyseros-intel) that publishes it.
VARIANTS = {
    'nvidia': {
        'slug': 'kyserai',
        'cdi': 'nvidia.com/gpu=all',
    },
    'amd': {
        'slug': 'kyserai-rocm',
        'cdi': 'amd.com/gpu=all',
    },
    'intel': {
        'slug': 'kyserai-intel',
        'cdi': 'intel.com/gpu=all',
    },
}


def load_manifest(variant):
    return json.loads((ROOT / variant / 'app.json').read_text())


class ManifestTests(unittest.TestCase):
    def test_variants_share_one_image_and_request_their_provider(self):
        manifests = {}
        for variant, expected in VARIANTS.items():
            manifest = load_manifest(variant)
            manifests[variant] = manifest
            self.assertEqual(manifest['slug'], expected['slug'])
            self.assertEqual(manifest['version'], VERSION)
            self.assertEqual(manifest['image'], IMAGE)
            self.assertEqual(manifest['source'], SOURCE)
            self.assertEqual(manifest['source_ref'], SOURCE_REF)
            # provider association: an explicit, exclusive CDI request
            # selects the matching Kyseros host provider artifact
            self.assertEqual(manifest['gpu'], False)
            self.assertEqual(manifest['devices'], [expected['cdi']])
            for other in VARIANTS:
                if other == variant:
                    continue
                self.assertNotIn(VARIANTS[other]['cdi'], manifest['devices'])
            self.assertEqual(manifest['env'], {})
            self.assertEqual(manifest['default_port'], 13305)
            self.assertEqual(
                manifest['volumes']['data']['mount'], '/var/lib/kyserai')
            self.assertEqual(manifest['volumes']['data']['uid'], 0)
            self.assertEqual(manifest['icon'], 'icon.png')
            self.assertIn('llm', manifest['tags'])

        self.assertEqual(
            len({manifest['slug'] for manifest in manifests.values()}), 3)

    def test_manifests_declare_the_platform_lan_beacon(self):
        # the device broadcasts this on the app's behalf from the host
        # network namespace (kyseros lan_beacon); the container's own
        # UDP beacon cannot cross its isolated bridge network, so the
        # image runs kyseraid with --no-broadcast
        for variant in VARIANTS:
            manifest = load_manifest(variant)
            self.assertEqual(manifest['lan_beacon'], {
                'udp_port': 13305,
                'service': 'kyserai',
                'url_path': '/api/v1/',
            })

    def test_manifests_do_not_wrap_ollama(self):
        for variant in VARIANTS:
            text = (ROOT / variant / 'app.json').read_text()
            self.assertNotIn('ollama', text.lower(), str(variant))
            self.assertTrue(
                load_manifest(variant)['image'].startswith('kyserai:'))

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
        self.assertIn('EXPOSE 13305', dockerfile)

    def test_dockerfile_builds_one_image_without_gpu_variant(self):
        # variants differ only in their CDI request, never in image
        # content, so there is no per-variant build knob
        dockerfile = (ROOT / 'Dockerfile').read_text()
        self.assertNotIn('GPU_VARIANT', dockerfile)
        self.assertNotIn('build-arg', dockerfile)
        self.assertEqual(dockerfile.count('FROM ubuntu:'), 3)

    def test_dockerfile_supports_a_github_mirror_prefix(self):
        # the Khronos clones go through the ghfast.top proxy by default
        # (build networks cannot reach github.com directly); an empty
        # GITHUB_MIRROR falls back to the upstream URLs
        dockerfile = (ROOT / 'Dockerfile').read_text()
        self.assertIn('ARG GITHUB_MIRROR=https://ghfast.top/', dockerfile)
        self.assertIn('${GITHUB_MIRROR}https://github.com/KhronosGroup',
                      dockerfile)
        self.assertIn('https://github.com/KhronosGroup/Vulkan-Loader.git',
                      dockerfile)
        publish = (ROOT / 'scripts' / 'publish.sh').read_text()
        self.assertIn('GITHUB_MIRROR="$github_mirror"', publish)
        self.assertIn(
            '${KYSEROS_GITHUB_MIRROR-https://ghfast.top/}', publish)
        # the provider bind reference must be tag-less: the service
        # matches the DB repo exactly against registry_url + repo
        self.assertIn('/api/catalog/sources', publish)
        self.assertIn('image["repo"] + "@" + image["digest"]', publish)

    def test_dockerfile_apt_defaults_to_the_aliyun_mirror(self):
        # every apt stage rewrites the distro sources to the Aliyun
        # mirror before installing anything
        dockerfile = (ROOT / 'Dockerfile').read_text()
        self.assertEqual(
            dockerfile.count('ARG APT_MIRROR=mirrors.aliyun.com'), 1)
        self.assertEqual(dockerfile.count('ARG APT_MIRROR\n'), 3)
        self.assertEqual(
            dockerfile.count(
                'sed -i "s|archive.ubuntu.com|$APT_MIRROR|g;'
                ' s|security.ubuntu.com|$APT_MIRROR|g"'), 3)
        self.assertLess(dockerfile.index('ARG APT_MIRROR=mirrors.aliyun.com'),
                        dockerfile.index('FROM ubuntu:'))

    def test_dockerfile_bakes_in_no_driver_stack(self):
        # kernel modules, firmware, CUDA / ROCm / XRT user space and
        # the Vulkan ICDs all come from the OS host provider via CDI;
        # comments are stripped so only real build steps are checked
        dockerfile = '\n'.join(
            line for line in (ROOT / 'Dockerfile').read_text().splitlines()
            if not line.lstrip().startswith('#')).lower()
        for banned in ('cuda', 'rocm', 'xrt', 'nvidia-container',
                       'nvidia-ctk', 'amd-ctk', 'amd-team', 'add-apt-repository',
                       'libnvidia', 'libcuda'):
            self.assertNotIn(banned, dockerfile)

    def test_dockerfile_ships_vulkan_loader_in_common_layer(self):
        # the Vulkan loader is the one piece of the Vulkan stack the
        # provider contract leaves to the app image
        dockerfile = (ROOT / 'Dockerfile').read_text()
        self.assertIn('libvulkan1', dockerfile)
        self.assertIn('vulkan-tools', dockerfile)
        self.assertFalse((ROOT / 'vulkan').exists())
        for variant in ('nvidia', 'amd', 'intel'):
            text = (ROOT / variant / 'app.json').read_text()
            self.assertNotIn('vulkan.com/gpu', text)

    def test_dockerfile_builds_current_vulkan_loader(self):
        # the pinned Khronos build overrides Ubuntu's 1.3.x package
        dockerfile = (ROOT / 'Dockerfile').read_text()
        self.assertIn('ARG VULKAN_VERSION=', dockerfile)
        self.assertIn('github.com/KhronosGroup/Vulkan-Loader.git', dockerfile)
        self.assertIn('github.com/KhronosGroup/Vulkan-Headers.git', dockerfile)
        self.assertIn('COPY --from=vulkan-loader', dockerfile)
        self.assertLess(dockerfile.index('AS vulkan-loader'),
                        dockerfile.index('COPY --from=vulkan-loader'))

    def test_repository_text_uses_plain_hyphens(self):
        for path in ROOT.rglob('*'):
            if path.is_file() and path.suffix in {'.json', '.md', '.py', '.yml'}:
                self.assertNotIn('\u2014', path.read_text(), str(path))


if __name__ == '__main__':
    unittest.main()
