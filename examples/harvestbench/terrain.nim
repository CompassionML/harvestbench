## Paintbot's GeneratedTerrain material system, dressed as a working farm.
## Terrain decoration never changes HarvestBench's authoritative grid rules.
import std/[json, math]
import vmath
import polyworld/[pathing, quadterrain, shadows, toon]

const TileSize* = 2

proc farmElevation(x,z,w,h: float32): float32 =
  let outside = max(max(-x,x-w),max(-z,z-h))
  if outside <= 0: return 0
  let fade=min(outside/5,1'f32)
  fade*(0.45+0.5*sin(x*0.24)*cos(z*0.29))

proc initFarmTerrain*(data: JsonNode) =
  let w=data["width"].getInt*TileSize
  let h=data["height"].getInt*TileSize
  const border=12
  let ground=QuadLayer(originX:HalfGrid.int-w div 2-border,
    originZ:HalfGrid.int-h div 2-border,width:w+2*border,depth:h+2*border,
    tiles:newSeq[Tile]((w+2*border)*(h+2*border)))
  for z in 0..<ground.depth:
    for x in 0..<ground.width:
      let wx=x-border
      let wz=z-border
      let gx=floor(wx.float32/TileSize.float32).int
      let gz=floor(wz.float32/TileSize.float32).int
      var kind=GrassTile
      # Broad cultivated plots, not a square under every individual crop.
      if (gx in 1..4 and gz in 3..10) or (gx in 16..20 and gz in 10..13):
        kind=RoadTile
      # A softly curving farm track that skirts the upper pasture.
      let lane=6.4+0.65*sin(wx.float32/TileSize.float32*0.29)
      if gx in 4..22 and abs(wz.float32/TileSize.float32-lane)<0.6: kind=RoadTile
      if gx in 21..23 and gz in 6..10: kind=RoadTile
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
  terrainBlendDepth=0.65
  terrainSplatChance=0.35
  setTileColor(GrassTile.int,vec3(0.93,1.0,0.85),vec3(0.75))
  setTileColor(RoadTile.int,vec3(0.88,0.81,0.65),vec3(0.7))
  computeWalkable()
  scatterGrass(2200,data["seed"].getInt,matchTerrain=true)
  bakeTerrain(rebuildWalkability=false)
  showAllTerrain()
  let lighting=newToonContext()
  lighting.setPalette(paletteAtHour(15.4))
  setEnvironmentPalette(lighting)
  applySunHour(15.4)
