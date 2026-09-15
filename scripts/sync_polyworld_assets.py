"""Verify vendored UI assets against their pinned Polyworld source hashes."""
import hashlib
import json
import os
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT/'coworld/assets.json').read_text())
data = Path(os.environ.get('POLYWORLD_DATA', ROOT/'assets/polyworld'))
for name, expected in manifest['files'].items():
    path = data/name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f'Polyworld asset missing or changed: {path}')
print(f"Verified {len(manifest['files'])} assets from {manifest['revision']}")
