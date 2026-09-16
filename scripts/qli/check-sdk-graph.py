#!/usr/bin/env python3
"""Reject image/runtime/graphics dependencies before compiling the RPM SDK."""
import argparse
import json
from pathlib import Path
import re

# A regression must be reviewed instead of quietly launching a larger build.
MAX_RECIPES = 170
MAX_TASKS = 2800
REQUIRED = {'meta-toolchain', 'gcc-cross-canadian-aarch64',
            'binutils-cross-canadian-aarch64', 'glibc', 'gcc-runtime',
            'linux-libc-headers', 'systemd', 'sqlite3'}
BANNED = ('networkmanager', 'modemmanager', 'bluez', 'bluez5', 'qemu', 'llvm', 'clang',
          'mesa', 'wayland', 'weston', 'xserver', 'xorg', 'spirv', 'vulkan',
          'libgpiod', 'jq', 'socat', 'sudo', 'u-boot', 'kernel-devsrc',
          'initramfs', 'qcom-multimedia', 'qcom-networking', 'gdb', 'rust',
          'cargo', 'go-cross', 'dnf', 'createrepo-c', 'cryptsetup',
          'lvm2', 'tpm2-tss', 'shared-mime-info')


def check(recipes, tasks):
    errors = []
    for recipe in sorted(recipes):
        base = recipe.removeprefix('nativesdk-')
        if ((base.startswith('linux-') and not base.startswith('linux-libc-headers'))
                or any(base == prefix or base.startswith(prefix + '-') for prefix in BANNED)
                or base.endswith('-ptest')):
            errors.append('Forbidden SDK recipe: ' + recipe)
    for task in sorted(tasks):
        if re.search(r'\.do_(rootfs|image(?:_.*)?)$', task):
            errors.append('Image task in SDK graph: ' + task)
    missing = REQUIRED - recipes
    if missing:
        errors.append('Missing compiler/library recipes: ' + ', '.join(sorted(missing)))
    if len(recipes) > MAX_RECIPES or len(tasks) > MAX_TASKS:
        errors.append(f'SDK graph exceeds budget: {len(recipes)} recipes/{len(tasks)} tasks '
                      f'(limits {MAX_RECIPES}/{MAX_TASKS})')
    if not tasks:
        errors.append('Empty or unrecognized task graph')
    if errors:
        raise ValueError('\n'.join(errors))
    return dict(recipe_count=len(recipes), task_count=len(tasks), recipes=sorted(recipes))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path)
    args = parser.parse_args()
    report_file = args.build / 'sdk-graph.json'
    report_file.unlink(missing_ok=True)
    recipes = set((args.build / 'pn-buildlist').read_text().splitlines())
    graph = (args.build / 'task-depends.dot').read_text()
    tasks = set(re.findall(r'^"([^"\n]+)"\s+\[label=', graph, re.MULTILINE))
    report = check(recipes, tasks)
    report_file.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Minimal SDK graph approved: {len(recipes)} recipes, {len(tasks)} tasks')


if __name__ == '__main__':
    main()
