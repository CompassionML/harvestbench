## Shared Silky HUD chrome for Polyworld games.

import
  std/[math, strutils, times],
  chroma, pixie, silky, vmath, windy,
  gameuis, inputs, profiles, quadterrain, rtscameras

const
  PanelAccent* = rgbx(83, 91, 108, 255)
  BarBack* = rgbx(35, 40, 50, 255)
  LabelColor* = rgbx(226, 230, 239, 255)
  ErrorFill* = rgbx(79, 18, 24, 248)
  ErrorLine* = rgbx(245, 80, 85, 255)
  CameraFrame* = rgbx(238, 235, 205, 255)
  WindowMargin* = 16.0'f32
  SlotPatch = 5
  TabPatch = 3
  BarTrackName = "bartrack.9patch"
  BarFillName = "barfill.9patch"
  BarTrackPatch = 7
  BarFillPatch = 5
  BarInset = 3.0'f32
  KeyPipName = "pip.medium"
  KeyPipSize = 28.0'f32
  KeyPipInset = 2.0'f32
  UiScaleSteps* = [
    0.25'f32, 0.5'f32, 1.0'f32, 1.25'f32, 2.0'f32, 2.5'f32, 4.0'f32
  ]
  UiCrispSteps* = [0.25'f32, 0.5'f32, 1.0'f32, 2.0'f32, 4.0'f32]
  HudReferenceSize* = vec2(1920, 1080)
  HudDaySeconds* = 300'i32
    ## Wall-clock seconds in one in-game day. A 20 minute match is four days.
  DebugWindowTitle* = "Debug"
  DebugWindowOrigin* = vec2(360, 32)
  DebugWindowSize* = vec2(460, 380)
  FpsLimitMin* = 15
  FpsLimitMax* = 240
  FpsAvgTau = 1.0'f32
  FpsAvgPeriod = 0.5
  FpsLabelSize = vec2(40, 22)
  FpsNowSize = vec2(70, 22)
  FpsAvgSize = vec2(168, 22)
  FpsStdSize = vec2(148, 22)

var
  hudScratch*: string
  debugMenuOpen* = false
  interpolateVisuals* = true
  showPaths* = false
  showTiles* = false
  framePaceHz* = 60
  fpsLastTime = 0.0
  fpsLabelTime = 0.0
  fpsHasAvg = false
  fpsAvgValue = 0.0'f32
  fpsVarValue = 0.0'f32
  fpsNowText = "  0.00"
  fpsAvgText = "frame   0.00 ms"
  fpsStdText = "  0.00 ms std"

proc addDigits(s: var string, value: int) =
  ## Appends an unsigned decimal value.
  if value >= 10:
    addDigits(s, value div 10)
  s.add char(ord('0') + value mod 10)

proc addHudInt*(s: var string, value: int) =
  ## Appends a signed decimal value.
  if value < 0:
    s.add '-'
    addDigits(s, -value)
  else:
    addDigits(s, value)

proc addPad2*(s: var string, value: int) =
  ## Appends a two-digit zero-padded value.
  if value < 10:
    s.add '0'
  addDigits(s, value)

proc addAmount*(s: var string, value: int) =
  ## Appends a count with thousands separators.
  if value < 0:
    s.add '-'
    addAmount(s, -value)
    return
  if value >= 1000:
    addAmount(s, value div 1000)
    s.add ','
    let rem = value mod 1000
    if rem < 100:
      s.add '0'
    if rem < 10:
      s.add '0'
    addDigits(s, rem)
  else:
    addDigits(s, value)

proc writeInt*(s: var string, value: int) =
  ## Replaces the buffer with a signed decimal value.
  s.setLen(0)
  s.addHudInt(value)

proc writeAmount*(s: var string, value: int) =
  ## Replaces the buffer with a thousands-separated count.
  s.setLen(0)
  s.addAmount(value)

proc writeRatio*(s: var string, a, b: int) =
  ## Replaces the buffer with "a / b".
  s.setLen(0)
  s.addAmount(a)
  s.add " / "
  s.addAmount(b)

proc writeClock*(s: var string, hour, minute: int) =
  ## Replaces the buffer with a zero-padded 24-hour clock.
  s.setLen(0)
  s.addPad2(hour)
  s.add ':'
  s.addPad2(minute)

proc hudDayTicks*(tickRate: int32): int32 =
  ## Ticks in one in-game day at this simulation rate.
  tickRate * HudDaySeconds

proc clockMinutes(tick, tickRate: int32): int =
  ## Absolute spectator minutes since 8:00 on day 1.
  8 * 60 + int(tick) * 24 * 60 div int(hudDayTicks(tickRate))

proc clockHour*(tick, tickRate: int32): float32 =
  ## The accelerated spectator clock in hours, 0 ..< 24 with a fraction.
  float32(clockMinutes(tick, tickRate) mod (24 * 60)) / 60

proc clockHour*(tick: float32, tickRate: int32): float32 =
  ## The same accelerated clock from a fractional tick (whole ticks plus
  ## the frame's sub-tick blend), continuous instead of stepping once per
  ## whole game minute — the sun and its shadows glide with it.
  var minutes =
    8.0'f32 * 60.0'f32 +
    tick * 24.0'f32 * 60.0'f32 / float32(hudDayTicks(tickRate))
  minutes = minutes - float32(24 * 60) * floor(minutes / float32(24 * 60))
  minutes / 60.0'f32

proc hudClock*(
    tick, tickRate: int32
): tuple[day, hour, minute: int] =
  ## Converts simulation ticks into day, hour, and minute.
  let
    totalMinutes = clockMinutes(tick, tickRate)
    minuteOfDay = totalMinutes mod (24 * 60)
  result.day = totalMinutes div (24 * 60) + 1
  result.hour = minuteOfDay div 60
  result.minute = minuteOfDay mod 60

proc formatAmount*(value: int): string =
  ## Writes a thousands-separated count into the shared HUD scratch.
  writeAmount(hudScratch, value)
  hudScratch

proc fitUiScale*(
    windowSize: Vec2,
    layoutFits: proc(layoutSize: Vec2): bool,
    steps: openArray[float32]
): float32 =
  ## Returns the largest stepped scale whose layout still fits.
  let avail = vec2(max(windowSize.x, 1), max(windowSize.y, 1))
  result = steps[0]
  for step in steps:
    if layoutFits(avail / step):
      result = step

proc fitUiScale*(
    windowSize: Vec2,
    layoutFits: proc(layoutSize: Vec2): bool
): float32 =
  ## Returns the largest default stepped scale whose layout still fits.
  fitUiScale(windowSize, layoutFits, UiScaleSteps)

proc fitUiScale*(windowSize, contentSize: Vec2): float32 =
  ## Returns the largest stepped scale where a bounding box still fits.
  let need = vec2(max(contentSize.x, 1), max(contentSize.y, 1))
  fitUiScale(
    windowSize,
    proc(layoutSize: Vec2): bool =
      need.x <= layoutSize.x and need.y <= layoutSize.y
  )

proc gameUiScale*(windowSize: Vec2): float32 =
  ## Uses the same crisp HUD breakpoints for every game window.
  fitUiScale(
    windowSize,
    proc(layoutSize: Vec2): bool =
      ## Checks both dimensions against the shared reference viewport.
      layoutSize.x >= HudReferenceSize.x and
        layoutSize.y >= HudReferenceSize.y,
    UiCrispSteps
  )

proc gameUiScale*(window: Window): float32 =
  ## Uses the shared HUD breakpoints for the current drawable size.
  gameUiScale(vec2(window.size.x.float32, window.size.y.float32))

proc inset*(panel: GameUiPanel, margin: float32): GameUiPanel =
  ## Returns the rectangle inside a uniform panel margin.
  GameUiPanel(
    origin: panel.origin + vec2(margin),
    size: vec2(
      max(panel.size.x - margin * 2, 0),
      max(panel.size.y - margin * 2, 0)
    )
  )

proc imageSlot*(
    panel: GameUiPanel,
    x, y, w, h: float32
): GameUiPanel =
  ## Returns one art-space rectangle mapped onto a placed panel.
  GameUiPanel(
    origin: panel.origin + vec2(x, y),
    size: vec2(w, h)
  )

proc drawPanel*(
    sk: Silky,
    panel: GameUiPanel,
    accent = PanelAccent
) =
  ## Draws one HUD panel with the main theme window 9-patch.
  discard accent
  sk.draw9Patch(
    "window.9patch",
    sk.theme.windowPatch,
    panel.origin,
    panel.size
  )

proc drawFrame*(
    sk: Silky,
    panel: GameUiPanel
) =
  ## Draws one inner frame 9-patch over a panel.
  sk.draw9Patch(
    "frame.9patch",
    sk.theme.framePatch,
    panel.origin,
    panel.size
  )

proc drawFaintFrame*(
    sk: Silky,
    panel: GameUiPanel
) =
  ## Draws one faded inner frame 9-patch over a panel.
  sk.draw9Patch(
    "frame.faint.9patch",
    sk.theme.framePatch,
    panel.origin,
    panel.size
  )

proc drawRibbon*(
    sk: Silky,
    panel: GameUiPanel
) =
  ## Draws the shared transport ribbon 9-patch.
  sk.draw9Patch(
    "frame.pureblack.9patch",
    sk.theme.framePatch,
    panel.origin,
    panel.size
  )

proc drawSlot*(
    sk: Silky,
    panel: GameUiPanel,
    selected = false
) =
  ## Draws one item or portrait slot 9-patch.
  let name =
    if selected:
      "slot.selected.9patch"
    else:
      "slot.9patch"
  sk.draw9Patch(name, SlotPatch, panel.origin, panel.size)

proc drawTab*(
    sk: Silky,
    panel: GameUiPanel,
    selected = false,
    hovered = false
) =
  ## Draws one theme tab 9-patch.
  let name =
    if selected:
      "panel.tab.selected.9patch"
    elif hovered:
      "panel.tab.hover.9patch"
    else:
      "panel.tab.9patch"
  sk.draw9Patch(name, TabPatch, panel.origin, panel.size)

proc beginPanel*(
    sk: Silky,
    panel: GameUiPanel,
    accent = PanelAccent
): GameUiPanel =
  ## Draws window chrome, then returns the inner content rect.
  sk.drawPanel(panel, accent)
  panel.inset(WindowMargin)

proc drawLabel*(
    sk: Silky,
    value: string,
    position,
    size: Vec2,
    color = LabelColor,
    font = "Hud",
    align = LeftAlign
) =
  ## Draws clipped HUD text inside an explicit screen rectangle.
  discard sk.drawText(
    font,
    value,
    position,
    color,
    maxWidth = size.x,
    maxHeight = size.y,
    hAlign = align,
    vAlign = MiddleAlign
  )

proc barPatch(size: Vec2, wanted: int): int =
  ## Returns a 9-patch border that still fits inside size.
  let cap = min(int(size.x / 2), int(size.y / 2))
  min(wanted, max(cap, 1))

proc drawBar*(
    sk: Silky,
    position,
    size: Vec2,
    value,
    maximum: float32,
    color: ColorRGBX
) =
  ## Draws one compact resource bar with a clamped fill.
  let ratio =
    if maximum <= 0:
      0.0'f32
    else:
      clamp(value / maximum, 0.0'f32, 1.0'f32)
  if BarTrackName in sk.atlas.entries:
    sk.draw9Patch(
      BarTrackName,
      barPatch(size, BarTrackPatch),
      position,
      size
    )
  else:
    sk.drawRect(position, size, BarBack)
  if ratio <= 0:
    return
  let
    inset = min(BarInset, size.y / 6.0'f32)
    innerPos = position + vec2(inset)
    innerSize = vec2(
      max(size.x - inset * 2, 1),
      max(size.y - inset * 2, 1)
    )
    fillSize = vec2(max(innerSize.x * ratio, 1), innerSize.y)
  if BarFillName in sk.atlas.entries:
    sk.draw9Patch(
      BarFillName,
      barPatch(fillSize, BarFillPatch),
      innerPos,
      fillSize,
      color
    )
  else:
    sk.drawRect(innerPos, fillSize, color)

proc drawSprite*(
    sk: Silky,
    name: string,
    pos,
    size: Vec2,
    color = rgbx(255, 255, 255, 255),
    radius = 0.0'f32
) =
  ## Draws one atlas image stretched to an explicit rectangle.
  if name notin sk.atlas.entries:
    sk.drawRect(pos, size, rgbx(28, 33, 44, 255))
    return
  if radius > 0.5:
    sk.drawRoundedImage(name, pos, size, radius, color)
    return
  let uv = sk.atlas.entries[name]
  sk.drawQuad(
    pos,
    size,
    vec2(uv.x.float32, uv.y.float32),
    vec2(uv.width.float32, uv.height.float32),
    color
  )

proc drawWellImage*(
    sk: Silky,
    well: GameUiPanel,
    name: string,
    color = rgbx(255, 255, 255, 255),
    pad = 4.0'f32,
    selected = false,
    iconSize = 0.0'f32
) =
  ## Draws one atlas image inside a theme slot. A positive iconSize draws
  ## the image at that fixed size centered in the well; power-of-two sizes
  ## land on exact mip levels of the 128 and 256 px art and stay crisp.
  sk.drawSlot(well, selected)
  if name.len == 0:
    return
  if iconSize > 0:
    sk.drawSprite(
      name,
      well.origin + (well.size - vec2(iconSize)) * 0.5'f32,
      vec2(iconSize),
      color
    )
    return
  let inner = well.inset(min(pad, min(well.size.x, well.size.y) * 0.08'f32))
  sk.drawSprite(name, inner.origin, inner.size, color)

proc beginFrame*(
    sk: Silky,
    panel: GameUiPanel
): GameUiPanel =
  ## Draws silky window chrome and returns the same outer rect.
  sk.drawPanel(panel)
  panel

proc drawValueBar*(
    sk: Silky,
    position,
    size: Vec2,
    value,
    maximum: float32,
    color: ColorRGBX,
    caption: string
) =
  ## Draws a resource bar with a centered caption over the fill.
  sk.drawBar(position, size, value, maximum, color)
  sk.drawLabel(
    caption,
    position,
    size,
    rgbx(255, 255, 255, 255),
    "Small",
    CenterAlign
  )

proc drawBadge*(
    sk: Silky,
    pos,
    size: Vec2,
    text: string,
    image = "badge",
    font = "Small"
) =
  ## Draws a circular level badge with a centered number.
  sk.drawSprite(
    image,
    pos,
    size,
    rgbx(255, 255, 255, 255)
  )
  sk.drawLabel(
    text,
    pos,
    size,
    rgbx(255, 255, 255, 255),
    font,
    CenterAlign
  )

proc drawKeyPip*(
    sk: Silky,
    well: GameUiPanel,
    key: string
) =
  ## Draws one hotkey letter on a ringed pip in a well's bottom-right corner.
  let pos = well.origin + well.size - vec2(KeyPipSize + KeyPipInset)
  sk.drawBadge(pos, vec2(KeyPipSize), key, KeyPipName, "Hud")

proc clicked*(
    window: Window,
    sk: Silky,
    panel: GameUiPanel
): bool =
  ## Returns whether this frame pressed inside a panel.
  window.mousePressed(MouseLeft) and panel.contains(sk.mousePos)

proc hovered*(sk: Silky, panel: GameUiPanel): bool =
  ## Returns whether the pointer is inside a panel.
  panel.contains(sk.mousePos)

proc mapArea*(
    panel: GameUiPanel,
    top = 28.0'f32,
    margin = 12.0'f32,
    verticalInset = 40.0'f32
): GameUiPanel =
  ## Returns the inner minimap rectangle inside a HUD panel.
  GameUiPanel(
    origin: panel.origin + vec2(margin, top),
    size: panel.size - vec2(margin * 2, verticalInset)
  )

proc mouseOverPanels*(
    mouse: Vec2,
    layout: GameUiLayout,
    panels: openArray[GameUiPanel]
): bool =
  ## Returns whether the pointer is over any game panel or the transport.
  for panel in panels:
    if panel.contains(mouse):
      return true
  layout.transportPanel.contains(mouse)

proc drawCameraFrame*(
    sk: Silky,
    viewport: MinimapViewRect,
    color = CameraFrame
) =
  ## Draws the camera's visible ground footprint on a minimap.
  let line = 2.0'f32
  sk.drawRect(viewport.origin, vec2(viewport.size.x, line), color)
  sk.drawRect(
    viewport.origin + vec2(0, viewport.size.y - line),
    vec2(viewport.size.x, line),
    color
  )
  sk.drawRect(viewport.origin, vec2(line, viewport.size.y), color)
  sk.drawRect(
    viewport.origin + vec2(viewport.size.x - line, 0),
    vec2(line, viewport.size.y),
    color
  )

proc drawError*(
    sk: Silky,
    windowSize: Vec2,
    title: string,
    detail = ""
) =
  ## Draws the shared replay-divergence banner.
  let
    errorSize = vec2(
      min(windowSize.x - 40, 900.0'f32),
      if detail.len > 0: 64.0'f32 else: 58.0'f32
    )
    errorPosition = vec2(
      (windowSize.x - errorSize.x) * 0.5'f32,
      18
    )
  sk.drawRect(errorPosition, errorSize, ErrorFill)
  sk.drawRect(errorPosition, vec2(errorSize.x, 3), ErrorLine)
  if detail.len == 0:
    sk.drawLabel(
      title,
      errorPosition + vec2(12, 10),
      vec2(errorSize.x - 24, 34),
      rgbx(255, 214, 214, 255),
      "Hud",
      CenterAlign
    )
  else:
    sk.drawLabel(
      title,
      errorPosition + vec2(12, 8),
      vec2(errorSize.x - 24, 22),
      rgbx(255, 230, 230, 255),
      "Small",
      CenterAlign
    )
    sk.drawLabel(
      detail,
      errorPosition + vec2(12, 32),
      vec2(errorSize.x - 24, 20),
      rgbx(255, 185, 185, 255),
      "Small",
      CenterAlign
    )

proc addFixedFps(s: var string, value: float32) =
  ## Appends a 6-character 2-decimal value like " 12.34".
  var cents = int(value * 100.0'f32 + 0.5'f32)
  if cents < 0:
    cents = 0
  if cents > 99999:
    cents = 99999
  let
    whole = cents div 100
    frac = cents mod 100
  if whole < 100:
    s.add ' '
  if whole < 10:
    s.add ' '
  s.addHudInt(whole)
  s.add '.'
  s.addPad2(frac)

proc writeFpsNow(now: float32) =
  ## Formats the current fps into its fixed-width label.
  fpsNowText.setLen(0)
  addFixedFps(fpsNowText, now)

proc writeFpsStats() =
  ## Formats the moving frame-time avg and std in milliseconds.
  fpsAvgText.setLen(0)
  fpsAvgText.add "frame "
  addFixedFps(fpsAvgText, fpsAvgValue)
  fpsAvgText.add " ms"
  fpsStdText.setLen(0)
  addFixedFps(fpsStdText, sqrt(max(fpsVarValue, 0.0'f32)))
  fpsStdText.add " ms std"

proc noteFps() =
  ## Records this frame's fps and refreshes the debug labels.
  let now = epochTime()
  if fpsLastTime > 0:
    let dt = now - fpsLastTime
    if dt > 0.0001 and dt < 1.0:
      let
        fps = 1.0'f32 / dt.float32
        ms = dt.float32 * 1000.0'f32
      if not fpsHasAvg:
        fpsAvgValue = ms
        fpsVarValue = 0.0'f32
        fpsHasAvg = true
      else:
        let
          k = 1.0'f32 - exp(-dt.float32 / FpsAvgTau)
          delta = ms - fpsAvgValue
        fpsAvgValue += k * delta
        fpsVarValue =
          (1.0'f32 - k) * (fpsVarValue + k * delta * delta)
      writeFpsNow(fps)
      if fpsLabelTime == 0.0 or now - fpsLabelTime >= FpsAvgPeriod:
        writeFpsStats()
        fpsLabelTime = now
  fpsLastTime = now

proc mouseOverDebugMenu*(mouse: Vec2): bool =
  ## Returns whether the pointer is over the F1 debug window.
  if not debugMenuOpen or DebugWindowTitle notin subWindowStates:
    return false
  let state = subWindowStates[DebugWindowTitle]
  if state == nil or not state.visible:
    return false
  mouse.x >= state.pos.x and
    mouse.x <= state.pos.x + state.size.x and
    mouse.y >= state.pos.y and
    mouse.y <= state.pos.y + state.size.y

proc drawDebugMenu*(sk: Silky, window: Window) =
  ## Draws the shared F1 debug window when it is open.
  noteFps()
  if not debugMenuOpen:
    return
  sk.beginDsl()
  try:
    subWindow(
      DebugWindowTitle,
      debugMenuOpen,
      DebugWindowOrigin,
      DebugWindowSize
    ):
      group "fpsRow":
        box(
          FpsLabelSize.x + FpsNowSize.x + FpsAvgSize.x + FpsStdSize.x,
          FpsLabelSize.y
        )
        text "fpsCaption":
          box 0, 0, FpsLabelSize.x, FpsLabelSize.y
          characters "FPS:"
          textAlign LeftAlign, MiddleAlign
        text "fpsNow":
          box FpsLabelSize.x, 0, FpsNowSize.x, FpsNowSize.y
          font "Mono"
          characters fpsNowText
          textAlign RightAlign, MiddleAlign
        text "fpsAvg":
          box(
            FpsLabelSize.x + FpsNowSize.x,
            0,
            FpsAvgSize.x,
            FpsAvgSize.y
          )
          font "Mono"
          characters fpsAvgText
          textAlign RightAlign, MiddleAlign
        text "fpsStd":
          box(
            FpsLabelSize.x + FpsNowSize.x + FpsAvgSize.x,
            0,
            FpsStdSize.x,
            FpsStdSize.y
          )
          font "Mono"
          characters fpsStdText
          textAlign RightAlign, MiddleAlign
      text "fpsLimitCaption":
        characters "FPS limit"
      scrubber(
        "fpsLimit",
        framePaceHz,
        FpsLimitMin,
        FpsLimitMax,
        $framePaceHz
      )
      text "terrainScaleCaption":
        characters "Terrain texture scale"
      scrubber(
        "terrainTextureScale",
        terrainTextureScale,
        0.01'f,
        1.0'f,
        terrainTextureScale.formatFloat(ffDecimal, 3)
      )
      text "terrainScaleHint":
        characters "Lower values make larger texture patterns."
      checkBox "Interpolation", interpolateVisuals
      checkBox "Show paths", showPaths
      checkBox "Show tiles", showTiles
  finally:
    sk.endDsl()

proc handleChromeKey*(button: Button): bool =
  ## Handles shared debug keys. F1 toggles this menu, F2 starts or writes
  ## a Fluffy trace.
  case button
  of KeyF1:
    debugMenuOpen = not debugMenuOpen
    true
  of KeyF2:
    toggleRuntimeTrace()
    true
  else:
    false
