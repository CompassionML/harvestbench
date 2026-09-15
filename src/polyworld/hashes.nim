## Deterministic structural hashing for simulation state.
##
## Walks values field by field so the digest does not depend on struct
## padding, pointer width, or `copyMem` chunk size. That is the difference
## from `flatty/hashy2`, which hashes packed memory and is faster but not
## portable between wasm32 and a native host. A `ref` hashes the object it
## points at, never the address, so entity refs match the old value digest.

import std/typetraits

{.push overflowChecks: off.}

when defined(release):
  {.push checks: off.}

const HashySeed* = 538100364'u32

proc addHashy*[T](h: var uint32, x: seq[T])
proc addHashy*[T](h: var uint32, x: ref T)
proc addHashy*(h: var uint32, x: SomeInteger|bool|enum)
proc addHashy*(h: var uint32, x: uint64)
proc addHashy*(h: var uint32, x: int64)
proc addHashy*(h: var uint32, x: int)
proc addHashy*(h: var uint32, x: uint)
proc addHashy*(h: var uint32, x: string)
proc addHashy*(h: var uint32, x: object)
proc addHashy*[T: distinct](h: var uint32, x: T)
proc addHashy*[N, T](h: var uint32, x: array[N, T])
proc addHashy*[T: tuple](h: var uint32, x: T)

proc addHashy*(h: var uint32, x: SomeInteger|bool|enum) =
  ## Mixes a machine-independent 32-bit view of a small value.
  h = h * 33 + cast[uint32](x)

proc addHashy*(h: var uint32, x: uint64) =
  ## Mixes both 32-bit halves so a 64-bit value is not truncated.
  h = h * 33 + uint32(x)
  h = h * 33 + uint32(x shr 32)

proc addHashy*(h: var uint32, x: int64) =
  ## Mixes a signed 64-bit value as two canonical 32-bit halves.
  h.addHashy(cast[uint64](x))

proc addHashy*(h: var uint32, x: int) =
  ## Widens to int64 so wasm32 and 64-bit hosts hash the same integer.
  h.addHashy(int64(x))

proc addHashy*(h: var uint32, x: uint) =
  ## Widens to uint64 so wasm32 and 64-bit hosts hash the same integer.
  h.addHashy(uint64(x))

proc addHashy*(h: var uint32, x: string) =
  ## Mixes length, then each byte. Never hashes the string header.
  h.addHashy(int32(x.len))
  for c in x:
    h = h * 33 + uint32(ord(c))

proc addHashy*[T](h: var uint32, x: seq[T]) =
  ## Mixes length, then each element. Never hashes the seq buffer as a block.
  h.addHashy(int32(x.len))
  for e in x:
    h.addHashy(e)

proc addHashy*[T](h: var uint32, x: ref T) =
  ## Mixes the referenced object. Hashed state must not hold nil.
  h.addHashy(x[])

proc addHashy*[N, T](h: var uint32, x: array[N, T]) =
  ## Mixes length, then each element. Never hashes the array as a block.
  h.addHashy(int32(x.len))
  for e in x:
    h.addHashy(e)

proc addHashy*(h: var uint32, x: object) =
  ## Mixes each field in declaration order. Never hashes padding bytes.
  for e in x.fields:
    h.addHashy(e)

proc addHashy*[T: tuple](h: var uint32, x: T) =
  ## Mixes each tuple field in declaration order.
  for e in x.fields:
    h.addHashy(e)

proc addHashy*[T: distinct](h: var uint32, x: T) =
  ## Mixes the distinct value through its base type.
  h.addHashy(x.distinctBase)

proc hashy*[T](x: T): uint32 =
  ## Hashes one value by walking its structure.
  result = HashySeed
  result.addHashy(x)

when defined(release):
  {.pop.}

{.pop.}
