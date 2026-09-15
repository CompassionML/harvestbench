## Silky profiling with Polyworld's capture budget and Fluffy viewer shortcut.

import
  std/os,
  silky/profiles

when not defined(emscripten):
  import std/osproc

export profiles

const
  MapProfileTracePath* {.strdefine.} = ""
  ProfileFrames* {.intdefine.} = 0
  RuntimeTracePath* = "tmp/fluffy.json"
  ActiveTracePath* =
    if ProfileTracePath.len > 0:
      ProfileTracePath
    else:
      MapProfileTracePath

var
  gameCapture = false
  presentedFrames = 0

proc startGameProfile*() =
  ## Starts Silky's recorder using the existing game capture flags.
  when ActiveTracePath.len > 0:
    if profileTraceActive():
      return
    gameCapture = true
    presentedFrames = 0
    startRuntimeProfileTrace(ActiveTracePath)

proc finishGameProfile*() =
  ## Writes the shared Silky trace and clears the game frame budget.
  discard finishProfileTrace()
  gameCapture = false

proc profileShouldDump*(frames: int): bool =
  ## Applies the legacy frame or tick budget to an active game capture.
  gameCapture and profileTraceActive() and
    ProfileFrames > 0 and frames >= ProfileFrames

proc noteProfileFrame*(): bool =
  ## Counts presented game frames, excluding loading splashes and UI passes.
  if not gameCapture or not profileTraceActive():
    return false
  inc presentedFrames
  if profileShouldDump(presentedFrames):
    finishGameProfile()
    return true

proc fluffyNimPath(): string =
  ## Finds the Fluffy viewer next to this repo.
  let
    fromHere = currentSourcePath().parentDir / "../../.." / "fluffy" / "src" / "fluffy.nim"
    fromCwd = getCurrentDir() / ".." / "fluffy" / "src" / "fluffy.nim"
  if fileExists(fromHere):
    return fromHere.normalizedPath
  if fileExists(fromCwd):
    return fromCwd.normalizedPath
  ""

proc openFluffy(path: string) =
  ## Opens the written trace in the Fluffy viewer.
  when defined(emscripten):
    discard
  else:
    let
      absPath = path.absolutePath
      fluffyNim = fluffyNimPath()
    if fluffyNim.len == 0:
      echo "Fluffy viewer not found; open ", absPath, " by hand"
      return
    let fluffyRoot = fluffyNim.parentDir.parentDir
    echo "Opening Fluffy: ", absPath
    discard startProcess(
      "nim",
      workingDir = fluffyRoot,
      args = ["r", "src/fluffy.nim", absPath],
      options = {poUsePath}
    )

proc toggleRuntimeTrace*() =
  ## Toggles Silky's recorder with F2 and opens the completed trace in Fluffy.
  when not defined(emscripten):
    gameCapture = false
    let path = toggleRuntimeProfileTrace(RuntimeTracePath)
    if path.len > 0:
      openFluffy(path)
