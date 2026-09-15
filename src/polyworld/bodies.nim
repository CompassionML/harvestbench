## Planar unit bodies in tile-space Q16.16.
##
## One tile is `FixedOne`. `Body.pos` is the xz plane (`y` is world z).
## Height stays on the game's integer world point. Navigation can keep using
## a tile grid; this module turns, walks, slides, and separates circles.

import
  polyworld/fixed

type
  Body* = object
    ## One mobile circle on the walkable plane.
    pos*: FixedVec2
    facing*: Fixed
    radius*: Fixed
  Walkable* = proc (pos: FixedVec2): bool {.nimcall.}
    ## Returns whether a planar point is legal to stand on.

proc worldToTiles*(world, worldScale: int32): Fixed {.inline.} =
  ## Converts one world-integer axis into tile-space fixed-point.
  Fixed(int32((int64(world) shl FixedShift) div int64(worldScale)))

proc tilesToWorld*(tiles: Fixed, worldScale: int32): int32 {.inline.} =
  ## Converts one tile-space axis back into world-integer units.
  int32((int64(int32(tiles)) * int64(worldScale)) div FixedScale)

proc wrapAngle*(angle: Fixed): Fixed =
  ## Wraps an angle into the range (-pi, pi].
  ##
  ## Uses `2 * pi` rather than `FixedTau` so a full turn lands on zero.
  let
    twoPi = FixedPi + FixedPi
    wrapped = floorMod(angle + FixedPi, twoPi) - FixedPi
  if wrapped <= -FixedPi:
    FixedPi
  else:
    wrapped

proc shortestTurn*(fromAngle, toAngle: Fixed): Fixed {.inline.} =
  ## Returns the signed shortest turn from one heading to another.
  wrapAngle(toAngle - fromAngle)

proc turnToward*(facing: var Fixed, target, rate: Fixed) =
  ## Rotates facing toward target by at most rate radians.
  let delta = shortestTurn(facing, target)
  if abs(delta) <= rate:
    facing = wrapAngle(facing + delta)
  else:
    facing = wrapAngle(facing + rate * sign(delta))

proc cell*(pos: FixedVec2): tuple[x, z: int32] {.inline.} =
  ## Floors a tile-space position to its containing cell.
  (whole(pos.x), whole(pos.y))

proc desiredStep*(
    pos, waypoint: FixedVec2,
    speed, arrive: Fixed
): FixedVec2 =
  ## Returns the remaining step toward a waypoint, or zero when arrived.
  let
    offset = waypoint - pos
    dist = length(offset)
  if dist <= arrive:
    FixedVec2Zero
  elif dist <= speed:
    offset
  else:
    normalize(offset) * speed

proc slide*(pos: var FixedVec2, delta: FixedVec2, walkable: Walkable) =
  ## Moves by delta, then axis-slides when the full step is blocked.
  if delta == FixedVec2Zero:
    return
  let next = pos + delta
  if walkable(next):
    pos = next
    return
  let onlyX = fixedVec2(pos.x + delta.x, pos.y)
  if walkable(onlyX):
    pos = onlyX
    return
  let onlyY = fixedVec2(pos.x, pos.y + delta.y)
  if walkable(onlyY):
    pos = onlyY

proc clampWalkable*(
    pos: var FixedVec2,
    previous: FixedVec2,
    walkable: Walkable
) =
  ## Keeps a point on walkable ground, sliding from the previous position.
  if walkable(pos):
    return
  let delta = pos - previous
  pos = previous
  slide(pos, delta, walkable)

proc steer*(
    body: var Body,
    toward: FixedVec2,
    speed, turnRate: Fixed,
    walkable: Walkable
) =
  ## Finishes turning, then advances toward the waypoint without overshoot.
  if toward == FixedVec2Zero:
    return
  let want = angle(toward)
  turnToward(body.facing, want, turnRate)
  if shortestTurn(body.facing, want) != FixedZero or speed <= FixedZero:
    return
  # Walking along an unfinished turn can orbit a nearby waypoint forever.
  # Use the exact offset so rounded headings cannot miss the final step.
  slide(
    body.pos,
    desiredStep(FixedVec2Zero, toward, speed, FixedZero),
    walkable
  )

proc separatePair*(a, b: var Body, walkable: Walkable) =
  ## Pushes two overlapping circles apart and clamps both to walkable ground.
  let
    offset = b.pos - a.pos
    dist = length(offset)
    need = a.radius + b.radius
  if dist == FixedZero or dist >= need:
    return
  let
    oldA = a.pos
    oldB = b.pos
    push = normalize(offset) * ((need - dist) / 2)
  a.pos -= push
  b.pos += push
  clampWalkable(a.pos, oldA, walkable)
  clampWalkable(b.pos, oldB, walkable)
