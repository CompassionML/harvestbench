## Logical tile grid shared by the terrain renderer and game code: quad
## layers of tile columns with per-corner heights, walkability, cross-layer
## edge links, A* pathfinding, and height sampling. No OpenGL here — the
## renderer in quadterrain.nim builds its meshes from this data.

import
  std/[heapqueue, math],
  vmath,
  profiles

const
  GridTiles* = (when defined(paintbotExpanded): 256 else: 128)
  HalfGrid* = GridTiles.float32 / 2.0
  HeightSteps* = 8.0'f32  # heights quantize to 1/8 of a tile
  PathUnitsPerTile* = 32'i32
  MaximumSlopeTangentSquaredNumerator = 2_039_606'i64
  MaximumSlopeTangentSquaredDenominator = 1_000_000'i64

proc pack*(values: array[4, float32]): array[4, int16] =
  ## Quantizes four world-space heights into compact height steps.
  for i in 0 .. 3:
    result[i] = int16(round(values[i] * HeightSteps))

proc unpack*(steps: array[4, int16]): array[4, float32] =
  ## Expands four compact height steps into world-space heights.
  for i in 0 .. 3:
    result[i] = steps[i].float32 / HeightSteps

const
  TileExists* = 1'u32
  TileConnectedEast* = 2'u32   # edge to (x+1, z); clear means a break
  TileConnectedSouth* = 4'u32  # edge to (x, z+1)
  TileImpassable* = 8'u32      # forced, e.g. ground squeezed under a bridge

  GrassTile* = 0'u32
  RoadTile* = 1'u32   # also the fort interior
  RockTile* = 2'u32   # natural rocky ground; boulders scatter here
  MarshTile* = 3'u32
  StoneTile* = 4'u32  # stone construction (bridge, fort walls); no boulders
  TreeTile* = 5'u32   # renders like grass; the tile itself carries a tree

type
  Tile* = object
    ## 24 bytes: corner heights in 1/8-tile integer steps, flag bits, and a
    ## game-specific tile kind (0 grass, 1 road, ...).
    tops*: array[4, int16]     # top corners: [x0z0, x1z0, x0z1, x1z1]
    bottoms*: array[4, int16]  # underside corners; only used by slab layers
    flags*: uint32
    kind*: uint32

  QuadLayer* = ref object
    originX*, originZ*: int  # placement in world tile coordinates
    width*, depth*: int
    slab*: bool   # slab layers close their sides and underside down to
                  # bottoms; the ground layer instead skirts to the floor
    water*: bool  # flat transparent surface; never walkable, never connects
                  # to other layers, and renders in its own blended pass
    tiles*: seq[Tile]

  EdgeLink* = object
    open*: bool
    layer*, x*, z*: int  # target tile when open

  PathPoint* = object
    ## Stores one path center in exact 1/32-tile units.
    x*, y*, z*: int32

  PathTile* = object
    ## One step of a path as grid coordinates. Games that move tile by tile
    ## want this rather than PathPoint: a tile-stepping simulation never
    ## needs a position, only which tile comes next and on which layer.
    layer*, x*, z*: int32

  PathNeighbors* = enum
    EdgeNeighbors ## Four edge-linked neighbours, including ramps.
    EightNeighbors ## Eight same-layer offsets, clockwise from north.

  PathWalkable* = proc (layer, x, z: int): bool {.nimcall.}
    ## Returns whether a tile may be entered. Games pass trees and
    ## structures here; the search never reads occupancy itself.

  PathEnterCost* = proc (layer, x, z: int): int32 {.nimcall.}
    ## Extra cost added when stepping onto a tile. Nil means zero. Used
    ## to prefer empty ground without treating other units as walls.

  PathQuery* = object
    ## Parameters for one A* search. Zeroed fields select the default
    ## four-neighbour terrain walk used by `findTilePath`.
    startLayer*, startX*, startZ*: int
    finishLayer*, finishX*, finishZ*: int
    neighbors*: PathNeighbors
    walkable*: PathWalkable
    enterCost*: PathEnterCost
    maxExpansions*: int
    orthogonalCost*, diagonalCost*: int32
    partial*: bool

  PathSearch* = object
    ## Tiles from the standing tile to the finish, or a prefix of that
    ## route when `partial` is set and the goal was not reached.
    tiles*: seq[PathTile]
    complete*: bool
    expansions*: int

  PathKeys = object
    complete: bool
    expansions: int

  PathingContext = object
    ready: bool
    layers: seq[QuadLayer]
    layerWalkable: seq[seq[bool]]
    layerNodeOffsets: seq[int]
    nodeLayers, nodeXs, nodeZs: seq[int]
    nodePathXs, nodePathYs, nodePathZs: seq[int32]
    edgeLinks: seq[array[4, EdgeLink]]
    edgeKnown: seq[array[4, bool]]

proc setFlag(tile: var Tile, flag: uint32, on: bool) =
  ## Sets or clears one bit in a tile's flags.
  if on:
    tile.flags = tile.flags or flag
  else:
    tile.flags = tile.flags and not flag

proc exists*(tile: Tile): bool =
  ## Returns whether the tile has renderable geometry.
  (tile.flags and TileExists) != 0

proc `exists=`*(tile: var Tile, on: bool) =
  ## Sets whether the tile has renderable geometry.
  tile.setFlag(TileExists, on)

proc connectedEast*(tile: Tile): bool =
  ## Returns whether the tile geometry connects to its eastern neighbor.
  (tile.flags and TileConnectedEast) != 0

proc `connectedEast=`*(tile: var Tile, on: bool) =
  ## Sets whether the tile geometry connects to its eastern neighbor.
  tile.setFlag(TileConnectedEast, on)

proc connectedSouth*(tile: Tile): bool =
  ## Returns whether the tile geometry connects to its southern neighbor.
  (tile.flags and TileConnectedSouth) != 0

proc `connectedSouth=`*(tile: var Tile, on: bool) =
  ## Sets whether the tile geometry connects to its southern neighbor.
  tile.setFlag(TileConnectedSouth, on)

proc impassable*(tile: Tile): bool =
  ## Returns whether gameplay explicitly blocks this tile.
  (tile.flags and TileImpassable) != 0

proc `impassable=`*(tile: var Tile, on: bool) =
  ## Sets whether gameplay explicitly blocks this tile.
  tile.setFlag(TileImpassable, on)

var
  layers*: seq[QuadLayer]
  layerWalkable*: seq[seq[bool]]  # parallel to layers; see computeWalkable
  layerNodeOffsets: seq[int]
  nodeLayers: seq[int]
  nodeXs: seq[int]
  nodeZs: seq[int]
  nodePathXs: seq[int32]
  nodePathYs: seq[int32]
  nodePathZs: seq[int32]
  edgeLinks: seq[array[4, EdgeLink]]
  edgeKnown: seq[array[4, bool]]
  pathCosts: seq[int64]
  pathCameFrom: seq[int]
  pathSeen: seq[uint32]
  pathGeneration = 0'u32
  pathResultKeys: seq[int]
  pathFrontierEdges: HeapQueue[(int64, int64, int)]
  pathFrontierEight: HeapQueue[(int32, int32)]
  dormantPathingContext: PathingContext

## Walkability

proc isSteep(firstDelta, secondDelta: int64): bool {.inline.} =
  ## Tests the fixed 55-degree limit for one eight-step tile triangle.
  (firstDelta * firstDelta + secondDelta * secondDelta) *
    MaximumSlopeTangentSquaredDenominator >
    64'i64 * MaximumSlopeTangentSquaredNumerator

proc computeWalkable(layer: QuadLayer): seq[bool] =
  ## A tile is walkable when it exists, isn't force-marked impassable, and
  ## neither of its top triangles exceeds the slope limit.
  result = newSeq[bool](layer.tiles.len)
  if layer.water:
    return  # water is never walkable and never links to other layers
  for i, t in layer.tiles:
    if not t.exists or t.impassable:
      continue
    let
      h = t.tops
      steep = isSteep(
        int64(h[1]) - int64(h[0]),
        int64(h[2]) - int64(h[0])
      ) or isSteep(
        int64(h[3]) - int64(h[2]),
        int64(h[3]) - int64(h[1])
      )
    result[i] = not steep

proc nodeIndex(layerIndex, x, z: int): int {.inline.} =
  ## Returns the flat node index for one layer-local tile.
  layerNodeOffsets[layerIndex] + z * layers[layerIndex].width + x

proc computeWalkable*() {.measure.} =
  ## Refills walkability and flat pathfinding caches after layer edits.
  layerWalkable = newSeq[seq[bool]](layers.len)
  layerNodeOffsets = newSeq[int](layers.len + 1)
  var totalNodes = 0
  for i, layer in layers:
    layerWalkable[i] = computeWalkable(layer)
    layerNodeOffsets[i] = totalNodes
    totalNodes += layer.tiles.len
  layerNodeOffsets[layers.len] = totalNodes

  nodeLayers = newSeq[int](totalNodes)
  nodeXs = newSeq[int](totalNodes)
  nodeZs = newSeq[int](totalNodes)
  nodePathXs = newSeq[int32](totalNodes)
  nodePathYs = newSeq[int32](totalNodes)
  nodePathZs = newSeq[int32](totalNodes)
  edgeLinks = newSeq[array[4, EdgeLink]](totalNodes)
  edgeKnown = newSeq[array[4, bool]](totalNodes)
  pathCosts = newSeq[int64](totalNodes)
  pathCameFrom = newSeq[int](totalNodes)
  pathSeen = newSeq[uint32](totalNodes)
  pathGeneration = 0

  for layerIndex, layer in layers:
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let
          index = nodeIndex(layerIndex, x, z)
          h = layer.tiles[z * layer.width + x].tops
        nodeLayers[index] = layerIndex
        nodeXs[index] = x
        nodeZs[index] = z
        nodePathXs[index] =
          int32(layer.originX + x - GridTiles div 2) *
          PathUnitsPerTile + PathUnitsPerTile div 2
        nodePathYs[index] =
          int32(h[0]) + int32(h[1]) + int32(h[2]) + int32(h[3])
        nodePathZs[index] =
          int32(layer.originZ + z - GridTiles div 2) *
          PathUnitsPerTile + PathUnitsPerTile div 2

proc sameLayers(contextLayers: openArray[QuadLayer]): bool =
  if layers.len != contextLayers.len or
      layerWalkable.len != contextLayers.len:
    return false
  for index, layer in contextLayers:
    if cast[pointer](layers[index]) != cast[pointer](layer):
      return false
  true

proc swapPathingContext(context: var PathingContext) =
  swap(layers, context.layers)
  swap(layerWalkable, context.layerWalkable)
  swap(layerNodeOffsets, context.layerNodeOffsets)
  swap(nodeLayers, context.nodeLayers)
  swap(nodeXs, context.nodeXs)
  swap(nodeZs, context.nodeZs)
  swap(nodePathXs, context.nodePathXs)
  swap(nodePathYs, context.nodePathYs)
  swap(nodePathZs, context.nodePathZs)
  swap(edgeLinks, context.edgeLinks)
  swap(edgeKnown, context.edgeKnown)
  if pathCosts.len < nodeLayers.len:
    pathCosts.setLen(nodeLayers.len)
    pathCameFrom.setLen(nodeLayers.len)
    pathSeen.setLen(nodeLayers.len)

proc installImmutableLayers*(nextLayers: seq[QuadLayer]) =
  ## Installs immutable geometry while retaining one displaced pathing context.
  ## Games that alternate between two maps avoid rebuilding either topology.
  if sameLayers(nextLayers):
    return
  if dormantPathingContext.ready and
      dormantPathingContext.layers.len == nextLayers.len:
    var matches = true
    for index, layer in nextLayers:
      if cast[pointer](dormantPathingContext.layers[index]) !=
          cast[pointer](layer):
        matches = false
        break
    if matches:
      swapPathingContext(dormantPathingContext)
      return
  dormantPathingContext = PathingContext(ready: true)
  swapPathingContext(dormantPathingContext)
  layers = nextLayers
  computeWalkable()

proc inLayer(layerIndex, x, z: int): bool {.inline.} =
  ## Returns whether a layer-local tile coordinate exists.
  layerIndex >= 0 and layerIndex < layers.len and
    x >= 0 and x < layers[layerIndex].width and
    z >= 0 and z < layers[layerIndex].depth

proc isWalkable*(layerIndex, x, z: int): bool =
  ## Safely queries the cached walkability of a layer-local tile.
  inLayer(layerIndex, x, z) and
    layerWalkable[layerIndex][z * layers[layerIndex].width + x]

proc rayTriangle*(origin, dir, a, b, c: Vec3): float32 =
  ## Ray-triangle intersection distance, or -1 when there is no hit.
  let
    edge1 = b - a
    edge2 = c - a
    p = cross(dir, edge2)
    det = dot(edge1, p)
  if abs(det) < 1e-6:
    return -1
  let
    invDet = 1.0'f32 / det
    tv = origin - a
    u = dot(tv, p) * invDet
  if u < 0 or u > 1:
    return -1
  let
    q = cross(tv, edge1)
    v = dot(dir, q) * invDet
  if v < 0 or u + v > 1:
    return -1
  let distance = dot(edge2, q) * invDet
  if distance > 0: distance else: -1

proc tileTopHit(origin, dir: Vec3, layer: QuadLayer, x, z: int): float32 =
  ## Distance to this tile's top triangles, or -1 when they miss.
  let tile = layer.tiles[z * layer.width + x]
  if not tile.exists:
    return -1
  let
    h = tile.tops.unpack
    x0 = (layer.originX + x).float32 - HalfGrid
    z0 = (layer.originZ + z).float32 - HalfGrid
    v00 = vec3(x0, h[0], z0)
    v10 = vec3(x0 + 1, h[1], z0)
    v01 = vec3(x0, h[2], z0 + 1)
    v11 = vec3(x0 + 1, h[3], z0 + 1)
  result = -1
  for distance in [
    rayTriangle(origin, dir, v00, v10, v01),
    rayTriangle(origin, dir, v10, v11, v01)
  ]:
    if distance > 0 and (result < 0 or distance < result):
      result = distance

proc pickWalkableTile*(
    origin, dir: Vec3,
    minLayer = 0,
    maxLayer = -1
): tuple[hit: bool, layer, x, z: int] =
  ## Nearest existing tile top the ray hits, if that tile is walkable.
  ## Missing tiles do not block, so a shaft hole picks the ramp below.
  if dir.length < 1e-8:
    return
  let
    ray = normalize(dir)
    first = max(minLayer, 0)
    last =
      if maxLayer < 0:
        layers.len - 1
      else:
        min(maxLayer, layers.len - 1)
  var
    best = float32.high
    found = false
    hitLayer, hitX, hitZ = 0
  for li in first .. last:
    let layer = layers[li]
    if layer.water:
      continue
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let distance = tileTopHit(origin, ray, layer, x, z)
        if distance > 0 and distance < best:
          best = distance
          found = true
          hitLayer = li
          hitX = x
          hitZ = z
  if found and isWalkable(hitLayer, hitX, hitZ):
    result = (true, hitLayer, hitX, hitZ)

proc worldWalkable*(layerIndex, worldX, worldZ: int): bool =
  ## Walkability at a world tile, converted into that layer's local grid.
  if layerIndex < 0 or layerIndex >= layers.len:
    return false
  isWalkable(
    layerIndex,
    worldX - layers[layerIndex].originX,
    worldZ - layers[layerIndex].originZ
  )

proc layersOpen*(current, dest, x, z: int): bool =
  ## True when this cell is standable on the current layer, or on dest
  ## when the two layers differ. Some other overlapping layer is ignored,
  ## so a bridge deck does not fall through to the ground under it.
  isWalkable(current, x, z) or
    (dest != current and isWalkable(dest, x, z))

proc worldLayersOpen*(current, dest, worldX, worldZ: int): bool =
  ## `layersOpen` in world tile coordinates.
  worldWalkable(current, worldX, worldZ) or
    (dest != current and worldWalkable(dest, worldX, worldZ))

proc preferLayer*(current, dest, x, z: int): int =
  ## Stays on the current layer while that cell is walkable. Switches
  ## only when the current layer has no tile here and dest does.
  if isWalkable(current, x, z):
    current
  elif dest != current and isWalkable(dest, x, z):
    dest
  else:
    current

proc worldPreferLayer*(current, dest, worldX, worldZ: int): int =
  ## `preferLayer` in world tile coordinates.
  if worldWalkable(current, worldX, worldZ):
    current
  elif dest != current and worldWalkable(dest, worldX, worldZ):
    dest
  else:
    current

## Edge links

proc computeEdgeLink(layerIndex, x, z, direction: int): EdgeLink =
  ## Computes one uncached walkable connection between tile edges.
  let
    layer = layers[layerIndex]
    h = layer.tiles[z * layer.width + x].tops
  var
    myA, myB: int16
    indexA, indexB, dx, dz: int
  case direction
  of 0: myA = h[1]; myB = h[3]; indexA = 0; indexB = 2; dx = 1
  of 1: myA = h[2]; myB = h[3]; indexA = 0; indexB = 1; dz = 1
  of 2: myA = h[0]; myB = h[2]; indexA = 1; indexB = 3; dx = -1
  else: myA = h[0]; myB = h[1]; indexA = 2; indexB = 3; dz = -1

  let
    nx = x + dx
    nz = z + dz
  if nx >= 0 and nx < layer.width and nz >= 0 and nz < layer.depth:
    let
      i = z * layer.width + x
      ni = nz * layer.width + nx
      connected = case direction
        of 0: layer.tiles[i].connectedEast
        of 1: layer.tiles[i].connectedSouth
        of 2: layer.tiles[ni].connectedEast
        else: layer.tiles[ni].connectedSouth
    if layerWalkable[layerIndex][ni] and connected and
        myA == layer.tiles[ni].tops[indexA] and
        myB == layer.tiles[ni].tops[indexB]:
      return EdgeLink(open: true, layer: layerIndex, x: nx, z: nz)

  let
    worldX = layer.originX + x + dx
    worldZ = layer.originZ + z + dz
  for li in 0 ..< layers.len:
    if li == layerIndex:
      continue
    let
      other = layers[li]
      lx = worldX - other.originX
      lz = worldZ - other.originZ
    if lx < 0 or lx >= other.width or lz < 0 or lz >= other.depth:
      continue
    let i = lz * other.width + lx
    if layerWalkable[li][i] and
        myA == other.tiles[i].tops[indexA] and
        myB == other.tiles[i].tops[indexB]:
      return EdgeLink(open: true, layer: li, x: lx, z: lz)
  EdgeLink(open: false)

proc edgeLink*(layerIndex, x, z, direction: int): EdgeLink =
  ## Returns one cached walkable tile-edge connection.
  if layerIndex < 0 or layerIndex >= layers.len or
      direction < 0 or direction > 3 or
      x < 0 or x >= layers[layerIndex].width or
      z < 0 or z >= layers[layerIndex].depth:
    return EdgeLink(open: false)
  let index = nodeIndex(layerIndex, x, z)
  if edgeKnown[index][direction]:
    return edgeLinks[index][direction]
  result = computeEdgeLink(layerIndex, x, z, direction)
  edgeLinks[index][direction] = result
  edgeKnown[index][direction] = true

proc edgeMask*(
    layerIndex, x, z: int,
    blockers: openArray[seq[int32]] = []
): uint8 =
  ## Returns open edge bits, east to north, including optional layer blockers.
  ## Nonzero blockers close both sides without changing cached terrain links.
  if not isWalkable(layerIndex, x, z):
    return
  if layerIndex < blockers.len and blockers[layerIndex].len > 0:
    doAssert blockers[layerIndex].len == layers[layerIndex].tiles.len
    if blockers[layerIndex][z * layers[layerIndex].width + x] != 0:
      return
  for direction in 0 .. 3:
    let link = edgeLink(layerIndex, x, z, direction)
    if not link.open:
      continue
    if link.layer < blockers.len and blockers[link.layer].len > 0:
      doAssert blockers[link.layer].len == layers[link.layer].tiles.len
      if blockers[link.layer][link.z * layers[link.layer].width + link.x] != 0:
        continue
    result = result or uint8(1 shl direction)

## Queries

proc tileCenter*(layerIndex, x, z: int): Vec3 =
  ## Converts one exact tile center for presentation code.
  if layerNodeOffsets.len == layers.len + 1:
    let index = nodeIndex(layerIndex, x, z)
    if index >= 0 and index < nodePathXs.len:
      return vec3(
        nodePathXs[index].float32 / PathUnitsPerTile.float32,
        nodePathYs[index].float32 / PathUnitsPerTile.float32,
        nodePathZs[index].float32 / PathUnitsPerTile.float32
      )
  let
    layer = layers[layerIndex]
    h = layer.tiles[z * layer.width + x].tops.unpack
  vec3(
    (layer.originX + x).float32 - HalfGrid + 0.5,
    (h[0] + h[1] + h[2] + h[3]) / 4.0,
    (layer.originZ + z).float32 - HalfGrid + 0.5
  )

proc tileTop*(layerIndex, x, z: int): int32 =
  ## Mean height of a tile's four top corners, in the same 1/8-tile integer
  ## steps that `Tile.tops` stores. Integer throughout, so a simulation can
  ## price a ramp step without ever touching `unpack` and its float32.
  ## Division floors toward negative infinity so the result is stable for
  ## tiles below y = 0 rather than biased toward zero.
  let
    layer = layers[layerIndex]
    tops = layer.tiles[z * layer.width + x].tops
    total = int32(tops[0]) + int32(tops[1]) + int32(tops[2]) + int32(tops[3])
  if total >= 0:
    total div 4
  else:
    -((-total + 3) div 4)

proc pathPoint*(layerIndex, x, z: int): PathPoint =
  ## Returns one exact integer tile center for authoritative game setup.
  let index = nodeIndex(layerIndex, x, z)
  PathPoint(
    x: nodePathXs[index],
    y: nodePathYs[index],
    z: nodePathZs[index]
  )

proc worldToTile*(worldX, worldZ: float32): (int, int) =
  ## World position to ground-layer tile coordinates (unclamped).
  (int(floor(worldX + HalfGrid)), int(floor(worldZ + HalfGrid)))

proc bilinearHeight(tile: Tile, offsetX, offsetZ: float32): float32 =
  ## Samples a tile top at normalized local coordinates.
  let h = tile.tops.unpack
  (h[0] * (1 - offsetX) + h[1] * offsetX) * (1 - offsetZ) +
    (h[2] * (1 - offsetX) + h[3] * offsetX) * offsetZ

proc layerHeight(
    layerIndex: int, worldX, worldZ: float32, height: var float32
): bool =
  ## Samples one layer's top surface; false when no tile exists there.
  let
    layer = layers[layerIndex]
    tileX = int(floor(worldX + HalfGrid)) - layer.originX
    tileZ = int(floor(worldZ + HalfGrid)) - layer.originZ
  if tileX < 0 or tileX >= layer.width or tileZ < 0 or tileZ >= layer.depth:
    return false
  let tile = layer.tiles[tileZ * layer.width + tileX]
  if not tile.exists:
    return false
  height = tile.bilinearHeight(
    worldX + HalfGrid - (layer.originX + tileX).float32,
    worldZ + HalfGrid - (layer.originZ + tileZ).float32
  )
  true

proc groundHeight*(worldX, worldZ: float32): float32 =
  ## Bilinear height of the ground layer at a world position.
  discard layerHeight(0, worldX, worldZ, result)

proc surfaceHeight*(worldX, worldZ: float32): float32 =
  ## The topmost solid surface at a world position: the highest non-water
  ## layer with a tile there (a bridge deck wins over the riverbed below).
  var found = false
  for layerIndex in 0 ..< layers.len:
    if layers[layerIndex].water:
      continue
    var height: float32
    if layerHeight(layerIndex, worldX, worldZ, height):
      if not found or height > result:
        result = height
      found = true

proc surfaceHeightNear*(
    worldX, worldZ, referenceY: float32
): float32 =
  ## Returns the solid surface closest to a reference height. This selects
  ## the ground under an overhead gate while still selecting an elevated
  ## bridge or rampart when the caller is already following that surface.
  var
    found = false
    bestDistance = float32.high
  for layerIndex in 0 ..< layers.len:
    if layers[layerIndex].water:
      continue
    var height: float32
    if layerHeight(layerIndex, worldX, worldZ, height):
      let distance = abs(height - referenceY)
      if not found or distance < bestDistance or
        (distance == bestDistance and height > result):
          result = height
          bestDistance = distance
          found = true

## Pathfinding

const
  EightOffsets = [
    (0, -1), (1, -1), (1, 0), (1, 1),
    (0, 1), (-1, 1), (-1, 0), (-1, -1)
  ]
    ## Clockwise from north, matching the eight-neighbour scan games use
    ## for movement so equal-cost ties break the same way.

proc octileCost(
    dx, dz, orthogonalCost, diagonalCost: int64
): int64 {.inline.} =
  ## Returns the eight-neighbour distance in the caller's cost units.
  let
    ax = abs(dx)
    az = abs(dz)
  diagonalCost * min(ax, az) +
    orthogonalCost * (max(ax, az) - min(ax, az))

proc beginSearch() =
  ## Advances the generation stamp so a new search can reuse scratch.
  if pathGeneration == uint32.high:
    pathSeen = newSeq[uint32](pathSeen.len)
    pathGeneration = 1
  else:
    inc pathGeneration

proc clearFrontier[T](heap: var HeapQueue[T]) =
  ## Drops queued nodes but keeps the backing buffer.
  while heap.len > 0:
    discard heap.pop()

proc reconstruct(startKey, finishKey: int) =
  ## Writes node keys from start to finish into reused scratch.
  pathResultKeys.setLen(0)
  var key = finishKey
  while true:
    pathResultKeys.add key
    if key == startKey:
      break
    key = pathCameFrom[key]
  var i = 0
  var j = pathResultKeys.high
  while i < j:
    swap(pathResultKeys[i], pathResultKeys[j])
    inc i
    dec j

proc searchEdges(query: PathQuery): PathKeys =
  ## Four-neighbour A* over cached edge links, including ramps.
  let customWalk = not query.walkable.isNil
  if not customWalk and (
      not isWalkable(
        query.startLayer, query.startX, query.startZ
      ) or       not isWalkable(
        query.finishLayer, query.finishX, query.finishZ
      )):
    pathResultKeys.setLen(0)
    return
  let
    startKey = nodeIndex(query.startLayer, query.startX, query.startZ)
    goalKey = nodeIndex(
      query.finishLayer, query.finishX, query.finishZ
    )
    goalPathX = int64(nodePathXs[goalKey])
    goalPathY = int64(nodePathYs[goalKey])
    goalPathZ = int64(nodePathZs[goalKey])
  template distanceToGoal(node: int): int64 =
    block:
      let
        key = node
        planar = abs(int64(nodePathXs[key]) - goalPathX) +
          abs(int64(nodePathZs[key]) - goalPathZ)
      if query.orthogonalCost > 0:
        planar div int64(PathUnitsPerTile) * int64(query.orthogonalCost)
      else:
        planar + abs(int64(nodePathYs[key]) - goalPathY)
  beginSearch()
  let generation = pathGeneration
  clearFrontier(pathFrontierEdges)
  var
    expansions = 0
    found = false
    bestKey = startKey
    bestHeuristic = distanceToGoal(startKey)
  pathFrontierEdges.push((0'i64, 0'i64, startKey))
  pathSeen[startKey] = generation
  pathCosts[startKey] = 0
  pathCameFrom[startKey] = -1
  while pathFrontierEdges.len > 0:
    if query.maxExpansions > 0 and expansions >= query.maxExpansions:
      break
    let (_, poppedCost, key) = pathFrontierEdges.pop()
    if pathSeen[key] != generation or poppedCost != pathCosts[key]:
      continue
    inc expansions
    if key == goalKey:
      found = true
      break
    let
      li = nodeLayers[key]
      x = nodeXs[key]
      z = nodeZs[key]
      currentCost = pathCosts[key]
      currentPathY = int64(nodePathYs[key])
    for direction in 0 .. 3:
      let link = edgeLink(li, x, z, direction)
      if not link.open:
        continue
      if customWalk and
          not query.walkable(link.layer, link.x, link.z):
        continue
      let
        nextKey = nodeIndex(link.layer, link.x, link.z)
        stepCost =
          if query.orthogonalCost > 0:
            int64(query.orthogonalCost)
          else:
            # Every edge crosses one world tile; only height varies.
            int64(PathUnitsPerTile) +
              abs(currentPathY - int64(nodePathYs[nextKey]))
        extra =
          if query.enterCost.isNil: 0'i64
          else: int64(query.enterCost(link.layer, link.x, link.z))
        newCost = currentCost + stepCost + extra
      if pathSeen[nextKey] == generation and
          newCost >= pathCosts[nextKey]:
        continue
      pathSeen[nextKey] = generation
      pathCosts[nextKey] = newCost
      pathCameFrom[nextKey] = key
      let guess = distanceToGoal(nextKey)
      if query.partial and (
          guess < bestHeuristic or
          (guess == bestHeuristic and nextKey < bestKey)):
        bestHeuristic = guess
        bestKey = nextKey
      pathFrontierEdges.push((newCost + guess, newCost, nextKey))
  result.expansions = expansions
  result.complete = found
  if not found and not query.partial:
    pathResultKeys.setLen(0)
    return
  reconstruct(startKey, if found: goalKey else: bestKey)

proc searchEight(query: PathQuery): PathKeys =
  ## Eight-neighbour A* on one layer. Same heap, costs, and partial-path
  ## rule Light vs Dark used when it owned this search.
  let customWalk = not query.walkable.isNil
  let
    startKey = nodeIndex(query.startLayer, query.startX, query.startZ)
    goalKey = nodeIndex(
      query.finishLayer, query.finishX, query.finishZ
    )
    li = query.startLayer
    orthogonalCost =
      if query.orthogonalCost > 0: query.orthogonalCost
      else: PathUnitsPerTile
    diagonalCost =
      if query.diagonalCost > 0: query.diagonalCost
      else: int32((int64(orthogonalCost) * 181) div 128)
  template allowed(x, z: int): bool =
    if customWalk:
      query.walkable(li, x, z)
    else:
      isWalkable(li, x, z)
  template octile(node: int): int32 =
    int32(octileCost(
      int64(nodeXs[node] - nodeXs[goalKey]),
      int64(nodeZs[node] - nodeZs[goalKey]),
      int64(orthogonalCost),
      int64(diagonalCost)
    ))
  beginSearch()
  let generation = pathGeneration
  if startKey == goalKey:
    result.complete = true
    pathResultKeys.setLen(1)
    pathResultKeys[0] = startKey
    return
  clearFrontier(pathFrontierEight)
  var
    expansions = 0
    found = false
    bestKey = startKey
    bestHeuristic = octile(startKey)
  pathFrontierEight.push((bestHeuristic, int32(startKey)))
  pathSeen[startKey] = generation
  pathCosts[startKey] = 0
  pathCameFrom[startKey] = -1
  while pathFrontierEight.len > 0 and
      (query.maxExpansions == 0 or expansions < query.maxExpansions):
    let (_, index32) = pathFrontierEight.pop()
    let index = int(index32)
    if pathSeen[index] != generation:
      continue
    inc expansions
    if index == goalKey:
      found = true
      break
    let
      x = nodeXs[index]
      z = nodeZs[index]
    for (dx, dz) in EightOffsets:
      let
        nextX = x + dx
        nextZ = z + dz
      if not inLayer(li, nextX, nextZ) or not allowed(nextX, nextZ):
        continue
      if dx != 0 and dz != 0 and
          (not allowed(x + dx, z) or not allowed(x, z + dz)):
        continue
      let
        nextKey = nodeIndex(li, nextX, nextZ)
        stepCost =
          if dx != 0 and dz != 0: diagonalCost
          else: orthogonalCost
        extra =
          if query.enterCost.isNil: 0'i32
          else: query.enterCost(li, nextX, nextZ)
        nextCost = int32(pathCosts[index]) + stepCost + extra
      if pathSeen[nextKey] == generation and
          pathCosts[nextKey] <= int64(nextCost):
        continue
      pathSeen[nextKey] = generation
      pathCosts[nextKey] = int64(nextCost)
      pathCameFrom[nextKey] = index
      let guess = octile(nextKey)
      if query.partial and (
          guess < bestHeuristic or
          (guess == bestHeuristic and nextKey < bestKey)):
        bestHeuristic = guess
        bestKey = nextKey
      pathFrontierEight.push((nextCost + guess, int32(nextKey)))
  result.expansions = expansions
  result.complete = found
  if not found and not query.partial:
    pathResultKeys.setLen(0)
    return
  reconstruct(startKey, if found: goalKey else: bestKey)

proc searchPath(query: PathQuery): PathKeys {.measure.} =
  ## Runs A* for the requested neighbour set and returns node keys from
  ## start to finish. Both graphs share one scratch; the public path procs
  ## are thin projections of this.
  if not inLayer(query.startLayer, query.startX, query.startZ) or
      not inLayer(query.finishLayer, query.finishX, query.finishZ):
    pathResultKeys.setLen(0)
    return
  case query.neighbors
  of EdgeNeighbors:
    searchEdges(query)
  of EightNeighbors:
    searchEight(query)

proc searchPath(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int
): seq[int] =
  ## Runs the default four-neighbour search and returns keys, or empty.
  discard searchPath(PathQuery(
    startLayer: startLayer,
    startX: startX,
    startZ: startZ,
    finishLayer: finishLayer,
    finishX: finishX,
    finishZ: finishZ
  ))
  result = pathResultKeys

proc worldPathTile(tile: PathTile): tuple[x, z: int] {.inline.} =
  ## Returns one tile in world tile coordinates.
  (
    layers[tile.layer].originX + int(tile.x),
    layers[tile.layer].originZ + int(tile.z)
  )

proc stepPathTile(
    tile: PathTile,
    direction: int
): tuple[open: bool, next: PathTile] =
  ## One edge crossing, possibly onto another layer.
  let link = edgeLink(int(tile.layer), int(tile.x), int(tile.z), direction)
  if link.open:
    (true, PathTile(
      layer: int32(link.layer),
      x: int32(link.x),
      z: int32(link.z)
    ))
  else:
    (false, tile)

proc lineClear*(a, b: PathTile): bool =
  ## Returns whether a straight line of open edges joins two tiles.
  ##
  ## Amanatides-Woo in world tiles. Every axis step is one `edgeLink`
  ## crossing, so a leg can take a ramp onto a bridge and will not cut a
  ## blocked corner. When the line hits a tile corner both ways around it
  ## must be open and meet on the same tile.
  var node = a
  let
    tileA = worldPathTile(a)
    tileB = worldPathTile(b)
    dx = tileB.x - tileA.x
    dz = tileB.z - tileA.z
  if tileA == tileB:
    return a == b
  let
    stepX = cmp(dx, 0)
    stepZ = cmp(dz, 0)
    adx = abs(dx)
    adz = abs(dz)
    dirX =
      if stepX > 0: 0
      else: 2
    dirZ =
      if stepZ > 0: 1
      else: 3
  var
    tileX = tileA.x
    tileZ = tileA.z
    ix = 0
    iz = 0
    guard = 0
  while tileX != tileB.x or tileZ != tileB.z:
    inc guard
    if guard > 4 * GridTiles:
      return false
    let
      left = int64(1 + 2 * ix) * int64(adz)
      right = int64(1 + 2 * iz) * int64(adx)
      corner = stepX != 0 and stepZ != 0 and left == right
      takeX =
        if stepX == 0: false
        elif stepZ == 0 or corner: true
        else: left < right
      takeZ =
        if stepZ == 0: false
        elif stepX == 0 or corner: true
        else: left > right
    if corner:
      let
        viaX = stepPathTile(node, dirX)
        viaXZ =
          if viaX.open: stepPathTile(viaX.next, dirZ)
          else: viaX
        viaZ = stepPathTile(node, dirZ)
        viaZX =
          if viaZ.open: stepPathTile(viaZ.next, dirX)
          else: viaZ
      if not (
        viaX.open and viaXZ.open and viaZ.open and viaZX.open
      ):
        return false
      if viaXZ.next != viaZX.next:
        return false
      node = viaXZ.next
      tileX += stepX
      tileZ += stepZ
      inc ix
      inc iz
    elif takeX:
      let crossing = stepPathTile(node, dirX)
      if not crossing.open:
        return false
      node = crossing.next
      tileX += stepX
      inc ix
    elif takeZ:
      let crossing = stepPathTile(node, dirZ)
      if not crossing.open:
        return false
      node = crossing.next
      tileZ += stepZ
      inc iz
    else:
      return false
  node == b

proc sameLayerSpan(tiles: seq[PathTile], first, last: int): bool =
  ## True when every tile from first to last shares one floor.
  let layer = tiles[first].layer
  for i in first .. last:
    if tiles[i].layer != layer:
      return false
  true

proc smoothPathTiles*(tiles: seq[PathTile]): seq[PathTile] {.measure.} =
  ## String-pulls an A* tile path. Keeps a waypoint when the straight
  ## line from the previous kept tile to the one after it is blocked.
  ## A layer change is always kept, because walkers only treat the
  ## current floor and the next waypoint floor as open.
  if tiles.len <= 2:
    return tiles
  result.add tiles[0]
  var anchor = 0
  while anchor < tiles.len - 1:
    var reach = anchor + 1
    for candidate in countdown(tiles.len - 1, anchor + 2):
      if not sameLayerSpan(tiles, anchor, candidate):
        continue
      if lineClear(tiles[anchor], tiles[candidate]):
        reach = candidate
        break
    result.add tiles[reach]
    anchor = reach

proc fillPathPoints*(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int,
    points: var seq[PathPoint],
    neighbors = EdgeNeighbors,
    smooth = false
) {.measure.} =
  ## Fills tile-center points. Reuses `points` capacity.
  discard searchPath(PathQuery(
    startLayer: startLayer,
    startX: startX,
    startZ: startZ,
    finishLayer: finishLayer,
    finishX: finishX,
    finishZ: finishZ,
    neighbors: neighbors
  ))
  var tiles: seq[PathTile]
  tiles.setLen(pathResultKeys.len)
  for i, key in pathResultKeys:
    tiles[i] = PathTile(
      layer: int32(nodeLayers[key]),
      x: int32(nodeXs[key]),
      z: int32(nodeZs[key])
    )
  if smooth:
    tiles = smoothPathTiles(tiles)
  points.setLen(tiles.len)
  for i, tile in tiles:
    points[i] = pathPoint(int(tile.layer), int(tile.x), int(tile.z))

proc findPathPoints*(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int,
    smooth = false
): seq[PathPoint] =
  ## Runs deterministic integer A* and returns exact tile center points.
  fillPathPoints(
    startLayer, startX, startZ, finishLayer, finishX, finishZ, result,
    smooth = smooth
  )

proc fillTilePath*(query: PathQuery, tiles: var seq[PathTile]): PathSearch =
  ## Fills tiles for a search. Reuses `tiles` capacity.
  let found = searchPath(query)
  result.complete = found.complete
  result.expansions = found.expansions
  tiles.setLen(pathResultKeys.len)
  for i, key in pathResultKeys:
    tiles[i] = PathTile(
      layer: int32(nodeLayers[key]),
      x: int32(nodeXs[key]),
      z: int32(nodeZs[key])
    )

proc findTilePath*(query: PathQuery): PathSearch =
  ## Runs A* with the given neighbour set, walkability, and budget.
  let stats = fillTilePath(query, result.tiles)
  result.complete = stats.complete
  result.expansions = stats.expansions

proc findTilePath*(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int
): seq[PathTile] =
  ## Runs deterministic integer A* and returns the tiles to walk through,
  ## starting with the tile you are already on. Consecutive entries are
  ## always edge-linked neighbors, so a tile-stepping actor can follow them
  ## one step at a time, including where a ramp crosses to another layer.
  discard fillTilePath(PathQuery(
    startLayer: startLayer,
    startX: startX,
    startZ: startZ,
    finishLayer: finishLayer,
    finishX: finishX,
    finishZ: finishZ
  ), result)

proc findPath*(
    startLayer, startX, startZ, finishLayer, finishX, finishZ: int
): seq[Vec3] =
  ## Converts an exact integer path to render-space tile centers.
  for point in findPathPoints(
    startLayer,
    startX,
    startZ,
    finishLayer,
    finishX,
    finishZ
  ):
    result.add vec3(
      point.x.float32 / PathUnitsPerTile.float32,
      point.y.float32 / PathUnitsPerTile.float32,
      point.z.float32 / PathUnitsPerTile.float32
    )
