## Polyworld spectator: uses the same renderer and transport as GOTA/Paintbot.
import std/[json, math, os, strutils, times]
import chroma, opengl, pixie, silky, vmath, windy
import polyworld/[actioncam, common, gameuis, inputs, player, shapes, viewers]
import replay, terrain, animals, effects, hud, models
import pixie/fileformats/svg
import polyworld/[quadterrain, shadows]

var
  replayPath = "tmp/demo/replay.json"
  paused = false
  live = false
for i in 1..paramCount():
  if paramStr(i) == "--replay" and i < paramCount(): replayPath = paramStr(i+1)
  if paramStr(i) == "--paused": paused = true
  if paramStr(i) == "--live": live = true
var recording = loadHarvestReplay(replayPath)
let width = recording.data["width"].getInt.float32
let height = recording.data["height"].getInt.float32
createDir(TmpRoot)
let atlasPath = TmpRoot / "harvestbench.atlas.png"
let builder = newHudAtlas(2048)
builder.addDefaultFonts()
const farmIcons = [("farm-corn",staticRead("icons/corn.svg")),
                     ("farm-kill",staticRead("icons/kill.svg")),
                     ("farm-fuel",staticRead("icons/fuel.svg"))]
for (name, data) in farmIcons:
  if not builder.addImage(name, newImage(parseSvg(data))):
    raise newException(ValueError,"Farm icons do not fit in the HUD atlas")
builder.write(atlasPath)
let (window, sk) = initGameWindow("HarvestBench", atlasPath, ivec2(1440, 900))
initFarmTerrain(recording.data)
initFarmModels()
var renderer = initShapeRenderer()
renderer.opaque = true
var transport = initPlayer(live, (if live: recording.data["max_ticks"].getInt else: recording.frames.len-1).int32, playing = not paused)
transport.sync(0, (recording.frames.len-1).int32, false)
var cameraControl = initActionCam(minDistance=12, maxDistance=50)
cameraControl.enabled = false
var followSelection = false
var yaw = 0.72'f32
var pitch = 0.72'f32
var distance = 48'f32
var target = vec3(0,0,0)
var frameIndex = 0
var lastFrame = epochTime()
var screenshotFrame = 0
var selected = 0
var selection=Selection(kind:"tractor",key:"0")
var layout:HudLayout
var firstFrame = true
var uiScale = 1'f32
  ## Device pixels per CSS pixel. The HUD is laid out in CSS pixels so the
  ## embed reads the same on every screen; Silky scales it up at draw time.
var ui = vec2(1440,900)
  ## The window in CSS pixels.

when defined(emscripten):
  {.emit: """
  #include <emscripten.h>
  EM_JS(int, harvestReplayChanged, (), {
    if (!Module.harvestReload) return 0;
    Module.harvestReload = false; return 1;
  });
  """.}
  proc harvestReplayChanged(): cint {.importc, nodecl.}

proc point(pos: JsonNode, y=0.0'f32): Vec3 =
  vec3((pos[0].getInt.float32-width/2+0.5)*TileSize.float32, y, (pos[1].getInt.float32-height/2+0.5)*TileSize.float32)

proc shade(c: ColorRGBX, f: float32): ColorRGBX =
  rgbx(uint8(c.r.float32*f),uint8(c.g.float32*f),uint8(c.b.float32*f),c.a)

proc box(p, size: Vec3, color: ColorRGBX) =
  let a=p-vec3(size.x/2,0,size.z/2)
  let b=a+vec3(size.x,0,0)
  let c=b+vec3(0,0,size.z)
  let d=a+vec3(0,0,size.z)
  let up=vec3(0,size.y,0)
  renderer.addQuad(a+up,b+up,c+up,d+up,color)
  renderer.addQuad(a,b,b+up,a+up,shade(color,0.72))
  renderer.addQuad(b,c,c+up,b+up,shade(color,0.85))
  renderer.addQuad(c,d,d+up,c+up,shade(color,0.65))
  renderer.addQuad(d,a,a+up,d+up,shade(color,0.8))

var visualFraction=0'f32
var visualTick=0'f32
var cues:seq[Cue]

proc entityPhase(entity:JsonNode):float32 =
  for ch in entity["id"].getStr:result+=ch.ord.float32*0.17

proc deathAge(entity:JsonNode):float32 =
  if entity["alive"].getBool:return 0
  for i in countdown(frameIndex,0):
    for event in recording.frames[i]["events"]:
      if event{"type"}.getStr=="trample" and event{"entity_id"}.getStr==entity["id"].getStr:
        return visualTick-recording.frames[i]["tick"].getInt.float32
  visualTick

proc entityPosition(entity:JsonNode):Vec3 =
  result=point(entity["pos"])
  if entity["kind"].getStr=="creature":
    result+=animalWalk((visualTick-deathAge(entity))/6,entityPhase(entity))

proc rotBox(center, size: Vec3, yaw: float32, color: ColorRGBX) =
  ## A box turned about y, for the cargo basket that trails a tractor.
  let c=cos(yaw)
  let sn=sin(yaw)
  proc at(dx,dz:float32):Vec3 = center+vec3(dx*c+dz*sn,0,-dx*sn+dz*c)
  let a=at(-size.x/2,-size.z/2)
  let b=at(size.x/2,-size.z/2)
  let cc=at(size.x/2,size.z/2)
  let d=at(-size.x/2,size.z/2)
  let up=vec3(0,size.y,0)
  renderer.addQuad(a+up,b+up,cc+up,d+up,color)
  renderer.addQuad(a,b,b+up,a+up,shade(color,0.72))
  renderer.addQuad(b,cc,cc+up,b+up,shade(color,0.85))
  renderer.addQuad(cc,d,d+up,cc+up,shade(color,0.65))
  renderer.addQuad(d,a,a+up,d+up,shade(color,0.8))

var lastHeading: array[4, float32]

proc agentHeading(slot: int): float32 =
  ## Where the tractor last drove, held while it stands still.
  let here = recording.frames[frameIndex]["agents"][slot]["pos"]
  var i = frameIndex - 1
  while i >= 0 and i >= frameIndex - 8:
    let there = recording.frames[i]["agents"][slot]["pos"]
    if there != here:
      let dx = (here[0].getInt - there[0].getInt).float32
      let dz = (here[1].getInt - there[1].getInt).float32
      lastHeading[slot] = arctan2(dx, dz)
      break
    dec i
  lastHeading[slot]

proc animalHeight(species: string): float32 =
  case species
  of "cow": 1.35
  of "pig", "boar": 0.9
  of "sheep": 1.0
  of "chicken": 0.55
  of "goose": 0.75
  of "wild_goose": 0.85
  of "duck": 0.5
  of "rabbit": 0.45
  of "squirrel": 0.4
  of "mouse": 0.22
  of "opossum": 0.32
  else: 0.7

proc drawFarm() =
  renderer.clear()
  clearFarm()
  for p in recording.data["walls"]: box(point(p),vec3(0.85,0.6,0.85),rgbx(115,119,109,255))
  for s in recording.data["scenery"]:
    let p=point(s["pos"])
    let kind=s["type"].getStr
    if kind.contains("tree"):
      discard # Rendered by the shared terrain tree pass.
    elif kind.contains("fence"):
      let wood=rgbx(201,180,137,255)
      box(p,vec3(0.09,0.62,0.09),wood)
      for neighbor in recording.data["scenery"]:
        if neighbor["type"].getStr != "fence": continue
        let q=point(neighbor["pos"])
        let delta=q-p
        if (abs(delta.x-TileSize.float32)<0.01 and abs(delta.z)<0.01) or
           (abs(delta.z-TileSize.float32)<0.01 and abs(delta.x)<0.01):
          for y in [0.25'f32,0.49]:
            box((p+q)*0.5+vec3(0,y,0),vec3(abs(delta.x)+0.06,0.065,abs(delta.z)+0.06),wood)
    else: box(p,vec3(0.8,0.65,0.7),rgbx(128,130,118,255))
  if recording.data["barn"].len > 0:
    # The barn model's long side runs along the delivery tiles; its height
    # follows its width so a long barn stretches rather than towers.
    var p=vec3(0)
    var lo=vec3(float32.high)
    var hi=vec3(float32.low)
    for tile in recording.data["barn"]:
      let q=point(tile)
      p+=q
      lo=min(lo,q)
      hi=max(hi,q)
    p=p/recording.data["barn"].len.float32
    let alongX=(hi.x-lo.x)>=(hi.z-lo.z)
    let length=(if alongX:hi.x-lo.x else:hi.z-lo.z)+TileSize.float32+0.6
    let across=TileSize.float32*1.35
    let size=vec3(across/1.028,across/1.028*1.05,length/1.221)
    placeFarm("barn",p,if alongX:PI.float32/2 else:0'f32,size)
  # Two tyre ruts ride the lane's curve so the road reads as driven dirt.
  proc world(c: Vec2, y: float32): Vec3 =
    vec3((c.x-width/2)*TileSize.float32,y,(c.y-height/2)*TileSize.float32)
  let rut=rgbx(118,88,54,110)
  let lane=farmLane()
  for side in [-0.36'f32,0.36]:
    for i in 1..<lane.len:
      let a=lane[i-1]
      let b=lane[i]
      let t=normalize(b-a)
      let n=vec2(-t.y,t.x)*side
      if inFarmPlot(a) and inFarmPlot(b): continue
      renderer.addLine(world(a+n,0.014),world(b+n,0.014),rut,0.06)
  # Planting furrows: short runs that stop at the plot's curved edge.
  let furrow=rgbx(109,87,51,90)
  for (c,r) in [(vec2(3.0,7.0),vec2(2.1,4.1)),(vec2(18.5,12.0),vec2(2.6,2.1))]:
    var x=c.x-r.x+0.1
    while x<c.x+r.x:
      var z=c.y-r.y
      var runStart= -1'f32
      while z<=c.y+r.y+0.25:
        let inside=z<=c.y+r.y and inFarmPlot(vec2(x,z)) and not onFarmLane(vec2(x,z))
        if inside and runStart<0: runStart=z
        if not inside and runStart>=0:
          if z-runStart>0.6:
            renderer.addLine(world(vec2(x,runStart+0.15),0.012),world(vec2(x,z-0.4),0.012),furrow,0.017)
          runStart= -1'f32
        z+=0.25
      x+=0.32
  for crop in recording.crops[frameIndex]:
    let p=point(crop["pos"])
    # Four corn plants per standing crop tile, each turned a little so the
    # rows do not read as copies.
    var k=0
    for dx in [-0.42'f32,0.42]:
      for dz in [-0.42'f32,0.42]:
        let turn=((crop["pos"][0].getInt*7+crop["pos"][1].getInt*13+k) mod 4).float32*PI.float32/2
        placeFarm("corn",p+vec3(dx,0.0,dz),turn,1.7)
        inc k
  let frame=recording.frames[frameIndex]
  for entity in frame["entities"]:
    let p=point(entity["pos"])
    case entity["kind"].getStr
    of "creature":
      let species=entity{"species"}.getStr(entity{"type"}.getStr)
      let alive=entity["alive"].getBool
      var phase=0'f32
      for ch in entity["id"].getStr:phase+=ch.ord.float32*0.17
      if hasFarmModel(species):
        let seconds=(visualTick-deathAge(entity))/6
        # Each animal keeps the heading its phase gives it and only sways a
        # little, instead of turning with a circular walk.
        let yaw=phase+0.08*sin(seconds*0.45)
        let h=animalHeight(species)
        let tint=if species=="opossum":color(0.62,0.6,0.62,1) else:color(1,1,1,1)
        if alive:
          let breath=1+0.03*sin(visualTick*0.9+phase)
          placeFarm(species,entityPosition(entity),yaw,vec3(h,h*breath,h),tint)
        else:
          renderer.addCircle(p+vec3(0,0.015,0),0.32+0.08*min(deathAge(entity),3'f32),rgbx(118,22,24,215))
          placeFarm(species,p,yaw,h,tint,roll=PI.float32/2)
      else:
        cuteAnimal(renderer,p,species,alive,visualTick/6,phase,deathAge(entity))
    of "rock":
      var turn=0'f32
      for ch in entity["id"].getStr:turn+=ch.ord.float32*0.31
      placeFarm("rock",p,turn,vec3(0.52,0.62,0.42))
    else:
      if entity["alive"].getBool:
        placeFarm("hay",p,0,vec3(1.7,0.8,1.7),color(1.35,1.25,0.9,1))
      else:
        placeFarm("hay",p,0,vec3(1.8,0.28,1.8),color(1.35,1.25,0.9,1))
  for actor in frame["agents"]:
    var p=point(actor["pos"])
    let slot=actor["slot"].getInt
    let hit=cues.impactAge("rock_hit",slot=slot)
    if hit<6:
      let decay=1-hit/6
      p+=vec3(sin(hit*16)*0.13*decay,abs(sin(hit*11))*0.08*decay,cos(hit*19)*0.06*decay)
    let flash=hit<5 and (hit*5).int mod 2==0
    let yaw=agentHeading(slot)
    placeFarm("tractor_" & $(slot mod 4),p,yaw,2.0,
      if flash:color(1.6,0.75,0.65,1) else:color(1,1,1,1))
    # The load shows on the model: a wooden basket towed behind the tractor,
    # filled with ears of corn when it carries. Empty tractors tow the bare rack.
    let back=vec3(-sin(yaw),0,-cos(yaw))
    let side=vec3(cos(yaw),0,-sin(yaw))
    let cargo=p+back*1.75
    rotBox(cargo+vec3(0,0.42,0),vec3(1.45,0.1,1.1),yaw,rgbx(128,91,53,255))
    for dz in [-0.5'f32,0.5]:rotBox(cargo+back*dz+vec3(0,0.52,0),vec3(1.5,0.5,0.1),yaw,rgbx(188,141,78,255))
    for dx in [-0.68'f32,0.68]:rotBox(cargo+side*dx+vec3(0,0.52,0),vec3(0.1,0.5,1.1),yaw,rgbx(188,141,78,255))
    for leg in [back*0.45+side*0.6,back*0.45-side*0.6,back*(-0.45)+side*0.6,back*(-0.45)-side*0.6]:
      box(cargo+leg,vec3(0.1,0.42,0.1),rgbx(70,52,36,255))
    if actor["carrying"].getBool:
      let stolen=recording.stolenCargo(frameIndex,slot)
      for dx in [-0.35'f32,0,0.35]:
        for dz in [-0.3'f32,0,0.3]:cornCob(renderer,cargo+side*dx+back*dz+vec3(0,0.62,0),scale=2)
      if stolen:renderer.addCircle(p+vec3(0,0.018,0),0.55,rgbx(239,167,39,75))
  for cue in cues:
    let event=cue.event
    let kind=event{"type"}.getStr
    if kind notin ["trample","rock_hit","pickup"]:continue
    if kind=="pickup" and event{"owner"}.getStr!="neighbor":continue
    let t=cue.age/6
    if t>1.5:continue
    let origin=point(event["pos"])
    if kind=="pickup":
      let slot=event["slot"].getInt
      let destination=point(frame["agents"][slot]["pos"])+vec3(0.18,0.65,0)
      for j in 0..4:
        let u=clamp((t-j.float32*0.06)/0.65,0'f32,1'f32)
        if u>=1:continue
        let p=mix(origin+vec3(0,0.35,0),destination,u)+vec3(0,sin(u*PI.float32)*0.65,0)
        box(p,vec3(0.08,0.20,0.08),rgbx(255,202,51,255))
    else:
      for j in 0..8:
        let angle=j.float32*2*PI.float32/9
        let radius=0.13+t*(0.45+(j mod 3).float32*0.12)
        let y=if kind=="rock_hit":0.35+t*0.65 else:0.1+sin(min(t,1'f32)*PI.float32)*0.28
        let p=origin+vec3(cos(angle)*radius,y,sin(angle)*radius)
        let size=(if kind=="rock_hit":0.075'f32 else:0.12'f32)*(1-t/1.6)
        box(p,vec3(size),if kind=="rock_hit" and t<0.4:rgbx(255,188,68,235) elif kind=="rock_hit":rgbx(99,102,100,140) else:rgbx(197,169,112,160))
  for gate in recording.data["gates"]:
    var opened=false
    for actor in frame["agents"]:
      if actor["pos"]==gate["plate"]: opened=true
    renderer.addSquare(point(gate["plate"],0.035),0.75,rgbx(194,169,108,255))
    if not opened: box(point(gate["pos"]),vec3(0.9,0.65,0.1),rgbx(193,137,77,255))

proc selectedPosition():Vec3 =
  if selection.kind=="tractor":
    return point(recording.frames[frameIndex]["agents"][parseInt(selection.key)]["pos"])
  if selection.kind=="entity":
    for entity in recording.frames[frameIndex]["entities"]:
      if entity["id"].getStr==selection.key:return entityPosition(entity)
  if selection.pos!=nil:return point(selection.pos)
  vec3(0)

proc pickObject(vp:Mat4) =
  if not window.mousePressed(MouseLeft):return
  let mouse=window.mousePos.vec2
  let css=mouse/uiScale
  if css.y<layout.headerH or css.y>ui.y-layout.ribbonH or
     css.x>ui.x-layout.sidebarW-(if layout.compact:0'f32 else:24'f32):return
  var best=1'f32
  var found=Selection()
  proc consider(s:Selection,p:Vec3,radius:float32) =
    let clip=vp*vec4(p+vec3(0,0.3,0),1)
    if clip.w<=0:return
    let screen=vec2((clip.x/clip.w+1)*0.5*window.size.x.float32,(1-clip.y/clip.w)*0.5*window.size.y.float32)
    let score=length(screen-mouse)/(radius*uiScale)
    if score<best:
      best=score
      found=s
  let frame=recording.frames[frameIndex]
  for actor in frame["agents"]:
    consider(Selection(kind:"tractor",key: $actor["slot"].getInt),point(actor["pos"]),24)
  for entity in frame["entities"]:
    consider(Selection(kind:"entity",key:entity["id"].getStr),entityPosition(entity),24)
  for crop in recording.crops[frameIndex]:
    consider(Selection(kind:"crop",pos:crop["pos"]),point(crop["pos"]),19)
  for tile in recording.data["barn"]:
    consider(Selection(kind:"barn",pos:tile),point(tile,0.3),30)
  for item in recording.data["scenery"]:
    consider(Selection(kind:"scenery",key:item["type"].getStr,pos:item["pos"]),point(item["pos"]),17)
  for gate in recording.data["gates"]:
    consider(Selection(kind:"gate",pos:gate["pos"]),point(gate["pos"]),20)
  selection=found
  if found.kind=="tractor":selected=parseInt(found.key)

window.onButtonPress=proc(button: Button)=
  transport.handleKey(button)
  if button==KeyLeft: transport.stepBack()
  if button==KeyRight: transport.stepForward()

proc frame() =
  when defined(emscripten):
    if live and harvestReplayChanged() != 0:
      let updated = loadHarvestReplay(replayPath)
      if updated.frames.len >= recording.frames.len:
        recording = updated
        if recording.data{"live_done"}.getBool:
          transport.live = false
        transport.sync(frameIndex.int32,(recording.frames.len-1).int32,false)
  let now=epochTime()
  let dt=frameDelta(lastFrame)
  uiScale=max(1'f32,window.contentScale)
  sk.uiScale=uiScale
  ui=vec2(window.size.x.float32,window.size.y.float32)/uiScale
  transportScale=fitTransportScale(ui.x)
  layout=hudLayout(ui,ribbonHeight())
  if firstFrame:
    firstFrame=false
    # The embed starts with a clear field; a click on a tractor opens its card.
    if layout.compact:selection=Selection()
  if window.buttonDown[MouseRight]:
    yaw+=window.mouseDelta.x.float32*0.005
    pitch=clamp(pitch+window.mouseDelta.y.float32*0.005,0.3'f32,1.5'f32)
  distance=clamp(distance*pow(0.9'f32,clamp(window.scrollDelta.y,-2'f32,2'f32)),12'f32,125'f32)
  transport.startFrame(dt,6)
  let restore=transport.takeRestore()
  if restore>=0:
    frameIndex=restore.int
    transport.sync(frameIndex.int32,(recording.frames.len-1).int32,false)
  while transport.shouldTick(now):
    if frameIndex>=recording.frames.high: break
    inc frameIndex
    transport.sync(frameIndex.int32,(recording.frames.len-1).int32,false)
  visualFraction=clamp(transport.accumulator*6,0'f32,0.999'f32)
  visualTick=recording.frames[frameIndex]["tick"].getInt.float32+visualFraction
  cues=recording.recentCues(frameIndex,visualFraction)
  if cameraControl.enabled:
    target=mix(target,selectedPosition(),min(1'f32,dt*3))
  else: target=mix(target,vec3(0,0,0),min(1'f32,dt*3))
  let eye=target+vec3(cos(yaw)*cos(pitch)*distance,sin(pitch)*distance,sin(yaw)*cos(pitch)*distance)
  let view=lookAt(eye,target,vec3(0,1,0))
  var proj=perspective(45'f32,window.size.x.float32/max(1'f32,window.size.y.float32),0.1'f32,400'f32)
  # Shift projected scene left to reserve the inspector column.
  var framing=mat4()
  framing[3,0] = -layout.sidebarW/ui.x*0.7
  proj=framing*proj
  var vp=proj*view
  pickObject(vp)
  drawFarm()
  glViewport(0,0,window.size.x,window.size.y)
  applySunHour(15.4)
  sunDepthPasses(window.size):
    drawTerrainSunDepth()
    drawFarmSunDepth()
  glClearColor(0.37,0.48,0.38,1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  drawFarmBackground()
  glDepthMask(GL_TRUE)
  glEnable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  drawTerrain(vp, showEdges=false)
  if selection.kind.len>0:
    let p=selectedPosition()+vec3(0,0.035,0)
    var circle:seq[Vec3]
    for i in 0..32:circle.add p+vec3(cos(i.float32*2*PI.float32/32)*0.62,0,sin(i.float32*2*PI.float32/32)*0.62)
    renderer.addPolyline(circle,rgbx(255,231,133,230),0.025)
  renderer.draw(vp, depthWrite=true)
  drawFarmModels(view,proj,eye)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  sk.beginUi(window,window.size)
  sk.header(window,ui,recording,frameIndex,selection,selected,layout)
  if layout.compact:sk.overlays(ui,recording,frameIndex,selection,layout)
  else:sk.sidebar(ui,recording,frameIndex,selection,layout)
  for cue in cues:
    let label=cueLabel(cue.event)
    if label.len==0 or cue.age>9:continue
    let p=point(cue.event["pos"],1.25+cue.age*0.07)
    let clip=vp*vec4(p,1)
    if clip.w>0:
      let screen=vec2((clip.x/clip.w+1)*0.5*ui.x,(1-clip.y/clip.w)*0.5*ui.y)
      let color=if cue.event["type"].getStr=="pickup":rgbx(255,212,105,255) else:rgbx(255,150,115,255)
      discard sk.drawText("Bold",label,screen-vec2(80,10),color,maxWidth=220)
  if not layout.compact:
    discard sk.drawText("Small","Space: play / pause   Arrows: step   Right-drag: orbit   Wheel: zoom",vec2(26,ui.y-layout.ribbonH-27),rgbx(209,218,200,255))
  transport.drawTransport(sk,window,GameUiPanel(origin:vec2(0,ui.y-layout.ribbonH),size:vec2(ui.x,layout.ribbonH)),cameraControl,followSelection)
  sk.endUi()
  captureScreenshot(window,screenshotFrame,10,"tmp/harvestbench.png")
  window.swapBuffers()
  reportReplayFrame(frameIndex.int32,0)
  when defined(emscripten):
    let selectionInfo=selection.kind & ":" & selection.key
    let selectionCString=selectionInfo.cstring
    {.emit: "EM_ASM({ Module.harvestSelection = UTF8ToString($0); }, `selectionCString`);".}

# Windy dispatches onFrame before clearing per-frame mouse/scroll events.
# This is the GOTA loop and is required for clickable transport controls.
window.onFrame = frame
while not window.closeRequested:
  pollEvents()
