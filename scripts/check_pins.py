"""Are we requesting any model by a moving alias when a dated one exists?

Sonnet 5 returned 17-21% across five cells in late July and about 3% across
three re-runs in August, same briefing, seeds and settings. Nothing in our
setup would have caught the served build changing, because the logs only
record the alias we asked for.

Anthropic publishes dated snapshot ids for some models and not others. Run
this before a panel: it lists what the API offers today and flags any model
we run by a bare alias that has since gained a dated form worth pinning.

    python scripts/check_pins.py
"""
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from panel import BEDROCK_IDS, canonical  # noqa: E402


def anthropic_key() -> str:
    """Read the key from the Windows User environment; never print it."""
    r = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "[Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY','User')"],
        capture_output=True, text=True)
    return r.stdout.strip()


def snapshots() -> dict[str, str]:
    key = anthropic_key()
    if not key:
        sys.exit("ANTHROPIC_API_KEY is not set in the User environment")
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/models?limit=100",
        headers={"x-api-key": key, "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return {m["id"]: (m.get("created_at") or "")[:10]
                for m in json.load(r).get("data", [])}


def dated(model_id: str) -> bool:
    """A dated snapshot ends in an 8-digit date."""
    tail = model_id.rsplit("-", 1)[-1]
    return len(tail) == 8 and tail.isdigit()


def main() -> int:
    ids = snapshots()
    families = {}
    for mid, created in ids.items():
        stem = mid.rsplit("-", 1)[0] if dated(mid) else mid
        families.setdefault(stem, []).append((mid, created))

    print(f"{'model we run':30s}{'requested as':38s}pin")
    print("-" * 88)
    bad = 0
    for model, bedrock_id in sorted(BEDROCK_IDS.items()):
        short = canonical(model).split("/", 1)[1].replace(".", "-")
        opts = families.get(short, [])
        has_dated = [m for m, _ in opts if dated(m)]
        pinned = dated(bedrock_id.replace("-v1:0", ""))
        if pinned:
            state = "pinned to a dated snapshot"
        elif has_dated:
            state = f"UNPINNED and {has_dated[0]} exists -- pin it"
            bad += 1
        else:
            state = "unpinned; the API offers no dated id for it"
        print(f"{model:30s}{bedrock_id:38s}{state}")

    print("\nWhat the Anthropic API offers today:")
    for mid, created in sorted(ids.items()):
        print(f"   {mid:34s} released {created}")
    if bad:
        print(f"\n{bad} model(s) could be pinned and are not.")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
