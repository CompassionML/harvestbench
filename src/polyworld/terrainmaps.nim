import
  std/math,
  noisy, vmath,
  pathing, terrainsplats, terrainsurfaces

type
  TerrainMapError* = object of CatchableError
  TerrainLayer* = object
    materials*: seq[int]
    ranges*: seq[Vec3]
  TerrainMap* = object
    layers*: seq[TerrainLayer]
    blends*, brushes*: seq[float32]
    placements*, peak*: int

proc neighborhood(
  layer: QuadLayer,
  materials: openArray[int],
  x, z, cornerIndex: int
): Vec4 {.raises: [].} =
  ## Collects only the material centers sharing this exact corner height.
  let
    cornerX = x + (cornerIndex and 1)
    cornerZ = z + (cornerIndex shr 1)
    height = layer.tiles[z * layer.width + x].tops[cornerIndex]
  result = vec4(-1)
  for slot, (tileX, tileZ, corner) in [
    (cornerX - 1, cornerZ - 1, 3), (cornerX, cornerZ - 1, 2),
    (cornerX - 1, cornerZ, 1), (cornerX, cornerZ, 0)
  ]:
    if tileX < 0 or tileX >= layer.width or
      tileZ < 0 or tileZ >= layer.depth:
        continue
    let i = tileZ * layer.width + tileX
    if layer.tiles[i].exists and layer.tiles[i].tops[corner] == height:
      result[slot] = materials[i].float32

proc buildTerrainMap*(
  layers: openArray[QuadLayer],
  kindMaterials: openArray[int],
  seed: int,
  textureSize = 2.5'f,
  patchSize = 24.0'f,
  heightScale = 2.91'f,
  count = 1,
  chance = 0.4'f,
  materialCount = SurfaceNames.len
): TerrainMap {.raises: [TerrainMapError].} =
  ## Builds visual material and splat buffers without changing game map data.
  if kindMaterials.len == 0 or not (patchSize > 0 and patchSize < Inf) or
    not (heightScale > 0 and heightScale < Inf) or
    materialCount < SurfaceNames.len:
      raise newException(TerrainMapError, "Invalid terrain material settings.")
  for material in kindMaterials:
    if material < 0 or material >= materialCount:
      raise newException(TerrainMapError, "Unknown generated terrain material.")
  try:
    let regions = initGrassRegions(seed, patchSize)
    var splats: seq[Splat]
    result.layers.setLen(layers.len)
    for layerIndex, layer in layers:
      if layer == nil or layer.width <= 0 or layer.depth <= 0 or
        layer.width > int.high div layer.depth or
        layer.tiles.len != layer.width * layer.depth:
          raise newException(TerrainMapError, "Invalid terrain layer size.")
      if layer.water:
        continue
      var
        materials = newSeq[int](layer.tiles.len)
        surfaces = newSeq[SplatTile](layer.tiles.len)
        ranges = newSeq[Vec3](layer.tiles.len)
      for i, tile in layer.tiles:
        let
          x = i mod layer.width
          z = i div layer.width
        var material = kindMaterials[min(tile.kind.int, kindMaterials.high)]
        if tile.exists and tile.kind == GrassTile:
          let
            heights = tile.tops.unpack()
            elevation = (heights[0] + heights[1] + heights[2] + heights[3]) /
              (4 * heightScale)
            dx = (heights[1] + heights[3] - heights[0] - heights[2]) * 0.5'f
            dz = (heights[2] + heights[3] - heights[0] - heights[1]) * 0.5'f
          material = grassMaterial(
            regions,
            (layer.originX + x).float32 + 0.5'f,
            (layer.originZ + z).float32 + 0.5'f,
            elevation,
            sqrt(dx * dx + dz * dz)
          )
        materials[i] = material
        surfaces[i] = SplatTile(
          # Extra construction materials have no natural terrain stamps.
          exists: tile.exists and material < SurfaceNames.len,
          material: material,
          variants: 1,
          tops: tile.tops
        )
        ranges[i] = vec3(0, 0, -1)
      let map = generateSplats(
        surfaces,
        layer.width,
        layer.depth,
        vec2(layer.originX.float32 - HalfGrid, layer.originZ.float32 - HalfGrid),
        seed.int64 * 7919 + layerIndex.int64 * 104729 + 53,
        count,
        chance,
        textureSize,
        materialCount
      )
      for i, tile in layer.tiles:
        if not tile.exists:
          continue
        let
          span = map.spans[i]
          first = result.blends.len div 4
        ranges[i] = vec3(
          (span.first + splats.len).float32,
          span.count.float32,
          first.float32
        )
        result.peak = max(result.peak, span.count)
        for corner in 0 .. 3:
          let neighbors = neighborhood(
            layer, materials, i mod layer.width, i div layer.width, corner
          )
          result.blends.add [neighbors.x, neighbors.y, neighbors.z, neighbors.w]
      splats.add(map.splats)
      result.placements += map.placements
      result.layers[layerIndex] = TerrainLayer(
        materials: materials,
        ranges: ranges
      )
    result.brushes = packedSplats(splats)
    if result.blends.len == 0:
      result.blends = @[0.0'f, 0.0'f, 0.0'f, 0.0'f]
  except TerrainSplatError, NoisyError:
    raise newException(TerrainMapError, getCurrentExceptionMsg())
