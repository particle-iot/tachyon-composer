#!/usr/bin/env python3
"""Resolve the independent QLI release stream without consuming Ubuntu tags."""
import argparse
import re
import subprocess

PREFIX = 'qli-2.0/'
SEED = (1, 4, 0)
STABLE = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def releases():
    result = []
    for tag in git('tag', '--list', PREFIX + '*').splitlines():
        match = STABLE.fullmatch(tag.removeprefix(PREFIX))
        if match and (version := tuple(map(int, match.groups()))) >= SEED:
            result.append((version, tag))
    return sorted(result)


def next_version(bump='patch', reuse_head=True):
    tags = releases()
    if reuse_head:
        at_head = set(git('tag', '--points-at', 'HEAD').splitlines())
        current = [v for v, tag in tags if tag in at_head]
        if current:
            return '.'.join(map(str, max(current)))
    if not tags:
        return '.'.join(map(str, SEED))
    major, minor, patch = tags[-1][0]
    if bump == 'major':
        major, minor, patch = major + 1, 0, 0
    elif bump == 'minor':
        minor, patch = minor + 1, 0
    else:
        patch += 1
    return f'{major}.{minor}.{patch}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('next', 'current', 'prerelease', 'previous'))
    parser.add_argument('--bump', choices=('patch', 'minor', 'major'), default='patch')
    parser.add_argument('--ref', default='')
    args = parser.parse_args()
    if args.mode == 'next':
        print(next_version(args.bump))
    elif args.mode == 'prerelease':
        print(f'{next_version(reuse_head=False)}-dev+build.{git("rev-parse", "--short=7", "HEAD")}')
    elif args.mode == 'current':
        tag = args.ref.removeprefix('refs/tags/')
        version = tag.removeprefix(PREFIX)
        core = version.split('-', 1)[0].split('+', 1)[0]
        match = STABLE.fullmatch(core)
        if (not tag.startswith(PREFIX) or not match
                or tuple(map(int, match.groups())) < SEED
                or not re.fullmatch(r'[0-9A-Za-z.+-]+', version)
                or git('rev-parse', tag + '^{commit}') != git('rev-parse', 'HEAD')):
            raise SystemExit('Release must be a qli-2.0/ tag at HEAD, version 1.4.0 or later')
        print(version)
    else:
        previous = git('tag', '--merged', 'HEAD^', '--list', PREFIX + '*').splitlines()
        candidates = [tag for _, tag in releases() if tag in previous]
        # An empty previous tag breaks release-changelog-builder on first release.
        print(candidates[-1] if candidates else git('rev-list', '--max-parents=0', 'HEAD').splitlines()[0])


if __name__ == '__main__':
    main()
