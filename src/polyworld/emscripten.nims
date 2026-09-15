## Shared Emscripten compile recipe for Polyworld games.

import
  std/[os, strformat, strutils]

proc setupEmscripten*(exampleDir: string) =
  ## Configures the wasm backend and writes the bundle next to the game.
  when defined(emscripten):
    let
      repoDir = exampleDir / ".." / ".."
      dataDir = getEnv("POLYWORLD_DATA", repoDir / "assets" / "polyworld")
      outputDir = exampleDir / "emscripten"
      shellFile = repoDir / "src" / "polyworld" /
        (if defined(replayViewer): "replay.html" else: "emscripten.html")
    let preJs =
      if defined(replayViewer):
        ""
      else:
        "--pre-js " & repoDir / "src" / "polyworld" / "webinputs.js"
    var preload = "--preload-file " & dataDir & "@/polyworld_data"
    let selection = exampleDir / "webdata.txt"
    if fileExists(selection):
      preload = ""
      for line in readFile(selection).splitLines():
        let name = line.strip()
        if name.len == 0 or name.startsWith("#"):
          continue
        if not fileExists(dataDir / name) and not dirExists(dataDir / name):
          raise newException(ValueError, "Missing replay asset: " & name)
        preload.add " --preload-file " & dataDir / name &
          "@/polyworld_data/" & name
    if not dirExists(outputDir):
      mkDir(outputDir)
    switch("nimcache", outputDir / "tmp")
    switch("threads", "off")
    --os:linux
    --cpu:wasm32
    --cc:clang
    when defined(windows):
      --clang.exe:emcc.bat
      --clang.linkerexe:emcc.bat
      --clang.cpp.exe:emcc.bat
      --clang.cpp.linkerexe:emcc.bat
    else:
      --clang.exe:emcc
      --clang.linkerexe:emcc
      --clang.cpp.exe:emcc
      --clang.cpp.linkerexe:emcc
    --gc:arc
    --exceptions:goto
    --define:noSignalHandler
    --debugger:native
    --define:noAutoGLerrorCheck
    --define:flatty64
    when not defined(debug):
      --define:release
    switch(
      "passL",
      (&"""
      -o {outputDir / projectName()}.html
      {preload}
      {preJs}
      --shell-file {shellFile}
      -s ASYNCIFY
      -s FETCH
      -s EXIT_RUNTIME=1
      -s USE_WEBGL2=1
      -s MAX_WEBGL_VERSION=2
      -s MIN_WEBGL_VERSION=1
      -s FULL_ES3=1
      -s GL_ENABLE_GET_PROC_ADDRESS=1
      -s ALLOW_MEMORY_GROWTH
      --profiling
      """).replace("\n", " ")
    )
    if paramStr(1) == "run" or paramStr(1) == "r":
      setCommand("c")
      echo "To run the Emscripten build, use:"
      echo "emrun " & outputDir / (projectName() & ".html")
