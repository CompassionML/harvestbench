## Shared paths and constants for Polyworld.
## Native games load assets from the sibling polyworld_data folder.
## Wasm packs that folder at /polyworld_data.

const
  DataRoot* {.strdefine.} =
    when defined(emscripten):
      "/polyworld_data"
    else:
      "assets/polyworld"
  # Generated files that do not belong in polyworld_data.
  TmpRoot* =
    when defined(emscripten):
      "/tmp"
    else:
      "tmp"
