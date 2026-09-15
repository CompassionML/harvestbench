import
  std/math,
  noisy

const
  SurfaceNames* = [
    "grass-1", "grass-2", "grass-3", "grass-4",
    "dirt-road-1", "cobble-road-1", "gravel-road-1",
    "forest-floor-1", "marsh-1"
  ]
  GrassSurface* = 0
  OliveSurface* = 1
  MossSurface* = 2
  SparseSurface* = 3
  DirtSurface* = 4
  CobbleSurface* = 5
  GravelSurface* = 6
  ForestSurface* = 7
  MarshSurface* = 8

type GrassRegions* = object
  moisture, cover: Simplex

proc initGrassRegions*(seed: int, size: float32): GrassRegions {.raises: [].} =
  ## Builds broad, seeded grass regions independently of texture repeat size.
  doAssert size > 0, "Grass region size must be positive."
  result.moisture = initSimplex(seed xor 0x5731)
  result.cover = initSimplex(seed xor 0x126B)
  result.moisture.frequency = 1.0'f / size
  result.moisture.octaves = 2
  result.moisture.gain = 0.25'f
  result.cover.frequency = 0.8'f / size
  result.cover.octaves = 2
  result.cover.gain = 0.25'f

proc grassMaterial*(
  regions: GrassRegions,
  x, z, elevation, slope: float32
): int {.raises: [NoisyError].} =
  ## Favors moss in damp lows, olive on dry highs, and sparse grass on slopes.
  let
    moisture = regions.moisture.value(x, z) -
      clamp(elevation, -1.0'f, 1.0'f) * 0.35'f
    exposure = regions.cover.value(x, z) +
      clamp(slope, 0.0'f, 1.0'f) * 0.5'f
  if exposure > 0.32'f:
    result = SparseSurface
  elif moisture > 0.18'f:
    result = MossSurface
  elif moisture < -0.18'f:
    result = OliveSurface
  else:
    result = GrassSurface

proc roadCenter*(z: float32): float32 {.raises: [].} =
  ## Leaves the fort gate straight before forming broad continuous bends.
  let distance = max(z - 10.0'f, 0.0'f)
  result = 0.5'f + 3.5'f * (sin(distance * 0.26'f) -
    0.5'f * sin(distance * 0.52'f))

proc roadDistance*(x, z: float32): float32 {.raises: [].} =
  ## Approximates perpendicular distance to the curved road centerline.
  let
    distance = max(z - 10.0'f, 0.0'f)
    slope = 0.91'f * (cos(distance * 0.26'f) - cos(distance * 0.52'f))
  result = abs(x - roadCenter(z)) / sqrt(1.0'f + slope * slope)

proc roadHalfWidth*(z: float32): float32 {.raises: [].} =
  ## Varies road width gently while matching the three-tile fort entrance.
  result = 1.4'f + 0.1'f * cos(max(z - 10.0'f, 0.0'f) * 0.35'f)
