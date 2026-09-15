import importlib.util
from pathlib import Path
import unittest
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('guard', Path(__file__).with_name('check-sdk-graph.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class SDKGraphTests(unittest.TestCase):
    def test_compiler_and_library_graph_accepted(self):
        result = guard.check(guard.REQUIRED | {'zlib-native'}, {'meta-toolchain.do_populate_sdk'})
        self.assertEqual(result['recipe_count'], len(guard.REQUIRED) + 1)

    def test_kernel_or_runtime_dependency_rejected(self):
        for recipe in ('linux-qcom', 'linux-firmware', 'networkmanager', 'libgpiod',
                       'dnf-native', 'cryptsetup', 'tpm2-tss', 'bluez5', 'qemu-native', 'nativesdk-qemu', 'nativesdk-spirv-tools',
                       'nativesdk-wayland', 'clang-native', 'mesa', 'gdb-cross-canadian-aarch64'):
            with self.subTest(recipe=recipe), self.assertRaises(ValueError):
                guard.check(guard.REQUIRED | {recipe}, {'meta-toolchain.do_populate_sdk'})

    def test_required_headers_and_libraries_cannot_disappear(self):
        for recipe in guard.REQUIRED:
            with self.subTest(recipe=recipe), self.assertRaises(ValueError):
                guard.check(guard.REQUIRED - {recipe}, {'meta-toolchain.do_populate_sdk'})

    def test_empty_graph_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Empty'):
            guard.check(guard.REQUIRED, set())

    def test_image_tasks_rejected(self):
        for task in ('core-image.do_rootfs', 'core-image.do_image', 'core-image.do_image_wic'):
            with self.subTest(task=task), self.assertRaises(ValueError):
                guard.check(guard.REQUIRED, {task})

    def test_image_repository_rejects_sdk_only_workspace(self):
        project = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'sdk'
            sdk.mkdir()
            (sdk / '.particle-sdk-workspace').touch()
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('build-components.py')),
                                     str(project / 'versions.json'), str(root / 'components'), str(sdk)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('SDK-only library packages must not enter', result.stderr)

    def test_failed_check_removes_previous_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'sdk-graph.json').write_text('{}')
            (root / 'pn-buildlist').write_text('linux-qcom\n')
            (root / 'task-depends.dot').write_text('"linux-qcom.do_compile" [label="kernel"]\n')
            result = subprocess.run([sys.executable, str(Path(guard.__file__)), directory],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / 'sdk-graph.json').exists())

    def test_graph_size_regression_rejected(self):
        with self.assertRaisesRegex(ValueError, 'budget'):
            guard.check(guard.REQUIRED | {f'new-{i}' for i in range(guard.MAX_RECIPES)}, {'sdk.do_build'})
        with self.assertRaisesRegex(ValueError, 'budget'):
            guard.check(guard.REQUIRED, {f'sdk.do_{i}' for i in range(guard.MAX_TASKS + 1)})


if __name__ == '__main__':
    unittest.main()
