## Shared Polyworld replay header, Flatty payload, file I/O, and action tape.

import
  std/[os, strutils, times],
  flatty

const
  ReplayMagic* = "POLYWORLDREPLAY"
  ReplayFileVersion* = 1'u16
  DefaultMaxReplayBytes* = 64 * 1024 * 1024
  MaximumReplayGameBytes* = 64
  HeaderFixedBytes = 6

type
  ReplayError* = object of CatchableError

  ReplayFileHeader* = object
    formatVersion*: uint16
    game*: string
    gameVersion*: uint16

proc fail(message: string) {.noreturn.} =
  ## Raises one replay-specific error.
  raise newException(ReplayError, message)

proc addUint16(bytes: var string, value: uint16) =
  ## Appends one portable little-endian header value.
  bytes.add char(value and 0xff)
  bytes.add char(value shr 8)

proc readUint16(bytes: string, offset: int): uint16 =
  ## Reads one checked little-endian header value.
  if offset < 0 or offset + 2 > bytes.len:
    fail("Polyworld replay header is truncated")
  uint16(bytes[offset].ord) or uint16(bytes[offset + 1].ord shl 8)

proc validateGame(game: string) =
  ## Validates one stable game identifier used in the common header.
  if game.len == 0 or game.len > MaximumReplayGameBytes:
    fail("Polyworld replay game identifier has an invalid length")
  for character in game:
    if character notin {'a' .. 'z', '0' .. '9', '_'}:
      fail("Polyworld replay game identifier is invalid: " & game)

proc replayFileHeader*(bytes: string): ReplayFileHeader =
  ## Reads the common header without decoding the game-specific payload.
  if bytes.len < ReplayMagic.len or
      bytes[0 ..< ReplayMagic.len] != ReplayMagic:
    fail("not a Polyworld replay file")
  let
    fixedOffset = ReplayMagic.len
    minimumBytes = fixedOffset + HeaderFixedBytes
  if bytes.len < minimumBytes:
    fail("Polyworld replay header is truncated")
  result.formatVersion = bytes.readUint16(fixedOffset)
  result.gameVersion = bytes.readUint16(fixedOffset + 2)
  let gameBytes = int(bytes.readUint16(fixedOffset + 4))
  if gameBytes == 0 or gameBytes > MaximumReplayGameBytes or
      minimumBytes + gameBytes > bytes.len:
    fail("Polyworld replay game identifier has an invalid length")
  result.game = bytes[minimumBytes ..< minimumBytes + gameBytes]
  result.game.validateGame()

proc loadReplayFileHeader*(path: string): ReplayFileHeader =
  ## Reads a replay file's common header without decoding its payload.
  if path.len == 0:
    fail("replay input path is empty")
  readFile(path).replayFileHeader()

proc payloadOffset(bytes: string, header: ReplayFileHeader): int =
  ## Returns the first byte of a validated game-specific payload.
  ReplayMagic.len + HeaderFixedBytes + header.game.len

proc validateHeader(
    header: ReplayFileHeader,
    expectedGame: string,
    expectedGameVersion: uint16
) =
  ## Rejects an incompatible replay before its payload is decoded.
  expectedGame.validateGame()
  if header.formatVersion != ReplayFileVersion:
    fail(
      "unsupported Polyworld replay format version " &
      $header.formatVersion & "; expected " & $ReplayFileVersion
    )
  if header.game != expectedGame:
    fail(
      "replay belongs to '" & header.game & "', not '" &
      expectedGame & "'"
    )
  if header.gameVersion != expectedGameVersion:
    fail(
      "replay game version " & $header.gameVersion & " for '" &
      header.game & "' is unsupported; expected " &
      $expectedGameVersion
    )

proc encodeReplayFile*[T](
    game: string,
    gameVersion: uint16,
    data: T,
    maxBytes = DefaultMaxReplayBytes
): string =
  ## Encodes one game payload behind the common Polyworld header.
  game.validateGame()
  if gameVersion == 0:
    fail("Polyworld replay game version must be positive")
  result = ReplayMagic
  result.addUint16(ReplayFileVersion)
  result.addUint16(gameVersion)
  result.addUint16(uint16(game.len))
  result.add game
  result.add data.toFlatty()
  if result.len > maxBytes:
    fail("encoded replay exceeds the file size limit")

proc decodeReplayFile*[T](
    game: string,
    gameVersion: uint16,
    bytes: string,
    replayType: typedesc[T],
    maxBytes = DefaultMaxReplayBytes
): T =
  ## Checks the common header before decoding one game payload.
  if bytes.len > maxBytes:
    fail("replay exceeds the file size limit")
  let header = bytes.replayFileHeader()
  header.validateHeader(game, gameVersion)
  let offset = bytes.payloadOffset(header)
  bytes[offset .. ^1].fromFlatty(replayType)

proc saveReplayFile*[T](
    path,
    game: string,
    gameVersion: uint16,
    data: T,
    maxBytes = DefaultMaxReplayBytes
) =
  ## Writes one game payload with the common Polyworld header.
  if path.len == 0:
    fail("replay output path is empty")
  writeFile(path, encodeReplayFile(game, gameVersion, data, maxBytes))

proc loadReplayFile*[T](
    path,
    game: string,
    gameVersion: uint16,
    replayType: typedesc[T],
    maxBytes = DefaultMaxReplayBytes
): T =
  ## Loads a file after checking its Polyworld and game identity.
  if path.len == 0:
    fail("replay input path is empty")
  decodeReplayFile(
    game,
    gameVersion,
    readFile(path),
    replayType,
    maxBytes
  )

type
  ReplayHashCheck* = object
    ## Counts hash mismatches while playback continues past the first one.
    mismatches*: int32
    firstTick*: int32
    error*: string

  TapeHeader*[Setup] = object
    ## Versions, creation time, and the game's immutable match setup.
    formatVersion*: uint16
    gameVersion*: uint16
    createdUnixMs*: int64
    setup*: Setup

  ActionTape*[Setup, Action] = object
    ## Hash count is the recorded duration, up to `setup.maximumTicks`.
    ## Setup stays unchanged when a match ends early or playback rewinds.
    header*: TapeHeader[Setup]
    actions*: seq[Action]
    hashes*: seq[uint64]

  TapeRecorder*[Setup, Action] = ref object
    ## Appends commands and hashes to one in-memory tape.
    data*: ActionTape[Setup, Action]

  TapePlayer*[Setup, Action] = ref object
    ## Walks one tape's commands in tick order.
    data*: ActionTape[Setup, Action]
    actionIndex*: int

proc appendAction*[T](
    actions: var seq[T],
    action: T,
    maxActions: int
) =
  ## Appends one command. `T` must have a `tick` field.
  if actions.len >= maxActions:
    fail("replay action limit exceeded")
  if actions.len > 0 and action.tick < actions[^1].tick:
    fail("replay actions move backward in time")
  actions.add action

proc appendHash*(
    hashes: var seq[uint64],
    hash: uint64,
    maximumTicks: uint32,
    maxHashes: int
) =
  ## Appends the canonical hash for one completed simulation tick.
  if maximumTicks > 0 and uint64(hashes.len) >= uint64(maximumTicks):
    fail("replay already has a hash for every configured tick")
  if hashes.len >= maxHashes:
    fail("replay hash limit exceeded")
  hashes.add hash

proc replayFinished*(actionIndex, actionCount: int): bool {.inline.} =
  ## Returns whether every recorded command has been consumed.
  actionIndex >= actionCount

proc actionIndexAfter*[T](
    actions: openArray[T],
    tick: uint32
): int =
  ## Returns the cursor after every command at or before `tick`.
  ##
  ## Live recording never advances a player cursor, so a seek restore must
  ## recompute this from the tape instead of trusting `actionIndex`.
  result = 0
  while result < actions.len and actions[result].tick <= tick:
    inc result

proc takeActionAt*[T](
    actions: openArray[T],
    actionIndex: var int,
    tick: uint32,
    action: var T
): bool =
  ## Consumes one command at an exact tick without allocating a sequence.
  if replayFinished(actionIndex, actions.len):
    return false
  let next = actions[actionIndex]
  if next.tick < tick:
    fail("replay playback skipped an action tick")
  if next.tick != tick:
    return false
  action = next
  inc actionIndex
  true

proc hashAt*(
    hashes: openArray[uint64],
    tick: uint32,
    hash: var uint64
): bool =
  ## Reads the recorded hash for one completed tick.
  if tick == 0:
    return false
  let index = int(tick) - 1
  if index >= hashes.len:
    return false
  hash = hashes[index]
  true

proc checkReplayHash*(
    hashes: openArray[uint64],
    tick: uint32,
    actual: uint64,
    check: var ReplayHashCheck
) =
  ## Compares one tick, prints the first mismatch, and keeps going.
  var expected: uint64
  if not hashes.hashAt(tick, expected) or expected == actual:
    return
  inc check.mismatches
  if check.mismatches > 1:
    return
  check.firstTick = int32(tick)
  check.error =
    "replay hash mismatch at tick " & $tick & ": expected " &
    expected.toHex(16) & ", got " & actual.toHex(16)
  echo "error: ", check.error

proc requireReplayComplete*(
    check: ReplayHashCheck,
    tick: uint32,
    recordedTicks: int
) =
  ## Rejects incomplete playback or any recorded hash divergence.
  if uint64(tick) != uint64(recordedTicks):
    fail("replay simulation ended at a different tick")
  if check.mismatches > 0:
    fail(
      $check.mismatches & " replay hash mismatches, first at tick " &
      $check.firstTick
    )

proc initActionTape*[Setup, Action](
    setup: Setup,
    formatVersion,
    gameVersion: uint16
): ActionTape[Setup, Action] =
  ## Creates an empty tape with a versioned deterministic setup.
  result.header = TapeHeader[Setup](
    formatVersion: formatVersion,
    gameVersion: gameVersion,
    createdUnixMs: toUnix(getTime()) * 1000,
    setup: setup
  )

proc initTapeRecorder*[Setup, Action](
    setup: Setup,
    formatVersion,
    gameVersion: uint16
): TapeRecorder[Setup, Action] =
  ## Creates an in-memory recorder for one match or expedition.
  TapeRecorder[Setup, Action](
    data: initActionTape[Setup, Action](
      setup,
      formatVersion,
      gameVersion
    )
  )

proc recordHash*[Setup, Action](
    recorder: TapeRecorder[Setup, Action],
    hash: uint64,
    maxHashes: int
) =
  ## Appends the canonical simulation hash for one completed tick.
  if recorder == nil:
    return
  recorder.data.hashes.appendHash(
    hash,
    recorder.data.header.setup.maximumTicks,
    maxHashes
  )

proc requireTapeVersion*[Setup](
    header: TapeHeader[Setup],
    formatVersion,
    gameVersion: uint16
) =
  ## Rejects a tape whose format or game version does not match this build.
  if header.formatVersion != formatVersion:
    fail("unsupported replay format version")
  if header.gameVersion != gameVersion:
    fail("unsupported replay game version")

proc initTapePlayer*[Setup, Action](
    tape: ActionTape[Setup, Action]
): TapePlayer[Setup, Action] =
  ## Creates a playback cursor over one tape. Does not validate.
  TapePlayer[Setup, Action](data: tape)

proc finished*[Setup, Action](
    player: TapePlayer[Setup, Action]
): bool =
  ## Returns whether every recorded command has been consumed.
  player == nil or
    replayFinished(player.actionIndex, player.data.actions.len)

proc syncCursor*[Setup, Action](
    player: TapePlayer[Setup, Action],
    tick: uint32
) =
  ## Points the cursor past every command at or before `tick`.
  if player == nil:
    return
  player.actionIndex = player.data.actions.actionIndexAfter(tick)

proc takeActionAt*[Setup, Action](
    player: TapePlayer[Setup, Action],
    tick: uint32,
    action: var Action
): bool =
  ## Consumes one command at an exact tick without allocating a sequence.
  if player == nil:
    return false
  player.data.actions.takeActionAt(player.actionIndex, tick, action)

proc hashAt*[Setup, Action](
    player: TapePlayer[Setup, Action],
    tick: uint32,
    hash: var uint64
): bool =
  ## Reads the recorded hash for one completed tick.
  if player == nil:
    return false
  player.data.hashes.hashAt(tick, hash)

proc actionsAt*[Setup, Action](
    player: TapePlayer[Setup, Action],
    tick: uint32
): seq[Action] =
  ## Consumes and returns every command recorded for one exact tick.
  var action: Action
  while player.takeActionAt(tick, action):
    result.add action

