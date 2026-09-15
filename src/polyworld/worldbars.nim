## Shared world-space billboard bars for Polyworld graphical clients.

import
  chroma, opengl, shady, vmath

const
  VertexFloats = 9
  DefaultGap* = 0.045'f32
  DefaultBorder* = 0.035'f32
  DefaultDamageHoldSeconds* = 1.25'f32
  DefaultDamageFadeSeconds* = 0.75'f32
  ShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop

type
  WorldBarError* = object of CatchableError

  WorldBarRenderer* = object
    program: GLuint
    vertexArray: GLuint
    vertexBuffer: GLuint
    vertices: seq[float32]

  WorldResourceBar* = object
    value*: float32
    maximum*: float32
    delayedValue*: float32
    height*: float32
    color*: ColorRGBX
    showDamageTrail*: bool

  DamageTrail = object
    id: int32
    observedValue: float32
    delayedValue: float32
    holdSeconds: float32
    seenFrame: int

  DamageTrailTracker* = object
    trails: seq[DamageTrail]
    frame: int

var
  barViewProjection: Uniform[Mat4]
  barCameraRight: Uniform[Vec3]
  barCameraUp: Uniform[Vec3]

proc barVertex(
    gl_Position: var Vec4,
    fragmentColor: var Vec4,
    worldCenter: Vec3,
    billboardOffset: Vec2,
    vertexColor: Vec4
) =
  ## Transforms one bar vertex into a camera-facing world-space plane.
  let position = worldCenter +
    barCameraRight * billboardOffset.x +
    barCameraUp * billboardOffset.y
  gl_Position = barViewProjection * vec4(position, 1)
  fragmentColor = vertexColor

proc barFragment(fragColor: var Vec4, fragmentColor: Vec4) =
  ## Emits one unlit resource-bar fragment.
  fragColor = fragmentColor

proc compileShaderStage(
    kind: GLenum,
    source,
    label: string
): GLuint =
  ## Compiles one bar shader stage with a useful diagnostic.
  result = glCreateShader(kind)
  let sources = allocCStringArray([source])
  defer:
    deallocCStringArray(sources)
  glShaderSource(result, 1, sources, nil)
  glCompileShader(result)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    raise newException(
      WorldBarError,
      label & " shader failed:\n" & log & "\n" & source
    )

proc compileProgram(): GLuint =
  ## Compiles and links the shared world-bar shader program.
  let
    vertexShader = compileShaderStage(
      GL_VERTEX_SHADER,
      toShader(barVertex, ShaderTarget, shaderVertex),
      "world bar vertex"
    )
    fragmentShader = compileShaderStage(
      GL_FRAGMENT_SHADER,
      toShader(barFragment, ShaderTarget, shaderFragment),
      "world bar fragment"
    )
  result = glCreateProgram()
  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)
  glLinkProgram(result)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)
  var status: GLint
  glGetProgramiv(result, GL_LINK_STATUS, status.addr)
  if status == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    raise newException(
      WorldBarError,
      "world bar program failed:\n" & log
    )

proc initWorldBarRenderer*(): WorldBarRenderer =
  ## Creates one dynamic mesh buffer for all world-space resource bars.
  result.program = compileProgram()
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  const stride = (VertexFloats * sizeof(float32)).GLsizei
  for attribute in [
    (name: "worldCenter", count: 3, offset: 0),
    (name: "billboardOffset", count: 2, offset: 3 * sizeof(float32)),
    (name: "vertexColor", count: 4, offset: 5 * sizeof(float32))
  ]:
    let location = glGetAttribLocation(
      result.program,
      attribute.name.cstring
    )
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(
      location.GLuint,
      attribute.count.GLint,
      cGL_FLOAT,
      GL_FALSE,
      stride,
      cast[pointer](attribute.offset)
    )
  glBindVertexArray(0)

proc clear*(renderer: var WorldBarRenderer) =
  ## Starts one empty bar batch while retaining its vertex allocation.
  renderer.vertices.setLen(0)

proc addVertex(
    renderer: var WorldBarRenderer,
    center: Vec3,
    offset: Vec2,
    color: ColorRGBX
) =
  ## Adds one interleaved billboard vertex to the dynamic mesh.
  const ByteScale = 1.0'f32 / 255.0'f32
  renderer.vertices.add center.x
  renderer.vertices.add center.y
  renderer.vertices.add center.z
  renderer.vertices.add offset.x
  renderer.vertices.add offset.y
  renderer.vertices.add color.r.float32 * ByteScale
  renderer.vertices.add color.g.float32 * ByteScale
  renderer.vertices.add color.b.float32 * ByteScale
  renderer.vertices.add color.a.float32 * ByteScale

proc addQuad(
    renderer: var WorldBarRenderer,
    center: Vec3,
    offset,
    size: Vec2,
    color: ColorRGBX
) =
  ## Adds one camera-facing colored rectangle as two mesh triangles.
  let
    bottomLeft = offset
    bottomRight = offset + vec2(size.x, 0)
    topLeft = offset + vec2(0, size.y)
    topRight = offset + size
  renderer.addVertex(center, bottomLeft, color)
  renderer.addVertex(center, bottomRight, color)
  renderer.addVertex(center, topRight, color)
  renderer.addVertex(center, bottomLeft, color)
  renderer.addVertex(center, topRight, color)
  renderer.addVertex(center, topLeft, color)

proc addResourceBars*(
    renderer: var WorldBarRenderer,
    anchor: Vec3,
    width: float32,
    bars: openArray[WorldResourceBar],
    gap = DefaultGap,
    border = DefaultBorder
) =
  ## Adds an extensible top-down stack of billboard resource bars.
  var top = 0.0'f32
  for bar in bars:
    let
      left = -width * 0.5'f32
      bottom = top - bar.height
      ratio =
        if bar.maximum <= 0:
          0.0'f32
        else:
          clamp(bar.value / bar.maximum, 0.0'f32, 1.0'f32)
      delayedRatio =
        if bar.maximum <= 0:
          0.0'f32
        else:
          clamp(bar.delayedValue / bar.maximum, ratio, 1.0'f32)
    renderer.addQuad(
      anchor,
      vec2(left - border, bottom - border),
      vec2(width + border * 2, bar.height + border * 2),
      rgbx(5, 7, 10, 240)
    )
    renderer.addQuad(
      anchor,
      vec2(left, bottom),
      vec2(width, bar.height),
      rgbx(28, 31, 36, 225)
    )
    if bar.showDamageTrail and delayedRatio > ratio:
      renderer.addQuad(
        anchor,
        vec2(left, bottom),
        vec2(width * delayedRatio, bar.height),
        rgbx(245, 243, 232, 255)
      )
    if ratio > 0:
      renderer.addQuad(
        anchor,
        vec2(left, bottom),
        vec2(width * ratio, bar.height),
        bar.color
      )
    top = bottom - gap

proc draw*(
    renderer: var WorldBarRenderer,
    viewProjection: Mat4,
    cameraRight,
    cameraUp: Vec3
) =
  ## Uploads and draws the world-space billboard batch with scene depth.
  if renderer.vertices.len == 0:
    return
  glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    renderer.vertices.len * sizeof(float32),
    renderer.vertices[0].addr,
    GL_DYNAMIC_DRAW
  )
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_FALSE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(renderer.program)
  barViewProjection = viewProjection
  barCameraRight = cameraRight
  barCameraUp = cameraUp
  glUniformMatrix4fv(
    glGetUniformLocation(renderer.program, "barViewProjection"),
    1,
    GL_FALSE,
    cast[ptr float32](barViewProjection.addr)
  )
  glUniform3f(
    glGetUniformLocation(renderer.program, "barCameraRight"),
    cameraRight.x,
    cameraRight.y,
    cameraRight.z
  )
  glUniform3f(
    glGetUniformLocation(renderer.program, "barCameraUp"),
    cameraUp.x,
    cameraUp.y,
    cameraUp.z
  )
  glBindVertexArray(renderer.vertexArray)
  glDrawArrays(
    GL_TRIANGLES,
    0,
    (renderer.vertices.len div VertexFloats).GLsizei
  )
  glBindVertexArray(0)
  glUseProgram(0)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)

proc healthColor*(value, maximum: float32): ColorRGBX =
  ## Returns green, yellow, or red for the current health percentage.
  let ratio =
    if maximum <= 0:
      0.0'f32
    else:
      clamp(value / maximum, 0.0'f32, 1.0'f32)
  if ratio > 0.6'f32:
    rgbx(62, 201, 92, 255)
  elif ratio > 0.3'f32:
    rgbx(238, 195, 55, 255)
  else:
    rgbx(224, 66, 63, 255)

proc beginFrame*(tracker: var DamageTrailTracker) =
  ## Begins one frame of damage-trail observations.
  inc tracker.frame

proc delayedValue*(
    tracker: var DamageTrailTracker,
    id: int32,
    current,
    maximum,
    dt: float32,
    holdSeconds = DefaultDamageHoldSeconds,
    fadeSeconds = DefaultDamageFadeSeconds
): float32 =
  ## Retains recently lost health, then eases its white trail downward.
  var trailIndex = -1
  for index, trail in tracker.trails:
    if trail.id == id:
      trailIndex = index
      break
  if trailIndex < 0:
    tracker.trails.add DamageTrail(
      id: id,
      observedValue: current,
      delayedValue: current,
      seenFrame: tracker.frame
    )
    trailIndex = tracker.trails.high
  let trail = tracker.trails[trailIndex].addr
  trail.seenFrame = tracker.frame
  if current < trail.observedValue:
    trail.delayedValue = max(trail.delayedValue, trail.observedValue)
    trail.holdSeconds = holdSeconds
  elif current > trail.observedValue:
    trail.delayedValue = max(trail.delayedValue, current)
  trail.observedValue = current
  if trail.holdSeconds > 0:
    trail.holdSeconds = max(trail.holdSeconds - dt, 0.0'f32)
  elif trail.delayedValue > current:
    let amount = min(dt / max(fadeSeconds, 0.001'f32), 1.0'f32)
    trail.delayedValue += (current - trail.delayedValue) * amount
    if trail.delayedValue - current < 0.5'f32:
      trail.delayedValue = current
  trail.delayedValue = clamp(
    trail.delayedValue,
    current,
    max(maximum, current)
  )
  trail.delayedValue

proc finishFrame*(tracker: var DamageTrailTracker) =
  ## Removes damage-trail state for units absent from the current frame.
  var writeIndex = 0
  for readIndex in 0 ..< tracker.trails.len:
    if tracker.trails[readIndex].seenFrame == tracker.frame:
      if writeIndex != readIndex:
        tracker.trails[writeIndex] = tracker.trails[readIndex]
      inc writeIndex
  tracker.trails.setLen(writeIndex)
