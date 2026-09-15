## Clip playback with cross-fades for gltf node trees.
##
## The gltf library plays one clip by writing node transforms directly, so
## switching clips snaps. ClipPlayer keeps the outgoing clip running while
## the new one fades in, sampling both into scratch poses and blending per
## node (lerp for translation and scale, slerp for rotation). It also knows
## which clips loop and which play once: a one-shot holds its last frame,
## then chains into its `next` clip or, without one, fades back to the
## looping clip that was playing before it (walk, attack, back to walk).

import
  vmath, gltf

type
  ClipRule* = object
    loop*: bool
    next*: string   ## one-shots only: clip to chain into; "" = return

  Pose = seq[tuple[pos: Vec3, rot: Quat, scale: Vec3]]

  ClipPlayer* = ref object
    root: Node
    nodes: seq[Node]
    rules: seq[ClipRule]        ## per clip index in root.animations
    current: int                ## clip index, -1 for bind pose
    currentTime: float32
    previous: int               ## clip fading out, -1 when not fading
    previousTime: float32
    fadeTime, fadeDuration: float32
    lastLoop: int               ## the looping clip one-shots return to
    outgoing, incoming: Pose

proc newClipPlayer*(root: Node): ClipPlayer =
  ## Every clip loops until `setRule` says otherwise.
  result = ClipPlayer(root: root, nodes: root.walkNodes, current: -1,
    previous: -1, lastLoop: -1)
  result.rules = newSeq[ClipRule](root.animations.len)
  for rule in result.rules.mitems:
    rule.loop = true
  result.outgoing.setLen(result.nodes.len)
  result.incoming.setLen(result.nodes.len)

proc clipIndex*(player: ClipPlayer, name: string): int =
  for i, clip in player.root.animations:
    if clip.name == name:
      return i
  -1

proc setRule*(player: ClipPlayer, name: string, rule: ClipRule) =
  let index = player.clipIndex(name)
  doAssert index >= 0, "no clip named " & name
  player.rules[index] = rule

proc current*(player: ClipPlayer): int = player.current
proc currentTime*(player: ClipPlayer): float32 = player.currentTime
proc fading*(player: ClipPlayer): bool = player.previous >= 0

proc play*(player: ClipPlayer, clip: int, fade = 0.2'f32) =
  ## Starts a clip (or the bind pose for -1), fading from whatever is
  ## posed now. Restarting the current clip just rewinds it.
  if clip == player.current:
    player.currentTime = 0
    return
  if fade > 0 and (player.current >= 0 or player.previous >= 0):
    player.previous = player.current
    player.previousTime = player.currentTime
    player.fadeTime = 0
    player.fadeDuration = fade
  else:
    player.previous = -1
  player.current = clip
  player.currentTime = 0
  if clip >= 0 and player.rules[clip].loop:
    player.lastLoop = clip

proc play*(player: ClipPlayer, name: string, fade = 0.2'f32) =
  player.play(player.clipIndex(name), fade)

proc restart*(player: ClipPlayer) =
  player.currentTime = 0

proc clipTime(player: ClipPlayer, clip: int, time: float32): float32 =
  ## Looping clips wrap inside applyClipAt; one-shots hold their last frame.
  if player.rules[clip].loop:
    time
  else:
    min(time, player.root.animations[clip].duration)

proc capture(player: ClipPlayer, pose: var Pose) =
  for i, node in player.nodes:
    pose[i] = (node.pos, node.rot, node.scale)

proc update*(player: ClipPlayer, dt: float32) =
  ## Advances time, chains finished one-shots, and poses the tree.
  let root = player.root
  player.currentTime += dt
  if player.previous >= 0:
    player.previousTime += dt
    player.fadeTime += dt
    if player.fadeTime >= player.fadeDuration:
      player.previous = -1

  if player.current >= 0 and not player.rules[player.current].loop and
      player.currentTime >= root.animations[player.current].duration:
    let rule = player.rules[player.current]
    if rule.next.len > 0:
      player.play(rule.next)
    elif player.lastLoop >= 0 and player.lastLoop != player.current:
      player.play(player.lastLoop)

  root.resetToBase()
  if player.current < 0 and player.previous < 0:
    return
  if player.previous < 0:
    applyClipAt(
      root.animations[player.current],
      player.clipTime(player.current, player.currentTime))
    return

  # Fade: sample both clips against the base pose, then blend per node.
  applyClipAt(
    root.animations[player.previous],
    player.clipTime(player.previous, player.previousTime))
  player.capture(player.outgoing)
  root.resetToBase()
  if player.current >= 0:
    applyClipAt(
      root.animations[player.current],
      player.clipTime(player.current, player.currentTime))
  player.capture(player.incoming)
  let w = clamp(player.fadeTime / player.fadeDuration, 0, 1)
  for i, node in player.nodes:
    let
      a = player.outgoing[i]
      b = player.incoming[i]
    node.pos = mix(a.pos, b.pos, w)
    node.rot = slerp(a.rot, b.rot, w)
    node.scale = mix(a.scale, b.scale, w)
