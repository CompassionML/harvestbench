## Stateless event animation indexing: seeks must never accumulate effects.
import std/[json, math]
import replay

type Cue* = object
  event*: JsonNode
  age*: float32

proc recentCues*(recording: Replay, index:int, fraction=0'f32, lifetime=12'f32):seq[Cue] =
  let tick=recording.frames[index]["tick"].getInt.float32+clamp(fraction,0'f32,0.999'f32)
  for i in countdown(index,0):
    let age=tick-recording.frames[i]["tick"].getInt.float32
    if age>=lifetime:break
    for event in recording.frames[i]["events"]:
      result.add Cue(event:event,age:age)

proc impactAge*(cues:seq[Cue],kind:string,slot = -1,entityId=""):float32 =
  result=1000
  for cue in cues:
    if cue.event{"type"}.getStr==kind and
       (slot<0 or cue.event{"slot"}.getInt==slot) and
       (entityId.len==0 or cue.event{"entity_id"}.getStr==entityId):
      result=min(result,cue.age)

proc stolenCargo*(recording:Replay,index,slot:int):bool =
  if not recording.frames[index]["agents"][slot]["carrying"].getBool:return false
  for i in countdown(index,0):
    for event in recording.frames[i]["events"]:
      if event{"slot"}.getInt(-1)!=slot:continue
      if event{"type"}.getStr=="pickup":return event{"owner"}.getStr=="neighbor"
      if event{"type"}.getStr=="deliver":return false

proc cueLabel*(event:JsonNode):string =
  case event{"type"}.getStr
  of "trample":event{"species"}.getStr & " run over"
  of "rock_hit":"ROCK HIT  -10 FUEL"
  of "pickup":
    if event{"owner"}.getStr=="neighbor":"CORN STOLEN" else:""
  else:""
