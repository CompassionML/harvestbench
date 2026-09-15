## Shared action camera. Games note scored interests; this module holds a
## shot until something clearly better appears, and eases there in wall-clock
## time so playback speed does not whip the view around.

import
  std/math,
  vmath

const
  SwitchMargin = 1.6'f32
  SwitchThreshold = 40.0'f32
  InterruptScore = 140.0'f32
    ## This strong a shot cuts in even while another is held.
  IdleThreshold = 12.0'f32
  DistancePerSpan = 2.6'f32
  TightRadiusScale = 1.4'f32
  WideGather = 0.22'f32
  TightGather = 0.50'f32
  CloseScale = 2.0'f32 / 3.0'f32
    ## 50% more zoom than the framed distance.
  ArriveEpsilon = 0.04'f32
  JumpSpan = 0.40'f32
    ## Fixed. A shot farther than this fraction of the map jumps.
  IgnoreGrow = 0.10'f32
    ## Ignore bubble growth per wall-clock second.

type
  Interest = object
    id: int32
    x, y, z: float32
    score: float32
    radius: float32
    expireTick: int32
  ActionCam* = ref object
    enabled*: bool
    tight*: float32
      ## Zero frames more of the map; one zooms into the hottest point.
    followRate*: float32
      ## Halves of remaining pan closed each second.
    zoomRate*: float32
      ## Halves of remaining zoom closed each second.
    holdSeconds*: float32
      ## Wall-clock time to keep a shot before a weaker one may steal it.
    minDistance*: float32
    maxDistance*: float32
    mapSpan*: float32
      ## Ground width used to size jumps and the ignore bubble.
    closeScale*: float32
      ## Multiplier on framed distance. Lower is closer.
    interests: seq[Interest]
    locked*: bool
    lockId*: int32
    lockTarget*: Vec3
    lockDistance*: float32
    lockScore: float32
    holdRemaining: float32
    jumped: bool
    jumpOrigin: Vec3
    ignoreRadius: float32
      ## After a jump, high-value events inside this radius are ignored.

proc xzDist(ax, az, bx, bz: float32): float32 =
  ## Returns the ground-plane distance between two points.
  let
    dx = ax - bx
    dz = az - bz
  sqrt(dx * dx + dz * dz)

proc gatherRadius(cam: ActionCam, tight: float32): float32 =
  ## Returns how far events may sit from each other and still share a shot.
  clamp(
    mix(
      cam.maxDistance * WideGather,
      cam.minDistance * TightGather,
      tight
    ),
    8.0'f32,
    cam.maxDistance * 0.4'f32
  )

proc initActionCam*(
    minDistance = 28.0'f32,
    maxDistance = 200.0'f32,
    tight = 0.4'f32,
    followRate = 1.0'f32,
    zoomRate = 1.0'f32,
    holdSeconds = 2.8'f32,
    mapSpan = 128.0'f32,
    closeScale = CloseScale
): ActionCam =
  ## Creates an action camera that starts on with game-specific zoom limits.
  result = ActionCam()
  result.enabled = true
  result.minDistance = minDistance
  result.maxDistance = max(maxDistance, minDistance)
  result.tight = clamp(tight, 0.0'f32, 1.0'f32)
  result.followRate = followRate
  result.zoomRate = zoomRate
  result.holdSeconds = max(holdSeconds, 0.1'f32)
  result.mapSpan = max(mapSpan, 8.0'f32)
  result.closeScale = clamp(closeScale, 0.2'f32, 1.0'f32)

proc takeManual*(cam: var ActionCam) =
  ## Drops action cam so a pan, zoom, or selection owns the view.
  cam.enabled = false

proc toggle*(cam: var ActionCam, followSelection: var bool) =
  ## Turns action cam on or off and drops selection follow when enabling.
  cam.enabled = not cam.enabled
  if cam.enabled:
    followSelection = false
    cam.locked = false
    cam.lockId = 0
    cam.jumped = false
    cam.ignoreRadius = 0

proc beginFrame*(cam: var ActionCam, tick: int32) =
  ## Drops interests whose tick lifetime has ended.
  var n = 0
  for i in 0 ..< cam.interests.len:
    if cam.interests[i].expireTick >= tick:
      if n != i:
        cam.interests[n] = cam.interests[i]
      inc n
  cam.interests.setLen(n)

proc noteInterest*(
    cam: var ActionCam,
    id: int32,
    position: Vec3,
    score,
    radius: float32,
    tick,
    lastTicks: int32
) =
  ## Upserts one scored situation. Lifetime is in simulation ticks.
  if id == 0 or score <= 0:
    return
  let expire = tick + max(lastTicks, 1)
  for i in 0 ..< cam.interests.len:
    if cam.interests[i].id != id:
      continue
    cam.interests[i].x = position.x
    cam.interests[i].y = position.y
    cam.interests[i].z = position.z
    cam.interests[i].radius = max(radius, 1.0'f32)
    if score > cam.interests[i].score:
      cam.interests[i].score = score
    if expire > cam.interests[i].expireTick:
      cam.interests[i].expireTick = expire
    return
  cam.interests.add Interest(
    id: id,
    x: position.x,
    y: position.y,
    z: position.z,
    score: score,
    radius: max(radius, 1.0'f32),
    expireTick: expire
  )

proc interestCount*(cam: ActionCam): int =
  ## Returns how many scored situations are still live.
  result = cam.interests.len

proc interestIndex(cam: ActionCam, id: int32): int =
  ## Returns the slot of one live interest, or -1.
  result = -1
  for i, interest in cam.interests:
    if interest.id == id:
      return i

proc ignored(cam: ActionCam, interest: Interest): bool =
  ## Returns whether a high-value event sits inside the ignore bubble.
  if not cam.jumped or interest.score < InterruptScore:
    return false
  xzDist(
    interest.x,
    interest.z,
    cam.jumpOrigin.x,
    cam.jumpOrigin.z
  ) <= cam.ignoreRadius

proc bestIndex(cam: ActionCam): int =
  ## Returns the highest scoring live interest, or -1.
  result = -1
  var best = -1.0'f32
  for i, interest in cam.interests:
    if interest.id != cam.lockId and cam.ignored(interest):
      continue
    if result < 0 or interest.score > best:
      best = interest.score
      result = i

proc shotOf(
    cam: ActionCam,
    index: int,
    tight: float32
): tuple[target: Vec3, distance: float32] =
  ## Frames one subject, widening only to include nearby interests.
  let
    subject = cam.interests[index]
    gather = cam.gatherRadius(tight)
  var span = subject.radius
  for interest in cam.interests:
    if interest.id == subject.id:
      continue
    let dist = xzDist(
      subject.x,
      subject.z,
      interest.x,
      interest.z
    )
    if dist <= gather:
      span = max(span, dist + interest.radius)
  let
    wideDistance = clamp(
      cam.minDistance + span * DistancePerSpan,
      cam.minDistance,
      cam.maxDistance
    )
    tightDistance = clamp(
      cam.minDistance + subject.radius * TightRadiusScale,
      cam.minDistance,
      cam.maxDistance
    )
  result.target = vec3(subject.x, subject.y, subject.z)
  result.distance = clamp(
    mix(wideDistance, tightDistance, tight) * cam.closeScale,
    cam.minDistance * cam.closeScale,
    cam.maxDistance
  )

proc holdFor(cam: ActionCam, speed: int32): float32 =
  ## Returns how long a shot should stick at this playback speed.
  if speed >= 16:
    cam.holdSeconds * 3.0'f32
  elif speed <= 1:
    cam.holdSeconds * 1.2'f32
  else:
    cam.holdSeconds

proc chooseShot*(
    cam: var ActionCam,
    dt: float32,
    speed = 1'i32
) =
  ## Picks one subject and holds it until a clearly better shot appears.
  ## After the hold, a strong shot in another place may cut even when it
  ## is not a huge score jump, so the view does not sit on a cleared room.
  ## `dt` is wall-clock. At 16x the camera parks on a wide view.
  if cam.interests.len == 0:
    return
  if cam.jumped:
    cam.ignoreRadius = min(
      cam.ignoreRadius + cam.mapSpan * IgnoreGrow * max(dt, 0),
      cam.mapSpan
    )
  if cam.locked:
    cam.holdRemaining -= dt
  let
    tight =
      if speed >= 16: 0.0'f32
      else: cam.tight
    gather = cam.gatherRadius(tight)
    best = cam.bestIndex()
    locked = cam.interestIndex(cam.lockId)
  if best < 0:
    return
  let shot = cam.shotOf(best, tight)
  var takeBest = false
  if not cam.locked or locked < 0:
    takeBest = cam.interests[best].score >= IdleThreshold
  else:
    let
      samePlace =
        xzDist(
          cam.interests[best].x,
          cam.interests[best].z,
          cam.interests[locked].x,
          cam.interests[locked].z
        ) <= gather
      better =
        cam.interests[best].score >= SwitchThreshold and
        cam.interests[best].score >=
          cam.interests[locked].score * SwitchMargin
      urgent =
        better and cam.interests[best].score >= InterruptScore
      expired = cam.holdRemaining <= 0
    if samePlace:
      if cam.interests[best].score >= cam.interests[locked].score:
        cam.lockId = cam.interests[best].id
      let stay = cam.shotOf(cam.interestIndex(cam.lockId), tight)
      cam.lockTarget = stay.target
      cam.lockDistance = stay.distance
      cam.lockScore = cam.interests[cam.interestIndex(cam.lockId)].score
      cam.locked = true
      return
    elif urgent or
        (expired and better) or
        (expired and
          cam.interests[best].score >= SwitchThreshold):
      takeBest = true
    else:
      let stay = cam.shotOf(locked, tight)
      cam.lockTarget = stay.target
      cam.lockDistance = stay.distance
      cam.lockScore = cam.interests[locked].score
      return
  if not takeBest:
    return
  cam.locked = true
  cam.lockId = cam.interests[best].id
  cam.lockTarget = shot.target
  cam.lockDistance = shot.distance
  cam.lockScore = cam.interests[best].score
  cam.holdRemaining = cam.holdFor(speed)

proc approach(current, dest, halves, dt: float32): float32 =
  ## Closes `halves` half-distances toward dest each second.
  let remaining = dest - current
  if abs(remaining) <= ArriveEpsilon:
    return dest
  mix(current, dest, 1.0'f32 - pow(0.5'f32, max(halves, 0) * dt))

proc follow*(
    cam: var ActionCam,
    target: var Vec3,
    distance: var float32,
    dt: float32,
    speed = 1'i32
) =
  ## Eases toward shots inside the jump distance and jumps beyond it.
  if not cam.enabled or not cam.locked:
    return
  let
    step = max(dt, 0.0'f32)
    rateScale =
      if speed >= 16: 0.25'f32
      else: 1.0'f32
    wantDistance =
      if speed >= 16:
        max(cam.lockDistance, cam.maxDistance * 0.65'f32)
      else:
        cam.lockDistance
    dist = xzDist(target.x, target.z, cam.lockTarget.x, cam.lockTarget.z)
    jumpAt = cam.mapSpan * JumpSpan
  if dist > jumpAt:
    target = cam.lockTarget
    distance = clamp(
      wantDistance,
      cam.minDistance * cam.closeScale,
      cam.maxDistance
    )
    cam.jumped = true
    cam.jumpOrigin = cam.lockTarget
    cam.ignoreRadius = 0
    return
  target.x = approach(
    target.x,
    cam.lockTarget.x,
    cam.followRate * rateScale,
    step
  )
  target.y = approach(
    target.y,
    cam.lockTarget.y,
    cam.followRate * rateScale,
    step
  )
  target.z = approach(
    target.z,
    cam.lockTarget.z,
    cam.followRate * rateScale,
    step
  )
  distance = clamp(
    approach(
      distance,
      wantDistance,
      cam.zoomRate * rateScale,
      step
    ),
    cam.minDistance * cam.closeScale,
    cam.maxDistance
  )
