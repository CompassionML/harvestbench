## Portable integer helpers for map generation.
##
## Games keep river, fort, and dungeon recipes. This module is the shared
## lattice noise, rounding, and blend arithmetic those recipes sit on.

import rngs

const MapBlendScale* = 1024'i32
  ## Blend amounts are fixed-point ratios over this scale.

proc roundDivision*(numerator, denominator: int64): int64 =
  ## Divides signed integers with deterministic half-away-from-zero rounding.
  doAssert denominator > 0, "rounding denominator must be positive"
  if numerator >= 0:
    (numerator + denominator div 2) div denominator
  else:
    -((-numerator + denominator div 2) div denominator)

proc floorDiv(value, divisor: int): int =
  ## Divides toward negative infinity so lattice cells stay uniform.
  if value >= 0: value div divisor
  else: -(((-value) + divisor - 1) div divisor)

proc floorMod(value, divisor: int): int =
  ## Returns a non-negative remainder matching `floorDiv`.
  value - floorDiv(value, divisor) * divisor

proc smoothstep*(value: int32): int32 =
  ## Maps a clamped fixed integer ratio onto a smooth cubic curve.
  let amount = clamp(value, 0'i32, MapBlendScale)
  int32(roundDivision(
    int64(amount) * int64(amount) *
      int64(3 * MapBlendScale - 2 * amount),
    int64(MapBlendScale) * int64(MapBlendScale)
  ))

proc blendHeight*(first, second, amount: int32): int32 =
  ## Blends packed height steps by a fixed integer amount.
  first + int32(roundDivision(
    int64(second - first) * int64(amount),
    MapBlendScale
  ))

proc packedHeights*(values: array[4, int32]): array[4, int16] =
  ## Stores four already-quantized deterministic height values.
  for i in 0 .. 3:
    doAssert values[i] >= int16.low and values[i] <= int16.high
    result[i] = int16(values[i])

proc coordinateNoise(seed: int32, stream: uint64, x, z: int): int32 =
  ## Returns a stable signed lattice value. This is one SplitMix64 round of
  ## a hashed coordinate, not a named stream.
  var rng = Rng(state: uint64(cast[uint32](seed)) xor stream)
  rng.state = rng.state xor uint64(x) * 0x632BE59BD9B4E019'u64
  rng.state = rng.state xor uint64(z) * 0x1C69B3F74AC4AE35'u64
  let value = rng.next()
  int32((value shr 53) and 0x7ff'u64) - MapBlendScale

proc valueNoise*(
    seed: int32,
    stream: uint64,
    x, z, spacing: int
): int32 =
  ## Samples deterministic smooth integer value noise on one lattice.
  doAssert spacing > 0, "noise spacing must be positive"
  let
    latticeX = floorDiv(x, spacing)
    latticeZ = floorDiv(z, spacing)
    amountX = smoothstep(
      int32(floorMod(x, spacing) * MapBlendScale div spacing))
    amountZ = smoothstep(
      int32(floorMod(z, spacing) * MapBlendScale div spacing))
    north = blendHeight(
      coordinateNoise(seed, stream, latticeX, latticeZ),
      coordinateNoise(seed, stream, latticeX + 1, latticeZ),
      amountX
    )
    south = blendHeight(
      coordinateNoise(seed, stream, latticeX, latticeZ + 1),
      coordinateNoise(seed, stream, latticeX + 1, latticeZ + 1),
      amountX
    )
  blendHeight(north, south, amountZ)
