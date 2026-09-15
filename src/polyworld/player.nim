## Shared play/replay transport for Polyworld games.
##
## Live matches and file replays use the same bar, the same speeds, and the
## same catch-up rule: simulate as fast as the machine allows, but yield to
## draw about ten times a second so a long seek still shows the world moving.

import
  std/times,
  chroma, pixie, silky, vmath, windy,
  actioncam, chrome, gameuis, inputs, stackpanels

const
  TransportHeight* = 80.0'f32
  PlayerSpeeds* = [1'i32, 2, 4, 16]
  CatchUpSeconds* = 0.1
  IconSize = 64.0'f32
  IconGap = 8.0'f32
  GroupGap = 24.0'f32
  IconPad = 8.0'f32
  IconY = 8.0'f32
  ScrubH = 24.0'f32
  RecordedH = 6.0'f32
  RecordedGap = 4.0'f32
  TickLabelW = 178.0'f32
  TransportControlsWidth =
    12 + (IconSize + IconGap) * 10 + (GroupGap - IconGap) * 3
  TransportMinWidth* =
    TransportControlsWidth + 80 + GroupGap + IconSize + 16 + TickLabelW
  SpeedIcons = ["speed_1x", "speed_2x", "speed_4x", "speed_16x"]
  GlyphColor = rgbx(226, 230, 239, 255)
  GlyphActive = rgbx(235, 216, 154, 255)
  GlyphDim = rgbx(112, 121, 138, 255)

type
  TransportPanels* = object
    controls*: array[5, GameUiPanel]
    loop*: GameUiPanel
    speeds*: array[4, GameUiPanel]
    scrub*, recorded*, scrubHit*, camera*, tick*: GameUiPanel

  Player* = object
    playing*: bool
    repeating*: bool
    speedIndex*: int
    live*: bool
    tick*: int32
    recordedTicks*: int32
      ## How far the in-memory tape has been simulated.
    durationTicks*: int32
      ## Configured match length. Live scrubber uses this until the game ends.
    over*: bool
    restoreTick*: int32
      ## Checkpoint to restore before catching up. -1 means none.
    targetTick*: int32
      ## Catch up to this tick at max speed. -1 means none.
    accumulator*: float32
    tickRate: int32

proc speed*(player: Player): int32 =
  ## Returns the selected realtime multiplier.
  PlayerSpeeds[player.speedIndex]

proc timelineEnd*(player: Player): int32 =
  ## Returns the right edge of the scrubber.
  if player.live and not player.over:
    player.durationTicks
  else:
    max(player.recordedTicks, 0)

proc inHistory*(player: Player): bool =
  ## Returns whether the next tick should come from recorded actions.
  (not player.live) or player.tick < player.recordedTicks

proc speedIndexOf*(value: int32): int =
  ## Maps a requested multiplier onto 1x, 2x, 4x, or 16x.
  result = 0
  for i, speed in PlayerSpeeds:
    if speed <= value:
      result = i

proc initPlayer*(
    live: bool,
    durationTicks: int32,
    playing = true,
    speed = 1'i32,
    repeating = false
): Player =
  ## Creates a transport that starts in play unless asked to pause.
  result.live = live
  result.durationTicks = max(durationTicks, 0)
  result.playing = playing
  result.repeating = repeating
  when defined(replayViewer):
    result.repeating = repeating or not live
  result.speedIndex = speedIndexOf(speed)
  result.restoreTick = -1
  result.targetTick = -1

proc sync*(
    player: var Player,
    tick,
    recordedTicks: int32,
    over: bool
) =
  ## Copies simulation progress into the transport.
  player.tick = max(tick, 0)
  player.recordedTicks = max(recordedTicks, 0)
  if over and not player.over:
    player.durationTicks = player.recordedTicks
  player.over = over
  if player.targetTick >= 0 and player.tick >= player.targetTick:
    player.targetTick = -1

proc seekTo*(player: var Player, tick: int32, play = true) =
  ## Jumps toward one timeline tick at max speed, restoring if going back.
  ## Backward seeks reload the last checkpoint at or before the target,
  ## then resimulate up to it.
  let wanted = clamp(tick, 0'i32, player.timelineEnd)
  if wanted < player.tick:
    player.restoreTick = wanted
  player.targetTick = wanted
  if play:
    player.playing = true

proc skipToStart*(player: var Player) =
  ## Jumps to the first timeline tick.
  player.seekTo(0)

proc skipToEnd*(player: var Player) =
  ## Jumps to the last timeline tick.
  player.seekTo(player.timelineEnd)

proc stepBack*(player: var Player) =
  ## Pauses and moves exactly one tick backward.
  ## Restores the last safe checkpoint and resimulates up to tick - 1.
  player.playing = false
  player.accumulator = 0
  player.seekTo(player.tick - 1, play = false)

proc stepForward*(player: var Player) =
  ## Pauses and moves exactly one tick forward.
  player.playing = false
  player.accumulator = 0
  player.seekTo(player.tick + 1, play = false)

proc pause*(player: var Player) =
  ## Stops realtime playback and any catch-up.
  player.playing = false
  player.targetTick = -1

proc play*(player: var Player) =
  ## Starts playback, rewinding first when already at the end.
  if player.tick >= player.timelineEnd and player.timelineEnd > 0:
    player.seekTo(0)
  else:
    player.playing = true

proc togglePlay*(player: var Player) =
  ## Flips between play and pause, including during catch-up.
  if player.playing or player.targetTick >= 0:
    player.pause()
  else:
    player.play()

proc setSpeed*(player: var Player, index: int) =
  ## Selects one of the four transport multipliers.
  player.speedIndex = clamp(index, 0, PlayerSpeeds.high)

proc reachedEnd(player: Player): bool =
  ## Returns whether playback has no further ticks to consume.
  if player.over:
    return true
  if player.live:
    return player.tick >= player.durationTicks
  player.tick >= player.recordedTicks

proc takeRestore*(player: var Player): int32 =
  ## Returns the tick to land on after a checkpoint restore, or -1.
  result = player.restoreTick
  player.restoreTick = -1
  if result >= 0:
    player.accumulator = 0

proc startFrame*(player: var Player, dt: float32, tickRate: int32) =
  ## Accounts realtime time when not catching up.
  player.tickRate = max(tickRate, 1)
  if player.targetTick >= 0 or not player.playing:
    return
  player.accumulator = min(
    player.accumulator + dt * player.speed.float32,
    0.25'f32
  )

proc shouldTick*(
    player: var Player,
    frameStart: float64
): bool =
  ## Returns whether one more simulation tick belongs in this frame.
  ## Paused seeks run until they land so single-tick steps stay exact.
  if player.reachedEnd:
    if player.repeating:
      player.seekTo(0)
      return false
    player.playing = false
    player.targetTick = -1
    player.accumulator = 0
    return false
  if player.targetTick >= 0:
    if not player.playing:
      return player.tick < player.targetTick
    return epochTime() - frameStart < CatchUpSeconds
  if not player.playing:
    return false
  let step = 1.0'f32 / max(player.tickRate, 1).float32
  if player.accumulator >= step:
    player.accumulator -= step
    return true
  false

proc transportPanels*(panel: GameUiPanel): TransportPanels =
  ## Reserves fixed controls at both ends, then fills the timeline between.
  var trailing = panel.stack(RightToLeft, vec2(0, IconY))
  let tick = trailing.takeColumn(TickLabelW, 16)
  result.camera = trailing.take(vec2(IconSize), GroupGap)
  var leading = trailing.takeRest().stack(LeftToRight)
  leading.gap(12)
  for control in result.controls.mitems:
    control = leading.take(vec2(IconSize), IconGap)
  leading.gap(GroupGap - IconGap)
  result.loop = leading.take(vec2(IconSize), IconGap)
  leading.gap(GroupGap - IconGap)
  for control in result.speeds.mitems:
    control = leading.take(vec2(IconSize), IconGap)
  leading.gap(GroupGap - IconGap)
  let clusterH = ScrubH + RecordedGap + RecordedH
  var timeline = leading.takeRest().stack(TopToBottom)
  timeline.gap((IconSize - clusterH) * 0.5'f)
  result.scrub = timeline.takeRow(ScrubH, RecordedGap)
  result.recorded = timeline.takeRow(RecordedH)
  result.scrubHit = GameUiPanel(
    origin: result.scrub.origin - vec2(0, 8),
    size: result.scrub.size + vec2(0, 24)
  )
  var label = tick.stack(TopToBottom)
  label.gap((IconSize - clusterH) * 0.5'f)
  result.tick = label.take(vec2(TickLabelW - 12, clusterH))

proc drawGlyph(
    sk: Silky,
    name: string,
    panel: GameUiPanel,
    color: ColorRGBX
) =
  ## Draws one atlas icon centered in a hit target.
  if name notin sk.atlas.entries:
    return
  let
    uv = sk.atlas.entries[name]
    size = vec2(IconSize - IconPad * 2)
    pos = panel.origin + vec2(IconPad)
  sk.drawQuad(
    pos,
    size,
    vec2(uv.x.float32, uv.y.float32),
    vec2(uv.width.float32, uv.height.float32),
    color
  )

proc drawIcon(
    sk: Silky,
    panel: GameUiPanel,
    name: string,
    active = false,
    dim = false
) =
  ## Draws one transport glyph with no text label.
  let color =
    if active: GlyphActive
    elif dim: GlyphDim
    else: GlyphColor
  sk.drawGlyph(name, panel, color)

proc clicked(
    window: Window,
    sk: Silky,
    panel: GameUiPanel
): bool =
  ## Returns whether this frame pressed a transport button.
  window.mousePressed(MouseLeft) and panel.contains(sk.mousePos)

proc drawTransport*(
    player: var Player,
    sk: Silky,
    window: Window,
    panel: GameUiPanel,
    actionCam: var ActionCam,
    followSelection: var bool
) =
  ## Draws the shared play/replay bar and applies clicks.
  sk.drawRibbon(panel)
  let playing = player.playing or player.targetTick >= 0
  let
    slots = panel.transportPanels()
    skipStart = slots.controls[0]
    stepBackBtn = slots.controls[1]
    playBtn = slots.controls[2]
    stepFwdBtn = slots.controls[3]
    skipEnd = slots.controls[4]
    loopBtn = slots.loop
    speeds = slots.speeds
  sk.drawIcon(skipStart, "skip_to_start")
  sk.drawIcon(stepBackBtn, "previous_frame")
  sk.drawIcon(playBtn, if playing: "pause" else: "play")
  sk.drawIcon(stepFwdBtn, "next_frame")
  sk.drawIcon(skipEnd, "skip_to_end")
  sk.drawIcon(loopBtn, "loop", player.repeating)
  if window.clicked(sk, skipStart):
    player.skipToStart()
  elif window.clicked(sk, stepBackBtn):
    player.stepBack()
  elif window.clicked(sk, playBtn):
    player.togglePlay()
  elif window.clicked(sk, stepFwdBtn):
    player.stepForward()
  elif window.clicked(sk, skipEnd):
    player.skipToEnd()
  elif window.clicked(sk, loopBtn):
    player.repeating = not player.repeating
  for i, button in speeds:
    sk.drawIcon(button, SpeedIcons[i], player.speedIndex == i)
    if window.clicked(sk, button):
      player.setSpeed(i)
  let
    scrubOrigin = slots.scrub.origin
    scrubSize = slots.scrub.size
    endTick = max(player.timelineEnd, 1)
  sk.drawBar(
    scrubOrigin,
    scrubSize,
    player.tick.float32,
    endTick.float32,
    rgbx(96, 132, 190, 255)
  )
  sk.drawBar(
    slots.recorded.origin,
    slots.recorded.size,
    player.recordedTicks.float32,
    endTick.float32,
    rgbx(151, 82, 199, 255)
  )
  if scrubSize.x > 0 and
    window.mouseDown(MouseLeft) and
    slots.scrubHit.contains(sk.mousePos):
      let ratio = clamp(
        (sk.mousePos.x - scrubOrigin.x) / scrubSize.x,
        0.0'f32,
        1.0'f32
      )
      player.seekTo(int32(ratio * player.timelineEnd.float32))
  let actionBtn = slots.camera
  sk.drawIcon(actionBtn, "action_cam", actionCam.enabled)
  if window.clicked(sk, actionBtn):
    actionCam.toggle(followSelection)
  hudScratch.setLen(0)
  hudScratch.add "Tick "
  hudScratch.addHudInt(player.tick.int)
  hudScratch.add " / "
  hudScratch.addHudInt(player.timelineEnd.int)
  discard sk.drawText(
    "Hud",
    hudScratch,
    slots.tick.origin,
    rgbx(190, 198, 214, 255),
    maxWidth = slots.tick.size.x,
    maxHeight = slots.tick.size.y,
    hAlign = RightAlign,
    vAlign = MiddleAlign
  )

proc handleKey*(player: var Player, button: Button) =
  ## Applies the shared space-to-pause shortcut.
  if button == KeySpace:
    player.togglePlay()
