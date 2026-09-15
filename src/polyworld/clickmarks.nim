## Accepted ground-click marks drawn with the shared fx mesh cylinder.

import
  std/math,
  vmath,
  fxmeshes

const
  ClickMarkDuration* = 0.42'f32
  ClickMarkStartScale* = 0.32'f32
  ClickMarkEndScale* = 1.05'f32
  MaximumClickMarks = 12

type
  ClickMark = object
    origin: Vec3
    startTime: float32
  ClickMarkSystem* = object
    renderer: FxRenderer
    settings: FxSettings
    marks: seq[ClickMark]
    time: float32

proc clickMarkLife*(age, duration: float32): float32 =
  ## Returns 0 at birth and 1 when the mark has finished expanding.
  fxLife(age, duration, false)

proc clickMarkScale*(life: float32): float32 =
  ## Returns the cylinder radius scale for one life fraction.
  mix(
    ClickMarkStartScale,
    ClickMarkEndScale,
    pow(clamp(life, 0, 1), 0.55'f32)
  )

proc clickMarkSettings*(): FxSettings =
  ## Returns the expanding gold cylinder used for move clicks.
  result = defaultFxSettings()
  result.name = "click"
  result.shape = CylinderShape
  result.axis = YAxis
  result.pivot = StartPivot
  result.radius = 0.55
  result.height = 0.18
  result.radialSegments = 28
  result.heightSegments = 2
  result.capStart = false
  result.capEnd = false
  result.duration = ClickMarkDuration
  result.loop = false
  result.expandStart = ClickMarkStartScale
  result.expandEnd = ClickMarkEndScale
  result.expandPower = 0.55
  result.texture = SoftTexture
  result.blendMode = AdditiveBlend
  result.gradientSource = LifeGradient
  result.uvScale = vec2(1, 1)
  result.startColor = vec4(1.0, 0.86, 0.32, 0.9)
  result.endColor = vec4(1.0, 0.55, 0.12, 0.0)
  result.edgeColor = vec4(1.0, 0.92, 0.55, 1.0)
  result.fadeIn = 0.08
  result.fadeOut = 0.45

proc initClickMarks*(): ClickMarkSystem =
  ## Creates the shared click cylinder and uploads it once.
  result.renderer = initFxRenderer()
  result.settings = clickMarkSettings()
  result.renderer.uploadFxMesh(result.settings)

proc emitClickMark*(system: var ClickMarkSystem, origin: Vec3) =
  ## Starts one expanding cylinder at a walkable click.
  if system.marks.len >= MaximumClickMarks:
    system.marks.delete(0)
  system.marks.add ClickMark(origin: origin, startTime: system.time)

proc advanceClickMarks*(system: var ClickMarkSystem, delta: float32) =
  ## Advances presentation time and drops finished marks.
  system.time += max(delta, 0)
  var i = system.marks.high
  while i >= 0:
    let age = system.time - system.marks[i].startTime
    if clickMarkLife(age, system.settings.duration) >= 1:
      system.marks.delete(i)
    dec i

proc drawClickMarks*(
    system: ClickMarkSystem,
    viewProjection: Mat4
) =
  ## Draws every live click cylinder through the shared fx mesh.
  for mark in system.marks:
    let life = clickMarkLife(
      system.time - mark.startTime,
      system.settings.duration
    )
    system.renderer.drawFxMesh(
      system.settings,
      viewProjection,
      translate(mark.origin) * fxModel(system.settings.axis),
      system.time,
      life
    )

proc closeClickMarks*(system: var ClickMarkSystem) =
  ## Releases click-mark GPU resources.
  closeFxRenderer(system.renderer)
  system = ClickMarkSystem()
