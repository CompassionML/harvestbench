import std/[os, strutils]

--path:"src"
let dependencyRoot = getEnv("POLYWORLD_DEPS")
if dependencyRoot.len > 0:
  for line in readFile(currentSourcePath().parentDir / "coworld/dependencies.lock").splitLines():
    let fields = line.splitWhitespace()
    if fields.len == 0:
      continue
    let name = fields[0]
    if name == "mummy" and not defined(coworld):
      continue
    let directory = dependencyRoot / name
    switch("path", if dirExists(directory / "src"): directory / "src" else: directory)
else:
  switch("path", getEnv("SILKY_PATH", "../silky/src"))
  --path:"../shady/src"
  --path:"../noisy/src"
  --path:"../windy/src"
  --path:"../gltf/src"
  --path:"../vmath/src"
  when defined(coworld):
    --path:"../mummy/src"

--define:nimTypeNames
--define:flatty64

when defined(coworld):
  when defined(emscripten):
    error("Coworld servers are native. Build replay viewers without -d:coworld.")
  --define:headless
  --threads:on

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck
