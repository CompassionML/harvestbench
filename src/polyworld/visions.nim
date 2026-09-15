## Deterministic integer line of sight over a flat tile grid.
##
## Tile steps along each ray are a precomputed kernel. Height along the
## ray still uses the same integer lerp so visibility matches the live
## formula.

const
  MaxVisionRadius* = 16
    ## Largest sight radius the kernel stores. Forts use 14.
  VisionKernelSide = MaxVisionRadius * 2 + 1
  VisionKernelCells = VisionKernelSide * VisionKernelSide

type
  VisionSource* = object
    ## Describes one observer and its circular sight range in tiles.
    x*, z*: int32
    radius*: int32
    eyeHeight*: int16
  VisionRayStep = object
    ox, oz: int8
  VisionOffset* = object
    ## One tile in a precomputed sight circle, relative to the observer.
    dx*, dz*: int8

var
  visionRayOffsets: seq[VisionRayStep]
  visionRayStart: array[VisionKernelCells, int32]
  visionRayCount: array[VisionKernelCells, int16]
  visionRaySteps: array[VisionKernelCells, int16]
  visionCircle: array[MaxVisionRadius + 1, seq[VisionOffset]]
  visionKernelReady = false

proc roundedDivision(numerator, denominator: int64): int64 =
  ## Divides signed integers with deterministic half-away-from-zero rounding.
  if numerator >= 0:
    (numerator + denominator div 2) div denominator
  else:
    -((-numerator + denominator div 2) div denominator)

proc visionKernelIndex(dx, dz: int): int =
  ## Packs a signed offset into the square kernel table.
  (dz + MaxVisionRadius) * VisionKernelSide + (dx + MaxVisionRadius)

proc initVisionKernel*() =
  ## Builds ray steps and per-radius circles once.
  if visionKernelReady:
    return
  visionRayOffsets.setLen(0)
  for dz in -MaxVisionRadius .. MaxVisionRadius:
    for dx in -MaxVisionRadius .. MaxVisionRadius:
      let
        i = visionKernelIndex(dx, dz)
        steps = max(abs(dx), abs(dz))
      visionRayStart[i] = int32(visionRayOffsets.len)
      visionRaySteps[i] = int16(steps)
      if steps <= 1:
        visionRayCount[i] = 0
        continue
      for step in 1 ..< steps:
        visionRayOffsets.add VisionRayStep(
          ox: int8(roundedDivision(
            int64(dx) * int64(step),
            int64(steps)
          )),
          oz: int8(roundedDivision(
            int64(dz) * int64(step),
            int64(steps)
          ))
        )
      visionRayCount[i] = int16(steps - 1)
  for radius in 0 .. MaxVisionRadius:
    visionCircle[radius].setLen(0)
    let limit = radius * radius
    for dz in -radius .. radius:
      for dx in -radius .. radius:
        if dx * dx + dz * dz <= limit:
          visionCircle[radius].add VisionOffset(
            dx: int8(dx),
            dz: int8(dz)
          )
  visionKernelReady = true

iterator visionCircleTiles*(radius: int32): VisionOffset =
  ## Yields every in-range offset for one sight radius.
  initVisionKernel()
  if radius >= 0 and radius <= MaxVisionRadius:
    for offset in visionCircle[radius]:
      yield offset

proc sameVisionKeys*(a, b: openArray[int32]): bool =
  ## Returns whether two skip signatures are identical.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc copyVisionKeys*(dest: var seq[int32], src: openArray[int32]) =
  ## Copies one skip signature into a reused buffer.
  dest.setLen(src.len)
  for i, value in src:
    dest[i] = value

proc rayBlocked(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ: int32,
    sourceY,
    targetY: int64,
    rayIndex: int
): bool =
  ## Returns whether a kernel ray hits an occluder before the target.
  let
    start = visionRayStart[rayIndex]
    count = int(visionRayCount[rayIndex])
    steps = int64(visionRaySteps[rayIndex])
  for i in 0 ..< count:
    let
      cell = visionRayOffsets[start + i]
      x = sourceX + int32(cell.ox)
      z = sourceZ + int32(cell.oz)
      index = z * width + x
      rayHeight = sourceY + roundedDivision(
        (targetY - sourceY) * int64(i + 1),
        steps
      )
      obstacleHeight = int64(terrainHeights[index]) +
        int64(blockerHeights[index])
    if obstacleHeight >= rayHeight:
      return true
  false

proc offsetVisible*(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ: int32,
    sourceY: int64,
    offset: VisionOffset
): bool =
  ## Tests one kernel circle offset from a known observer height.
  let
    rayIndex = visionKernelIndex(int(offset.dx), int(offset.dz))
    steps = int(visionRaySteps[rayIndex])
  if steps <= 1:
    return true
  let
    x = sourceX + int32(offset.dx)
    z = sourceZ + int32(offset.dz)
    index = z * width + x
    targetY = int64(terrainHeights[index]) + 3
  not rayBlocked(
    width,
    terrainHeights,
    blockerHeights,
    sourceX,
    sourceZ,
    sourceY,
    targetY,
    rayIndex
  )

proc liveRayBlocked(
    width: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ,
    deltaX,
    deltaZ: int32,
    sourceY,
    targetY: int64
): bool =
  ## Walks one ray with the live rounding formula. Used past the kernel.
  let steps = max(abs(deltaX), abs(deltaZ))
  if steps <= 1:
    return false
  for step in 1'i32 ..< steps:
    let
      x = sourceX + int32(roundedDivision(
        int64(deltaX) * int64(step),
        int64(steps)
      ))
      z = sourceZ + int32(roundedDivision(
        int64(deltaZ) * int64(step),
        int64(steps)
      ))
      index = z * width + x
      rayHeight = sourceY + roundedDivision(
        (targetY - sourceY) * int64(step),
        int64(steps)
      )
      obstacleHeight = int64(terrainHeights[index]) +
        int64(blockerHeights[index])
    if obstacleHeight >= rayHeight:
      return true
  false

proc lineVisible*(
    width,
    height: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sourceX,
    sourceZ,
    targetX,
    targetZ,
    radius: int32,
    eyeHeight = 14'i16,
    targetHeight = 3'i16
): bool =
  ## Tests range and occlusion using the ray kernel when the offset fits.
  if sourceX < 0 or sourceX >= width or sourceZ < 0 or sourceZ >= height or
      targetX < 0 or targetX >= width or targetZ < 0 or targetZ >= height:
    return false
  let
    deltaX = targetX - sourceX
    deltaZ = targetZ - sourceZ
  if deltaX * deltaX + deltaZ * deltaZ > radius * radius:
    return false
  let steps = max(abs(deltaX), abs(deltaZ))
  if steps <= 1:
    return true
  let
    sourceIndex = sourceZ * width + sourceX
    targetIndex = targetZ * width + targetX
    sourceY = int64(terrainHeights[sourceIndex]) + int64(eyeHeight)
    targetY = int64(terrainHeights[targetIndex]) + int64(targetHeight)
  if abs(deltaX) <= MaxVisionRadius and abs(deltaZ) <= MaxVisionRadius:
    initVisionKernel()
    return not rayBlocked(
      width,
      terrainHeights,
      blockerHeights,
      sourceX,
      sourceZ,
      sourceY,
      targetY,
      visionKernelIndex(int(deltaX), int(deltaZ))
    )
  not liveRayBlocked(
    width,
    terrainHeights,
    blockerHeights,
    sourceX,
    sourceZ,
    deltaX,
    deltaZ,
    sourceY,
    targetY
  )

proc revealVision*(
    visible: var seq[uint8],
    width,
    height: int32,
    terrainHeights,
    blockerHeights: openArray[int16],
    sources: openArray[VisionSource]
) =
  ## Rebuilds a byte-per-tile visibility map from a set of observers.
  initVisionKernel()
  let cellCount = int(width * height)
  if visible.len != cellCount:
    visible = newSeq[uint8](cellCount)
  else:
    for value in visible.mitems:
      value = 0
  for source in sources:
    if source.radius <= 0:
      continue
    if source.radius > MaxVisionRadius:
      let
        minimumX = max(source.x - source.radius, 0)
        maximumX = min(source.x + source.radius, width - 1)
        minimumZ = max(source.z - source.radius, 0)
        maximumZ = min(source.z + source.radius, height - 1)
      for z in minimumZ .. maximumZ:
        for x in minimumX .. maximumX:
          let index = z * width + x
          if visible[index] != 0:
            continue
          if lineVisible(
            width,
            height,
            terrainHeights,
            blockerHeights,
            source.x,
            source.z,
            x,
            z,
            source.radius,
            source.eyeHeight
          ):
            visible[index] = 255
      continue
    let
      sourceIndex = source.z * width + source.x
      sourceY = int64(terrainHeights[sourceIndex]) + int64(source.eyeHeight)
    for offset in visionCircle[source.radius]:
      let
        x = source.x + int32(offset.dx)
        z = source.z + int32(offset.dz)
      if x < 0 or x >= width or z < 0 or z >= height:
        continue
      let index = z * width + x
      if visible[index] != 0:
        continue
      let
        rayIndex = visionKernelIndex(int(offset.dx), int(offset.dz))
        steps = int(visionRaySteps[rayIndex])
      if steps <= 1:
        visible[index] = 255
        continue
      let targetY = int64(terrainHeights[index]) + 3
      if not rayBlocked(
        width,
        terrainHeights,
        blockerHeights,
        source.x,
        source.z,
        sourceY,
        targetY,
        rayIndex
      ):
        visible[index] = 255

proc blurVisibility*(visible: openArray[uint8], width, height: int32): seq[uint8] =
  ## Softens only presentation edges with one deterministic box-blur pass.
  result = newSeq[uint8](visible.len)
  for z in 0 ..< height:
    for x in 0 ..< width:
      var
        total = 0'i32
        count = 0'i32
      for offsetZ in -1'i32 .. 1:
        for offsetX in -1'i32 .. 1:
          let
            sampleX = x + offsetX
            sampleZ = z + offsetZ
          if sampleX < 0 or sampleX >= width or
              sampleZ < 0 or sampleZ >= height:
            continue
          total += int32(visible[sampleZ * width + sampleX])
          inc count
      result[z * width + x] = uint8(total div max(count, 1))
