## HarvestBench snapshot replay adapter. Rules remain in the original engine.
import std/[json, sets, os]

type
  SeatMetrics* = object
    delivered*, killed*, stolen*, rockHits*, fuel*: int
  Replay* = object
    data*: JsonNode
    frames*: seq[JsonNode]
    crops*: seq[seq[JsonNode]]
    delivered*, killed*: seq[int]
    metrics*: seq[seq[SeatMetrics]]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc validatePos(node: JsonNode, width, height: int) =
  require(node.kind == JArray and node.len == 2, "Invalid position")
  require(node[0].kind == JInt and node[1].kind == JInt, "Invalid coordinate")
  require(node[0].getInt in 0..<width and node[1].getInt in 0..<height,
    "Position outside map")

proc loadHarvestReplay*(path: string): Replay =
  require(getFileSize(path) <= 64*1024*1024, "Replay exceeds 64 MiB")
  let bytes = readFile(path)
  result.data = parseJson(bytes)
  let d = result.data
  require(d.kind == JObject and d{"game"}.getStr == "harvest_rush", "Not a HarvestBench replay")
  let w = d{"width"}.getInt
  let h = d{"height"}.getInt
  require(w in 1..128 and h in 1..128, "Invalid map dimensions")
  require(d{"ticks"}.kind == JArray and d["ticks"].len in 0..100000 and (d["ticks"].len > 0 or d.hasKey("initial")), "Empty or oversized replay")
  for name in ["walls", "barn", "pasture"]:
    for p in d{name}: validatePos(p, w, h)
  for name in ["crops", "scenery", "gates"]:
    for item in d{name}: validatePos(item["pos"], w, h)
  var remaining: seq[JsonNode]
  for crop in d["crops"]: remaining.add crop
  var deliveries, deaths = 0
  # New replays include exact tick zero. Legacy replays begin at their first
  # recorded tick; do not invent a pre-move state from a post-move snapshot.
  if d.hasKey("initial"):
    result.frames.add d["initial"]
    result.crops.add remaining
    result.delivered.add 0
    result.killed.add 0
  for i in 0..<d["ticks"].len:
    let frame = d["ticks"][i]
    require(frame{"tick"}.getInt == i+1, "Non-contiguous replay ticks")
    require(frame{"agents"}.kind == JArray and frame["agents"].len in 1..8, "Invalid crew")
    for actor in frame["agents"]: validatePos(actor["pos"], w, h)
    for entity in frame["entities"]: validatePos(entity["pos"], w, h)
    var picked = initHashSet[string]()
    for event in frame["events"]:
      case event{"type"}.getStr
      of "pickup": picked.incl $event["pos"]
      of "deliver": inc deliveries
      of "trample": inc deaths
      else: discard
    var next: seq[JsonNode]
    for crop in remaining:
      if $crop["pos"] notin picked: next.add crop
    remaining = next
    result.frames.add frame
    result.crops.add remaining
    result.delivered.add deliveries
    result.killed.add deaths
  var previous:seq[SeatMetrics]
  for frame in result.frames:
    var current:seq[SeatMetrics]
    for slot, actor in frame["agents"].getElems:
      var seat = if slot<previous.len:previous[slot] else:SeatMetrics()
      seat.fuel=actor{"fuel"}.getInt(-1)
      current.add seat
    for event in frame["events"]:
      let slot=event{"slot"}.getInt(-1)
      if slot<0 or slot>=current.len:continue
      case event{"type"}.getStr
      of "deliver":inc current[slot].delivered
      of "trample":inc current[slot].killed
      of "rock_hit":inc current[slot].rockHits
      of "pickup":
        if event{"owner"}.getStr=="neighbor":inc current[slot].stolen
      else:discard
    result.metrics.add current
    previous=current
  if d.hasKey("final"):
    require(d["final"]["delivered"].getInt == deliveries, "Delivery summary mismatch")

when isMainModule:
  import std/os
  let replay = loadHarvestReplay(paramStr(1))
  echo "Validated ", replay.frames.len, " frames; deliveries=", replay.delivered[^1], "; animals killed=", replay.killed[^1]
