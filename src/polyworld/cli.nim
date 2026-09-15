## Shared command-line parsing for Polyworld games.
##
## Every game understands `--bot`, `--player`, `--replay`, `--record`,
## `--seed`, `--play`, `--speed`, `--windowSize`, `--vsync`, `--seconds`,
## `--minutes`, and `--ticks`. Duration flags all write `maximumTicks`.
## Each game runs its own argument loop, farms those flags through
## `takeCommonFlag`, and handles the rest itself.

import
  std/strutils

type
  BotGroup* = object
    path*: string
    count*: int

  GameOptions* = object
    botGroups*: seq[BotGroup]
    replayPath*: string
    recordPath*: string
    seed*: int32
    seconds*: int32
      ## Duration in seconds, kept in sync with `maximumTicks`.
    maximumTicks*: int32
      ## Match length in simulation ticks. `--seconds`, `--minutes`, and
      ## `--ticks` all write this field.
    speed*: int32
      ## Graphical simulation speed multiplier.
    verbose*: bool
    viewMode*: int32
      ## Spectator fog: 0 omniscient, 1 first side, 2 second side.
    spawnIntervalTicks*: int32
    pauseOnStart*: bool
      ## Graphical transport starts paused when true.
    windowWidth*: int32
      ## Graphical window width. Zero keeps the shared default.
    windowHeight*: int32
      ## Graphical window height. Zero keeps the shared default.
    vsync*: bool = true
      ## Graphical window waits for the display when true.
    playerSlot*: int32
      ## One-based human controller slot. Zero means bots fill every slot.

proc fail*(message: string) {.noreturn.} =
  ## Prints one command-line error and exits.
  quit(message)

proc argumentValue*(
    arguments: seq[string],
    index: var int,
    name: string
): string =
  ## Consumes and returns the required value after one flag.
  inc index
  if index >= arguments.len:
    fail(name & " requires a value")
  arguments[index]

proc parseInt32*(text, name: string): int32 =
  ## Parses one signed 32-bit integer flag value.
  var value: int64
  try:
    value = parseBiggestInt(text)
  except ValueError:
    fail(name & " must be an integer")
  if value < int32.low or value > int32.high:
    fail(name & " must fit int32")
  int32(value)

proc parsePositiveInt32*(text, name: string): int32 =
  ## Parses one integer flag value that must be greater than zero.
  result = parseInt32(text, name)
  if result <= 0:
    fail(name & " must be positive")

proc addBotSpec*(groups: var seq[BotGroup], specification: string) =
  ## Parses one bot path with an optional trailing instance count.
  if specification.len == 0:
    fail("--bot requires a path")
  var
    path = specification
    count = 1
  let separator = specification.rfind(':')
  if separator >= 0 and separator < specification.high:
    let suffix = specification[separator + 1 .. ^1]
    var numeric = true
    for character in suffix:
      if character notin {'0' .. '9'}:
        numeric = false
        break
    if numeric:
      path = specification[0 ..< separator]
      count = parseInt(suffix)
  if path.len == 0:
    fail("--bot requires a path")
  if count <= 0:
    fail("--bot count must be positive")
  groups.add BotGroup(path: path, count: count)

proc botCount*(groups: openArray[BotGroup]): int =
  ## Returns the expanded number of configured bot instances.
  for group in groups:
    result += group.count

proc botSources*(
    groups: openArray[BotGroup],
    count: static int
): array[count, string] =
  ## Loads and expands bot files into one source string per slot.
  var slot = 0
  for group in groups:
    let source = readFile(group.path)
    for _ in 0 ..< group.count:
      if slot >= count:
        fail("too many bots to expand")
      result[slot] = source
      inc slot
  if slot != count:
    fail("bot files do not fill every slot")

proc parseWindowSize*(text, name: string): (int32, int32) =
  ## Parses one `WIDTHxHEIGHT` window size, such as `800x400`.
  let separator = text.find({'x', 'X'})
  if separator <= 0 or separator >= text.high:
    fail(name & " must look like 800x400")
  (
    parsePositiveInt32(text[0 ..< separator], name),
    parsePositiveInt32(text[separator + 1 .. ^1], name)
  )

const
  SharedTickRate* = 24'i32
    ## Simulation ticks per second used by every Polyworld game.
  DefaultMinutes* = 20'i32
    ## Default match length in minutes.
  DefaultDurationTicks* = DefaultMinutes * 60 * SharedTickRate
    ## Twenty minutes at `SharedTickRate`, 28800 ticks.

proc ticksFromCount(count, scale: int32, name: string): int32 =
  ## Converts a positive count into ticks without overflowing int32.
  let ticks = int64(count) * int64(scale)
  if ticks > int32.high:
    fail(name & " is too large")
  int32(ticks)

proc setMaximumTicks*(options: var GameOptions, ticks: int32) =
  ## Writes the canonical tick duration and the derived second count.
  options.maximumTicks = ticks
  options.seconds = ticks div SharedTickRate

proc takeDurationFlag(
    options: var GameOptions,
    arguments: seq[string],
    index: var int,
    argument: string
): bool =
  ## Handles `--seconds`, `--minutes`, and `--ticks`.
  var
    name = ""
    text = ""
  if argument.startsWith("--seconds="):
    name = "--seconds"
    text = argument[10 .. ^1]
  elif argument.startsWith("--minutes="):
    name = "--minutes"
    text = argument[10 .. ^1]
  elif argument.startsWith("--ticks="):
    name = "--ticks"
    text = argument[8 .. ^1]
  else:
    case argument
    of "--seconds", "--minutes", "--ticks":
      name = argument
      text = arguments.argumentValue(index, argument)
    else:
      return false
  let count = parsePositiveInt32(text, name)
  case name
  of "--seconds":
    options.setMaximumTicks(ticksFromCount(count, SharedTickRate, name))
  of "--minutes":
    options.setMaximumTicks(
      ticksFromCount(count, 60 * SharedTickRate, name)
    )
  of "--ticks":
    options.setMaximumTicks(count)
  else:
    return false
  true

proc takePlayerFlag(options: var GameOptions, argument: string): bool =
  ## Handles `--player`, `--player:N`, and `--player=N`.
  var text = ""
  if argument == "--player":
    text = "1"
  elif argument.startsWith("--player:"):
    text = argument[9 .. ^1]
  elif argument.startsWith("--player="):
    text = argument[9 .. ^1]
  else:
    return false
  if options.playerSlot != 0:
    fail("only one --player allowed")
  if text.len == 0:
    fail("--player requires a slot")
  options.playerSlot = parsePositiveInt32(text, "--player")
  true

proc parsePlayFlag(text: string): bool =
  ## Parses `--play` as a boolean.
  case text.strip().toLowerAscii()
  of "true", "1", "yes", "on":
    result = true
  of "false", "0", "no", "off":
    result = false
  else:
    fail("--play must be true or false")

proc parseVsyncFlag(text: string): bool =
  ## Parses `--vsync` as on or off.
  case text.strip().toLowerAscii()
  of "true", "1", "yes", "on":
    result = true
  of "false", "0", "no", "off":
    result = false
  else:
    fail("--vsync must be on or off")

proc takeCommonFlag*(
    options: var GameOptions,
    arguments: seq[string],
    index: var int,
    argument: string
): bool =
  ## Handles one shared flag. Returns false when the game should try it.
  if argument.startsWith("--bot:"):
    options.botGroups.addBotSpec(argument[6 .. ^1])
    return true
  if argument.startsWith("--play="):
    options.pauseOnStart = not parsePlayFlag(argument[7 .. ^1])
    return true
  if argument.startsWith("--speed="):
    options.speed = parsePositiveInt32(argument[8 .. ^1], "--speed")
    return true
  if argument.startsWith("--windowSize:"):
    (options.windowWidth, options.windowHeight) =
      parseWindowSize(argument[13 .. ^1], "--windowSize")
    return true
  if argument.startsWith("--windowSize="):
    (options.windowWidth, options.windowHeight) =
      parseWindowSize(argument[13 .. ^1], "--windowSize")
    return true
  if argument.startsWith("--vsync:"):
    options.vsync = parseVsyncFlag(argument[8 .. ^1])
    return true
  if argument.startsWith("--vsync="):
    options.vsync = parseVsyncFlag(argument[8 .. ^1])
    return true
  if options.takeDurationFlag(arguments, index, argument):
    return true
  if options.takePlayerFlag(argument):
    return true
  case argument
  of "--":
    result = true
  of "--bot":
    options.botGroups.addBotSpec(
      arguments.argumentValue(index, "--bot")
    )
    result = true
  of "--replay":
    options.replayPath = arguments.argumentValue(index, "--replay")
    result = true
  of "--record":
    options.recordPath = arguments.argumentValue(index, "--record")
    result = true
  of "--seed":
    options.seed = parseInt32(
      arguments.argumentValue(index, "--seed"),
      "--seed"
    )
    result = true
  of "--play":
    options.pauseOnStart = not parsePlayFlag(
      arguments.argumentValue(index, "--play")
    )
    result = true
  of "--speed":
    options.speed = parsePositiveInt32(
      arguments.argumentValue(index, "--speed"),
      "--speed"
    )
    result = true
  of "--windowSize":
    (options.windowWidth, options.windowHeight) =
      parseWindowSize(
        arguments.argumentValue(index, "--windowSize"),
        "--windowSize"
      )
    result = true
  of "--vsync":
    options.vsync = parseVsyncFlag(
      arguments.argumentValue(index, "--vsync")
    )
    result = true
  else:
    result = false

proc validateGameOptions*(
    options: GameOptions,
    liveSlotCount: int,
    liveBotMessage: string
) =
  ## Checks replay exclusivity and the live-game bot count.
  when defined(headless):
    if options.playerSlot != 0:
      fail("--player requires the graphical client")
  if options.replayPath.len > 0:
    if options.botGroups.len > 0:
      fail("--replay cannot be used with --bot")
    if options.playerSlot != 0:
      fail("--replay cannot be used with --player")
    if options.recordPath.len > 0:
      fail("--replay cannot be recorded again")
  elif liveSlotCount > 0:
    if options.playerSlot != 0 and
        (options.playerSlot < 1 or
          options.playerSlot > liveSlotCount):
      fail("--player must be between 1 and " & $liveSlotCount)
    let
      needed =
        if options.playerSlot != 0:
          liveSlotCount - 1
        else:
          liveSlotCount
      count = options.botGroups.botCount
    if count != needed:
      if options.playerSlot != 0:
        fail(
          "live games with --player require " & $needed &
            " bots; configured " & $count
        )
      fail(liveBotMessage & "; configured " & $count)
