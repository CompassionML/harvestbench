## Shared exact-silhouette selection outlines for Polyworld graphical clients.

import
  opengl, shady, vmath

const
  ShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop

type
  SelectionOutlineError* = object of CatchableError

  SelectionOutline* = object
    framebuffer: GLuint
    colorTexture: GLuint
    depthBuffer: GLuint
    program: GLuint
    vertexArray: GLuint
    vertexBuffer: GLuint
    size: IVec2

var
  selectionTexture: Uniform[Sampler2d]
  selectionResolution: Uniform[Vec2]
  selectionColor: Uniform[Vec3]

const
  SelectionOutlineColor* = vec3(1.0, 0.78, 0.12)
  AttackOutlineColor* = vec3(0.92, 0.16, 0.14)

proc selectionVertex(
    gl_Position: var Vec4,
    texturePosition: var Vec2,
    vertexPosition: Vec2
) =
  ## Emits one full-screen triangle vertex for the selection outline.
  texturePosition = vertexPosition * 0.5'f32 + 0.5'f32
  gl_Position = vec4(vertexPosition.x, vertexPosition.y, 0, 1)

proc selectionFragment(fragColor: var Vec4, texturePosition: Vec2) =
  ## Finds the outside edge of the selected object's exact silhouette.
  let
    pixel = vec2(1, 1) / selectionResolution
    center = texture(selectionTexture, texturePosition).a
  var nearby = 0.0'f32
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(-2, -2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(0, -2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(2, -2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(-2, 0) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(2, 0) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(-2, 2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(0, 2) * pixel
    ).a
  )
  nearby = max(
    nearby,
    texture(
      selectionTexture,
      texturePosition + vec2(2, 2) * pixel
    ).a
  )
  let edge = clamp(nearby - center, 0, 1)
  fragColor = vec4(selectionColor, edge)

proc compileShaderStage(
    kind: GLenum,
    source,
    label: string
): GLuint =
  ## Compiles one selection shader stage with a useful diagnostic.
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
      SelectionOutlineError,
      label & " shader failed:\n" & log & "\n" & source
    )

proc compileProgram(): GLuint =
  ## Compiles and links the shared selection edge shader program.
  let
    vertexShader = compileShaderStage(
      GL_VERTEX_SHADER,
      toShader(selectionVertex, ShaderTarget, shaderVertex),
      "selection vertex"
    )
    fragmentShader = compileShaderStage(
      GL_FRAGMENT_SHADER,
      toShader(selectionFragment, ShaderTarget, shaderFragment),
      "selection fragment"
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
      SelectionOutlineError,
      "selection program failed:\n" & log
    )

proc initSelectionOutline*(): SelectionOutline =
  ## Creates the selection edge shader and full-screen triangle.
  result.program = compileProgram()
  let vertices = [
    -1.0'f32, -1.0'f32,
    3.0'f32, -1.0'f32,
    -1.0'f32, 3.0'f32
  ]
  glGenVertexArrays(1, result.vertexArray.addr)
  glBindVertexArray(result.vertexArray)
  glGenBuffers(1, result.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    sizeof(vertices),
    unsafeAddr vertices[0],
    GL_STATIC_DRAW
  )
  let location = glGetAttribLocation(result.program, "vertexPosition")
  doAssert location >= 0
  glEnableVertexAttribArray(location.GLuint)
  glVertexAttribPointer(
    location.GLuint,
    2,
    cGL_FLOAT,
    GL_FALSE,
    (2 * sizeof(float32)).GLsizei,
    nil
  )
  glBindVertexArray(0)
  glGenFramebuffers(1, result.framebuffer.addr)
  glGenTextures(1, result.colorTexture.addr)
  glGenRenderbuffers(1, result.depthBuffer.addr)

proc ensureSize(outline: var SelectionOutline, size: IVec2) =
  ## Resizes the silhouette framebuffer to match the current window.
  let safeSize = ivec2(max(size.x, 1), max(size.y, 1))
  if outline.size == safeSize:
    return
  outline.size = safeSize
  glBindTexture(GL_TEXTURE_2D, outline.colorTexture)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RGBA8.GLint,
    safeSize.x,
    safeSize.y,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    nil
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MIN_FILTER,
    GL_NEAREST.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MAG_FILTER,
    GL_NEAREST.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_WRAP_S,
    GL_CLAMP_TO_EDGE.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_WRAP_T,
    GL_CLAMP_TO_EDGE.GLint
  )
  glBindRenderbuffer(GL_RENDERBUFFER, outline.depthBuffer)
  glRenderbufferStorage(
    GL_RENDERBUFFER,
    GL_DEPTH_COMPONENT16,
    safeSize.x,
    safeSize.y
  )
  glBindFramebuffer(GL_FRAMEBUFFER, outline.framebuffer)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER,
    GL_COLOR_ATTACHMENT0,
    GL_TEXTURE_2D,
    outline.colorTexture,
    0
  )
  glFramebufferRenderbuffer(
    GL_FRAMEBUFFER,
    GL_DEPTH_ATTACHMENT,
    GL_RENDERBUFFER,
    outline.depthBuffer
  )
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
    GL_FRAMEBUFFER_COMPLETE
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc beginMask*(outline: var SelectionOutline, size: IVec2) =
  ## Clears and binds the selected-object silhouette target.
  outline.ensureSize(size)
  glBindFramebuffer(GL_FRAMEBUFFER, outline.framebuffer)
  glViewport(0, 0, outline.size.x, outline.size.y)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)
  glEnable(GL_DEPTH_TEST)
  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

proc drawOutline*(
    outline: SelectionOutline,
    color = SelectionOutlineColor
) =
  ## Composites a two-pixel edge around the current silhouette.
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, outline.size.x, outline.size.y)
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(outline.program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, outline.colorTexture)
  glUniform1i(
    glGetUniformLocation(outline.program, "selectionTexture"),
    0
  )
  glUniform2f(
    glGetUniformLocation(outline.program, "selectionResolution"),
    outline.size.x.float32,
    outline.size.y.float32
  )
  glUniform3f(
    glGetUniformLocation(outline.program, "selectionColor"),
    color.x,
    color.y,
    color.z
  )
  glBindVertexArray(outline.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glBindVertexArray(0)
  glUseProgram(0)
  glDisable(GL_BLEND)
