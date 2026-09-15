import
  std/[math, random],
  vmath

const
  MaterialNames* = [
    "grass-1", "grass-2", "grass-3",
    "rocks-1", "rocks-2", "rocks-3",
    "path-1", "path-2", "path-3",
    "dirt-1", "dirt-2", "dirt-3",
    "sand-1", "sand-2", "sand-3",
    "marsh-1", "marsh-2", "marsh-3"
  ]
  TextureSize* = 256

type
  TerrainSplatError* = object of CatchableError
  Splat* = object
    position*: Vec2
    size*, angle*, amount*: float32
    material*: int
  SplatSpan* = object
    first*, count*: int
  SplatTile* = object
    exists*: bool
    material*: int
    variants*: int
    tops*: array[4, int16]
  SplatMap* = object
    spans*: seq[SplatSpan]
    splats*: seq[Splat]
    placements*: int

proc accepts(a, b: SplatTile, dx, dz: int): bool {.raises: [].} =
  ## Allows projection only where neighboring tiles share their corner heights.
  if not b.exists or abs(dx) > 1 or abs(dz) > 1:
    return false
  if dx == 0 and dz == 0:
    return true
  if dx != 0 and dz != 0:
    let corner = (if dx > 0: 1 else: 0) + (if dz > 0: 2 else: 0)
    return a.tops[corner] == b.tops[3 - corner]
  if dx != 0:
    let edge = if dx > 0: 1 else: 0
    return a.tops[edge] == b.tops[1 - edge] and
      a.tops[edge + 2] == b.tops[3 - edge]
  let edge = if dz > 0: 2 else: 0
  a.tops[edge] == b.tops[2 - edge] and
    a.tops[edge + 1] == b.tops[3 - edge]

proc generateSplats*(
  tiles: openArray[SplatTile],
  width, depth: int,
  origin: Vec2,
  seed: int64,
  count: int,
  chance = 1.0'f,
  size = 1.0'f,
  materialCount = MaterialNames.len
): SplatMap {.raises: [TerrainSplatError].} =
  ## Builds stable variable-length tile spans from overlapping world brushes.
  if width <= 0 or depth <= 0 or width > int.high div depth or
    tiles.len != width * depth or count < 0:
      raise newException(TerrainSplatError, "Invalid splat map dimensions or count.")
  for tile in tiles:
    if tile.material < 0 or tile.material >= materialCount or tile.variants < 0:
      raise newException(TerrainSplatError, "Invalid splat material.")
    let
      first = if tile.variants == 0: (tile.material div 3) * 3 else: tile.material
      variants = if tile.variants == 0: 3 else: tile.variants
    if variants > materialCount - first:
      raise newException(TerrainSplatError, "Splat variants exceed the material array.")
  if count > 1_000_000 div tiles.len:
    raise newException(TerrainSplatError, "Splat placement budget exceeds one million.")
  if not (chance >= 0 and chance <= 1) or not (size > 0 and size <= 12):
    raise newException(TerrainSplatError, "Invalid splat placement chance or scale.")
  var
    rng = initRand(seed)
    placements: seq[Splat]
    owners: seq[int]
  result.spans = newSeq[SplatSpan](tiles.len)
  for i, tile in tiles:
    if not tile.exists:
      continue
    for j in 0 ..< count:
      let
        first = if tile.variants == 0: (tile.material div 3) * 3 else: tile.material
        variants = if tile.variants == 0: 3 else: tile.variants
        roll = rng.rand(1.0).float32
        splat = Splat(
          position: origin + vec2(
            (i mod width).float32 + rng.rand(1.0).float32,
            (i div width).float32 + rng.rand(1.0).float32
          ),
          size: size,
          angle: rng.rand(PI * 2).float32,
          amount: 1,
          material: first + rng.rand(variants - 1)
        )
      if chance > 0 and roll <= chance:
        placements.add(splat)
        owners.add(i)
  result.placements = placements.len
  var
    visited = newSeq[int](tiles.len)
    queue: seq[int]
    references: seq[tuple[tile, brush: int]]
  for i, splat in placements:
    let
      radius = splat.size * 0.5'f *
        (abs(cos(splat.angle)) + abs(sin(splat.angle)))
      local = splat.position - origin
      x0 = max(0, floor(local.x - radius).int)
      x1 = min(width - 1, floor(local.x + radius).int)
      z0 = max(0, floor(local.y - radius).int)
      z1 = min(depth - 1, floor(local.y + radius).int)
    queue.setLen(0)
    queue.add(owners[i])
    visited[owners[i]] = i + 1
    var cursor = 0
    while cursor < queue.len:
      let
        current = queue[cursor]
        x = current mod width
        z = current div width
      inc cursor
      references.add((current, i))
      inc result.spans[current].count
      for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let
          nx = x + dx
          nz = z + dz
        if nx < x0 or nx > x1 or nz < z0 or nz > z1:
          continue
        let neighbor = nz * width + nx
        if visited[neighbor] == i + 1 or
          not tiles[current].accepts(tiles[neighbor], dx, dz):
            continue
        visited[neighbor] = i + 1
        queue.add(neighbor)
  var total = 0
  for span in result.spans.mitems:
    span.first = total
    total += span.count
    span.count = 0
  result.splats = newSeq[Splat](total)
  for reference in references:
    let destination = result.spans[reference.tile].first +
      result.spans[reference.tile].count
    result.splats[destination] = placements[reference.brush]
    inc result.spans[reference.tile].count

proc packedSplats*(splats: openArray[Splat]): seq[float32] {.raises: [].} =
  ## Encodes two RGBA32F texels per brush for the shader's dynamic loop.
  result = newSeq[float32](max(1, splats.len) * 8)
  for i, splat in splats:
    result[i * 8] = splat.position.x
    result[i * 8 + 1] = splat.position.y
    result[i * 8 + 2] = cos(splat.angle) / splat.size
    result[i * 8 + 3] = sin(splat.angle) / splat.size
    result[i * 8 + 4] = splat.material.float32
    result[i * 8 + 5] = splat.amount

proc variant*(x, z, material: int): int {.raises: [].} =
  ## Selects coherent variations from a shared corner's world coordinates.
  let hash = cast[uint32](x) * 0x9E3779B9'u32 xor
    cast[uint32](z) * 0x85EBCA6B'u32
  (material div 3) * 3 + int((hash xor (hash shr 16)) mod 3)
