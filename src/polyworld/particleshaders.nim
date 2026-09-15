## Shady shaders for bounded one-shot game particle effects.

import
  shady, vmath

type ParticleEffectKind* = enum
  CombatSparks,
  MagicBolt,
  MagicBurst,
  Fireball,
  FireBurst,
  ArrowWake,
  HealingAura

var
  uParticleViewProjection*: Uniform[Mat4]
  uParticleCameraRight*: Uniform[Vec3]
  uParticleCameraUp*: Uniform[Vec3]
  uParticleCameraForward*: Uniform[Vec3]
  uParticleTime*: Uniform[float32]
  uParticleStartTime*: Uniform[float32]
  uParticleTravelTime*: Uniform[float32]
  uParticleSeed*: Uniform[float32]
  uParticleEffectKind*: Uniform[int32]
  uParticleOrigin*: Uniform[Vec3]
  uParticleTarget*: Uniform[Vec3]

func particleHash(value: float32): float32 =
  ## Produces a repeatable zero-to-one value for one particle.
  var fraction = fract(value * 0.1031'f)
  fraction *= fraction + 33.33'f
  fraction *= fraction + fraction
  result = fract(fraction)

proc particleRandom(state: var float32): float32 =
  ## Advances one shader-local random stream.
  state += 1.0'f
  result = particleHash(state)

proc particleDirection(state: var float32): Vec3 =
  ## Produces one uniformly distributed unit vector.
  let
    y = particleRandom(state) * 2.0'f - 1.0'f
    angle = particleRandom(state) * 6.28318530718'f
    radius = sqrt(max(0.0'f, 1.0'f - y * y))
  result = vec3(cos(angle) * radius, y, sin(angle) * radius)

func safeParticleDirection(value: Vec3): Vec3 =
  ## Normalizes a vector with a stable upward fallback.
  let valueLength = length(value)
  if valueLength < 0.0001'f:
    result = vec3(0.0'f, 1.0'f, 0.0'f)
  else:
    result = value / valueLength

proc evaluateParticle(
    particleId: float32,
    position: var Vec3,
    velocity: var Vec3,
    size: var float32,
    color: var Vec4,
    life: var float32,
    alive: var float32
) =
  ## Evaluates one semantic particle entirely on the GPU.
  position = uParticleOrigin
  velocity = vec3(0.0'f)
  size = 0.0'f
  color = vec4(0.0'f)
  life = 0.0'f
  alive = 0.0'f
  let elapsed: float32 = uParticleTime - uParticleStartTime
  if elapsed < 0.0'f:
    return
  var state: float32 = particleId * 17.0'f +
    uParticleSeed * 0.123'f

  if uParticleEffectKind == CombatSparks.ord.int32:
    let
      birth = particleId * 0.0025'f
      age = elapsed - birth
      lifetime = 0.42'f + particleRandom(state) * 0.34'f
    if age < 0.0'f or age >= lifetime:
      return
    var direction = particleDirection(state)
    direction.y = abs(direction.y) * 0.72'f + 0.28'f
    direction = safeParticleDirection(direction)
    let speed = 2.6'f + particleRandom(state) * 3.6'f
    velocity = direction * speed + vec3(0.0'f, -5.4'f * age, 0.0'f)
    position = uParticleOrigin + direction * speed * age +
      vec3(0.0'f, -2.7'f * age * age, 0.0'f)
    life = age / lifetime
    size = 0.022'f * (0.75'f + particleRandom(state) * 0.7'f)
    color = mix(
      vec4(1.0'f, 0.96'f, 0.48'f, 1.0'f),
      vec4(1.0'f, 0.16'f, 0.01'f, 0.0'f),
      life
    )
    alive = 1.0'f
    return

  if uParticleEffectKind == MagicBurst.ord.int32:
    let
      birth = particleId * 0.0035'f
      age = elapsed - birth
      lifetime = 0.72'f + particleRandom(state) * 0.38'f
    if age < 0.0'f or age >= lifetime:
      return
    let
      direction = particleDirection(state)
      progress = age / lifetime
      radius = sin(progress * 3.14159265359'f) *
        (0.45'f + particleRandom(state) * 0.85'f)
    position = uParticleOrigin + direction * radius +
      vec3(0.0'f, age * 0.38'f, 0.0'f)
    velocity = direction * 1.8'f + vec3(0.0'f, 0.38'f, 0.0'f)
    life = progress
    size = mix(0.095'f, 0.025'f, progress) *
      (0.72'f + particleRandom(state) * 0.65'f)
    color = mix(
      vec4(0.26'f, 0.82'f, 1.0'f, 0.95'f),
      vec4(0.85'f, 0.18'f, 1.0'f, 0.0'f),
      progress
    )
    alive = 1.0'f
    return

  if uParticleEffectKind == FireBurst.ord.int32:
    let
      birth = particleId * 0.002'f
      age = elapsed - birth
      lifetime = 0.5'f + particleRandom(state) * 0.35'f
    if age < 0.0'f or age >= lifetime:
      return
    let
      direction = particleDirection(state)
      speed = 1.8'f + particleRandom(state) * 3.2'f
      progress = age / lifetime
    position = uParticleOrigin + direction * speed * age +
      vec3(0.0'f, 0.7'f * age, 0.0'f)
    velocity = direction * speed + vec3(0.0'f, 0.7'f, 0.0'f)
    life = progress
    size = mix(0.16'f, 0.045'f, progress) *
      (0.72'f + particleRandom(state) * 0.62'f)
    color = mix(
      vec4(1.0'f, 0.86'f, 0.18'f, 1.0'f),
      vec4(1.0'f, 0.08'f, 0.01'f, 0.0'f),
      progress
    )
    alive = 1.0'f
    return

  if uParticleEffectKind == HealingAura.ord.int32:
    let
      birth = particleId * 0.008'f
      age = elapsed - birth
      lifetime = 0.9'f + particleRandom(state) * 0.45'f
    if age < 0.0'f or age >= lifetime:
      return
    let
      progress = age / lifetime
      angle = particleRandom(state) * 6.28318530718'f + age * 4.2'f
      radius = 0.28'f + particleRandom(state) * 0.62'f
    position = uParticleOrigin + vec3(
      cos(angle) * radius,
      particleRandom(state) * 0.35'f + age * 1.25'f,
      sin(angle) * radius
    )
    velocity = vec3(
      -sin(angle) * radius * 4.2'f,
      1.25'f,
      cos(angle) * radius * 4.2'f
    )
    life = progress
    size = mix(0.075'f, 0.025'f, progress) *
      (0.75'f + particleRandom(state) * 0.55'f)
    color = mix(
      vec4(0.42'f, 1.0'f, 0.48'f, 0.95'f),
      vec4(1.0'f, 0.88'f, 0.24'f, 0.0'f),
      progress
    )
    alive = 1.0'f
    return

  let
    travel: float32 = max(uParticleTravelTime, 0.05'f)
    path: Vec3 = uParticleTarget - uParticleOrigin
    pathDirection: Vec3 = safeParticleDirection(path)
    pathSpeed: float32 = length(path) / travel
    progress: float32 = clamp(elapsed / travel, 0.0'f, 1.0'f)

  if uParticleEffectKind == MagicBolt.ord.int32:
    if particleId < 4.0'f:
      if elapsed > travel:
        return
      let angle = particleId * 1.57079632679'f + elapsed * 13.0'f
      position = mix(uParticleOrigin, uParticleTarget, progress) + vec3(
        cos(angle) * 0.08'f,
        sin(angle * 1.31'f) * 0.08'f,
        sin(angle) * 0.08'f
      )
      velocity = pathDirection * pathSpeed
      size = 0.13'f
      color = vec4(0.35'f, 0.78'f, 1.0'f, 0.96'f)
      life = progress
      alive = 1.0'f
      return
    let
      birth = (particleId - 4.0'f) / 31.0'f * travel
      age = elapsed - birth
      lifetime = 0.32'f + particleRandom(state) * 0.25'f
    if age < 0.0'f or age >= lifetime or birth > travel:
      return
    let
      birthProgress = clamp(birth / travel, 0.0'f, 1.0'f)
      angle = particleRandom(state) * 6.28318530718'f + age * 11.0'f
      radius = 0.05'f + particleRandom(state) * 0.11'f
    position = mix(uParticleOrigin, uParticleTarget, birthProgress) + vec3(
      cos(angle) * radius,
      sin(angle * 1.37'f) * radius,
      sin(angle) * radius
    )
    velocity = pathDirection * pathSpeed
    life = age / lifetime
    size = mix(0.085'f, 0.025'f, life)
    color = mix(
      vec4(0.22'f, 0.78'f, 1.0'f, 0.88'f),
      vec4(0.82'f, 0.22'f, 1.0'f, 0.0'f),
      life
    )
    alive = 1.0'f
    return

  if uParticleEffectKind == Fireball.ord.int32:
    if particleId < 5.0'f:
      if elapsed > travel:
        return
      let angle = particleId * 1.25663706144'f + elapsed * 17.0'f
      position = mix(uParticleOrigin, uParticleTarget, progress) + vec3(
        cos(angle) * 0.10'f,
        sin(angle * 1.19'f) * 0.10'f,
        sin(angle) * 0.10'f
      )
      velocity = pathDirection * pathSpeed
      size = 0.18'f
      color = vec4(1.0'f, 0.72'f, 0.12'f, 1.0'f)
      life = progress
      alive = 1.0'f
      return
    let
      birth = (particleId - 5.0'f) / 46.0'f * travel
      age = elapsed - birth
      lifetime = 0.38'f + particleRandom(state) * 0.3'f
    if age < 0.0'f or age >= lifetime or birth > travel:
      return
    let
      birthProgress = clamp(birth / travel, 0.0'f, 1.0'f)
      direction = particleDirection(state)
    position = mix(uParticleOrigin, uParticleTarget, birthProgress) +
      direction * particleRandom(state) * 0.13'f +
      vec3(0.0'f, age * 0.35'f, 0.0'f)
    velocity = pathDirection * pathSpeed + vec3(0.0'f, 0.35'f, 0.0'f)
    life = age / lifetime
    size = mix(0.12'f, 0.035'f, life) *
      (0.7'f + particleRandom(state) * 0.7'f)
    color = mix(
      vec4(1.0'f, 0.86'f, 0.18'f, 0.95'f),
      vec4(1.0'f, 0.09'f, 0.01'f, 0.0'f),
      life
    )
    alive = 1.0'f
    return

  if uParticleEffectKind == ArrowWake.ord.int32:
    if particleId < 2.0'f:
      if elapsed > travel:
        return
      position = mix(uParticleOrigin, uParticleTarget, progress)
      velocity = pathDirection * max(pathSpeed, 4.0'f)
      size = 0.032'f
      color = vec4(0.82'f, 0.93'f, 1.0'f, 0.72'f)
      life = progress
      alive = 1.0'f
      return
    let
      birth = (particleId - 2.0'f) / 21.0'f * travel
      age = elapsed - birth
      lifetime = 0.12'f + particleRandom(state) * 0.12'f
    if age < 0.0'f or age >= lifetime or birth > travel:
      return
    let birthProgress = clamp(birth / travel, 0.0'f, 1.0'f)
    position = mix(uParticleOrigin, uParticleTarget, birthProgress) -
      pathDirection * age * 0.35'f +
      particleDirection(state) * 0.025'f
    velocity = pathDirection * max(pathSpeed, 4.0'f)
    life = age / lifetime
    size = mix(0.038'f, 0.012'f, life)
    color = mix(
      vec4(0.78'f, 0.9'f, 1.0'f, 0.35'f),
      vec4(0.42'f, 0.58'f, 0.78'f, 0.0'f),
      life
    )
    alive = 1.0'f

proc gameParticleVertex*(
    gl_Position: var Vec4,
    fragmentUv: var Vec2,
    fragmentColor: var Vec4,
    fragmentLife: var float32,
    fragmentAlive: var float32
) =
  ## Expands one GPU instance into a camera-facing particle quad.
  let
    vertexId = gl_VertexID
    particleId = gl_InstanceID.float32
  fragmentUv = vec2(
    (vertexId mod 2'i32).float32,
    (vertexId div 2'i32).float32
  )
  var
    position: Vec3
    velocity: Vec3
    size: float32
  evaluateParticle(
    particleId,
    position,
    velocity,
    size,
    fragmentColor,
    fragmentLife,
    fragmentAlive
  )
  if fragmentAlive < 0.5'f:
    gl_Position = vec4(2.0'f, 2.0'f, 2.0'f, 1.0'f)
    return
  let corner: Vec2 = fragmentUv * 2.0'f - 1.0'f
  var
    right: Vec3 = uParticleCameraRight
    up: Vec3 = uParticleCameraUp
    lengthScale: float32 = 1.0'f
  if uParticleEffectKind == CombatSparks.ord.int32 or
      uParticleEffectKind == ArrowWake.ord.int32:
    var along: Vec3 = velocity
    along -= uParticleCameraForward * dot(
      velocity,
      uParticleCameraForward
    )
    let alongLength: float32 = length(along)
    if alongLength > 0.0001'f:
      along = along / alongLength
    else:
      along = uParticleCameraUp
    var side: Vec3 = cross(uParticleCameraForward, along)
    let sideLength: float32 = length(side)
    if sideLength > 0.0001'f:
      side = side / sideLength
    else:
      side = uParticleCameraRight
    right = side
    up = along
    if uParticleEffectKind == ArrowWake.ord.int32:
      lengthScale = 7.0'f
    else:
      lengthScale = 1.0'f + length(velocity) * 0.1'f
  let worldPosition: Vec3 = position +
    right * corner.x * size +
    up * corner.y * size * lengthScale
  gl_Position = uParticleViewProjection * vec4(worldPosition, 1.0'f)

proc gameParticleFragment*(
    fragmentUv: Vec2,
    fragmentColor: Vec4,
    fragmentLife: float32,
    fragmentAlive: float32,
    fragColor: var Vec4
) =
  ## Draws a feathered particle with a bright center.
  if fragmentAlive < 0.5'f:
    discardFragment()
  let
    point = fragmentUv * 2.0'f - 1.0'f
    radiusSquared = dot(point, point)
    glow = exp(-radiusSquared * 3.4'f)
    core = exp(-radiusSquared * 15.0'f)
    flicker = 0.9'f + 0.1'f * sin(fragmentLife * 19.0'f)
    alpha = fragmentColor.w * min(1.0'f, glow + core) * flicker
  if alpha < 0.004'f:
    discardFragment()
  fragColor = vec4(
    fragmentColor.xyz * (0.72'f + core * 0.72'f),
    alpha
  )
