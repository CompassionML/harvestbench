"""Resolve and check out pinned Nim dependencies without modifying sibling repos."""
import argparse
import fcntl
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def command(*args):
    """Return a checked command's output without mixing subprocess diagnostics."""
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.stderr.strip()) from error


def sync(entry, latest):
    """Fetch one dependency and pin a detached checkout to its resolved revision."""
    name, version, url, revision = entry.split()
    path = Path(os.environ.get('POLYWORLD_DEPS', ROOT / 'tmp/coworld/deps')) / name
    created = not (path / '.git').exists()
    if created:
        path.parent.mkdir(parents=True, exist_ok=True)
        command('git', 'clone', '--filter=blob:none', '--no-checkout', url, str(path))
    if not latest and not created and command('git', '-C', str(path), 'rev-parse', 'HEAD') == revision:
        if command('git', '-C', str(path), 'status', '--porcelain', '--untracked-files=no'):
            raise RuntimeError(f'Dependency has local modifications: {path}')
        print(f'{name}: {revision}', flush=True)
        return entry
    if latest:
        revision = command('git', 'ls-remote', url, 'HEAD').split()[0]
    command('git', '-C', str(path), 'fetch', '--depth=1', 'origin', revision)
    command('git', '-C', str(path), 'checkout', '--detach', revision)
    if latest:
        manifests = list(path.glob('*.nimble'))
        if manifests:
            found = re.search(r'version\s*=\s*"([^"]+)"', manifests[0].read_text())
            if found:
                version = found[1]
    print(f'{name}: {revision}', flush=True)
    return f'{name} {version} {url} {revision}'


def main():
    """Sync all dependencies and optionally rewrite both repository lock files."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--latest', action='store_true')
    args = parser.parse_args()
    entries = (ROOT / 'coworld/dependencies.lock').read_text().splitlines()
    cache = Path(os.environ.get('POLYWORLD_DEPS', ROOT / 'tmp/coworld/deps'))
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / '.sync.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with ThreadPoolExecutor(max_workers=8) as pool:
            resolved = list(pool.map(lambda entry: sync(entry, args.latest), entries))
    if args.latest:
        (ROOT / 'coworld/dependencies.lock').write_text('\n'.join(resolved) + '\n')
        (ROOT / 'nimby.lock').write_text('\n'.join(e for e in resolved if not e.startswith('mummy ')) + '\n')
    print('Dependencies ready in', ROOT / 'tmp/coworld/deps')


if __name__ == '__main__':
    main()
