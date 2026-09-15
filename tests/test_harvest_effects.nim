import std/[json, os, unittest]
import ../examples/harvestbench/[replay, effects]
let file=getTempDir()/"harvest-effects-test.json"
let initial = %*{"tick":0,"agents":[{"slot":0,"pos":[0,0],"carrying":false,"fuel":30}],"entities":[],"events":[]}
var d = %*{"game":"harvest_rush","width":3,"height":2,"walls":[],"pasture":[],"scenery":[],"gates":[],"barn":[[2,0]],"crops":[{"pos":[1,0],"owner":"neighbor"}],"initial":initial,"ticks":[],"final":{"delivered":1}}
for tick in 1..5:
  var frame=initial.copy()
  frame["tick"] = %tick
  frame["agents"][0]["carrying"] = %(tick==3)
  case tick
  of 1:frame["events"] = %*[{"type":"rock_hit","slot":0,"pos":[0,0]}]
  of 2:frame["events"] = %*[{"type":"trample","slot":0,"entity_id":"pig","pos":[0,0]}]
  of 3:frame["events"] = %*[{"type":"pickup","slot":0,"owner":"neighbor","pos":[1,0]}]
  of 4:frame["events"] = %*[{"type":"deliver","slot":0}]
  else:discard
  d["ticks"].add frame
writeFile(file,$d)
let r=loadHarvestReplay(file)
suite "Event-driven presentation":
  test "impacts do not appear before their recorded tick":
    check r.recentCues(0).len==0
    check r.recentCues(1).impactAge("trample",entityId="pig")==1000
    check r.recentCues(2).impactAge("trample",entityId="pig")==0
  test "fractional replay time advances an impact and seek restores it":
    check r.recentCues(2,0.5).impactAge("trample",entityId="pig")==0.5
    check r.recentCues(4).impactAge("trample",entityId="pig")==2
    check r.recentCues(2).impactAge("trample",entityId="pig")==0
  test "old effects expire":
    check r.recentCues(5,lifetime=2).impactAge("rock_hit")==1000
  test "cargo changes only on actual pickup and delivery":
    check not r.stolenCargo(2,0)
    check r.stolenCargo(3,0)
    check not r.stolenCargo(4,0)
  test "score and graph samples are independent checkpoints":
    check r.metrics[4][0].delivered==1
    check r.metrics[4][0].killed==1
    check r.metrics[4][0].stolen==1
    check r.metrics[4][0].rockHits==1
    check r.metrics[0][0].delivered==0
    check r.metrics[0][0].killed==0
    check r.metrics[0][0].stolen==0
removeFile(file)
