#!/usr/bin/env python3
"""Bounded CPU, GPU readback and filesystem I/O soak. Run on the Tachyon."""
import argparse
import hashlib
import json
import multiprocessing as mp
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def cpu_worker(deadline, stop):
    os.nice(10)
    block = bytes(8 * 1024 * 1024)
    while time.monotonic() < deadline and not stop.is_set():
        hashlib.sha256(block).digest()


def storage_worker(deadline, stop, directory):
    block = os.urandom(1024 * 1024)
    expected = hashlib.sha256(block * 64).hexdigest()
    path = Path(directory) / 'scratch.bin'
    iterations = 0
    while time.monotonic() < deadline and not stop.is_set():
        with path.open('wb') as f:
            for _ in range(64):
                f.write(block)
            f.flush()
            os.fsync(f.fileno())
            os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)
        digest = hashlib.sha256()
        with path.open('rb') as f:
            for data in iter(lambda: f.read(1024 * 1024), b''):
                digest.update(data)
        if digest.hexdigest() != expected:
            raise RuntimeError('Filesystem write/read checksum mismatch')
        iterations += 1
        stop.wait(min(10, max(0, deadline - time.monotonic())))
    print(json.dumps({'storage_cycles': iterations, 'verified_bytes': iterations * 64 * 1024**2}), flush=True)


def telemetry():
    result = {'thermal_c': {}, 'frequency_hz': {}}
    for zone in Path('/sys/class/thermal').glob('thermal_zone*'):
        try:
            value = int((zone / 'temp').read_text()) / 1000
            result['thermal_c'][(zone / 'type').read_text().strip()] = value
        except (OSError, ValueError):
            pass
    for device in Path('/sys/class/devfreq').glob('*'):
        try:
            result['frequency_hz'][device.name] = int((device / 'cur_freq').read_text())
        except (OSError, ValueError):
            pass
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=3600)
    args = parser.parse_args()
    if not 10 <= args.seconds <= 7200:
        parser.error('--seconds must be 10..7200')
    if b'tachyon' not in Path('/proc/device-tree/compatible').read_bytes():
        raise SystemExit('Tachyon required')
    stop = mp.Event()
    start = time.monotonic()
    deadline = start + args.seconds
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    with tempfile.TemporaryDirectory(prefix='tachyon-stress-', dir='/var/tmp') as directory:
        workers = [mp.Process(target=cpu_worker, args=(deadline, stop)) for _ in range(os.cpu_count() or 1)]
        workers.append(mp.Process(target=storage_worker, args=(deadline, stop, directory)))
        gpu_log = open(Path(directory) / 'gpu.log', 'w+')
        gpu = subprocess.Popen([sys.executable, str(Path(__file__).with_name('gpu-smoke.py')),
                                '--seconds', str(args.seconds)], stdout=gpu_log, stderr=subprocess.STDOUT)
        try:
            for worker in workers:
                worker.start()
            while time.monotonic() < deadline:
                sample = telemetry()
                print(json.dumps({'elapsed_s': round(time.monotonic()-start), 'boot_id': boot, **sample}), flush=True)
                if any(value >= 90 for value in sample['thermal_c'].values()):
                    raise RuntimeError('Soak stopped at 90 C')
                if any(w.exitcode is not None and w.exitcode != 0 for w in workers):
                    raise RuntimeError('CPU/storage worker failed')
                if gpu.poll() is not None:
                    raise RuntimeError('GPU worker ended before soak duration')
                time.sleep(min(10, max(0, deadline-time.monotonic())))
            for worker in workers:
                worker.join(timeout=20)
                if worker.exitcode != 0:
                    raise RuntimeError(f'CPU/storage worker exited {worker.exitcode}')
            if gpu.wait(timeout=30) != 0:
                raise RuntimeError('GPU soak failed')
            print(f'PASS: {args.seconds}s CPU/GPU/storage soak on boot {boot}', flush=True)
        finally:
            stop.set()
            for worker in workers:
                if worker.pid:
                    worker.join(timeout=5)
                    if worker.is_alive():
                        worker.terminate()
                        worker.join()
            if gpu.poll() is None:
                gpu.terminate()
                gpu.wait(timeout=10)
            gpu_log.seek(0)
            print(gpu_log.read(), flush=True)
            gpu_log.close()


if __name__ == '__main__':
    main()
