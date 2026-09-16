#!/usr/bin/env python3
"""Tachyon hardware check: silent default playback, optional brief mic capture.

Run on the board. Capture samples stay in memory and are discarded; only
sample counts and levels are printed. This does not verify audible output.
"""
import argparse
import array
import math
import os
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', action='store_true', help='also sample the microphone for two seconds')
    args = parser.parse_args()
    cards = Path('/proc/asound/cards').read_text()
    match = re.search(r'^\s*(\d+)\s+\[.*qcm6490.*', cards, re.MULTILINE)
    if not match or 'qcm6490-tachyon-snd-card' not in cards:
        raise RuntimeError('Tachyon ALSA sound card not registered')
    status = Path(f'/proc/asound/card{match[1]}/pcm0p/sub0/status')
    env = dict(os.environ, PIPEWIRE_RUNTIME_DIR='/run/pipewire')
    command = ['aplay', '-D', 'default', '-t', 'raw', '-f', 'S16_LE',
               '-c', '2', '-r', '48000', '-d', '3', '/dev/zero']
    player = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    pointers = []
    try:
        deadline = time.monotonic() + 10
        while player.poll() is None and time.monotonic() < deadline:
            snapshot = status.read_text()
            pointer = re.search(r'^hw_ptr\s*:\s*(\d+)', snapshot, re.MULTILINE)
            if 'state: RUNNING' in snapshot and pointer:
                pointers.append(int(pointer[1]))
            time.sleep(0.1)
        _, stderr = player.communicate(timeout=2)
        if player.returncode:
            raise RuntimeError(stderr.decode())
        if len(set(pointers)) < 2:
            raise RuntimeError('Default playback did not advance the physical headphone PCM')
        print(f'PASS: default playback advanced hardware PCM (observed hw_ptr {min(pointers)}..{max(pointers)})')
    finally:
        if player.poll() is None:
            player.kill()
            player.communicate()
    if args.capture:
        command = ['arecord', '-D', 'default', '-t', 'raw', '-f', 'S16_LE',
                   '-c', '2', '-r', '48000', '-d', '2']
        result = subprocess.run(command, env=env, capture_output=True, timeout=12, check=True)
        if len(result.stdout) != 48000 * 2 * 2 * 2:
            raise RuntimeError(f'Unexpected capture length: {len(result.stdout)} bytes')
        samples = array.array('h', result.stdout)
        rms = math.sqrt(sum(value * value for value in samples) / len(samples))
        print(f'PASS: default capture returned {len(samples)//2} stereo frames; peak={max(map(abs, samples))}, RMS={rms:.2f}')


if __name__ == '__main__':
    main()
