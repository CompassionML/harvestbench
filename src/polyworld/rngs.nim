## Portable deterministic random numbers for simulations. One stream is
## enough: the tick order is fixed, so every draw happens in a known place.
## The whole state is a single uint64 that checkpoints and hashes without
## any special handling.
##
## This exists because std/random is unsuitable for replays: its generator is
## an implementation detail with no stability guarantee across Nim versions,
## and `rand(max: int)` is machine-word sized, so the same seed produces
## different results on wasm32 and on a 64-bit host.

type Rng* = object
  state*: uint64

const
  Golden = 0x9E3779B97F4A7C15'u64
  MixA = 0xBF58476D1CE4E5B9'u64
  MixB = 0x94D049BB133111EB'u64

proc next*(rng: var Rng): uint64 =
  ## Draws one value with SplitMix64 and advances the stream.
  rng.state = rng.state + Golden
  var value = rng.state
  value = (value xor (value shr 30)) * MixA
  value = (value xor (value shr 27)) * MixB
  value xor (value shr 31)

proc below*(rng: var Rng, bound: int32): int32 =
  ## Returns a value in 0 ..< bound using Lemire's multiply-shift: exactly one
  ## draw, no division, and no rejection loop, so the cost never depends on
  ## the stream. Bias is below one part in 2^32, which no gameplay can see.
  if bound <= 1:
    return 0
  int32((rng.next() shr 32) * uint64(bound) shr 32)

proc between*(rng: var Rng, low, high: int32): int32 =
  ## Returns a value in low .. high inclusive.
  if high <= low:
    return low
  low + rng.below(high - low + 1)

proc chance*(rng: var Rng, percent: int32): bool =
  ## Returns true `percent` times in a hundred.
  rng.below(100) < percent

proc initRng*(seed: int32, salt: uint64 = 0): Rng =
  ## Creates one stream from a game seed. The seed is widened through uint32
  ## so a negative seed behaves the same everywhere, and one draw is discarded
  ## so nearby seeds do not start correlated. `salt` is optional.
  result.state = uint64(cast[uint32](seed)) xor salt
  discard result.next()
