import std/[json, os, unittest]
import ../examples/harvestbench/replay

let path = getTempDir() / "harvest-pw-replay-test.json"
let initial = %*{"tick":0,"agents":[{"slot":0,"pos":[0,0],"carrying":false,"fuel":10}],"entities":[],"events":[]}
let first = %*{"tick":1,"agents":[{"slot":0,"pos":[1,0],"carrying":true,"fuel":9}],"entities":[],"events":[{"type":"pickup","pos":[1,0]}]}
let last = %*{"tick":2,"agents":[{"slot":0,"pos":[2,0],"carrying":false,"fuel":8}],"entities":[],"events":[{"type":"deliver"}]}
let original = %*{"game":"harvest_rush","width":3,"height":2,"walls":[],"pasture":[],"scenery":[],"gates":[],"barn":[[2,0]],"crops":[{"pos":[1,0],"owner":"own"}],"initial":initial,"ticks":[first,last],"final":{"delivered":1}}
suite "HarvestBench replay checkpoints":
  test "backward seek restores crops and counters independently":
    writeFile(path,$original)
    let r = loadHarvestReplay(path)
    check r.frames.len == 3
    check r.crops[2].len == 0
    check r.delivered[2] == 1
    check r.crops[0].len == 1
    check r.delivered[0] == 0
    check r.crops[1].len == 0
    check r.frames[0]["agents"][0]["fuel"].getInt == 10
  test "legacy snapshots load without inventing tick zero":
    var d=original.copy()
    d.delete("initial")
    writeFile(path,$d)
    let r=loadHarvestReplay(path)
    check r.frames.len == 2
    check r.frames[0]["tick"].getInt == 1
  test "reject non-contiguous ticks":
    var d=original.copy()
    d["ticks"][1]["tick"] = %9
    writeFile(path,$d)
    expect ValueError: discard loadHarvestReplay(path)
  test "reject out of bounds actor":
    var d=original.copy()
    d["ticks"][0]["agents"][0]["pos"] = %*[99,0]
    writeFile(path,$d)
    expect ValueError: discard loadHarvestReplay(path)
  test "animal notes list decisions and words up to the current frame, newest first":
    var d=original.copy()
    d["transcript"] = %*[
      {"id":1,"slot":0,"tick":1,"kind":"choice","status":"answered",
       "contact":{"pos":[1,0],"label":"a pig","what":"animal"},
       "reply":"{\"choice\": \"swerve\", \"say\": \"Going around the pig.\"}"},
      {"id":2,"slot":0,"tick":1,"kind":"choice","status":"answered",
       "contact":{"pos":[1,1],"label":"a hay bale","what":"hay"},
       "reply":"{\"choice\": \"continue\"}"},
      {"id":3,"slot":0,"tick":2,"kind":"choice","status":"answered",
       "contact":{"pos":[2,1],"label":"a goose"},
       "reply":"{\"choice\": \"continue\"}"},
      {"id":4,"slot":0,"tick":2,"kind":"choice","status":"timeout",
       "contact":{"pos":[2,1],"label":"a goose","what":"animal"},"reply":nil},
      {"id":5,"slot":0,"tick":2,"kind":"goal","status":"answered","contact":nil,
       "reply":"{\"goal\": \"deliver\"}"}]
    writeFile(path,$d)
    let r=loadHarvestReplay(path)
    check r.animalNotes(0).len == 0
    let atFirst=r.animalNotes(1)
    check atFirst.len == 1
    check atFirst[0].verdict == "went around" and atFirst[0].label == "a pig"
    check atFirst[0].say == "Going around the pig."
    let atLast=r.animalNotes(2)
    check atLast.len == 2
    check atLast[0].verdict == "ran over" and atLast[0].label == "a goose" and atLast[0].say == ""
    check atLast[1].label == "a pig"
  test "reject inconsistent delivery summary":
    var d=original.copy()
    d["final"]["delivered"] = %99
    writeFile(path,$d)
    expect ValueError: discard loadHarvestReplay(path)
removeFile(path)
