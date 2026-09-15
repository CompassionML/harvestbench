## Sun shadow maps for the polyworld games. One directional light renders
## every caster (terrain, props, trees, characters) into depth maps with
## hardware PCF comparison filtering, and the lit shaders in quadterrain and
## toon darken whatever the light cannot see. A day clock drives the whole
## atmosphere: the sun arcs east to west from 6:00 to 20:00, the moon rides
## the same track at night and shades like a darker sun, and a signed
## horizon band fades the directional light toward the shadow side so the
## sun-to-moon swap does not pop.
##
## A continuously rotating light re-rasterizes every caster edge each frame,
## which boils shadow edges (and the toon band turns that sampling noise
## into binary color flips). So the sun the SHADOW MAPS see is quantized to
## SunStepHours increments — stable for many frames — and every frame
## renders two maps, one at each neighbouring step; receivers sample both
## and cross-fade by the smooth clock, so shadows dissolve from one sun
## position to the next instead of shimmering. Lighting, palette, and
## strengths all use the smooth hour directly.
##
## This module owns the depth framebuffers, the light matrices, the sun
## path, and the depth-only shader programs. The mesh modules build their
## own depth vertex arrays against these programs and draw inside the
## sunDepthPasses bracket, using sunDepthPassMvp() as the light transform.
## Ported from experiments/terrain/quadterrain_shadows.nim.

import
  std/os,
  opengl, shady, vmath

const
  SunShadowMapSize* =
    when defined(emscripten):
      2048
    else:
      4096
  SunShadowTexel* = 1.0'f32 / SunShadowMapSize.float32
  SunStepHours* = 0.05'f32
    ## The shadow-map sun advances in steps of this many game hours; the
    ## cross-fade between neighbouring steps is what the viewer sees move.

var
  sunShadowsEnabled* = true      ## Master switch; SUN_SHADOWS=0 disables.
  sunAzimuth* = 48.0'f32         ## Degrees around the map.
  sunElevation* = 53.0'f32       ## Degrees above the horizon.
  sunShadowStrength* = 0.75'f32  ## 1: full shadow drops to the shadow band.
  sunShadingStrength* = 1.0'f32  ## 1: full directional shading, 0: flat.
  sunShadowBias* = 0.0012'f32    ## Depth offset that hides self-shadow acne.
  sunShadowSoftness* = 1.5'f32   ## PCF spread in shadow-map texels.
  moonShadowStrength* = 0.4'f32  ## Night moon casts like the sun, darker.
  lightLevel* = 1.0'f32          ## 1 full sun or moonlight, 0 shadow side.
  solarElevation* = 53.0'f32     ## Signed: sun positive, moon negative.
  sunDirection* = normalize(vec3(0.45, 0.8, 0.4))  ## Toward the sun (smooth).
  sunLightMvp0*: Mat4            ## Light view-projection at the earlier step.
  sunLightMvp1*: Mat4            ## The same at the next step.
  sunShadowBlend*: float32       ## 0 at step 0 .. 1 at step 1.
  sunShadowTextures*: array[2, GLuint]  ## Depth textures, compare mode on.
  sunLightRadius = 100.0'f32
  sunLightDistance = 170.0'f32
  sunFramebuffers: array[2, GLuint]
  activeDepthMvp: Mat4
  depthProgram, cutoutDepthProgram: GLuint
  depthMvpLocation: GLint
  cutoutMvpLocation, cutoutTexturesLocation, cutoutCutoffLocation: GLint

## Depth-only shaders: casters need position (plus uv and texture layer for
## alpha-cutout foliage), nothing else.

var
  sunDepthMvp: Uniform[Mat4]
  cutoutTextures: Uniform[Sampler2dArray]
  cutoutCutoff: Uniform[float32]

proc texture(buffer: Uniform[Sampler2dArray], position: Vec3): Vec4 =
  ## Provides Shady with the texture-array builtin signature.
  vec4(0)

proc sunDepthVert(gl_Position: var Vec4, vertPos: Vec3) =
  ## Projects one caster vertex into the sun's clip space.
  gl_Position = sunDepthMvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)

proc sunDepthFrag(fragColor: var Vec4) =
  ## Depth-only target; the color write goes nowhere.
  fragColor = vec4(1.0, 1.0, 1.0, 1.0)

proc sunCutoutDepthVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec3,
    fragUv: var Vec3
) =
  ## Projects a textured caster vertex, keeping uv for the cutout test.
  gl_Position = sunDepthMvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  fragUv = vertUv

proc sunCutoutDepthFrag(fragColor: var Vec4, fragUv: Vec3) =
  ## Alpha-cutout casters (foliage) keep their holes in the shadow map.
  if texture(cutoutTextures, fragUv).w < cutoutCutoff:
    discardFragment()
  fragColor = vec4(1.0, 1.0, 1.0, 1.0)

const SunShaderTarget =
  when defined(emscripten):
    glsl3WebGL
  else:
    glsl4Desktop

proc compileStage(kind: GLenum, source, label: string): GLuint =
  ## Compiles one OpenGL shader stage or terminates with its diagnostic.
  result = glCreateShader(kind)
  var sourceArray = allocCStringArray([source])
  defer: deallocCStringArray(sourceArray)
  glShaderSource(result, 1.GLsizei, sourceArray, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    quit(label & " shader failed:\n" & log & "\nsource:\n" & source)

proc compileDepthProgram(vertexSource, fragmentSource: string): GLuint =
  ## Links one depth program or terminates with its diagnostic.
  let
    vertexShader = compileStage(GL_VERTEX_SHADER, vertexSource, "sundepth.vert")
    fragmentShader = compileStage(
      GL_FRAGMENT_SHADER, fragmentSource, "sundepth.frag")
  result = glCreateProgram()
  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)
  glLinkProgram(result)
  var ok: GLint
  glGetProgramiv(result, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    quit("sun depth program failed:\n" & log)

## Sun rig

proc sunDirectionFor(azimuth, elevation: float32): Vec3 =
  ## Unit direction toward the sun for compass and altitude angles.
  let
    a = azimuth * PI.float32 / 180.0
    e = elevation * PI.float32 / 180.0
  vec3(cos(e) * sin(a), sin(e), cos(e) * cos(a))

proc lightMatrixFor(azimuth, elevation: float32): Mat4 =
  ## The sun camera's orthographic view-projection: centered on the map
  ## origin, sized once (initSunShadows) to cover the whole grid.
  let
    direction = sunDirectionFor(azimuth, elevation)
    view = lookAt(direction * sunLightDistance, vec3(0, 0, 0), vec3(0, 1, 0))
    projection = ortho(
      -sunLightRadius, sunLightRadius, -sunLightRadius, sunLightRadius,
      sunLightDistance - sunLightRadius, sunLightDistance + sunLightRadius)
  projection * view

const HorizonMapFloor = 8.0'f32
  ## Keeps the depth-map caster off the ground while the horizon fade
  ## has already killed the directional light.

proc mapElevation(elevation: float32): float32 =
  ## Floors elevation so the shadow map stays valid near the horizon.
  max(elevation, HorizonMapFloor)

proc horizonLight*(signedElev: float32): float32 =
  ## Moonlight below -20°, no directional light from -10° to +10°,
  ## full sun above +20°. The scene stays visible; only the light fades.
  if signedElev <= -20:
    result = 1.0
  elif signedElev < -10:
    result = 1.0 - smoothstep(-20.0'f32, -10.0'f32, signedElev)
  elif signedElev <= 10:
    result = 0.0
  elif signedElev < 20:
    result = smoothstep(10.0'f32, 20.0'f32, signedElev)
  else:
    result = 1.0

proc updateSunMatrix*() =
  ## Recomputes the smooth sun direction and points both shadow steps at it
  ## (blend 0) — the manual path when no day clock drives the rig.
  solarElevation = sunElevation
  lightLevel = horizonLight(solarElevation)
  sunDirection = sunDirectionFor(sunAzimuth, mapElevation(sunElevation))
  sunLightMvp0 = lightMatrixFor(sunAzimuth, mapElevation(sunElevation))
  sunLightMvp1 = sunLightMvp0
  sunShadowBlend = 0

proc sunRigAt(hour: float32): tuple[azimuth, elevation, sunUp: float32] =
  ## The sun's place at an hour: it arcs east to west from 6:00 to 20:00,
  ## and the moon rides the same track through the night. Elevation is
  ## allowed to fall through the 10-20° fade so the handoff is dark.
  ## sunUp is 0 at night, 1 at noon.
  let h = ((hour mod 24) + 24) mod 24
  if h >= 6 and h <= 20:
    let t = (h - 6) / 14
    result.sunUp = sin(t * PI.float32)
    result.azimuth = 90 + t * 180
    result.elevation = result.sunUp * 70
  else:
    let sinceSunset = if h > 20: h - 20 else: h + 4
    let t = sinceSunset / 10
    result.sunUp = 0
    result.azimuth = 90 + t * 180
    result.elevation = sin(t * PI.float32) * 45

proc applySunHour*(hour: float32) =
  ## Drives the whole sun rig from a day clock. Lighting and strengths use
  ## the smooth hour; the shadow maps use the two neighbouring SunStepHours
  ## steps with a cross-fade, so shadow edges dissolve toward the next sun
  ## position instead of re-rasterizing (and shimmering) every frame. Night
  ## keeps real moon shading; the horizon band fades only the light.
  let
    smooth = sunRigAt(hour)
    h = ((hour mod 24) + 24) mod 24
    isDay = h >= 6 and h <= 20
  sunAzimuth = smooth.azimuth
  sunElevation = smooth.elevation
  solarElevation =
    if isDay:
      smooth.elevation
    else:
      -smooth.elevation
  lightLevel = horizonLight(solarElevation)
  sunDirection = sunDirectionFor(smooth.azimuth, mapElevation(smooth.elevation))
  if isDay:
    let strength =
      0.15'f32 + 0.7'f32 * smoothstep(0.0'f32, 0.3'f32, smooth.sunUp)
    sunShadowStrength = strength
    sunShadingStrength = strength
  else:
    sunShadowStrength = moonShadowStrength
    sunShadingStrength = 0.8'f32
  let
    step0 = floor(h / SunStepHours) * SunStepHours
    rig0 = sunRigAt(step0)
    rig1 = sunRigAt(step0 + SunStepHours)
  sunShadowBlend = clamp((h - step0) / SunStepHours, 0.0'f32, 1.0'f32)
  sunLightMvp0 = lightMatrixFor(rig0.azimuth, mapElevation(rig0.elevation))
  sunLightMvp1 = lightMatrixFor(rig1.azimuth, mapElevation(rig1.elevation))

## Setup

proc initSunShadows*(
    lightRadius = 100.0'f32, lightDistance = 170.0'f32
) =
  ## Compiles the depth programs and creates the two shadow framebuffers.
  ## Requires a current GL context; safe to call more than once. The radius
  ## must cover the whole scene from any sun angle (map half-diagonal plus
  ## the tallest features).
  if sunFramebuffers[0] != 0:
    return
  if getEnv("SUN_SHADOWS") == "0":
    sunShadowsEnabled = false
  sunLightRadius = lightRadius
  sunLightDistance = lightDistance

  depthProgram = compileDepthProgram(
    toShader(sunDepthVert, SunShaderTarget, shaderVertex),
    toShader(sunDepthFrag, SunShaderTarget, shaderFragment)
  )
  depthMvpLocation = glGetUniformLocation(depthProgram, "sunDepthMvp")
  cutoutDepthProgram = compileDepthProgram(
    toShader(sunCutoutDepthVert, SunShaderTarget, shaderVertex),
    toShader(sunCutoutDepthFrag, SunShaderTarget, shaderFragment)
  )
  cutoutMvpLocation = glGetUniformLocation(cutoutDepthProgram, "sunDepthMvp")
  cutoutTexturesLocation = glGetUniformLocation(
    cutoutDepthProgram, "cutoutTextures")
  cutoutCutoffLocation = glGetUniformLocation(
    cutoutDepthProgram, "cutoutCutoff")

  for step in 0 .. 1:
    # Linear filtering plus the comparison mode turns every sampler2DShadow
    # tap into a bilinearly filtered depth test (hardware PCF).
    glGenTextures(1, sunShadowTextures[step].addr)
    glBindTexture(GL_TEXTURE_2D, sunShadowTextures[step])
    glTexImage2D(
      GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24.GLint,
      SunShadowMapSize, SunShadowMapSize, 0,
      GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nil
    )
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(
      GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL.GLint)
    glBindTexture(GL_TEXTURE_2D, 0)

    glGenFramebuffers(1, sunFramebuffers[step].addr)
    glBindFramebuffer(GL_FRAMEBUFFER, sunFramebuffers[step])
    glFramebufferTexture2D(
      GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D,
      sunShadowTextures[step], 0)
    var drawTargets = [GL_NONE]
    glDrawBuffers(1, cast[ptr GLenum](drawTargets.addr))
    glReadBuffer(GL_NONE)
    doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
      GL_FRAMEBUFFER_COMPLETE
    # Start the map at far depth so everything counts as lit until the
    # first real depth pass runs.
    glClear(GL_DEPTH_BUFFER_BIT)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  updateSunMatrix()

proc sunShadowsActive*(): bool =
  ## Returns whether the shadow maps exist and shadows are switched on.
  sunShadowsEnabled and sunFramebuffers[0] != 0

proc sunDepthProgramId*(): GLuint =
  ## The plain depth program, for mesh modules building depth vertex arrays.
  depthProgram

proc sunCutoutProgramId*(): GLuint =
  ## The alpha-cutout depth program, same purpose.
  cutoutDepthProgram

## Per-frame passes

proc beginSunDepthPass*(step: int) =
  ## Binds one step's shadow framebuffer and clears it. Prefer the
  ## sunDepthPasses template, which brackets both steps.
  glBindFramebuffer(GL_FRAMEBUFFER, sunFramebuffers[step])
  when not defined(emscripten):
    glDisable(GL_MULTISAMPLE)
  glViewport(0, 0, SunShadowMapSize, SunShadowMapSize)
  glClear(GL_DEPTH_BUFFER_BIT)
  glEnable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  activeDepthMvp = if step == 0: sunLightMvp0 else: sunLightMvp1

proc sunDepthPassMvp*(): Mat4 =
  ## The light view-projection of the depth pass currently rendering.
  activeDepthMvp

proc bindSunDepth*(transform: Mat4) =
  ## Selects the plain depth program with the given light-space transform.
  var matrix = transform
  glUseProgram(depthProgram)
  glUniformMatrix4fv(depthMvpLocation, 1, GL_FALSE, cast[ptr float32](matrix.addr))

proc bindSunCutoutDepth*(transform: Mat4, alphaCutoff: float32) =
  ## Selects the cutout depth program; the caller binds its texture array to
  ## unit 0 before drawing.
  var matrix = transform
  glUseProgram(cutoutDepthProgram)
  glUniformMatrix4fv(
    cutoutMvpLocation, 1, GL_FALSE, cast[ptr float32](matrix.addr))
  glUniform1i(cutoutTexturesLocation, 0)
  glUniform1f(cutoutCutoffLocation, alphaCutoff)

proc endSunDepthPass*(windowSize: IVec2) =
  ## Unbinds the shadow framebuffer and restores the window viewport.
  glBindVertexArray(0)
  glUseProgram(0)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, windowSize.x.GLsizei, windowSize.y.GLsizei)

template sunDepthPasses*(windowSize: IVec2, body: untyped) =
  ## Runs the caster draws in `body` once per shadow step, so both maps of
  ## the cross-fade see the same frame. `sunPassIndex` is 0 for the first
  ## pass and 1 for the second, for loops that must mutate state only once.
  ## Restores the window target and MSAA setting even if a draw fails.
  if sunShadowsActive():
    when not defined(emscripten):
      let multisampleEnabled = glIsEnabled(GL_MULTISAMPLE)
    try:
      for sunPassIndex {.inject.} in 0 .. 1:
        beginSunDepthPass(sunPassIndex)
        body
    finally:
      endSunDepthPass(windowSize)
      when not defined(emscripten):
        if multisampleEnabled == GL_TRUE:
          glEnable(GL_MULTISAMPLE)
        else:
          glDisable(GL_MULTISAMPLE)
