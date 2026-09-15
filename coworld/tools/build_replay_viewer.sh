#!/usr/bin/env bash
# Same Polyworld Emscripten shell and shared transport used by GOTA.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="${1:?usage: build_replay_viewer.sh <absolute bundle directory>}"
python3 - "$root" "$output" <<'CHECK'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
if not output.is_absolute() or output.is_symlink() or output.resolve() in [root, *root.parents]:
    raise SystemExit('Unsafe replay bundle directory')
CHECK
export POLYWORLD_DEPS="${POLYWORLD_DEPS:-$root/tmp/coworld/deps}"
export POLYWORLD_DATA="${POLYWORLD_DATA:-$root/assets/polyworld}"
python3 "$root/coworld/tools/sync_dependencies.py"
python3 "$root/scripts/sync_polyworld_assets.py"
cd "$root"
nim c -d:emscripten -d:replayViewer examples/harvestbench/harvestbench.nim
mkdir -p "$output"
for suffix in js wasm data; do
  cp "examples/harvestbench/emscripten/harvestbench.$suffix" "$output/"
done
cp examples/harvestbench/emscripten/harvestbench.html "$output/index.html"
# The same viewer is served by the live game container.
live="$root/coworld/game/client/polyworld"
mkdir -p "$live"
if [[ "$output" != "$live" ]]; then
  cp "$output"/harvestbench.{js,wasm,data} "$live/"
  cp "$output/index.html" "$live/index.html"
fi
