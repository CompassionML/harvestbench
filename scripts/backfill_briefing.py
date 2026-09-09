"""Stamp briefing_version onto every record in logs/cells_cache.json.

Why this exists (2026-09-09): the cache never recorded which briefing a
cell ran on. The published panel ran on briefing 1 (arm file with its
Controls section, driving note appended); code after 2026-08-04 ran
briefing 2 (section removed). The August "variance" cells were briefing 2
and were compared to the briefing-1 panel as replicates, which turned a
15-35 point prompt effect into what read as noise or routing. The board
gate now requires briefing_version == 1, so every record needs the field.

Rule: logs written after 2026-08-04 carry briefing_version in sample
metadata; logs before it do not and are briefing 1 by construction.

Reads one sample's metadata straight out of the .eval zip rather than
loading the whole log, so the full cache takes seconds, not minutes.

    python scripts/backfill_briefing.py          # writes the cache
    python scripts/backfill_briefing.py --dry    # report only
"""
import glob
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from build_cache import CACHE, DIRS  # noqa: E402

DRY = "--dry" in sys.argv


def briefing_of(path: str):
    """briefing_version from the first sample in the log; 1 if the run
    predates the stamp (no such key in any sample's metadata)."""
    with zipfile.ZipFile(path) as z:
        names = sorted(n for n in z.namelist()
                       if n.startswith("samples/") and n.endswith(".json"))
        if not names:
            return None
        md = json.loads(z.read(names[0])).get("metadata") or {}
        return md.get("briefing_version", 1)


def main():
    cache = json.loads(CACHE.read_text())
    by_name = {}
    for d in DIRS:
        for p in glob.glob(str(ROOT / "logs" / d / "*.eval")):
            by_name[Path(p).name] = p
    done = missing = 0
    counts = {}
    for key, rec in cache.items():
        if "briefing_version" in rec:
            counts[rec["briefing_version"]] = counts.get(rec["briefing_version"], 0) + 1
            continue
        name = key.split("|", 1)[0]
        p = by_name.get(name)
        if p is None:
            missing += 1
            print(f"  no log on disk for {name}; left unstamped", flush=True)
            continue
        bv = briefing_of(p)
        if bv is None:
            missing += 1
            print(f"  no samples in {name}; left unstamped", flush=True)
            continue
        rec["briefing_version"] = bv
        counts[bv] = counts.get(bv, 0) + 1
        done += 1
    print(f"stamped {done} records, {missing} left unstamped; "
          f"briefing_version counts: {counts}", flush=True)
    if not DRY:
        CACHE.write_text(json.dumps(cache))
        print(f"wrote {CACHE}", flush=True)


if __name__ == "__main__":
    main()
