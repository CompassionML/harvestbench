## World-space filled shapes for graphical clients.

import
  std/math,
  chroma, opengl, shady, vmath

const
  VertexFloats = 9
  DefaultHalfWidth* = 0.12'f32
  DefaultAlpha* = 128'u8
  CircleSides* = 24
  HexagonSides* = 6
  MiterLimit = 2.5'f32
  ShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop

type
  ShapeError* = object of CatchableError
  ShapeRenderer* = object
    ## Batches colored, optionally textured triangles in world space.
    program: GLuint
    vertexArray: GLuint
    vertexBuffer: GLuint
    whiteTexture: GLuint
    texture*: GLuint
    opaque*: bool
      ## Render solid meshes without the overlay alpha default.
    vertices: seq[float32]

var
  shapeViewProjection: Uniform[Mat4]
  shapeSampler: Uniform[Sampler2d]

proc shapeVertex(
    gl_Position: var Vec4,
    fragmentColor: var Vec4,
    fragmentUv: var Vec2,
    worldPosition: Vec3,
    texturePosition: Vec2,
    vertexColor: Vec4
) =
  ## Transforms one shape vertex by the camera matrix.
  gl_Position = shapeViewProjection * vec4(worldPosition, 1)
  fragmentColor = vertexColor
  fragmentUv = texturePosition

proc shapeFragment(
    fragColor: var Vec4,
    fragmentColor: Vec4,
    fragmentUv: Vec2
) =
  ## Tints one sampled texel by the vertex color.
  fragColor = texture(shapeSampler, fragmentUv) * fragmentColor

proc compileShaderStage(
    kind: GLenum,
    source,
    label: string
): GLuint =
  ## Compiles one shape shader stage with a useful diagnostic.
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
      ShapeError,
      label & " shader failed:\n" & log & "\n" & source
    )

proc compileProgram(): GLuint =
  ## Compiles and links the shape shader program.
  let
    vertexShader = compileShaderStage(
      GL_VERTEX_SHADER,
      toShader(shapeVertex, ShaderTarget, shaderVertex),
      "shape vertex"
    )
    fragmentShader = compileShaderStage(
      GL_FRAGMENT_SHADER,
      toShader(shapeFragment, ShaderTarget, shaderFragment),
      "shape fragment"
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
      ShapeError,
      "shape program failed:\n" & log
    )

proc makeWhiteTexture(): GLuint =
  ## Builds a 1x1 white texel used when no atlas is bound.
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D, result)
  var pixel = [255'u8, 255, 255, 255]
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RGBA.GLint,
    1,
    1,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    pixel[0].addr
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)

proc initShapeRenderer*(): ShapeRenderer =
  ## Creates one dynamic mesh buffer for world-space shapes.
  result.program = compileProgram()
  result.whiteTexture = makeWhiteTexture()
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  const stride = (VertexFloats * sizeof(float32)).GLsizei
  for attribute in [
    (name: "worldPosition", count: 3, offset: 0),
    (name: "texturePosition", count: 2, offset: 3 * sizeof(float32)),
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

proc clear*(renderer: var ShapeRenderer) =
  ## Starts one empty batch while retaining its vertex allocation.
  renderer.vertices.setLen(0)

proc tint(color: ColorRGBX): ColorRGBX =
  ## Uses half alpha when the caller passed a fully opaque color.
  if color.a == 255:
    rgbx(color.r, color.g, color.b, DefaultAlpha)
  else:
    color

proc addVertex(
    renderer: var ShapeRenderer,
    position: Vec3,
    uv: Vec2,
    color: ColorRGBX
) =
  ## Adds one interleaved vertex to the dynamic mesh.
  const ByteScale = 1.0'f32 / 255.0'f32
  renderer.vertices.add position.x
  renderer.vertices.add position.y
  renderer.vertices.add position.z
  renderer.vertices.add uv.x
  renderer.vertices.add uv.y
  renderer.vertices.add color.r.float32 * ByteScale
  renderer.vertices.add color.g.float32 * ByteScale
  renderer.vertices.add color.b.float32 * ByteScale
  renderer.vertices.add color.a.float32 * ByteScale

proc addTriangle*(
    renderer: var ShapeRenderer,
    a,
    b,
    c: Vec3,
    color: ColorRGBX,
    uvA = vec2(0, 0),
    uvB = vec2(1, 0),
    uvC = vec2(0.5, 1)
) =
  ## Adds one world-space triangle.
  let painted = if renderer.opaque: color else: tint(color)
  renderer.addVertex(a, uvA, painted)
  renderer.addVertex(b, uvB, painted)
  renderer.addVertex(c, uvC, painted)

proc addQuad*(
    renderer: var ShapeRenderer,
    a,
    b,
    c,
    d: Vec3,
    color: ColorRGBX,
    uvA = vec2(0, 0),
    uvB = vec2(1, 0),
    uvC = vec2(1, 1),
    uvD = vec2(0, 1)
) =
  ## Adds one quad as two triangles. `a-b-c-d` is the corner winding.
  renderer.addTriangle(a, b, c, color, uvA, uvB, uvC)
  renderer.addTriangle(a, c, d, color, uvA, uvC, uvD)

proc rotateY(offset: Vec3, angle: float32): Vec3 =
  ## Rotates an XZ offset around Y.
  let
    cosine = cos(angle)
    sine = sin(angle)
  vec3(
    offset.x * cosine - offset.z * sine,
    offset.y,
    offset.x * sine + offset.z * cosine
  )

proc addSquare*(
    renderer: var ShapeRenderer,
    center: Vec3,
    size: float32,
    color: ColorRGBX,
    angle = 0.0'f32
) =
  ## Adds a filled XZ square. `size` is the full edge length.
  let h = size * 0.5'f32
  renderer.addQuad(
    center + rotateY(vec3(-h, 0, -h), angle),
    center + rotateY(vec3(h, 0, -h), angle),
    center + rotateY(vec3(h, 0, h), angle),
    center + rotateY(vec3(-h, 0, h), angle),
    color
  )

proc addPolygon*(
    renderer: var ShapeRenderer,
    center: Vec3,
    radius: float32,
    sides: int,
    color: ColorRGBX,
    angle = 0.0'f32
) =
  ## Adds a filled regular polygon in the XZ plane.
  if sides < 3 or radius <= 0:
    return
  let step = TAU / sides.float32
  for i in 0 ..< sides:
    let
      a0 = angle + step * i.float32
      a1 = angle + step * (i + 1).float32
      p0 = center + vec3(cos(a0) * radius, 0, sin(a0) * radius)
      p1 = center + vec3(cos(a1) * radius, 0, sin(a1) * radius)
    renderer.addTriangle(
      center,
      p0,
      p1,
      color,
      vec2(0.5, 0.5),
      vec2(cos(a0) * 0.5'f32 + 0.5'f32, sin(a0) * 0.5'f32 + 0.5'f32),
      vec2(cos(a1) * 0.5'f32 + 0.5'f32, sin(a1) * 0.5'f32 + 0.5'f32)
    )

proc addCircle*(
    renderer: var ShapeRenderer,
    center: Vec3,
    radius: float32,
    color: ColorRGBX,
    sides = CircleSides
) =
  ## Adds a filled XZ circle as a regular polygon.
  renderer.addPolygon(center, radius, sides, color)

proc addHexagon*(
    renderer: var ShapeRenderer,
    center: Vec3,
    radius: float32,
    color: ColorRGBX,
    angle = 0.0'f32
) =
  ## Adds a filled XZ hexagon.
  renderer.addPolygon(center, radius, HexagonSides, color, angle)

proc flatNormal(a, b: Vec3): Vec3 =
  ## Returns the unit left-hand XZ normal of one segment, or zero.
  let
    d = vec3(b.x - a.x, 0, b.z - a.z)
    len2 = lengthSq(d)
  if len2 < 1e-10'f32:
    return vec3(0)
  let inv = 1.0'f32 / sqrt(len2)
  vec3(-d.z * inv, 0, d.x * inv)

proc compactPoints(points: openArray[Vec3]): seq[Vec3] =
  ## Drops consecutive points that sit on top of each other.
  for point in points:
    if result.len == 0 or lengthSq(point - result[^1]) >= 1e-8'f32:
      result.add point

proc addPolyline*(
    renderer: var ShapeRenderer,
    points: openArray[Vec3],
    color: ColorRGBX,
    halfWidth = DefaultHalfWidth
) =
  ## Adds a flat ribbon with mitered joins and beveled sharp corners.
  let pts = compactPoints(points)
  if pts.len < 2 or halfWidth <= 0:
    return
  var
    leftIn = newSeq[Vec3](pts.len)
    rightIn = newSeq[Vec3](pts.len)
    leftOut = newSeq[Vec3](pts.len)
    rightOut = newSeq[Vec3](pts.len)
  let startN = flatNormal(pts[0], pts[1])
  leftIn[0] = pts[0] + startN * halfWidth
  rightIn[0] = pts[0] - startN * halfWidth
  leftOut[0] = leftIn[0]
  rightOut[0] = rightIn[0]
  let endN = flatNormal(pts[^2], pts[^1])
  leftIn[^1] = pts[^1] + endN * halfWidth
  rightIn[^1] = pts[^1] - endN * halfWidth
  leftOut[^1] = leftIn[^1]
  rightOut[^1] = rightIn[^1]
  for i in 1 ..< pts.len - 1:
    let
      n0 = flatNormal(pts[i - 1], pts[i])
      n1 = flatNormal(pts[i], pts[i + 1])
    if lengthSq(n0) < 1e-10'f32 or lengthSq(n1) < 1e-10'f32:
      let n = if lengthSq(n0) > 0: n0 else: n1
      leftIn[i] = pts[i] + n * halfWidth
      rightIn[i] = pts[i] - n * halfWidth
      leftOut[i] = leftIn[i]
      rightOut[i] = rightIn[i]
      continue
    let combined = n0 + n1
    if lengthSq(combined) < 1e-8'f32:
      leftIn[i] = pts[i] + n0 * halfWidth
      rightIn[i] = pts[i] - n0 * halfWidth
      leftOut[i] = pts[i] + n1 * halfWidth
      rightOut[i] = pts[i] - n1 * halfWidth
      continue
    let
      bisector = normalize(combined)
      denom = dot(bisector, n0)
    if denom > 1.0'f32 / MiterLimit:
      let miter = bisector * (halfWidth / denom)
      leftIn[i] = pts[i] + miter
      rightIn[i] = pts[i] - miter
      leftOut[i] = leftIn[i]
      rightOut[i] = rightIn[i]
    else:
      leftIn[i] = pts[i] + n0 * halfWidth
      rightIn[i] = pts[i] - n0 * halfWidth
      leftOut[i] = pts[i] + n1 * halfWidth
      rightOut[i] = pts[i] - n1 * halfWidth
      let turn = n0.x * n1.z - n0.z * n1.x
      if turn > 0:
        renderer.addTriangle(
          pts[i] - n0 * halfWidth,
          pts[i] - n1 * halfWidth,
          pts[i],
          color
        )
      else:
        renderer.addTriangle(
          pts[i] + n0 * halfWidth,
          pts[i] + n1 * halfWidth,
          pts[i],
          color
        )
  var traveled = 0.0'f32
  var total = 0.0'f32
  for i in 0 ..< pts.len - 1:
    total += length(pts[i + 1] - pts[i])
  if total < 1e-8'f32:
    return
  for i in 0 ..< pts.len - 1:
    let
      span = length(pts[i + 1] - pts[i])
      u0 = traveled / total
      u1 = (traveled + span) / total
    renderer.addQuad(
      leftOut[i],
      leftIn[i + 1],
      rightIn[i + 1],
      rightOut[i],
      color,
      vec2(u0, 0),
      vec2(u1, 0),
      vec2(u1, 1),
      vec2(u0, 1)
    )
    traveled += span

proc addLine*(
    renderer: var ShapeRenderer,
    a,
    b: Vec3,
    color: ColorRGBX,
    halfWidth = DefaultHalfWidth
) =
  ## Adds one flat ribbon segment in the XZ plane.
  renderer.addPolyline([a, b], color, halfWidth)

proc draw*(
    renderer: var ShapeRenderer,
    viewProjection: Mat4,
    depthWrite = false
) =
  ## Uploads and draws the shape batch with scene depth.
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
  glDepthMask(if depthWrite: GL_TRUE else: GL_FALSE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(renderer.program)
  shapeViewProjection = viewProjection
  glUniformMatrix4fv(
    glGetUniformLocation(renderer.program, "shapeViewProjection"),
    1,
    GL_FALSE,
    cast[ptr float32](shapeViewProjection.addr)
  )
  glActiveTexture(GL_TEXTURE0)
  if renderer.texture != 0:
    glBindTexture(GL_TEXTURE_2D, renderer.texture)
  else:
    glBindTexture(GL_TEXTURE_2D, renderer.whiteTexture)
  glUniform1i(glGetUniformLocation(renderer.program, "shapeSampler"), 0)
  glBindVertexArray(renderer.vertexArray)
  glDrawArrays(
    GL_TRIANGLES,
    0,
    (renderer.vertices.len div VertexFloats).GLsizei
  )
  glBindVertexArray(0)
  glBindTexture(GL_TEXTURE_2D, 0)
  glDepthMask(GL_TRUE)
