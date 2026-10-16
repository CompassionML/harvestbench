## Paintbot's GeneratedTerrain material system, dressed as a working farm.
## Terrain decoration never changes HarvestBench's authoritative grid rules.
import std/[json, math]
import vmath
import polyworld/[pathing, quadterrain, shadows, toon]

const TileSize* = 2

proc hash2(ix,iz: int): float32 =
  # Unsigned so it wraps instead of raising on the 32-bit wasm target.
  var n=uint32(ix and 0xffff)*374761393'u32 + uint32(iz and 0xffff)*668265263'u32
  n=(n xor (n shr 13))*1274126177'u32
  (n and 0xffff).float32/65535

proc fieldNoise*(x,z: float32): float32 =
  ## Smooth 0..1 value noise in cell units; gives the dirt edges their wobble.
  let ix=floor(x).int
  let iz=floor(z).int
  var fx=x-ix.float32
  var fz=z-iz.float32
  fx=fx*fx*(3-2*fx)
  fz=fz*fz*(3-2*fz)
  let a=hash2(ix,iz)
  let b=hash2(ix+1,iz)
  let c=hash2(ix,iz+1)
  let d=hash2(ix+1,iz+1)
  mix(mix(a,b,fx),mix(c,d,fx),fz)

# The farm track, in grid-cell units: it leaves the upper plot, wanders
# across the pasture and bends down to the barn. Catmull-Rom through these.
const LaneControl=[
  vec2(1.5,6.5),vec2(3.6,6.3),vec2(7.0,7.1),vec2(10.5,5.8),vec2(14.0,6.9),
  vec2(17.5,6.0),vec2(20.5,6.6),vec2(22.3,8.4),vec2(22.7,11.0),vec2(22.4,13.5)]

proc farmLane*(): seq[Vec2] =
  ## The lane's centre line as a fine polyline (cell units).
  for i in 1..<LaneControl.len-2:
    let p0=LaneControl[i-1]
    let p1=LaneControl[i]
    let p2=LaneControl[i+1]
    let p3=LaneControl[i+2]
    for k in 0..<10:
      let t=k.float32/10
      let t2=t*t
      let t3=t2*t
      result.add (p1*2'f32+(p2-p0)*t+(p0*2'f32-p1*5'f32+p2*4'f32-p3)*t2+(p1*3'f32-p0-p2*3'f32+p3)*t3)*0.5'f32
  result.add LaneControl[^2]

let laneLine=farmLane()

proc laneDistance*(p: Vec2): float32 =
  ## Distance from a point (cell units) to the lane's centre line.
  result=float32.high
  for i in 0..<laneLine.len-1:
    let a=laneLine[i]
    let b=laneLine[i+1]
    let ab=b-a
    let t=clamp(dot(p-a,ab)/max(dot(ab,ab),1e-6'f32),0'f32,1'f32)
    result=min(result,length(p-(a+ab*t)))

proc laneHalfWidth*(p: Vec2): float32 =
  0.58+0.16*(fieldNoise(p.x*0.9+3,p.y*0.9)-0.5)

proc onFarmLane*(p: Vec2): bool =
  laneDistance(p)<laneHalfWidth(p)

# Cultivated plots: soft rounded blobs (a squared-off ellipse with a wobbly
# edge), one at the upper left and one inside the lower fence.
const FarmPlots* = [(vec2(3.0,7.0),vec2(2.1,4.1)),(vec2(18.5,12.0),vec2(2.6,2.1))]

proc inFarmPlot*(p: Vec2): bool =
  for (c,r) in FarmPlots:
    let d=p-c
    let e=pow(abs(d.x/r.x),2.6'f32)+pow(abs(d.y/r.y),2.6'f32)
    if e<1+0.22*(fieldNoise(p.x*1.3,p.y*1.3)-0.5): return true
  false

proc farmElevation(x,z,w,h: float32): float32 =
  let outside = max(max(-x,x-w),max(-z,z-h))
  if outside <= 0: return 0
  let fade=min(outside/5,1'f32)
  fade*(0.45+0.5*sin(x*0.24)*cos(z*0.29))

proc initFarmTerrain*(data: JsonNode) =
  let w=data["width"].getInt*TileSize
  let h=data["height"].getInt*TileSize
  const border=22
  let ground=QuadLayer(originX:HalfGrid.int-w div 2-border,
    originZ:HalfGrid.int-h div 2-border,width:w+2*border,depth:h+2*border,
    tiles:newSeq[Tile]((w+2*border)*(h+2*border)))
  for z in 0..<ground.depth:
    for x in 0..<ground.width:
      let wx=x-border
      let wz=z-border
      let gx=floor(wx.float32/TileSize.float32).int
      let gz=floor(wz.float32/TileSize.float32).int
      # All grass: the dirt is drawn as flat decal geometry (harvestbench.nim)
      # because tile kinds can only blend along the tile grid, in steps.
      var kind=GrassTile
      if gx<0 or gx>=w div TileSize or gz<0 or gz>=h div TileSize:
        if (x*19+z*37) mod 17==0 and (gx < -2 or gx>w div TileSize+2 or gz < -2 or gz>h div TileSize+2):
          kind=TreeTile
      var tile=Tile(flags:TileExists or TileConnectedEast or TileConnectedSouth,kind:kind)
      tile.tops=pack([
        farmElevation(wx.float32,wz.float32,w.float32,h.float32),
        farmElevation(wx.float32+1,wz.float32,w.float32,h.float32),
        farmElevation(wx.float32,wz.float32+1,w.float32,h.float32),
        farmElevation(wx.float32+1,wz.float32+1,w.float32,h.float32)])
      ground.tiles[z*ground.width+x]=tile
  # The original impassable trees use Paintbot's hand-painted tree models.
  for scenery in data["scenery"]:
    if scenery["type"].getStr in ["tree","trees"]:
      let x=scenery["pos"][0].getInt*TileSize+border+1
      let z=scenery["pos"][1].getInt*TileSize+border+1
      ground.tiles[z*ground.width+x].kind=TreeTile
  layers = @[ground]
  amplitude=0.8
  treeHeight=2.6
  treeWidth=1.8
  terrainGrassPatchSize=10
  initTerrain(MixedTrees,GeneratedTerrain,PaintedRocks)
  terrainTextureScale=0.55
  terrainBlendDepth=0.9
  terrainSplatChance=0.35
  setTileColor(GrassTile.int,vec3(0.93,1.0,0.85),vec3(0.75))
  setTileColor(RoadTile.int,vec3(0.80,0.66,0.47),vec3(0.62))
  computeWalkable()
  scatterGrass(2200,data["seed"].getInt,matchTerrain=true)
  bakeTerrain(rebuildWalkability=false)
  showAllTerrain()
  let lighting=newToonContext()
  lighting.setPalette(paletteAtHour(15.4))
  setEnvironmentPalette(lighting)
  applySunHour(15.4)
