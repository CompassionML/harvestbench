## Shared fixed-north camera and minimap geometry for RTS games.

import
  std/math,
  vmath, windy

const
  RtsCameraYaw* = 0.0'f32
  RtsCameraPitch* = 0.92'f32
  RtsFieldOfView* = 45.0'f32
  RtsEdgePanMargin* = 16.0'f32
    ## Pixel band at the window edge that pans the camera.
    ## Edge pan is only used while the window is fullscreen.
  RtsPanSpeed* = 0.96'f32
    ## World units per second per unit of camera distance.
  RtsFollowLift* = 0.25'f32
    ## Fraction of the visible ground height used to raise a followed
    ## subject above the HUD.
  RtsGotaFollowLift* = 0.15'f32
    ## GOTA's HUD is shorter, so the hero sits closer to center.
  RtsPortraitEase* = 0.55'f32
    ## Ease-in-out duration when a HUD portrait pans to a hero.

type
  MinimapViewRect* = object
    ## Describes the visible ground footprint inside a minimap rectangle.
    origin*: Vec2
    size*: Vec2
  CameraEase* = object
    ## One-shot ease-in-out pan from a start point toward a live dest.
    active*: bool
    start*: Vec3
    elapsed*: float32
    duration*: float32

proc rtsCameraEye*(target: Vec3, distance: float32): Vec3 =
  ## Returns the locked north-facing RTS camera position.
  target + vec3(
    sin(RtsCameraYaw) * cos(RtsCameraPitch),
    sin(RtsCameraPitch),
    cos(RtsCameraYaw) * cos(RtsCameraPitch)
  ) * distance

proc rtsFollowFrame*(
    subject: Vec3,
    distance: float32,
    liftAmount = RtsFollowLift
): Vec3 =
  ## Returns the look-at that places `subject` above the optical center.
  let
    halfVerticalFov = RtsFieldOfView * PI.float32 / 360.0'f32
    cameraHeight = distance * sin(RtsCameraPitch)
    cameraForward = distance * cos(RtsCameraPitch)
    farOffset = cameraForward -
      cameraHeight / tan(RtsCameraPitch - halfVerticalFov)
    nearOffset = cameraForward -
      cameraHeight / tan(RtsCameraPitch + halfVerticalFov)
    lift = (nearOffset - farOffset) * liftAmount
  subject + vec3(
    sin(RtsCameraYaw) * lift,
    0,
    cos(RtsCameraYaw) * lift
  )

proc minimapWorldPoint*(
    pointer,
    origin,
    size: Vec2,
    worldHalfSize: float32
): Vec2 =
  ## Converts a minimap pixel into a clamped world XZ position.
  let ratio = clamp(
    (pointer - origin) / size,
    vec2(0),
    vec2(1)
  )
  vec2(
    ratio.x * worldHalfSize * 2 - worldHalfSize,
    ratio.y * worldHalfSize * 2 - worldHalfSize
  )

proc minimapViewport*(
    target: Vec3,
    distance,
    aspect: float32,
    origin,
    size: Vec2,
    worldHalfSize: float32
): MinimapViewRect =
  ## Approximates the camera's ground footprint in minimap pixels.
  let
    halfVerticalFov = RtsFieldOfView * PI.float32 / 360.0'f32
    cameraHeight = distance * sin(RtsCameraPitch)
    cameraForward = distance * cos(RtsCameraPitch)
    farOffset = cameraForward -
      cameraHeight / tan(RtsCameraPitch - halfVerticalFov)
    nearOffset = cameraForward -
      cameraHeight / tan(RtsCameraPitch + halfVerticalFov)
    halfHorizontalFov = arctan(tan(halfVerticalFov) * aspect)
    halfWidth = max(distance * tan(halfHorizontalFov), 1.0'f32)
    minimum = vec2(
      target.x - halfWidth,
      target.z + farOffset
    )
    maximum = vec2(
      target.x + halfWidth,
      target.z + nearOffset
    )
    worldSize = worldHalfSize * 2
    normalizedMinimum = clamp(
      (minimum + vec2(worldHalfSize)) / worldSize,
      vec2(0),
      vec2(1)
    )
    normalizedMaximum = clamp(
      (maximum + vec2(worldHalfSize)) / worldSize,
      vec2(0),
      vec2(1)
    )
  let rawSize = (normalizedMaximum - normalizedMinimum) * size
  result.size = vec2(
    clamp(rawSize.x, 4.0'f32, size.x),
    clamp(rawSize.y, 4.0'f32, size.y)
  )
  let rawOrigin = origin + normalizedMinimum * size
  result.origin = vec2(
    clamp(rawOrigin.x, origin.x, origin.x + size.x - result.size.x),
    clamp(rawOrigin.y, origin.y, origin.y + size.y - result.size.y)
  )

proc rtsEdgePanDir*(
    mouse, size: Vec2,
    margin = RtsEdgePanMargin,
    inside = true
): Vec2 =
  ## Returns a pan from the pointer sitting on the window border.
  ## X is east, Y is south, matching the locked-north camera.
  if not inside:
    return
  if mouse.x < 0 or mouse.y < 0 or
      mouse.x > size.x or mouse.y > size.y:
    return
  if mouse.x <= margin:
    result.x -= 1
  elif mouse.x >= size.x - margin:
    result.x += 1
  if mouse.y <= margin:
    result.y -= 1
  elif mouse.y >= size.y - margin:
    result.y += 1

proc rtsKeyPanDir*(window: Window): Vec2 =
  ## Returns a pan from arrow keys.
  if window.buttonDown[KeyLeftControl] or
      window.buttonDown[KeyRightControl] or
      window.buttonDown[KeyLeftSuper] or
      window.buttonDown[KeyRightSuper]:
    return
  if window.buttonDown[KeyRight]:
    result.x += 1
  if window.buttonDown[KeyLeft]:
    result.x -= 1
  if window.buttonDown[KeyDown]:
    result.y += 1
  if window.buttonDown[KeyUp]:
    result.y -= 1

proc rtsPanDir*(key, edge: Vec2): Vec2 =
  ## Combines keyboard and edge pans without doubling a held direction.
  result = key + edge
  let length = result.length
  if length > 1:
    result = result / length

proc rtsPointerInside(window: Window): bool =
  ## True while the OS reports the cursor over this window.
  when compiles(window.mouseInside):
    window.mouseInside
  else:
    true

proc rtsEdgePanAllowed*(
    fullscreen, inside, captured: bool
): bool =
  ## Edge pan is only live in fullscreen with a free cursor over the window.
  fullscreen and inside and not captured

proc rtsPanDir*(window: Window): Vec2 =
  ## Returns the combined keyboard and screen-edge pan for this frame.
  ## Edge pan only runs in fullscreen so a windowed game does not drift
  ## when the pointer sits on a chrome border.
  if not window.focused:
    return
  let edge =
    if rtsEdgePanAllowed(
      window.fullscreen, rtsPointerInside(window), window.mouseCaptured
    ):
      rtsEdgePanDir(window.mousePos.vec2, window.size.vec2)
    else:
      vec2(0)
  rtsPanDir(rtsKeyPanDir(window), edge)

proc rtsPanSpeed*(distance: float32): float32 =
  ## Returns world-space pan speed for this camera zoom.
  max(distance, 1.0'f32) * RtsPanSpeed

proc mouseRay*(
    mouse,
    windowSize: Vec2,
    viewProjection: Mat4
): (Vec3, Vec3) =
  ## Unprojects the pointer to a world-space ray origin and direction.
  let
    ndcX = 2.0'f32 * mouse.x / max(windowSize.x, 1.0'f32) - 1.0'f32
    ndcY = 1.0'f32 - 2.0'f32 * mouse.y / max(windowSize.y, 1.0'f32)
    inv = inverse(viewProjection)
  var
    nearPoint = inv * vec4(ndcX, ndcY, -1, 1)
    farPoint = inv * vec4(ndcX, ndcY, 1, 1)
  let
    origin = nearPoint.xyz / nearPoint.w
    farPos = farPoint.xyz / farPoint.w
  (origin, farPos - origin)

proc pickGroundPoint*(
    mouse,
    windowSize: Vec2,
    viewProjection: Mat4,
    planeY = 0.0'f32
): Vec3 =
  ## Unprojects the pointer onto a horizontal plane in world space.
  let (origin, dir) = mouseRay(mouse, windowSize, viewProjection)
  if abs(dir.y) < 0.0001'f32:
    return vec3(origin.x, planeY, origin.z)
  origin + dir * ((planeY - origin.y) / dir.y)

proc groundTile*(
    point: Vec3,
    halfSpan: float32,
    tiles: int32
): (int32, int32) =
  ## Converts a ground point into a clamped map tile.
  (
    int32(clamp(int(floor(point.x + halfSpan)), 0, tiles - 1)),
    int32(clamp(int(floor(point.z + halfSpan)), 0, tiles - 1))
  )

proc applyRtsPan*(
    target: var Vec3,
    dir: Vec2,
    dt, distance, halfSpan: float32
): bool =
  ## Moves a camera target on the XZ plane. Returns whether it moved.
  if dir.x == 0 and dir.y == 0:
    return false
  let speed = rtsPanSpeed(distance)
  target.x = clamp(
    target.x + dir.x * speed * dt,
    -halfSpan,
    halfSpan
  )
  target.z = clamp(
    target.z + dir.y * speed * dt,
    -halfSpan,
    halfSpan
  )
  true

proc rtsEaseT*(t: float32): float32 =
  ## Smoothstep ease-in-out in 0 .. 1.
  let u = clamp(t, 0.0'f32, 1.0'f32)
  u * u * (3.0'f32 - 2.0'f32 * u)

proc startCameraEase*(
    ease: var CameraEase,
    fromPos: Vec3,
    duration = RtsPortraitEase
) =
  ## Begins an ease-in-out pan from the current look-at.
  ease.active = true
  ease.start = fromPos
  ease.elapsed = 0
  ease.duration = max(duration, 0.001'f32)

proc cancelCameraEase*(ease: var CameraEase) =
  ## Stops a running portrait pan without changing the look-at.
  ease.active = false

proc advanceCameraEase*(
    ease: var CameraEase,
    target: var Vec3,
    dest: Vec3,
    dt: float32
): bool =
  ## Moves `target` toward `dest` with ease-in-out. Still running if true.
  if not ease.active:
    return false
  ease.elapsed += dt
  let t = rtsEaseT(ease.elapsed / ease.duration)
  target = mix(ease.start, dest, t)
  if ease.elapsed >= ease.duration:
    target = dest
    ease.active = false
    return false
  true
