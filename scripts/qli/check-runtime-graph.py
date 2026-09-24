#!/usr/bin/env python3
"""Reject accidental image/SDK/kernel builds before runtime RPM compilation."""
import argparse
import json
from pathlib import Path
import re

REQUIRED = {'jq', 'socat', 'sudo', 'grep', 'sed', 'libgpiod', 'networkmanager', 'tzdata'}
MAX_RECIPES = 250
MAX_TASKS = 2800
BANNED = ('meta-toolchain', 'nativesdk-', 'gcc-cross-canadian', 'binutils-cross-canadian',
          'u-boot', 'kernel-devsrc', 'initramfs', 'qcom-multimedia', 'qcom-networking',
          'mesa', 'weston', 'xserver', 'llvm', 'clang', 'rust', 'cargo')


def check(recipes, tasks):
    errors = []
    for recipe in sorted(recipes):
        if ((recipe.startswith('linux-') and recipe != 'linux-libc-headers')
                or any(recipe.startswith(prefix) for prefix in BANNED)):
            errors.append('Forbidden runtime build recipe: ' + recipe)
    for task in sorted(tasks):
        if re.search(r'\.do_(rootfs|image(?:_.*)?|populate_sdk(?:_.*)?)$', task):
            errors.append('Image/SDK task in runtime build: ' + task)
    if REQUIRED - recipes:
        errors.append('Missing runtime targets: ' + ', '.join(sorted(REQUIRED - recipes)))
    if not tasks or len(recipes) > MAX_RECIPES or len(tasks) > MAX_TASKS:
        errors.append(f'Runtime graph exceeds budget or is empty: {len(recipes)} recipes/{len(tasks)} tasks (limits {MAX_RECIPES}/{MAX_TASKS})')
    if errors:
        raise ValueError('\n'.join(errors))
    return dict(recipe_count=len(recipes), task_count=len(tasks), recipes=sorted(recipes))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path)
    args = parser.parse_args()
    report = args.build / 'runtime-graph.json'
    report.unlink(missing_ok=True)
    recipes = set((args.build / 'pn-buildlist').read_text().splitlines())
    tasks = set(re.findall(r'^"([^"\n]+)"\s+\[label=', (args.build / 'task-depends.dot').read_text(), re.MULTILINE))
    data = check(recipes, tasks)
    report.write_text(json.dumps(data, indent=2) + '\n')
    print(f'Runtime RPM graph approved: {len(recipes)} recipes, {len(tasks)} tasks')
