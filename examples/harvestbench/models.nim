## Farm models: the CC0 and CC BY glTF props the viewer draws with
## Polyworld's toon shader (see assets/polyworld/farm/license.md). Every file
## is normalised offline: feet on y=0, centred in x and z, 1.0 tall, so a draw
## is a position, a heading and a target size. Instances are queued while the
## scene is built, then drawn into the sun depth map and the main pass.
import std/[tables, math, strutils]
import chroma, gltf, vmath
import polyworld/[common, shadows, toon]

type FarmInstance* = object
  name*: string
  transform*: Mat4
  tint*: Color

const FarmModelNames* = ["tractor_0", "tractor_1", "tractor_2", "tractor_3",
  "cow", "pig", "sheep", "boar", "chicken", "goose", "wild_goose", "duck",
  "rabbit", "mouse", "squirrel", "opossum", "barn", "hay", "corn", "rock"]

## Every model's long axis is z. These heading offsets turn each one so that
## yaw 0 faces +z, measured from the first hosted render.
let FarmFacing* = {"tractor": 0'f32, "cow": 0, "pig": 0, "sheep": 0, "boar": 0,
  "chicken": 0, "goose": 0, "wild_goose": 0, "duck": 0, "rabbit": 0, "mouse": 0,
  "squirrel": 0, "opossum": 0}.toTable

var
  toonCtx: ToonContext
  roots: Table[string, Node]
  instances: seq[FarmInstance]

proc initFarmModels*(hour = 15.4'f32) =
  ## Loads the pack and its toon context. Needs the GL context.
  toonCtx = newToonContext()
  toonCtx.setPalette(paletteAtHour(hour))
  for name in FarmModelNames:
    roots[name] = readGltfFile(DataRoot & "/farm/" & name & ".glb").root

proc hasFarmModel*(name: string): bool = name in roots

proc facing*(name: string): float32 =
  let key = if name.startsWith("tractor"): "tractor" else: name
  FarmFacing.getOrDefault(key, 0'f32)

proc clearFarm*() = instances.setLen(0)

proc placeFarm*(name: string, at: Vec3, yaw: float32, size: Vec3,
                tint = color(1, 1, 1, 1), roll = 0'f32) =
  ## Queues one model with its base at `at`, turned by `yaw` about y and
  ## stretched to `size` (world units per normalised unit, so size.y is the
  ## height). `roll` tips it over about its own centre, for a felled animal.
  var m = translate(at) * rotateY(yaw + facing(name))
  if roll != 0:
    m = m * translate(vec3(0, size.x * 0.5, 0)) * rotateZ(roll) *
      translate(vec3(0, -size.y * 0.5, 0))
  instances.add FarmInstance(name: name, transform: m * scale(size), tint: tint)

proc placeFarm*(name: string, at: Vec3, yaw, height: float32,
                tint = color(1, 1, 1, 1), roll = 0'f32) =
  placeFarm(name, at, yaw, vec3(height), tint, roll)

proc drawFarmSunDepth*() =
  ## Call inside sunDepthPasses so the models cast shadows.
  for inst in instances:
    toonCtx.transform = inst.transform
    toonCtx.drawSunDepth(roots[inst.name])

proc drawFarmModels*(view, proj: Mat4, eye: Vec3) =
  toonCtx.view = view
  toonCtx.proj = proj
  toonCtx.cameraPosition = eye
  toonCtx.lightDirection = -sunDirection
  for inst in instances:
    toonCtx.transform = inst.transform
    toonCtx.tint = inst.tint
    toonCtx.draw(roots[inst.name])
  toonCtx.tint = color(1, 1, 1, 1)
