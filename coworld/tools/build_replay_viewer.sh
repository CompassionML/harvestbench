#!/usr/bin/env bash
# Coworld build hook (STATIC_REPLAY_VIEWERS.md): produce the static replay
# viewer bundle. `coworld build` runs it with the resolved absolute bundle
# directory as its only argument and the Coworld project directory as the
# working directory. The viewer is the same replay.html the game image serves
# at /client/replay, which reads the replay from #replay=<url> when present,
# plus the shared canvas renderer it loads by relative URL.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:?usage: build_replay_viewer.sh <absolute bundle directory>}"

# Accept the OS-native absolute path: POSIX (/...) or Windows drive-letter (C:\... or C:/...).
if [[ "${output_dir}" != /* && ! "${output_dir}" =~ ^[A-Za-z]:[\\/] ]] \
  || [[ "${output_dir}" == "/" || "${output_dir}" == "${project_dir}" ]]; then
  echo "unsafe bundle output: ${output_dir}" >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"
cp "${project_dir}/game/client/replay.html" "${output_dir}/index.html"
cp "${project_dir}/game/client/harvest_view.js" "${output_dir}/harvest_view.js"
test -s "${output_dir}/index.html" && test -s "${output_dir}/harvest_view.js"
echo "static replay viewer written to ${output_dir}"
