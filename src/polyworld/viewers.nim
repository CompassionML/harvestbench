## Shared graphical viewer bootstrap for Polyworld games.

import
  std/[math, os, strutils, times],
  chroma, opengl, pixie, silky, vmath, windy,
  common, player

when defined(emscripten):
  {.emit: "#include <emscripten.h>".}

const
  DefaultWindowSize* = ivec2(1280, 800)
  DefaultFontPath* = DataRoot & "/fonts/Rubik-Regular.ttf"
  BoldFontPath* = DataRoot & "/fonts/Rubik-Bold.ttf"
  MonoFontPath* = DataRoot & "/fonts/OverpassMono-Regular.ttf"
  MainThemeDir* = DataRoot & "/themes/main/"
  UiDir* = DataRoot & "/ui/"
  IconDir* = DataRoot & "/icons/"
  HudIconSize = 64
  SplashName* = "logo"
  SplashSeconds* = 3.0
    ## How long the theme logo stays up while the client finishes loading.

type Splash* = object
  ## Wall-clock start of one loading splash.
  startedAt*: float64
  name*: string

proc damping*(rate, dt: float32): float32 =
  ## Returns a frame-rate-independent exponential easing fraction.
  1.0'f32 - exp(-rate * dt)

proc shortestTurn*(current, target: float32): float32 =
  ## Returns the shortest signed turn between two yaw angles.
  var delta = target - current
  while delta > PI.float32:
    delta -= (2 * PI).float32
  while delta < -PI.float32:
    delta += (2 * PI).float32
  delta

proc addThemeLogo*(builder: AtlasBuilder, path: string) =
  ## Packs one game's theme logo for the loading splash.
  if not builder.addImage(SplashName, readImage(path)):
    raise newException(
      ValueError,
      "the UI atlas is too small for the theme logo"
    )

proc addDefaultFonts*(builder: AtlasBuilder) =
  ## Adds the shared HUD type ramp used by every graphical client.
  builder.addFont(BoldFontPath, "H1", 32.0)
  builder.addFont(DefaultFontPath, "Default", 18.0)
  builder.addFont(BoldFontPath, "Bold", 18.0)
  builder.addFont(DefaultFontPath, "Hud", 15.0)
  builder.addFont(DefaultFontPath, "Small", 12.0)
  builder.addFont(MonoFontPath, "Mono", 18.0)

proc applyThemePatches*(sk: Silky) =
  ## Uses the measured corner slices of the main theme 9-patches.
  sk.theme.windowPatch = 7
  sk.theme.headerPatch = 4
  sk.theme.framePatch = 5
  sk.theme.buttonPatch = 5
  sk.theme.dropdownPatch = 5
  sk.theme.textboxPatch = 4
  sk.theme.tooltipPatch = 3
  sk.theme.scrollbarPatch = 5
  sk.theme.scrollbarTrackPatch = 3
  sk.theme.progressBarPatch = 3
  sk.theme.scrubberPatch = 3

proc addHudGlyphs(builder: AtlasBuilder) =
  ## Packs the shared transport and HUD glyphs every game can draw.
  for file in walkDir(IconDir):
    if not file.path.endsWith(".png"):
      continue
    let
      name = splitFile(file.path).name
      icon = readImage(file.path).resize(HudIconSize, HudIconSize)
    if not builder.addImage(name, icon):
      raise newException(
        ValueError,
        "the UI atlas is too small for HUD icons"
      )

proc newHudAtlas*(size = 1024): AtlasBuilder =
  ## Starts an atlas with the shared main theme and UI images.
  result = newAtlasBuilder(size, 4)
  result.addDir(MainThemeDir, MainThemeDir)
  result.addDir(UiDir, UiDir)
  result.addHudGlyphs()

proc gameWindowSize*(width, height: int32): IVec2 =
  ## Returns a requested window size, or the shared default.
  if width > 0 and height > 0:
    ivec2(width, height)
  else:
    DefaultWindowSize

proc initGameWindow*(
    title,
    atlasPath: string,
    size = DefaultWindowSize,
    vsync = true,
    msaa = msaaDisabled
): (Window, Silky) =
  ## Creates the spectator window, GL context, and Silky atlas client.
  let window = newWindow(title, size, vsync = vsync, msaa = msaa)
  window.makeContextCurrent()
  loadExtensions()
  let sk = newSilky(window, atlasPath)
  sk.applyThemePatches()
  window.onRune = proc(rune: Rune) =
    sk.inputRunes.add(rune)
  (window, sk)

proc drawSplash*(
    sk: Silky,
    window: Window,
    name = SplashName
) =
  ## Draws the theme logo centered on a black frame.
  sk.beginUi(window, window.size)
  sk.clearScreen(rgbx(0, 0, 0, 255))
  if name in sk.atlas.entries:
    let
      uv = sk.atlas.entries[name]
      src = vec2(uv.width.float32, uv.height.float32)
      area = window.size.vec2 * 0.78
      scale = min(area.x / max(src.x, 1), area.y / max(src.y, 1))
      dest = src * scale
      pos = (window.size.vec2 - dest) * 0.5
    sk.drawQuad(
      pos,
      dest,
      vec2(uv.x.float32, uv.y.float32),
      src,
      rgbx(255, 255, 255, 255)
    )
  sk.endUi()
  window.swapBuffers()
  pollEvents()

proc startSplash*(
    sk: Silky,
    window: Window,
    name = SplashName
): Splash =
  ## Shows the splash and starts the hold clock.
  result.startedAt = epochTime()
  result.name = name
  drawSplash(sk, window, name)

proc holdSplash*(
    sk: Silky,
    window: Window,
    splash: Splash,
    seconds = SplashSeconds
) =
  ## Keeps the splash up until the hold time elapses.
  when defined(takeScreenshot) or defined(emscripten):
    drawSplash(sk, window, splash.name)
    return
  while epochTime() - splash.startedAt < seconds:
    if window.closeRequested:
      quit(0)
    drawSplash(sk, window, splash.name)
    sleep(10)

var
  presentDeadline = 0.0
  presentPaceHz = 0

proc presentFrame*(window: Window, paceHz = 60) =
  ## Swaps the back buffer, then waits so presents stay on one cadence.
  ## ProMotion vsync alone flips between 8.33 ms and 16.67 ms.
  window.swapBuffers()
  if paceHz <= 0:
    presentDeadline = 0
    presentPaceHz = 0
    return
  if paceHz != presentPaceHz:
    presentDeadline = 0
    presentPaceHz = paceHz
  let
    step = 1.0 / paceHz.float64
    now = epochTime()
  if presentDeadline <= 0 or now > presentDeadline + step * 2:
    presentDeadline = now + step
    return
  let remain = presentDeadline - now
  if remain > 0.001:
    sleep(int(remain * 1000.0))
  presentDeadline += step

proc frameDelta*(
    lastFrameTime: var float64,
    captureStep = 1.0'f32 / 60.0'f32
): float32 =
  ## Returns clamped wall-clock dt, or a fixed step when capturing.
  let now = epochTime()
  result = clamp(now - lastFrameTime, 0.0, 0.1).float32
  lastFrameTime = now
  when defined(takeScreenshot):
    result = captureStep

proc simulationActive*(transport: Player): bool =
  ## Returns whether presentation should advance on this frame.
  transport.playing or transport.targetTick >= 0

proc atLiveTickCap*(tick, maximumTicks: int32, live: bool): bool =
  ## Returns whether a live match has used its configured tick budget.
  live and tick >= maximumTicks

proc applyScreenshotCamera*(cameraDistance: var float32) =
  ## Overrides camera distance from CAM_DIST when capturing.
  when defined(takeScreenshot):
    if existsEnv("CAM_DIST"):
      cameraDistance = getEnv("CAM_DIST").parseFloat.float32
  else:
    discard cameraDistance

proc captureScreenshot*(
    window: Window,
    frame: var int,
    waitFrames: int,
    defaultPath: string
) =
  ## Writes one back-buffer capture after waitFrames when capturing.
  when defined(takeScreenshot):
    inc frame
    if frame < waitFrames:
      return
    let
      path =
        if existsEnv("SCREENSHOT_PATH"):
          getEnv("SCREENSHOT_PATH")
        else:
          defaultPath
      image = newImage(window.size.x, window.size.y)
    glReadPixels(
      0,
      0,
      window.size.x.GLsizei,
      window.size.y.GLsizei,
      GL_RGBA,
      GL_UNSIGNED_BYTE,
      image.data[0].addr
    )
    image.flipVertical()
    image.writeFile(path)
    quit(0)
  else:
    discard (window, frame, waitFrames, defaultPath)

proc reportReplayFrame*(tick, mismatches: int32) =
  ## Reports browser readiness and divergence after presenting a game frame.
  when defined(emscripten):
    {.emit: """
    EM_ASM({
      if (Module.polyworldFrame) Module.polyworldFrame($0, $1);
    }, `tick`, `mismatches`);
    """.}
