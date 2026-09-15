## Bounded GPU particle effects shared by Polyworld game renderers.

import
  std/strutils,
  opengl, shady, vmath,
  particleshaders

const
  MaximumParticleEffects = 192
  ParticleUniformNames = [
    "uParticleViewProjection",
    "uParticleCameraRight",
    "uParticleCameraUp",
    "uParticleCameraForward",
    "uParticleTime",
    "uParticleStartTime",
    "uParticleTravelTime",
    "uParticleSeed",
    "uParticleEffectKind",
    "uParticleOrigin",
    "uParticleTarget"
  ]
  ParticleVertexSource =
    when defined(emscripten):
      toShader(gameParticleVertex, glsl3WebGL, shaderVertex)
    else:
      toShader(gameParticleVertex, glsl4Desktop, shaderVertex)
  ParticleFragmentSource =
    when defined(emscripten):
      toShader(gameParticleFragment, glsl3WebGL, shaderFragment)
    else:
      toShader(gameParticleFragment, glsl4Desktop, shaderFragment)

type
  ParticleError* = object of CatchableError

  ParticleUniform = enum
    ViewProjectionUniform,
    CameraRightUniform,
    CameraUpUniform,
    CameraForwardUniform,
    TimeUniform,
    StartTimeUniform,
    TravelTimeUniform,
    SeedUniform,
    EffectKindUniform,
    OriginUniform,
    TargetUniform

  ParticleProgram = object
    id: GLuint
    locations: array[ParticleUniform, GLint]

  ParticleEffect = object
    kind: ParticleEffectKind
    origin: Vec3
    target: Vec3
    startTime: float32
    travelTime: float32
    endTime: float32
    seed: uint32

  ParticleSystem* = object
    program: ParticleProgram
    vertexArray: GLuint
    effects: seq[ParticleEffect]
    time: float32
    nextSeed: uint32

proc compileParticleStage(
    kind: GLenum,
    source,
    label: string
): GLuint =
  ## Compiles one particle shader stage or raises its full diagnostic.
  result = glCreateShader(kind)
  var sources = allocCStringArray([source])
  defer: deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok != 0:
    return
  var length: GLint
  glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
  var log = newString(max(length.int, 1))
  glGetShaderInfoLog(result, length, nil, log.cstring)
  glDeleteShader(result)
  let message = label & " failed:\n" & log.strip(chars = {'\0'}) &
    "\nExpanded source:\n" & source
  echo message
  raise newException(ParticleError, message)

proc compileParticleProgram(): ParticleProgram =
  ## Compiles and links the shared semantic particle shader pair.
  let
    vertex = compileParticleStage(
      GL_VERTEX_SHADER,
      ParticleVertexSource,
      "particle vertex shader"
    )
    fragment = compileParticleStage(
      GL_FRAGMENT_SHADER,
      ParticleFragmentSource,
      "particle fragment shader"
    )
  result.id = glCreateProgram()
  glAttachShader(result.id, vertex)
  glAttachShader(result.id, fragment)
  glLinkProgram(result.id)
  glDeleteShader(vertex)
  glDeleteShader(fragment)
  var ok: GLint
  glGetProgramiv(result.id, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetProgramiv(result.id, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(max(length.int, 1))
    glGetProgramInfoLog(result.id, length, nil, log.cstring)
    glDeleteProgram(result.id)
    raise newException(
      ParticleError,
      "particle shaders failed to link:\n" & log.strip(chars = {'\0'})
    )
  for uniform in ParticleUniform:
    result.locations[uniform] = glGetUniformLocation(
      result.id,
      ParticleUniformNames[uniform.ord].cstring
    )

proc initParticleSystem*(): ParticleSystem =
  ## Creates the shared shaders and empty instanced-quad vertex array.
  result.program = compileParticleProgram()
  result.nextSeed = 1
  glGenVertexArrays(1, result.vertexArray.addr)

proc effectParticleCount(kind: ParticleEffectKind): int =
  ## Returns the bounded instance count for one semantic effect.
  case kind
  of CombatSparks:
    24
  of MagicBolt:
    36
  of MagicBurst:
    32
  of Fireball:
    52
  of FireBurst:
    40
  of ArrowWake:
    24
  of HealingAura:
    48

proc effectLifetime(
    kind: ParticleEffectKind,
    travelTime: float32
): float32 =
  ## Returns how long one effect must remain available for drawing.
  case kind
  of CombatSparks:
    0.9'f32
  of MagicBolt:
    travelTime + 0.7'f32
  of MagicBurst:
    1.25'f32
  of Fireball:
    travelTime + 0.8'f32
  of FireBurst:
    1.0'f32
  of ArrowWake:
    travelTime + 0.35'f32
  of HealingAura:
    1.75'f32

proc addParticleEffect(
    system: var ParticleSystem,
    kind: ParticleEffectKind,
    origin,
    target: Vec3,
    travelTime,
    delay: float32
) =
  ## Adds one effect while keeping the presentation queue bounded.
  if system.effects.len >= MaximumParticleEffects:
    system.effects.delete(0)
  let startTime = system.time + max(delay, 0.0'f32)
  system.effects.add ParticleEffect(
    kind: kind,
    origin: origin,
    target: target,
    startTime: startTime,
    travelTime: max(travelTime, 0.05'f32),
    endTime: startTime + kind.effectLifetime(travelTime),
    seed: system.nextSeed
  )
  inc system.nextSeed

proc emitParticleBurst*(
    system: var ParticleSystem,
    kind: ParticleEffectKind,
    position: Vec3,
    delay = 0.0'f32
) =
  ## Emits one stationary burst now or after a short presentation delay.
  system.addParticleEffect(
    kind,
    position,
    position,
    0.05'f32,
    delay
  )

proc emitParticleProjectile*(
    system: var ParticleSystem,
    projectile,
    impact: ParticleEffectKind,
    origin,
    target: Vec3,
    travelTime: float32
) =
  ## Emits a travelling effect and a matching impact at its destination.
  let duration = max(travelTime, 0.05'f32)
  system.addParticleEffect(
    projectile,
    origin,
    target,
    duration,
    0.0'f32
  )
  system.emitParticleBurst(impact, target, duration)

proc advanceParticles*(system: var ParticleSystem, delta: float32) =
  ## Advances presentation time and removes every finished effect.
  system.time += max(delta, 0.0'f32)
  var index = system.effects.high
  while index >= 0:
    if system.effects[index].endTime <= system.time:
      system.effects.delete(index)
    dec index

proc clearParticles*(system: var ParticleSystem) =
  ## Removes all active effects without rewinding presentation time.
  system.effects.setLen(0)

proc uploadParticleEffect(
    system: ParticleSystem,
    effect: ParticleEffect,
    viewProjection: var Mat4,
    cameraRight,
    cameraUp,
    cameraForward: Vec3
) =
  ## Uploads one effect and the current camera basis to the shader.
  template location(uniform: ParticleUniform): GLint =
    system.program.locations[uniform]
  glUniformMatrix4fv(
    location(ViewProjectionUniform),
    1,
    GL_FALSE,
    cast[ptr float32](viewProjection.addr)
  )
  glUniform3f(
    location(CameraRightUniform),
    cameraRight.x,
    cameraRight.y,
    cameraRight.z
  )
  glUniform3f(
    location(CameraUpUniform),
    cameraUp.x,
    cameraUp.y,
    cameraUp.z
  )
  glUniform3f(
    location(CameraForwardUniform),
    cameraForward.x,
    cameraForward.y,
    cameraForward.z
  )
  glUniform1f(location(TimeUniform), system.time)
  glUniform1f(location(StartTimeUniform), effect.startTime)
  glUniform1f(location(TravelTimeUniform), effect.travelTime)
  glUniform1f(
    location(SeedUniform),
    (effect.seed mod 65_521'u32).float32
  )
  glUniform1i(location(EffectKindUniform), effect.kind.ord.GLint)
  glUniform3f(
    location(OriginUniform),
    effect.origin.x,
    effect.origin.y,
    effect.origin.z
  )
  glUniform3f(
    location(TargetUniform),
    effect.target.x,
    effect.target.y,
    effect.target.z
  )

proc drawParticles*(
    system: ParticleSystem,
    viewProjection: Mat4,
    cameraRight,
    cameraUp,
    cameraForward: Vec3
) =
  ## Draws every active effect with instanced, depth-tested billboards.
  if system.program.id == 0 or system.effects.len == 0:
    return
  var matrix = viewProjection
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glEnable(GL_BLEND)
  glDisable(GL_CULL_FACE)
  glUseProgram(system.program.id)
  glBindVertexArray(system.vertexArray)
  for effect in system.effects:
    if effect.startTime > system.time:
      continue
    if effect.kind == ArrowWake:
      glBlendFuncSeparate(
        GL_SRC_ALPHA,
        GL_ONE_MINUS_SRC_ALPHA,
        GL_ONE,
        GL_ONE_MINUS_SRC_ALPHA
      )
    else:
      glBlendFuncSeparate(
        GL_SRC_ALPHA,
        GL_ONE,
        GL_ZERO,
        GL_ONE
      )
    system.uploadParticleEffect(
      effect,
      matrix,
      cameraRight,
      cameraUp,
      cameraForward
    )
    glDrawArraysInstanced(
      GL_TRIANGLE_STRIP,
      0,
      4,
      effect.kind.effectParticleCount.GLsizei
    )
  glBindVertexArray(0)
  glUseProgram(0)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)

proc closeParticles*(system: var ParticleSystem) =
  ## Releases particle GPU resources and clears presentation state.
  if system.program.id != 0:
    glDeleteProgram(system.program.id)
  if system.vertexArray != 0:
    glDeleteVertexArrays(1, system.vertexArray.addr)
  system = ParticleSystem()
