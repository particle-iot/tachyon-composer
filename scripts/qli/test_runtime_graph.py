import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('runtime_graph', Path(__file__).with_name('check-runtime-graph.py'))
graph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(graph)


class RuntimeGraphTests(unittest.TestCase):
    def test_scoped_rpm_graph_is_accepted(self):
        report = graph.check(graph.REQUIRED | {'gcc-cross-aarch64', 'linux-libc-headers'}, {'jq.do_package_write_rpm'})
        self.assertEqual(report['recipe_count'], 9)

    def test_rejects_kernel_sdk_and_graphics_work(self):
        for recipe in ('linux-qcom', 'meta-toolchain', 'nativesdk-glibc', 'mesa', 'gcc-cross-canadian-aarch64'):
            with self.subTest(recipe=recipe), self.assertRaisesRegex(ValueError, 'Forbidden'):
                graph.check(graph.REQUIRED | {recipe}, {'jq.do_package_write_rpm'})

    def test_rejects_image_and_sdk_tasks_even_with_innocent_recipe_names(self):
        for task in ('target.do_rootfs', 'target.do_image', 'target.do_image_complete', 'target.do_populate_sdk', 'target.do_populate_sdk_ext'):
            with self.subTest(task=task), self.assertRaisesRegex(ValueError, 'Image/SDK'):
                graph.check(graph.REQUIRED, {task})

    def test_rejects_incomplete_or_empty_graph(self):
        with self.assertRaisesRegex(ValueError, 'Missing runtime'):
            graph.check({'jq'}, {'jq.do_package_write_rpm'})
        with self.assertRaisesRegex(ValueError, 'empty'):
            graph.check(graph.REQUIRED, set())

    def test_rejects_unreviewed_growth(self):
        with self.assertRaisesRegex(ValueError, 'budget'):
            graph.check(graph.REQUIRED | {f'new-{i}' for i in range(graph.MAX_RECIPES)}, {'jq.do_package_write_rpm'})
        with self.assertRaisesRegex(ValueError, 'budget'):
            graph.check(graph.REQUIRED, {f'target.do_task_{i}' for i in range(graph.MAX_TASKS + 1)})
