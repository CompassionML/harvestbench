## Skinned character rendering as a library: load a glb once and draw any
## number of independently animated instances of it per frame with the gltf
## PBR renderer or the toon renderer. Each draw re-poses the
## shared node tree (activeClips + animTime, then updateAnimation(0)) and
## re-uploads the joint matrices, so instances don't need their own model
## copies.
##
## Modular characters (../polyworld_data/characters/modular_chars) are one glb carrying
## every swappable part; `loadModularCharacterModel` picks a part list or a
## manifest preset and the model shows just those part nodes when it draws.
## Outfits share the loaded file.

import
  std/[tables, json, strutils, sets, os],
  chroma, gltf, vmath, windy,
  pathing, shadows, toon

type
  CharacterShading* = enum
    PbrCharacters, ToonCharacters

  CharacterModel* = ref object
    file*: GltfFile
    clips*: OrderedTable[string, int]  # animation clip name -> index
    baseTransform*: Mat4        # scales to targetHeight, feet at y 0
    partNodes*: seq[Node]       # modular only: every swappable mesh node
    shownParts*: seq[Node]      # modular only: the outfit this model shows
    unlitParts*: seq[string]    # modular only: eyes, mouth, brows

  CharacterScene* = ref object
    renderer*: Renderer
    context*: PbrContext
    toon*: ToonContext
    shading*: CharacterShading
    sunDepthPass*: bool  ## drawCharacter renders into the sun map instead

const ToonRimStrength* = 0.6'f32  ## the rim light every game shares

var sharedFiles: Table[string, GltfFile]

proc baseTransformFor(bounds: AABounds, targetHeight: float32): Mat4 =
  let
    height = max(bounds.max.y - bounds.min.y, 0.001'f32)
    factor = targetHeight / height
  scale(vec3(factor, factor, factor)) * translate(vec3(0, -bounds.min.y, 0))

proc loadCharacterModel*(
    path: string, targetHeight: float32
): CharacterModel =
  ## Requires a current GL context (the PBR renderer uploads textures on
  ## first draw, but bounds and clips are plain CPU data).
  result = CharacterModel(file: readGltfFile(path))
  for i, clip in result.file.root.animations:
    result.clips[clip.name] = i
  result.baseTransform =
    baseTransformFor(result.file.root.getAABounds(), targetHeight)

proc loadModularFile(path: string): CharacterModel =
  ## Returns a model wrapping the shared glb for this path.
  if path notin sharedFiles:
    sharedFiles[path] = readGltfFile(path)
  result = CharacterModel(file: sharedFiles[path])
  for i, clip in result.file.root.animations:
    result.clips[clip.name] = i

proc applyModularParts(
    model: CharacterModel,
    parts: openArray[string],
    targetHeight: float32
) =
  ## Shows one outfit and sizes height from those parts alone.
  var byName: Table[string, Node]
  for node in model.file.root.walkNodes:
    if node.mesh != nil:
      model.partNodes.add node
      byName[node.name] = node
  for name in parts:
    doAssert name in byName, "no part node " & name
    model.shownParts.add byName[name]
    if name.startsWith("Eye_") or name.startsWith("Mouth_") or
        name.startsWith("Brow_"):
      model.unlitParts.add name
  doAssert model.shownParts.len > 0, "modular outfit has no parts"
  var bounds = model.shownParts[0].getAABounds()
  for node in model.shownParts:
    bounds = bounds.merge(node.getAABounds())
  model.baseTransform = baseTransformFor(bounds, targetHeight)

proc loadModularCharacterModel*(
    path: string, parts: openArray[string], targetHeight: float32
): CharacterModel =
  ## One outfit of a modular character: the glb is loaded once per path
  ## and shared, `parts` names the nodes to show. Height comes from the
  ## shown parts alone, so a tall hat does not shrink the character.
  result = loadModularFile(path)
  applyModularParts(result, parts, targetHeight)

proc loadModularCharacterModel*(
    path, manifestPath, presetName: string, targetHeight: float32
): CharacterModel =
  ## Same as the parts overload, looking the outfit up in the manifest.
  let manifest = parseFile(manifestPath)
  var found = false
  var parts: seq[string]
  for preset in manifest["presets"]:
    if preset["name"].getStr != presetName:
      continue
    found = true
    for part in preset["parts"]:
      parts.add part.getStr
  doAssert found, manifestPath & ": no preset " & presetName
  loadModularCharacterModel(path, parts, targetHeight)

proc clipIndex*(model: CharacterModel, name: string): int =
  ## Returns the animation index registered under a clip name.
  model.clips[name]

proc clipDuration*(model: CharacterModel, clip: int): float32 =
  ## Returns the duration in seconds of an animation clip.
  model.file.root.animations[clip].duration

proc newCharacterScene*(window: Window): CharacterScene =
  ## Creates the shared PBR renderer and attaches its environment map, plus
  ## the toon renderer; `shading` picks which one draws.
  let renderer = newRenderer(window)
  result = CharacterScene(
    renderer: renderer,
    context: newPbrContext(renderer),
    toon: newToonContext(),
    shading: PbrCharacters
  )
  result.context.attachEnvironmentMap(loadDefaultEnvironmentMap())

proc useToonShading*(scene: CharacterScene, rim = ToonRimStrength) =
  ## Draws characters with the toon renderer and its rim light. Games call
  ## this once after newCharacterScene so they all look the same.
  scene.shading = ToonCharacters
  scene.toon.rimColor = color(1, 1, 1, rim)
  scene.toon.lightDirection = ToonLightDirection
  # TOON_LIGHT="x,y,z" overrides the light for tuning.
  if existsEnv("TOON_LIGHT"):
    let parts = getEnv("TOON_LIGHT").split(",")
    scene.toon.lightDirection = normalize(vec3(
      parts[0].parseFloat.float32, parts[1].parseFloat.float32,
      parts[2].parseFloat.float32))

proc toggleShading*(scene: CharacterScene) =
  ## Flips between the toon and PBR renderers (a debug key in every game).
  scene.shading =
    if scene.shading == ToonCharacters: PbrCharacters else: ToonCharacters

proc setToonHour*(scene: CharacterScene, hour: float32) =
  ## Follows a game's clock: the toon palette blends through the day, and
  ## the sun rig (polyworld/shadows) tracks the same hour — where the light
  ## comes from, how strong the sun or moon casts, and the horizon fade
  ## that hides the swap — so one clock drives the whole atmosphere.
  ## TOON_HOUR=<h> pins it for tuning and captures.
  var h = hour
  if existsEnv("TOON_HOUR"):
    h = getEnv("TOON_HOUR").parseFloat.float32
  scene.toon.setPalette(paletteAtHour(h))
  applySunHour(h)
  # TOON_LIGHT keeps its override; otherwise characters and terrain are lit
  # from wherever the sun (or moon) actually is.
  if not existsEnv("TOON_LIGHT"):
    scene.toon.lightDirection = -sunDirection

proc beginCharacters*(
    scene: CharacterScene, window: Window,
    view, projection: Mat4, cameraEye: Vec3
) =
  ## Sets up the frame's camera and light rig, then beginFrame (which
  ## enables depth test and back-face culling). Never clears the screen —
  ## the caller owns the frame's single clear.
  let context = scene.context
  context.size = window.size
  context.view = view
  context.proj = projection
  context.useTrs = true
  # The PBR shader negates the light vectors: these light the model from the
  # camera side (upper front-left).
  context.ambientLightColor = color(0.32, 0.36, 0.46, 0.35)
  context.sunLightDirection = normalize(vec3(1, -4, -2))
  context.sunLightColor = color(0.95, 0.96, 1.0, 1.0)
  context.rimLightDirection = normalize(vec3(-1, 1, -1))
  context.rimLightColor = color(0.95, 0.72, 0.46, 0.25)
  context.debugView = dvLit
  context.cameraPosition = cameraEye
  context.useShadows = false
  context.drawSkybox = false
  context.skyboxLod = 0
  context.vsync = false
  let toon = scene.toon
  toon.view = view
  toon.proj = projection
  toon.cameraPosition = cameraEye
  scene.renderer.beginFrame(window, window.size)

proc drawCharacter*(
    scene: CharacterScene, model: CharacterModel,
    position: Vec3, facing: float32, clip: int, animTime: float32,
    tint = color(1, 1, 1, 1), sizeFactor = 1.0'f32
) =
  ## Poses the shared model at the given clip time and draws one instance.
  ## Looping clips may pass any time (playback wraps); one-shot clips like
  ## Death should clamp animTime to clipDuration to hold the last frame.
  ## Keep tint.a at 1.0 — lower alpha reroutes into the blended pass.
  let root = model.file.root
  if model.partNodes.len > 0:
    # Modular: the shared tree shows exactly this model's outfit.
    for node in model.partNodes:
      node.baseVisible = false
      node.visible = false
    for node in model.shownParts:
      node.baseVisible = true
      node.visible = true
  if root.activeClips.len != 1:
    root.activeClips.setLen(1)
  root.activeClips[0] = clip
  root.animTime = animTime
  root.updateAnimation(0)
  let transform =
    translate(position) * rotateY(facing) *
    scale(vec3(sizeFactor, sizeFactor, sizeFactor)) * model.baseTransform
  if scene.sunDepthPass:
    # Same pose, but rendered into the sun's shadow map: games run their
    # character loop once inside the depth pass and once for the camera.
    scene.toon.transform = transform
    scene.toon.drawSunDepth(model.file.root)
    return
  case scene.shading
  of PbrCharacters:
    scene.context.transform = transform
    scene.context.tint = tint
    scene.context.draw(root)
  of ToonCharacters:
    let toon = scene.toon
    for name in model.unlitParts:
      toon.unlitNodes.incl name
    toon.transform = transform
    toon.tint = tint
    toon.draw(root)

proc finishCharacters*(scene: CharacterScene) =
  ## Finishes the character renderer's current frame.
  scene.renderer.endFrame()

proc pickPrimitive(
    primitive: Primitive,
    world: Mat4,
    origin,
    dir: Vec3
): float32 =
  ## Ray distance to one mesh primitive, or -1 when it misses.
  result = -1
  if primitive == nil or primitive.points.len == 0:
    return
  template consider(ia, ib, ic: int) =
    if ia < primitive.points.len and
        ib < primitive.points.len and
        ic < primitive.points.len:
      let distance = rayTriangle(
        origin,
        dir,
        world * primitive.points[ia],
        world * primitive.points[ib],
        world * primitive.points[ic]
      )
      if distance > 0 and (result < 0 or distance < result):
        result = distance
  if primitive.indices32.len > 0:
    var i = 0
    while i + 2 < primitive.indices32.len:
      consider(
        primitive.indices32[i].int,
        primitive.indices32[i + 1].int,
        primitive.indices32[i + 2].int
      )
      i += 3
  elif primitive.indices16.len > 0:
    var i = 0
    while i + 2 < primitive.indices16.len:
      consider(
        primitive.indices16[i].int,
        primitive.indices16[i + 1].int,
        primitive.indices16[i + 2].int
      )
      i += 3
  else:
    var i = 0
    while i + 2 < primitive.points.len:
      consider(i, i + 1, i + 2)
      i += 3

proc pickCharacter*(
    model: CharacterModel,
    origin,
    dir,
    position: Vec3,
    facing: float32,
    clip: int,
    animTime: float32,
    sizeFactor = 1.0'f32
): float32 =
  ## Ray distance to one posed character's triangles, or -1 when they miss.
  result = -1
  let root = model.file.root
  if model.partNodes.len > 0:
    for node in model.partNodes:
      node.baseVisible = false
      node.visible = false
    for node in model.shownParts:
      node.baseVisible = true
      node.visible = true
  if root.activeClips.len != 1:
    root.activeClips.setLen(1)
  root.activeClips[0] = clip
  root.animTime = animTime
  root.updateAnimation(0)
  let transform =
    translate(position) * rotateY(facing) *
    scale(vec3(sizeFactor, sizeFactor, sizeFactor)) * model.baseTransform
  root.updateTransforms(transform)
  for node in root.walkNodes:
    if node.mesh == nil or not node.visible:
      continue
    for primitive in node.mesh.primitives:
      let distance = pickPrimitive(primitive, node.mat, origin, dir)
      if distance > 0 and (result < 0 or distance < result):
        result = distance
