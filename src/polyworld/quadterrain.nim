## Quad terrain rendering as a library: bakes the tile layers from
## polyworld/pathing into OpenGL meshes (tile tops, skirt and cliff walls,
## tree/grass/rock props, transparent water) and draws them with shaders
## authored via shady. The caller builds `layers`, optionally scatters
## props, then calls initTerrain once and bakeTerrain after any change.
## Requires a current GL context and runs relative to the repo root
## (prop models load from ../polyworld_data/terrain/).

import
  std/[random, strformat, strutils, tables],
  chroma, gltf, opengl, pixie, pixie/internal, shady, vmath,
  common, pathing, shadows, terrainblends, terrainmaps, terrainsurfaces, toon

## Shaders
##
## Terrain, props, trees and water share one environment palette: the same
## highlight and shadow colours and light direction the toon character
## renderer uses, so a time-of-day change grades the whole scene together.
## Environment surfaces get a soft version of the character ramp, and the
## sun shadow map (polyworld/shadows) drops occluded ground into the
## palette's shadow band.

var
  envHighlight: Uniform[Vec3]
  envShadow: Uniform[Vec3]
  envLightDirection: Uniform[Vec3]  # toward the light
  # Sun shadow map sampling, fed from polyworld/shadows each frame. Two
  # maps at neighbouring quantized sun steps, cross-faded by shadowStep so
  # shadows dissolve toward the next sun position instead of shimmering.
  shadowMvp0: Uniform[Mat4]
  shadowMvp1: Uniform[Mat4]
  shadowMapPcf0: Uniform[Sampler2dShadow]
  shadowMapPcf1: Uniform[Sampler2dShadow]
  shadowStep: Uniform[float32]
  shadowsOn: Uniform[float32]
  shadowStrength: Uniform[float32]
  shadowBias: Uniform[float32]
  shadowTexel: Uniform[float32]
  shadowSoftness: Uniform[float32]
  shadingStrength: Uniform[float32]
  envLightLevel: Uniform[float32]

const EnvironmentExposure = 1.15'f32
  ## Lifts the palette-graded environment back to the brightness the old
  ## fixed half-lambert gave flat ground under the Day palette.

proc sunLitFraction0(shadowPos: Vec3): float32 =
  ## Raw lit fraction from the first shadow step, 0 shadowed .. 1 clear: a
  ## 3x3 grid of hardware-PCF taps, each itself bilinearly filtered by the
  ## comparison sampler. Positions outside the map count as lit.
  result = 1.0'f
  let
    shadowCoord: Vec4 = shadowMvp0 * vec4(shadowPos, 1.0'f)
    su = shadowCoord.x * 0.5'f + 0.5'f
    sv = shadowCoord.y * 0.5'f + 0.5'f
    sd = shadowCoord.z * 0.5'f + 0.5'f - shadowBias
  if su > 0.0'f and su < 1.0'f and sv > 0.0'f and sv < 1.0'f and sd < 1.0'f:
    let spread = shadowTexel * shadowSoftness
    var lit = 0.0'f32
    lit = lit + texture(shadowMapPcf0, vec3(su - spread, sv - spread, sd))
    lit = lit + texture(shadowMapPcf0, vec3(su, sv - spread, sd))
    lit = lit + texture(shadowMapPcf0, vec3(su + spread, sv - spread, sd))
    lit = lit + texture(shadowMapPcf0, vec3(su - spread, sv, sd))
    lit = lit + texture(shadowMapPcf0, vec3(su, sv, sd))
    lit = lit + texture(shadowMapPcf0, vec3(su + spread, sv, sd))
    lit = lit + texture(shadowMapPcf0, vec3(su - spread, sv + spread, sd))
    lit = lit + texture(shadowMapPcf0, vec3(su, sv + spread, sd))
    lit = lit + texture(shadowMapPcf0, vec3(su + spread, sv + spread, sd))
    result = lit / 9.0'f

proc sunLitFraction1(shadowPos: Vec3): float32 =
  ## The same for the second shadow step.
  result = 1.0'f
  let
    shadowCoord: Vec4 = shadowMvp1 * vec4(shadowPos, 1.0'f)
    su = shadowCoord.x * 0.5'f + 0.5'f
    sv = shadowCoord.y * 0.5'f + 0.5'f
    sd = shadowCoord.z * 0.5'f + 0.5'f - shadowBias
  if su > 0.0'f and su < 1.0'f and sv > 0.0'f and sv < 1.0'f and sd < 1.0'f:
    let spread = shadowTexel * shadowSoftness
    var lit = 0.0'f32
    lit = lit + texture(shadowMapPcf1, vec3(su - spread, sv - spread, sd))
    lit = lit + texture(shadowMapPcf1, vec3(su, sv - spread, sd))
    lit = lit + texture(shadowMapPcf1, vec3(su + spread, sv - spread, sd))
    lit = lit + texture(shadowMapPcf1, vec3(su - spread, sv, sd))
    lit = lit + texture(shadowMapPcf1, vec3(su, sv, sd))
    lit = lit + texture(shadowMapPcf1, vec3(su + spread, sv, sd))
    lit = lit + texture(shadowMapPcf1, vec3(su - spread, sv + spread, sd))
    lit = lit + texture(shadowMapPcf1, vec3(su, sv + spread, sd))
    lit = lit + texture(shadowMapPcf1, vec3(su + spread, sv + spread, sd))
    result = lit / 9.0'f

proc sampleSunShadow(shadowPos: Vec3): float32 =
  ## How lit by the sun a surface point is, cross-fading between the two
  ## quantized sun steps. The result already folds in the shadow strength.
  result = 1.0'f
  if shadowsOn > 0.5'f:
    let lit = mix(
      sunLitFraction0(shadowPos), sunLitFraction1(shadowPos), shadowStep)
    result = 1.0'f - (1.0'f - lit) * shadowStrength

proc envShade(albedo, normal: Vec3, sunFactor: float32): Vec3 =
  ## Palette-graded lighting: half-lambert toward the shared light scaled by
  ## the shadow test, softly stepped, choosing between the shadow and
  ## highlight colours. lightLevel fades only that directional term toward
  ## the shadow band, so the horizon swap does not flatten or black out.
  let
    halfLambert = dot(normalize(normal), envLightDirection) * 0.5'f + 0.5'f
    intensity =
      (1.0'f - shadingStrength + halfLambert * sunFactor * shadingStrength) *
      envLightLevel
    band = smoothstep(0.45'f, 0.8'f, intensity)
  result = albedo * mix(envShadow, envHighlight, band) * EnvironmentExposure

proc envShadeTwoSided(albedo, normal: Vec3, sunFactor: float32): Vec3 =
  ## The same for cards lit from either side (foliage).
  let
    halfLambert =
      abs(dot(normalize(normal), envLightDirection)) * 0.5'f + 0.5'f
    intensity =
      (1.0'f - shadingStrength + halfLambert * sunFactor * shadingStrength) *
      envLightLevel
    band = smoothstep(0.45'f, 0.8'f, intensity)
  result = albedo * mix(envShadow, envHighlight, band) * EnvironmentExposure

var
  mvp: Uniform[Mat4]
  borderWidthUniform: Uniform[float32]
  heightScale: Uniform[float32]
  edgesEnabled: Uniform[float32]
  texScale: Uniform[float32]
  blendDepth: Uniform[float32]
  heightBlend: Uniform[float32]
  terrainTextures: Uniform[Sampler2dArray]
  generatedEnabled: Uniform[float32]
  heightBlendEnabled: Uniform[float32]
  splatsEnabled: Uniform[float32]
  splatAmount: Uniform[float32]
  splatColors: Uniform[Sampler2dArray]
  splatHeights: Uniform[Sampler2dArray]
  splatData: Uniform[Sampler2D]
  blendData: Uniform[Sampler2D]
  splatDataSize: Uniform[Vec2]
  blendDataSize: Uniform[Vec2]
  visibilityTex: Uniform[Sampler2D]
  visibilityOffset: Uniform[float32]
  visibilityScale: Uniform[float32]
  groundMask: Uniform[Sampler2D]
  groundMaskEnabled: Uniform[float32]
  groundLayers: Uniform[Vec4]
  groundRing: Uniform[Vec4]
  groundRingShape: Uniform[Vec3]
  propTint: Uniform[Vec4]

proc texture(buffer: Uniform[Sampler2dArray], position: Vec3): Vec4 =
  ## Provides Shady with the texture-array builtin signature.
  vec4(0)

proc atan(y, x: float32): float32 =
  ## Provides Shady with the two-argument atan builtin.
  arctan2(y, x)

proc textureLod(
    buffer: Uniform[Sampler2dArray], position: Vec3, lod: float32
): Vec4 =
  ## Provides Shady with the explicit-mip texture-array builtin signature.
  vec4(0)

proc blendFetch(index: float32): Vec4 =
  ## Reads one material neighborhood from a nearest-filtered data texture.
  let row = floor(index / blendDataSize.x)
  result = texture(blendData, vec2(
    (index - row * blendDataSize.x + 0.5) / blendDataSize.x,
    (row + 0.5) / blendDataSize.y
  ))

proc splatFetch(index: float32): Vec4 =
  ## Reads one brush record with the same path on desktop GL and WebGL 2.
  let row = floor(index / splatDataSize.x)
  result = texture(splatData, vec2(
    (index - row * splatDataSize.x + 0.5) / splatDataSize.x,
    (row + 0.5) / splatDataSize.y
  ))

proc surfaceAmount(paint, baseHeight, detailHeight: float32): float32 =
  ## Shifts coverage toward higher details while preserving empty endpoints.
  result = paint
  if heightBlendEnabled > 0.5 and paint > 0.0 and paint < 1.0:
    let
      difference = 2.0 * paint - 1.0 +
        (detailHeight - baseHeight) * heightBlend
      ratio = clamp(difference / max(blendDepth, 0.0001), -1.0, 1.0)
      a = 1.0 - max(ratio, 0.0)
      b = 1.0 + min(ratio, 0.0)
    result = b / (a + b)

proc terrainVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    edgeMask: float32,
    normal: Vec3,
    tileColor: Vec3,
    materials: Vec4,
    cornerWeight: Vec4,
    splatRange: Vec3,
    worldPos: var Vec3,
    vertEdgeMask: var float32,
    vertNormal: var Vec3,
    vertColor: var Vec3,
    vertMaterials: var Vec4,
    vertWeights: var Vec4,
    vertSplatRange: var Vec3,
    shadowPos: var Vec3
) =
  ## Emits terrain vertex outputs for the generated OpenGL shader.
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  # Normal-offset shadows: sample the sun's maps slightly off the surface,
  # which suppresses self-shadow acne better than depth bias alone.
  shadowPos = vec3(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08
  )
  worldPos = vertPos
  vertEdgeMask = edgeMask
  vertNormal = normal
  vertColor = tileColor
  vertMaterials = materials
  vertWeights = cornerWeight
  vertSplatRange = splatRange

proc terrainFrag(
    fragColor: var Vec4,
    worldPos: Vec3,
    vertEdgeMask: float32,
    vertNormal: Vec3,
    vertColor: Vec3,
    vertMaterials: Vec4,
    vertWeights: Vec4,
    vertSplatRange: Vec3,
    shadowPos: Vec3
) =
  ## Height-blends textured tile materials and applies visibility fog.
  let
    tilePos = vec2(worldPos.x, worldPos.z)
    h = clamp(
      worldPos.y / max(heightScale, 0.001) * 0.5 + 0.5,
      0.0,
      1.0
    )
    absNormal = abs(vertNormal)
  var uv = vec2(worldPos.x, worldPos.z) * texScale
  if absNormal.y < 0.5:
    if absNormal.x > absNormal.z:
      uv = vec2(worldPos.z, -worldPos.y) * texScale
    else:
      uv = vec2(worldPos.x, -worldPos.y) * texScale
  var
    materials = vertMaterials
    spatial = vertWeights
  if generatedEnabled > 0.5 and vertSplatRange.z >= 0:
    let
      tileUv = tilePos - floor(tilePos)
      quadrant = floor(tileUv.x + 0.5) + floor(tileUv.y + 0.5) * 2.0
      centerUv = tilePos - floor(tilePos + vec2(0.5)) + vec2(0.5)
    materials = blendFetch(floor(vertSplatRange.z + 0.5) + quadrant)
    spatial = radialWeights(centerUv)
  let
    sample0 = texture(
      terrainTextures,
      vec3(uv.x, uv.y, max(materials.x, 0.0))
    )
    sample1 = texture(
      terrainTextures,
      vec3(uv.x, uv.y, max(materials.y, 0.0))
    )
    sample2 = texture(
      terrainTextures,
      vec3(uv.x, uv.y, max(materials.z, 0.0))
    )
    sample3 = texture(
      terrainTextures,
      vec3(uv.x, uv.y, max(materials.w, 0.0))
    )
    blend0 = vertWeights.x + sample0.w * heightBlend
    blend1 = vertWeights.y + sample1.w * heightBlend
    blend2 = vertWeights.z + sample2.w * heightBlend
    blend3 = vertWeights.w + sample3.w * heightBlend
    cutoff = max(
      max(blend0, blend1),
      max(blend2, blend3)
    ) - blendDepth
    weight0 = max(blend0 - cutoff, 0.0)
    weight1 = max(blend1 - cutoff, 0.0)
    weight2 = max(blend2 - cutoff, 0.0)
    weight3 = max(blend3 - cutoff, 0.0)
    totalWeight = weight0 + weight1 + weight2 + weight3
    blended = (
      sample0.xyz * weight0 +
      sample1.xyz * weight1 +
      sample2.xyz * weight2 +
      sample3.xyz * weight3
    ) / max(totalWeight, 0.001)
  # Ground mask: where a game baked stone and dirt coverage, cobbles are
  # discrete. A stone survives only while coverage beats its height, so the
  # rim is ragged whole stones with dirt showing between them, and dirt then
  # height-blends into grass.
  var ground = blended
  let
    worldDx = dFdx(tilePos)
    worldDy = dFdy(tilePos)
  if generatedEnabled > 0.5:
    var weights = materialWeights(spatial, materials)
    if heightBlendEnabled > 0.5:
      weights = reliefWeights(
        weights, vec4(sample0.w, sample1.w, sample2.w, sample3.w),
        heightBlend, blendDepth
      )
    var surface = sample0 * weights.x + sample1 * weights.y +
      sample2 * weights.z + sample3 * weights.w
    if splatsEnabled > 0.5 and splatAmount > 0.0:
      var index = int(vertSplatRange.x + 0.5)
      let finish = index + int(vertSplatRange.y + 0.5)
      while index < finish:
        let
          placement = splatFetch(float32(index * 2))
          brush = splatFetch(float32(index * 2 + 1))
          delta = tilePos - placement.xy
          uvSplat = vec2(
            delta.x * placement.z + delta.y * placement.w,
            delta.y * placement.z - delta.x * placement.w
          ) + vec2(0.5)
          dx = vec2(
            worldDx.x * placement.z + worldDx.y * placement.w,
            worldDx.y * placement.z - worldDx.x * placement.w
          )
          dy = vec2(
            worldDy.x * placement.z + worldDy.y * placement.w,
            worldDy.y * placement.z - worldDy.x * placement.w
          )
        if uvSplat.x >= 0.0 and uvSplat.x <= 1.0 and
          uvSplat.y >= 0.0 and uvSplat.y <= 1.0:
            let
              position = vec3(uvSplat, brush.x)
              paint = textureGrad(splatColors, position, dx, dy)
              relief = textureGrad(splatHeights, position, dx, dy)
              alpha = paint.w
              detailHeight = relief.x / max(relief.w, 0.00001)
              amount = min(alpha, surfaceAmount(
                alpha * brush.y * splatAmount, surface.w, detailHeight
              ))
              source = vec4(paint.xyz / max(alpha, 0.00001), detailHeight)
            surface = surface * (1.0 - amount) + source * amount
        index += 1
    ground = surface.xyz
  if groundMaskEnabled > 0.5:
    let
      maskUv = vec2(
        (tilePos.x + visibilityOffset) * visibilityScale,
        (tilePos.y + visibilityOffset) * visibilityScale
      )
      mask = texture(groundMask, maskUv)
    if mask.x + mask.y > 0.002:
      let
        stone = texture(terrainTextures, vec3(uv.x, uv.y, groundLayers.x))
        dirt = texture(terrainTextures, vec3(uv.x, uv.y, groundLayers.y))
        grass = texture(terrainTextures, vec3(uv.x, uv.y, groundLayers.z))
        dirtBlend = mask.y + dirt.w * heightBlend
        grassBlend = (1.0 - mask.y) + grass.w * heightBlend
        groundCutoff = max(dirtBlend, grassBlend) - blendDepth
        dirtWeight = max(dirtBlend - groundCutoff, 0.0)
        grassWeight = max(grassBlend - groundCutoff, 0.0)
        soil = (dirt.xyz * dirtWeight + grass.xyz * grassWeight) /
          max(dirtWeight + grassWeight, 0.001)
      ground = soil
      if stone.w >= 1.0 - mask.x:
        ground = stone.xyz
  # Ground ring: a curb of cut stones sampled around a circle rather than
  # across the world, one stone row spanning the band, dropping out past
  # the outer edge the same way the cobbles do. The polar coordinate jumps
  # at the angle seam and at every row change, which would send automatic
  # mip selection to the smallest level along those lines, so the mip is
  # chosen from the ring distance, which is smooth everywhere. Screen
  # derivatives are undefined inside a branch some pixels skip, so the
  # ring's derivative is taken before the band test.
  if groundRingShape.x > 0.5:
    let
      ringDx = tilePos.x - groundRing.x
      ringDz = tilePos.y - groundRing.y
      ringDistance = sqrt(ringDx * ringDx + ringDz * ringDz)
      tilesPerPixel = length(
        vec2(dFdx(ringDistance), dFdy(ringDistance)))
    if ringDistance >= groundRing.z:
      let cover = clamp(
        (groundRing.w + groundRingShape.z - ringDistance) / groundRingShape.z,
        0.0, 1.0)
      if cover > 0.0:
        let
          turns = atan(ringDz, ringDx) / 6.2831853 + 0.5
          along = turns * groundRingShape.x
          cells = groundRingShape.y
          sheetTurn = floor(along / cells)
          row = sheetTurn - cells * floor(sheetTurn / cells)
          across = clamp(
            (ringDistance - groundRing.z) / (groundRing.w - groundRing.z),
            0.0, 1.0)
          stoneTiles = 6.2831853 * (groundRing.z + groundRing.w) * 0.5 /
            groundRingShape.x
          texelsPerPixel = 1024.0 / cells * tilesPerPixel / stoneTiles
          lod = max(log2(max(texelsPerPixel, 0.0001)), 0.0)
          curb = textureLod(
            terrainTextures,
            vec3(along / cells, (row + across) / cells, groundLayers.w),
            lod)
        if curb.w >= 1.0 - cover:
          ground = curb.xyz
  var color = ground * vertColor * (0.75 + 0.5 * h)
  # Passability borders draw on upward faces only (walls sit exactly on
  # integer x/z, so the fract test would classify their every pixel as
  # border), and only while the edge display is toggled on. Each strip is
  # colored by its edge's passability: green connected, red blocked. The
  # mask packs the four edges as bits: east 1, south 2, west 4, north 8.
  if edgesEnabled > 0.5 and vertNormal.y > 0.3:
    let
      fx = tilePos.x - floor(tilePos.x)
      fy = tilePos.y - floor(tilePos.y)
      edge = min(min(fx, 1.0 - fx), min(fy, 1.0 - fy))
    if edge < borderWidthUniform:
      var maskLeft = vertEdgeMask
      var northPass = 0.0'f32
      var westPass = 0.0'f32
      var southPass = 0.0'f32
      var eastPass = 0.0'f32
      if maskLeft >= 8.0:
        northPass = 1.0
        maskLeft = maskLeft - 8.0
      if maskLeft >= 4.0:
        westPass = 1.0
        maskLeft = maskLeft - 4.0
      if maskLeft >= 2.0:
        southPass = 1.0
        maskLeft = maskLeft - 2.0
      if maskLeft >= 1.0:
        eastPass = 1.0
      var passable = 0.0'f32
      if edge == fx:
        passable = westPass
      elif edge == 1.0 - fx:
        passable = eastPass
      elif edge == fy:
        passable = northPass
      else:
        passable = southPass
      if passable >= 0.5:
        color = vec3(0.10, 0.72, 0.22)
      else:
        color = vec3(0.88, 0.10, 0.08)
  # Palette-graded lighting: smooth vertex normals across connected
  # terrain, hard breaks at cliffs and walls, sun shadows folded in.
  color = envShade(color, vertNormal, sampleSunShadow(shadowPos))
  let
    visibilityUv = vec2(
      (tilePos.x + visibilityOffset) * visibilityScale,
      (tilePos.y + visibilityOffset) * visibilityScale
    )
    visibility = smoothstep(
      0.05,
      0.95,
      texture(visibilityTex, visibilityUv).x
    )
    gray = dot(color, vec3(0.30, 0.59, 0.11)) * 0.32
  color = color * visibility +
    vec3(gray, gray, gray) * (1.0 - visibility)
  fragColor = vec4(color.x, color.y, color.z, 1.0)

## Water shader: transparent blue with a Blinn-Phong specular highlight.

var
  cameraPos: Uniform[Vec3]
  waterNormals: Uniform[Sampler2dArray]
  waterTime: Uniform[float32]

proc waterVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    normal: Vec3,
    worldPos: var Vec3,
    waterNormal: var Vec3
) =
  ## Emits water vertex outputs for the generated OpenGL shader.
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  worldPos = vertPos
  waterNormal = normal

proc waterFrag(
    fragColor: var Vec4,
    worldPos: Vec3,
    waterNormal: Vec3
) =
  ## Shades transparent water with a view-dependent highlight.
  let
    normalA: Vec3 = texture(waterNormals, vec3(
      worldPos.x * 0.08 + waterTime * 0.018, worldPos.z * 0.08 + waterTime * 0.009, 0.0)).xyz * 2.0 - vec3(1.0)
    normalB: Vec3 = texture(waterNormals, vec3(
      worldPos.z * -0.13 - waterTime * 0.012, worldPos.x * 0.13 + waterTime * 0.015, 1.0)).xyz * 2.0 - vec3(1.0)
    detailNormal: Vec3 = normalize(vec3(
      normalA.x + normalB.x,
      normalA.z + normalB.z,
      normalA.y + normalB.y
    ))
    surfaceNormal: Vec3 = normalize(mix(
      normalize(waterNormal),
      detailNormal,
      clamp(waterNormal.y, 0.0, 1.0) * 0.38
    ))
    specular = pow(
    max(dot(
      surfaceNormal,
      normalize(normalize(cameraPos - worldPos) + envLightDirection)
    ), 0.0),
    48.0)
    visibilityUv = vec2(
      (worldPos.x + visibilityOffset) * visibilityScale,
      (worldPos.z + visibilityOffset) * visibilityScale
    )
    visibility = smoothstep(
      0.05,
      0.95,
      texture(visibilityTex, visibilityUv).x
    )
  let water: Vec3 = vec3(
    (0.05 + 0.08 * visibility) + specular * visibility * envLightLevel,
    (0.10 + 0.24 * visibility) + specular * visibility * envLightLevel,
    (0.16 + 0.42 * visibility) + specular * visibility * envLightLevel
  ) * envHighlight
  fragColor = vec4(water.x, water.y, water.z,
    clamp(0.55 + specular * envLightLevel * 0.45, 0.0, 1.0))

## Prop shader: baked vertex colors with half-lambert lighting.

proc propVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertColor: Vec3,
    normal: Vec3,
    fragmentColor: var Vec3,
    fragmentNormal: var Vec3,
    fragmentPosition: var Vec3,
    shadowPos: var Vec3
) =
  ## Emits baked prop vertex outputs for the generated OpenGL shader.
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  shadowPos = vec3(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08
  )
  fragmentColor = vertColor
  fragmentNormal = normal
  fragmentPosition = vertPos

proc propFrag(
    fragColor: var Vec4,
    fragmentColor: Vec3,
    fragmentNormal,
    fragmentPosition: Vec3,
    shadowPos: Vec3
) =
  ## Shades baked prop colors with the palette-graded lighting.
  let
    visibilityUv = vec2(
      (fragmentPosition.x + visibilityOffset) * visibilityScale,
      (fragmentPosition.z + visibilityOffset) * visibilityScale
    )
    visibility = smoothstep(
      0.05,
      0.95,
      texture(visibilityTex, visibilityUv).x
    )
    litColor = envShade(
      fragmentColor, fragmentNormal, sampleSunShadow(shadowPos))
    gray = dot(litColor, vec3(0.30, 0.59, 0.11)) * 0.32
  fragColor = vec4(
    (litColor.x * visibility + gray * (1.0 - visibility)) * propTint.x,
    (litColor.y * visibility + gray * (1.0 - visibility)) * propTint.y,
    (litColor.z * visibility + gray * (1.0 - visibility)) * propTint.z,
    propTint.w
  )

## Tree shader: handpainted textured meshes whose foliage is alpha-cutout
## cards. The vertex stream carries uv plus the texture array layer; the
## fragment shader discards transparent texels, lights cards from either
## side, and applies the same visibility fade as the terrain.

var
  treeTextures: Uniform[Sampler2dArray]
  treeAlphaCutoff: Uniform[float32]

proc treeVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec3,
    normal: Vec3,
    fragUv: var Vec3,
    fragmentNormal: var Vec3,
    fragmentPosition: var Vec3,
    shadowPos: var Vec3
) =
  ## Emits textured tree vertex outputs for the generated OpenGL shader.
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  shadowPos = vec3(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08
  )
  fragUv = vertUv
  fragmentNormal = normal
  fragmentPosition = vertPos

proc treeFrag(
    fragColor: var Vec4,
    fragUv: Vec3,
    fragmentNormal,
    fragmentPosition: Vec3,
    shadowPos: Vec3
) =
  ## Cuts out foliage by alpha and shades the painting from either side.
  let texel = texture(treeTextures, fragUv)
  if texel.w < treeAlphaCutoff:
    discardFragment()
  let
    visibilityUv = vec2(
      (fragmentPosition.x + visibilityOffset) * visibilityScale,
      (fragmentPosition.z + visibilityOffset) * visibilityScale
    )
    visibility = smoothstep(
      0.05,
      0.95,
      texture(visibilityTex, visibilityUv).x
    )
    litColor = envShadeTwoSided(
      texel.xyz, fragmentNormal, sampleSunShadow(shadowPos))
    gray = dot(litColor, vec3(0.30, 0.59, 0.11)) * 0.32
  fragColor = vec4(
    litColor.x * visibility + gray * (1.0 - visibility),
    litColor.y * visibility + gray * (1.0 - visibility),
    litColor.z * visibility + gray * (1.0 - visibility),
    1.0
  )

proc texturedPropVert(
    gl_Position: var Vec4,
    vertPos: Vec3,
    vertUv: Vec3,
    normal: Vec3,
    vertTint: Vec3,
    fragUv: var Vec3,
    fragmentNormal: var Vec3,
    fragmentPosition: var Vec3,
    shadowPos: var Vec3,
    fragTint: var Vec3
) =
  ## Tree vertex outputs plus a per-instance tint for textured props.
  gl_Position = mvp * vec4(vertPos.x, vertPos.y, vertPos.z, 1.0)
  shadowPos = vec3(
    vertPos.x + normal.x * 0.08,
    vertPos.y + normal.y * 0.08,
    vertPos.z + normal.z * 0.08
  )
  fragUv = vertUv
  fragmentNormal = normal
  fragmentPosition = vertPos
  fragTint = vertTint

proc texturedPropFrag(
    fragColor: var Vec4,
    fragUv: Vec3,
    fragmentNormal,
    fragmentPosition: Vec3,
    shadowPos: Vec3,
    fragTint: Vec3
) =
  ## The tree cutout shading with the instance tint folded into the paint.
  let texel = texture(treeTextures, fragUv)
  if texel.w < treeAlphaCutoff:
    discardFragment()
  let
    visibilityUv = vec2(
      (fragmentPosition.x + visibilityOffset) * visibilityScale,
      (fragmentPosition.z + visibilityOffset) * visibilityScale
    )
    visibility = smoothstep(
      0.05,
      0.95,
      texture(visibilityTex, visibilityUv).x
    )
    paint = vec3(
      texel.x * fragTint.x, texel.y * fragTint.y, texel.z * fragTint.z)
    litColor = envShadeTwoSided(
      paint, fragmentNormal, sampleSunShadow(shadowPos))
    gray = dot(litColor, vec3(0.30, 0.59, 0.11)) * 0.32
  fragColor = vec4(
    litColor.x * visibility + gray * (1.0 - visibility),
    litColor.y * visibility + gray * (1.0 - visibility),
    litColor.z * visibility + gray * (1.0 - visibility),
    1.0
  )

proc texturedInstantFrag(
    fragColor: var Vec4,
    fragUv: Vec3,
    fragmentNormal,
    fragmentPosition: Vec3,
    shadowPos: Vec3
) =
  ## The tree cutout shading with the standalone prop tint folded in, for
  ## textured props drawn per frame rather than baked.
  let texel = texture(treeTextures, fragUv)
  if texel.w < treeAlphaCutoff:
    discardFragment()
  let
    visibilityUv = vec2(
      (fragmentPosition.x + visibilityOffset) * visibilityScale,
      (fragmentPosition.z + visibilityOffset) * visibilityScale
    )
    visibility = smoothstep(
      0.05,
      0.95,
      texture(visibilityTex, visibilityUv).x
    )
    paint = vec3(
      texel.x * propTint.x, texel.y * propTint.y, texel.z * propTint.z)
    litColor = envShadeTwoSided(
      paint, fragmentNormal, sampleSunShadow(shadowPos))
    gray = dot(litColor, vec3(0.30, 0.59, 0.11)) * 0.32
  fragColor = vec4(
    litColor.x * visibility + gray * (1.0 - visibility),
    litColor.y * visibility + gray * (1.0 - visibility),
    litColor.z * visibility + gray * (1.0 - visibility),
    1.0
  )

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

proc compileProgram(vertexSource, fragmentSource: string): GLuint =
  ## Links the terrain shader program or terminates with its diagnostic.
  let
    vertexShader = compileStage(GL_VERTEX_SHADER, vertexSource, "terrain.vert")
    fragmentShader = compileStage(
      GL_FRAGMENT_SHADER,
      fragmentSource,
      "terrain.frag"
    )
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
    quit("terrain program failed:\n" & log)

var
  environmentHighlight = ToonPalettes[0].highlight
  environmentShadow = ToonPalettes[0].shadow
  environmentLight = ToonLightDirection  # direction the light travels

type EnvLocations = object
  highlight, shadow, light, level: GLint

proc envLocations(program: GLuint): EnvLocations =
  result.highlight = glGetUniformLocation(program, "envHighlight")
  result.shadow = glGetUniformLocation(program, "envShadow")
  result.light = glGetUniformLocation(program, "envLightDirection")
  result.level = glGetUniformLocation(program, "envLightLevel")

proc setEnvUniforms(loc: EnvLocations) =
  ## Uploads the environment palette to the program currently in use.
  let
    h = environmentHighlight
    s = environmentShadow
    l = -environmentLight
  glUniform3f(loc.highlight, h.r, h.g, h.b)
  glUniform3f(loc.shadow, s.r, s.g, s.b)
  glUniform3f(loc.light, l.x, l.y, l.z)
  glUniform1f(loc.level, lightLevel)

proc setEnvironmentPalette*(
    highlight, shadow: Color, lightDirection = ToonLightDirection
) =
  ## Sets the palette and light every environment shader draws with.
  environmentHighlight = highlight
  environmentShadow = shadow
  environmentLight = lightDirection

proc setEnvironmentPalette*(toon: ToonContext) =
  ## Matches the environment to a character toon context, so scene and
  ## characters share one palette and light.
  setEnvironmentPalette(toon.highlightColor, toon.shadowColor, toon.lightDirection)

type ShadowLocations = object
  mvp0, mvp1, map0, map1, step: GLint
  on, strength, bias, texel, softness, shading: GLint

proc shadowLocations(program: GLuint): ShadowLocations =
  result.mvp0 = glGetUniformLocation(program, "shadowMvp0")
  result.mvp1 = glGetUniformLocation(program, "shadowMvp1")
  result.map0 = glGetUniformLocation(program, "shadowMapPcf0")
  result.map1 = glGetUniformLocation(program, "shadowMapPcf1")
  result.step = glGetUniformLocation(program, "shadowStep")
  result.on = glGetUniformLocation(program, "shadowsOn")
  result.strength = glGetUniformLocation(program, "shadowStrength")
  result.bias = glGetUniformLocation(program, "shadowBias")
  result.texel = glGetUniformLocation(program, "shadowTexel")
  result.softness = glGetUniformLocation(program, "shadowSoftness")
  result.shading = glGetUniformLocation(program, "shadingStrength")

proc setShadowUniforms(loc: ShadowLocations) =
  ## Uploads the sun shadow state (polyworld/shadows) to the program
  ## currently in use, binding the two step maps on texture units 2 and 3.
  var
    lightMatrix0 = sunLightMvp0
    lightMatrix1 = sunLightMvp1
  glUniformMatrix4fv(
    loc.mvp0, 1, GL_FALSE, cast[ptr float32](lightMatrix0.addr))
  glUniformMatrix4fv(
    loc.mvp1, 1, GL_FALSE, cast[ptr float32](lightMatrix1.addr))
  glUniform1f(loc.step, sunShadowBlend)
  glUniform1f(loc.on, if sunShadowsActive(): 1.0 else: 0.0)
  glUniform1f(loc.strength, sunShadowStrength * lightLevel)
  glUniform1f(loc.bias, sunShadowBias)
  glUniform1f(loc.texel, SunShadowTexel)
  glUniform1f(loc.softness, sunShadowSoftness)
  glUniform1f(loc.shading, sunShadingStrength)
  glActiveTexture(GL_TEXTURE2)
  glBindTexture(GL_TEXTURE_2D, sunShadowTextures[0])
  glUniform1i(loc.map0, 2)
  glActiveTexture(GL_TEXTURE3)
  glBindTexture(GL_TEXTURE_2D, sunShadowTextures[1])
  glUniform1i(loc.map1, 3)
  glActiveTexture(GL_TEXTURE0)

var
  terrainProgram: GLuint
  terrainEnv, waterEnv, propEnv, treeEnv: EnvLocations
  mvpLocation, borderWidthLocation: GLint
  heightScaleLocation, edgesEnabledLocation: GLint
  texScaleLocation, blendDepthLocation, heightBlendLocation: GLint
  terrainTexturesLocation, visibilityTexLocation: GLint
  groundMaskLocation, groundMaskEnabledLocation, groundLayersLocation: GLint
  groundRingLocation, groundRingShapeLocation: GLint
  visibilityOffsetLocation, visibilityScaleLocation: GLint
  terrainTextureArray, visibilityTexture, groundMaskTexture: GLuint
  generatedLocation, heightBlendEnabledLocation: GLint
  splatsEnabledLocation, splatAmountLocation: GLint
  splatColorsLocation, splatHeightsLocation: GLint
  splatDataLocation, blendDataLocation: GLint
  splatDataSizeLocation, blendDataSizeLocation: GLint
  splatColorArray, splatHeightArray, splatDataTexture, blendDataTexture: GLuint
  splatDimensions, blendDimensions: Vec2
  generatedMap: TerrainMap
  terrainAverageColors: seq[Vec3]
  generatedTerrain = false
  groundMaskActive = false
  groundLayerIndices = vec4(4, 5, 0, 0)
  groundRingValues = vec4(0)
  groundRingShapeValues = vec3(0)
  waterProgram: GLuint
  waterMvpLocation, waterCameraLocation, waterNormalsLocation: GLint
  waterTimeLocation, waterVisibilityTexLocation: GLint
  waterVisibilityOffsetLocation, waterVisibilityScaleLocation: GLint
  waterNormalTextureArray: GLuint
  propProgram: GLuint
  propMvpLocation, propVisibilityTexLocation: GLint
  propVisibilityOffsetLocation, propVisibilityScaleLocation: GLint
  propTintLocation: GLint
  treeProgram, texturedPropProgram, texturedInstantProgram: GLuint
  texturedInstantMvpLocation, texturedInstantVisibilityTexLocation: GLint
  texturedInstantVisibilityOffsetLocation: GLint
  texturedInstantVisibilityScaleLocation: GLint
  texturedInstantTexturesLocation, texturedInstantAlphaCutoffLocation: GLint
  texturedInstantTintLocation: GLint
  texturedInstantEnv: EnvLocations
  texturedInstantShadow: ShadowLocations
  texturedPropMvpLocation, texturedPropVisibilityTexLocation: GLint
  texturedPropVisibilityOffsetLocation: GLint
  texturedPropVisibilityScaleLocation: GLint
  texturedPropTexturesLocation, texturedPropAlphaCutoffLocation: GLint
  texturedPropEnv: EnvLocations
  texturedPropShadow: ShadowLocations
  treeMvpLocation, treeVisibilityTexLocation: GLint
  treeVisibilityOffsetLocation, treeVisibilityScaleLocation: GLint
  treeTexturesLocation, treeAlphaCutoffLocation: GLint
  treeTextureArray: GLuint
  terrainShadow, propShadow, treeShadow: ShadowLocations
  terrainDepthVertexArray, propDepthVertexArray: GLuint
  treeDepthVertexArray: GLuint

const OpenGlShaderTarget =
  when defined(emscripten):
    glsl3WebGL
  else:
    glsl4Desktop

## Low-poly props: loaded with the gltf library, the palette texture baked
## into per-vertex colors, each model normalized with its base at the origin.

type
  QuadTerrainError* = object of CatchableError

  PropModel = ref object
    name: string
    height: float32         # model height before pack scaling
    vertices: seq[float32]  # x y z r g b nx ny nz; pack-scaled, base at y 0
    uvs: seq[float32]       # u v layer per vertex, into the pack's atlases
    textureArray: GLuint    # the pack's atlas array; 0 draws vertex colors
    texturedVertexArray: GLuint       # immediate textured draw, on first use
    texturedVertexBuffer: GLuint
    texturedDepthVertexArray: GLuint
    vertexArray: GLuint
    vertexBuffer: GLuint
    depthVertexArray: GLuint  # position-only view for the sun depth pass
    vertexCount: GLsizei
  TreePlacement = object
    model: int
    position: Vec3
    rotation: float32
    scale: float32  # mild per-instance jitter around 1

  PropPack* = ref object
    models: seq[PropModel]
    names: OrderedTable[string, int]
    textureArray: GLuint    # set when the pack was loaded textured

  TexturedBatch = object
    ## Every baked placement of one textured pack, drawn like the trees
    ## with a per-instance tint.
    textureArray: GLuint
    mesh: seq[float32]      # x y z u v layer nx ny nz r g b
    vertexArray, vertexBuffer, depthVertexArray: GLuint

  PropPlacement = object
    model: PropModel
    position: Vec3
    rotation: float32
    scale: float32
    stretch: Vec3           # per-axis scale in model space, before turning
    tint: Vec3              # multiplies the texture of textured models

  TreeModel = object
    name: string
    height: float32         # model height before pack scaling
    width: float32          # Crown diameter around the trunk at any rotation.
    weight: float32         # relative planting frequency
    vertices: seq[float32]  # x y z u v nx ny nz; pack-scaled, base at y 0
    summerLayers: seq[int]  # tree texture array layers this mesh can wear:
    autumnLayers: seq[int]  # greens only, or greens plus reds and yellows

  TreeStyle* = enum
    MixedTrees, EvergreenTrees, DenseTrees
  TerrainStyle* = enum
    CartoonTerrain, GeneratedTerrain
  RockStyle* = enum
    LowPolyRocks, PaintedRocks

var
  treeModels: seq[TreeModel]   # trees; occupy a tile and block it
  grassModels: seq[PropModel]  # grass puffs; walkable decoration
  rockModels: seq[PropModel]   # boulders; half-buried on rock tiles
  grassPlacements: seq[TreePlacement]
  grassMatchesTerrain = false
  rockPlacements: seq[TreePlacement]
  rockScaleRange = vec2(0.9, 1.1)
  rockBurial = 0.45'f
  propPlacements: seq[PropPlacement]
  texturedBatches: seq[TexturedBatch]

proc bakedTexel(image: Image, x, y: int): ColorRGBX =
  ## The colour to bake for one uv sample. Cutout foliage atlases are mostly
  ## transparent and store premultiplied colour, so a vertex whose uv lands
  ## on a clear texel must not bake black: the nearest texel with coverage
  ## in a widening window stands in, and the colour is unpremultiplied.
  for radius in 0 .. 24:
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if max(abs(dx), abs(dy)) != radius:
          continue
        let
          px = x + dx
          py = y + dy
        if px < 0 or py < 0 or px >= image.width or py >= image.height:
          continue
        let texel = image[px, py]
        if texel.a >= 8:
          return rgbx(
            uint8(min(int(texel.r) * 255 div int(texel.a), 255)),
            uint8(min(int(texel.g) * 255 div int(texel.a), 255)),
            uint8(min(int(texel.b) * 255 div int(texel.a), 255)),
            255)
  rgbx(128, 128, 128, 255)

proc atlasLayer(images: var seq[Image], image: Image): float32 =
  ## The layer one material image will occupy in a pack's texture array.
  for i, known in images:
    if known == image:
      return float32(i)
  images.add image
  float32(images.len - 1)

proc collectPropModels(
    node: gltf.Node, parent: Mat4, models: var seq[PropModel],
    skipPrefix = "", only: seq[string] = @[], images: ptr seq[Image] = nil
) =
  ## Flattens renderable glTF nodes into normalized colored triangle models.
  ## With `only` given, nodes not named in it are skipped. With `images`
  ## given, every material image is gathered there and each vertex keeps
  ## its uv and image layer, for packs drawn textured.
  let world = parent * (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  if node.mesh != nil and
      (skipPrefix.len == 0 or not node.name.startsWith(skipPrefix)) and
      (only.len == 0 or node.name in only):
    var
      points: seq[Vec3]
      colors: seq[Vec3]
      uvs: seq[Vec3]
      sourceNormals: seq[Vec3]
      low = vec3(float32.high, float32.high, float32.high)
      high = vec3(float32.low, float32.low, float32.low)
    # Normals need the inverse transpose: node scales can be wildly
    # non-uniform (the rock pack), which distorts rotated normals.
    let normalMatrix = world.inverse.transpose
    for primitive in node.mesh.primitives:
      let
        image =
          if primitive.material != nil: primitive.material.baseColor else: nil
        layer =
          if images != nil and image != nil: atlasLayer(images[], image)
          else: 0.0'f32
      template addCorner(index: int) =
        let point = world * primitive.points[index]
        low = min(low, point)
        high = max(high, point)
        points.add point
        if index < primitive.uvs.len:
          uvs.add vec3(primitive.uvs[index].x, primitive.uvs[index].y, layer)
        else:
          uvs.add vec3(0, 0, layer)
        if index < primitive.normals.len:
          let transformed = normalMatrix * vec4(
            primitive.normals[index].x,
            primitive.normals[index].y,
            primitive.normals[index].z,
            0
          )
          sourceNormals.add normalize(vec3(
            transformed.x,
            transformed.y,
            transformed.z
          ))
        else:
          sourceNormals.add vec3(0, 0, 0)
        if image != nil and index < primitive.uvs.len:
          let
            uv = primitive.uvs[index]
            px = clamp(int(uv.x * image.width.float32), 0, image.width - 1)
            py = clamp(int(uv.y * image.height.float32), 0, image.height - 1)
            sample = bakedTexel(image, px, py)
          colors.add vec3(
            sample.r.float32 / 255 * primitive.material.baseColorFactor.r,
            sample.g.float32 / 255 * primitive.material.baseColorFactor.g,
            sample.b.float32 / 255 * primitive.material.baseColorFactor.b
          )
        elif primitive.material != nil:
          # No UVs (e.g. the grass pack): flat material color.
          colors.add vec3(
            primitive.material.baseColorFactor.r,
            primitive.material.baseColorFactor.g,
            primitive.material.baseColorFactor.b
          )
        else:
          colors.add vec3(0.5, 0.5, 0.5)
      if primitive.indices32.len > 0:
        for index in primitive.indices32:
          addCorner(index.int)
      elif primitive.indices16.len > 0:
        for index in primitive.indices16:
          addCorner(index.int)
    if points.len > 0:
      let
        height = max(high.y - low.y, 0.001'f32)
        center = (low + high) / 2
      var model = PropModel(name: node.name, height: height)
      for t in countup(0, points.len - 3, 3):
        # Authored normals when the model has them; otherwise flat facet
        # normals from the triangle.
        var facet = cross(
          points[t + 1] - points[t], points[t + 2] - points[t])
        if facet.length > 0:
          facet = facet.normalize
        else:
          facet = vec3(0, 1, 0)
        for i in t .. t + 2:
          let
            point = points[i] - vec3(center.x, low.y, center.z)
            normal =
              if sourceNormals[i].length > 0.5: sourceNormals[i]
              else: facet
          model.vertices.add point.x
          model.vertices.add point.y
          model.vertices.add point.z
          model.vertices.add colors[i].x
          model.vertices.add colors[i].y
          model.vertices.add colors[i].z
          model.vertices.add normal.x
          model.vertices.add normal.y
          model.vertices.add normal.z
          model.uvs.add uvs[i].x
          model.uvs.add uvs[i].y
          model.uvs.add uvs[i].z
      models.add model
  for child in node.nodes:
    collectPropModels(child, world, models, skipPrefix, only, images)

proc scalePack(models: var seq[PropModel], targetTallest: float32) =
  ## Scales a whole pack by one factor (tallest model becomes targetTallest
  ## tiles) so relative sizes within the pack are preserved.
  var tallest = 0.001'f32
  for model in models:
    tallest = max(tallest, model.height)
  let packScale = targetTallest / tallest
  for model in models.mitems:
    model.height *= packScale
    var i = 0
    while i < model.vertices.len:
      model.vertices[i] *= packScale
      model.vertices[i + 1] *= packScale
      model.vertices[i + 2] *= packScale
      i += 9

proc normalizeModels(models: var seq[PropModel]) =
  ## Scales each model independently to unit height — for packs whose
  ## showroom sizes vary wildly and carry no meaningful relative scale.
  for model in models.mitems:
    let factor = 1.0'f32 / max(model.height, 0.001)
    model.height = 1.0
    var i = 0
    while i < model.vertices.len:
      model.vertices[i] *= factor
      model.vertices[i + 1] *= factor
      model.vertices[i + 2] *= factor
      i += 9

proc brighten(models: var seq[PropModel], factor: float32) =
  ## Scales the baked vertex colors; some packs are authored very dark.
  for model in models.mitems:
    var i = 0
    while i < model.vertices.len:
      model.vertices[i + 3] = min(model.vertices[i + 3] * factor, 1.0)
      model.vertices[i + 4] = min(model.vertices[i + 4] * factor, 1.0)
      model.vertices[i + 5] = min(model.vertices[i + 5] * factor, 1.0)
      i += 9

## Handpainted trees: textured glb meshes from ../polyworld_data/terrain/handpainted_trees.
## Every variant of a model shares its UV layout, so one texture array holds
## all the paintings and each planted tree picks a layer.

const
  TreeTextures = [
    "fir",                                                       # 0
    "birch_simple_01", "birch_simple_02", "birch_simple_03",     # 1..4
    "birch_simple_04", "oak_simple_01", "oak_simple_02",         # ..6
    "birch_double_01", "birch_double_02", "birch_double_03",     # 7..10
    "birch_double_04", "oak_double_01", "oak_double_02",         # ..12
  ]
    ## Leafy paintings: 01 light green, 02 dark green, 03 red, 04 yellow
    ## (birch); 01 light green, 02 dark green (oak).
  TreeAlphaCutoff = 0.5'f32

proc collectTreeMesh(
    node: gltf.Node, parent: Mat4,
    points: var seq[Vec3], uvs: var seq[Vec2], normals: var seq[Vec3]
) =
  ## Flattens a glb node tree into world-space triangle soup keeping UVs.
  let world = parent * (translate(node.pos) * node.rot.mat4 * scale(node.scale))
  if node.mesh != nil:
    let normalMatrix = world.inverse.transpose
    for primitive in node.mesh.primitives:
      template addCorner(index: int) =
        points.add world * primitive.points[index]
        uvs.add primitive.uvs[index]
        let transformed = normalMatrix * vec4(
          primitive.normals[index].x, primitive.normals[index].y,
          primitive.normals[index].z, 0)
        normals.add normalize(vec3(transformed.x, transformed.y, transformed.z))
      if primitive.indices32.len > 0:
        for index in primitive.indices32:
          addCorner(index.int)
      else:
        for index in primitive.indices16:
          addCorner(index.int)
  for child in node.nodes:
    collectTreeMesh(child, world, points, uvs, normals)

proc loadTreeModel(
    name: string, weight: float32, summerLayers, autumnLayers: seq[int]
): TreeModel =
  ## Loads one tree glb, recentering it on its trunk base.
  var
    points: seq[Vec3]
    uvs: seq[Vec2]
    normals: seq[Vec3]
  collectTreeMesh(
    readGltfFile(&"{DataRoot}/terrain/handpainted_trees/{name}.glb").root, mat4(),
    points, uvs, normals)
  var
    low = vec3(float32.high, float32.high, float32.high)
    high = vec3(float32.low, float32.low, float32.low)
  for point in points:
    low = min(low, point)
    high = max(high, point)
  let center = (low + high) / 2
  result = TreeModel(
    name: name, height: high.y - low.y, weight: weight,
    summerLayers: summerLayers, autumnLayers: autumnLayers)
  for i, point in points:
    let p = point - vec3(center.x, low.y, center.z)
    result.width = max(result.width, 2 * sqrt(p.x * p.x + p.z * p.z))
    result.vertices.add p.x
    result.vertices.add p.y
    result.vertices.add p.z
    result.vertices.add uvs[i].x
    result.vertices.add uvs[i].y
    result.vertices.add normals[i].x
    result.vertices.add normals[i].y
    result.vertices.add normals[i].z

proc scaleTrees(models: var seq[TreeModel], targetTallest: float32) =
  ## Scales the whole tree pack by one factor so relative sizes hold.
  var tallest = 0.001'f32
  for model in models:
    tallest = max(tallest, model.height)
  let packScale = targetTallest / tallest
  for model in models.mitems:
    model.height *= packScale
    model.width *= packScale
    var i = 0
    while i < model.vertices.len:
      model.vertices[i] *= packScale
      model.vertices[i + 1] *= packScale
      model.vertices[i + 2] *= packScale
      i += 8

proc pickTreeModel(rng: var Rand): int =
  ## Weighted choice over the tree models.
  var total = 0.0'f32
  for model in treeModels:
    total += model.weight
  var roll = rng.rand(total.float)
  for i, model in treeModels:
    roll -= model.weight
    if roll <= 0:
      return i
  treeModels.high

proc mipChain(image: Image): seq[Image] =
  ## Full mip chain down to 1x1, box filtered in pixie's premultiplied space.
  result.add image
  while result[^1].width > 1:
    result.add result[^1].minifyBy2()

proc coverage(image: Image): float32 =
  ## Fraction of texels that pass the cutout test.
  var passing = 0
  for c in image.data:
    if c.a.float32 / 255 >= TreeAlphaCutoff:
      inc passing
  passing.float32 / image.data.len.float32

proc loadTreeTextures(): seq[seq[Image]] =
  ## Coverage-preserving mip chains. Box filtering thin leaf shapes into
  ## their transparent surroundings drags alpha under the cutoff, so plain
  ## mips shed leaves level by level and distant trees go bald. Each level
  ## instead gets its alpha rescaled until the same fraction of texels
  ## passes the cutout as at full resolution.
  for name in TreeTextures:
    let chain = mipChain(readImage(&"{DataRoot}/terrain/handpainted_trees/{name}.png"))
    let target = coverage(chain[0])
    for level, mip in chain:
      # Filtered in premultiplied space (no dark fringes); the cutout
      # shader wants straight color.
      mip.data.toStraightAlpha()
      if level == 0:
        continue
      var lo = 1.0'f32
      var hi = 8.0'f32
      for step in 0 ..< 10:
        let mid = (lo + hi) / 2
        var passing = 0
        for c in mip.data:
          if min(c.a.float32 * mid / 255, 1.0) >= TreeAlphaCutoff:
            inc passing
        if passing.float32 / mip.data.len.float32 < target:
          lo = mid
        else:
          hi = mid
      let alphaScale = (lo + hi) / 2
      for c in mip.data.mitems:
        c.a = uint8(min(c.a.float32 * alphaScale, 255))
    result.add chain

proc buildTextureArray(layers: seq[seq[Image]], wrap: GLint): GLuint =
  ## Uploads equally sized RGBA mip chains as one anisotropic
  ## GL_TEXTURE_2D_ARRAY, one chain per layer.
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D_ARRAY, result)
  for level, mip in layers[0]:
    glTexImage3D(
      GL_TEXTURE_2D_ARRAY, level.GLint, GL_RGBA8.GLint,
      mip.width.GLsizei, mip.height.GLsizei,
      layers.len.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil
    )
  for layer, chain in layers:
    if chain.len != layers[0].len:
      raise newException(
        QuadTerrainError, "texture array layers must share dimensions")
    for level, mip in chain:
      if mip.width != layers[0][level].width:
        raise newException(
          QuadTerrainError, "texture array layers must share dimensions")
      glTexSubImage3D(
        GL_TEXTURE_2D_ARRAY, level.GLint, 0, 0, layer.GLint,
        mip.width.GLsizei, mip.height.GLsizei, 1,
        GL_RGBA, GL_UNSIGNED_BYTE, mip.data[0].addr
      )
  glTexParameteri(
    GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_LEVEL, (layers[0].len - 1).GLint)
  when not defined(emscripten):
    glTexParameterf(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_ANISOTROPY_EXT, 8.0)
  glTexParameteri(
    GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, wrap)
  glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, wrap)
  glBindTexture(GL_TEXTURE_2D_ARRAY, 0)

proc loadPropPack*(
    path: string, unitHeight = true, brightness = 1.0'f32,
    only: seq[string] = @[], textured = false, repeatTexture = false,
    maxTextureSize = 0
): PropPack =
  ## Loads named glTF props, scaled to unit height unless disabled.
  ## Brightness adjusts baked colors; textured keeps material images.
  ## RepeatTexture tiles those images beyond their UV edges.
  ## Textured packs require a current GL context.
  result = PropPack()
  var images: seq[Image]
  collectPropModels(
    readGltfFile(path).root, mat4(), result.models, only = only,
    images = if textured: images.addr else: nil)
  if textured and images.len > 0:
    var size = 1
    for image in images:
      size = max(size, max(image.width, image.height))
    if maxTextureSize > 0: size = min(size, maxTextureSize)
    var chains: seq[seq[Image]]
    for image in images:
      let square =
        if image.width == size and image.height == size: image
        else: image.resize(size, size)
      chains.add mipChain(square)
    let wrap =
      if repeatTexture:
        GL_REPEAT.GLint
      else:
        GL_CLAMP_TO_EDGE.GLint
    result.textureArray = buildTextureArray(chains, wrap)
    for model in result.models:
      model.textureArray = result.textureArray
  if unitHeight:
    result.models.normalizeModels()
  if brightness != 1.0'f32:
    result.models.brighten(brightness)
  for i, model in result.models:
    result.names[model.name] = i

proc hasProp*(pack: PropPack, name: string): bool =
  ## Returns whether a pack contains a model with the requested node name.
  pack != nil and name in pack.names

proc propDimensions*(pack: PropPack, name: string): Vec3 =
  ## Bounds after loading/normalization, for collision-aligned placements.
  if not pack.hasProp(name):
    raise newException(QuadTerrainError, "Unknown prop: " & name)
  var low = vec3(float32.high, float32.high, float32.high)
  var high = vec3(float32.low, float32.low, float32.low)
  let vertices = pack.models[pack.names[name]].vertices
  for i in countup(0, vertices.len - 9, 9):
    let p = vec3(vertices[i], vertices[i+1], vertices[i+2])
    low = min(low, p)
    high = max(high, p)
  max(high-low, vec3(0.001, 0.001, 0.001))

proc pickProp*(
    pack: PropPack,
    name: string,
    origin,
    dir,
    position: Vec3,
    rotation,
    propScale: float32
): float32 =
  ## Ray distance to a placed prop's triangles, or -1 when they miss.
  result = -1
  if not pack.hasProp(name):
    return
  let
    model = pack.models[pack.names[name]]
    world =
      translate(position) * rotateY(rotation) *
      scale(vec3(propScale, propScale, propScale))
  var i = 0
  while i + 26 < model.vertices.len:
    let
      a = world * vec3(
        model.vertices[i],
        model.vertices[i + 1],
        model.vertices[i + 2]
      )
      b = world * vec3(
        model.vertices[i + 9],
        model.vertices[i + 10],
        model.vertices[i + 11]
      )
      c = world * vec3(
        model.vertices[i + 18],
        model.vertices[i + 19],
        model.vertices[i + 20]
      )
      distance = rayTriangle(origin, dir, a, b, c)
    if distance > 0 and (result < 0 or distance < result):
      result = distance
    i += 27

proc placeProp*(
    pack: PropPack,
    name: string,
    position: Vec3,
    rotation = 0.0'f32,
    scale = 1.0'f32,
    tint = vec3(1, 1, 1),
    stretch = vec3(1, 1, 1)
) =
  ## Adds one named prop to the next baked terrain mesh. The tint multiplies
  ## the paint of textured models and is ignored by vertex-coloured ones.
  ## Stretch scales each model axis on its own, before the turn, for pieces
  ## that must fit an opening the kit did not size them for.
  if not pack.hasProp(name):
    raise newException(
      QuadTerrainError,
      "terrain prop '" & name & "' was not found in the loaded pack"
    )
  propPlacements.add PropPlacement(
    model: pack.models[pack.names[name]],
    position: position,
    rotation: rotation,
    scale: scale,
    stretch: stretch,
    tint: tint
  )

proc clearProps*() =
  ## Clears all explicit prop placements without changing scattered props.
  propPlacements.setLen(0)

proc uploadPropModel(model: PropModel) =
  ## Uploads one independently drawable prop model on first use.
  if model.vertexArray != 0:
    return
  doAssert propProgram != 0, "initTerrain must run before drawing props"
  glGenVertexArrays(1, model.vertexArray.addr)
  glBindVertexArray(model.vertexArray)
  glGenBuffers(1, model.vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, model.vertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    model.vertices.len * sizeof(float32),
    model.vertices[0].addr,
    GL_STATIC_DRAW
  )
  const stride = (9 * sizeof(float32)).GLsizei
  for attribute in [
    (name: "vertPos", count: 3, offset: 0),
    (name: "vertColor", count: 3, offset: 3 * sizeof(float32)),
    (name: "normal", count: 3, offset: 6 * sizeof(float32))
  ]:
    let location = glGetAttribLocation(
      propProgram,
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
  model.vertexCount = (model.vertices.len div 9).GLsizei
  # A position-only view of the same buffer for the sun depth pass.
  glGenVertexArrays(1, model.depthVertexArray.addr)
  glBindVertexArray(model.depthVertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, model.vertexBuffer)
  block:
    let location = glGetAttribLocation(sunDepthProgramId(), "vertPos")
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(location.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  glBindVertexArray(0)

proc uploadTexturedPropModel(model: PropModel) =
  ## Uploads one textured prop for immediate drawing on first use: a
  ## model-space buffer in the tree layout, with a lit view and a
  ## position-plus-uv view for the cutout depth pass.
  if model.texturedVertexArray != 0:
    return
  doAssert texturedInstantProgram != 0,
    "initTerrain must run before drawing props"
  var mesh: seq[float32]
  var i = 0
  while i < model.vertices.len:
    let uv = i div 9 * 3
    mesh.add model.vertices[i]
    mesh.add model.vertices[i + 1]
    mesh.add model.vertices[i + 2]
    mesh.add model.uvs[uv]
    mesh.add model.uvs[uv + 1]
    mesh.add model.uvs[uv + 2]
    mesh.add model.vertices[i + 6]
    mesh.add model.vertices[i + 7]
    mesh.add model.vertices[i + 8]
    i += 9
  const stride = (9 * sizeof(float32)).GLsizei
  glGenBuffers(1, model.texturedVertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, model.texturedVertexBuffer)
  glBufferData(
    GL_ARRAY_BUFFER,
    mesh.len * sizeof(float32),
    mesh[0].addr,
    GL_STATIC_DRAW
  )
  glGenVertexArrays(1, model.texturedVertexArray.addr)
  glBindVertexArray(model.texturedVertexArray)
  for attribute in [
    (name: "vertPos", count: 3, offset: 0),
    (name: "vertUv", count: 3, offset: 3 * sizeof(float32)),
    (name: "normal", count: 3, offset: 6 * sizeof(float32))
  ]:
    let location = glGetAttribLocation(
      texturedInstantProgram, attribute.name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(
      location.GLuint, attribute.count.GLint, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](attribute.offset))
  glGenVertexArrays(1, model.texturedDepthVertexArray.addr)
  glBindVertexArray(model.texturedDepthVertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, model.texturedVertexBuffer)
  for attribute in [
    (name: "vertPos", count: 3, offset: 0),
    (name: "vertUv", count: 3, offset: 3 * sizeof(float32))
  ]:
    let location = glGetAttribLocation(
      sunCutoutProgramId(), attribute.name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(
      location.GLuint, attribute.count.GLint, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](attribute.offset))
  glBindVertexArray(0)
  model.vertexCount = (model.vertices.len div 9).GLsizei

proc drawTexturedProp(
    model: PropModel,
    position: Vec3,
    rotation,
    propScale: float32,
    viewProjection: Mat4,
    tint: Vec4
) =
  ## Draws one textured prop immediately with the cutout texture program.
  model.uploadTexturedPropModel()
  let model3d =
    translate(position) * rotateY(rotation) *
    scale(vec3(propScale, propScale, propScale))
  var
    transform = viewProjection * model3d
    shadowTransform0 = sunLightMvp0 * model3d
    shadowTransform1 = sunLightMvp1 * model3d
  glDisable(GL_BLEND)
  glDepthMask(GL_TRUE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glUseProgram(texturedInstantProgram)
  setEnvUniforms(texturedInstantEnv)
  setShadowUniforms(texturedInstantShadow)
  glUniformMatrix4fv(
    texturedInstantShadow.mvp0, 1, GL_FALSE,
    cast[ptr float32](shadowTransform0.addr))
  glUniformMatrix4fv(
    texturedInstantShadow.mvp1, 1, GL_FALSE,
    cast[ptr float32](shadowTransform1.addr))
  glUniformMatrix4fv(
    texturedInstantMvpLocation, 1, GL_FALSE,
    cast[ptr float32](transform.addr))
  glUniform1f(texturedInstantVisibilityOffsetLocation, HalfGrid)
  glUniform1f(
    texturedInstantVisibilityScaleLocation, 1.0'f32 / GridTiles.float32)
  glUniform1f(texturedInstantAlphaCutoffLocation, TreeAlphaCutoff)
  glUniform4f(texturedInstantTintLocation, tint.x, tint.y, tint.z, tint.w)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glUniform1i(texturedInstantVisibilityTexLocation, 1)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D_ARRAY, model.textureArray)
  glUniform1i(texturedInstantTexturesLocation, 0)
  glBindVertexArray(model.texturedVertexArray)
  glDrawArrays(GL_TRIANGLES, 0, model.vertexCount)
  glBindVertexArray(0)
  glUseProgram(0)

proc setPropTint(tint: Vec4) =
  ## Uploads the standalone or batched prop color multiply.
  if propTintLocation >= 0:
    glUniform4f(propTintLocation, tint.x, tint.y, tint.z, tint.w)

proc drawProp*(
    pack: PropPack,
    name: string,
    position: Vec3,
    rotation,
    propScale: float32,
    viewProjection: Mat4,
    tint = vec4(1, 1, 1, 1)
) =
  ## Draws one named prop immediately into the current framebuffer.
  if not pack.hasProp(name):
    return
  let model = pack.models[pack.names[name]]
  if model.textureArray != 0:
    drawTexturedProp(
      model, position, rotation, propScale, viewProjection, tint)
    return
  model.uploadPropModel()
  let model3d =
    translate(position) * rotateY(rotation) *
    scale(vec3(propScale, propScale, propScale))
  var transform = viewProjection * model3d
  if tint.w < 1.0'f32:
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDepthMask(GL_FALSE)
  else:
    glDisable(GL_BLEND)
    glDepthMask(GL_TRUE)
  glDisable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glUseProgram(propProgram)
  setEnvUniforms(propEnv)
  setShadowUniforms(propShadow)
  # Standalone props keep model-space vertices, so the shadow lookups need
  # the model transform folded into both step matrices.
  var
    shadowTransform0 = sunLightMvp0 * model3d
    shadowTransform1 = sunLightMvp1 * model3d
  glUniformMatrix4fv(
    propShadow.mvp0, 1, GL_FALSE, cast[ptr float32](shadowTransform0.addr))
  glUniformMatrix4fv(
    propShadow.mvp1, 1, GL_FALSE, cast[ptr float32](shadowTransform1.addr))
  glUniformMatrix4fv(
    propMvpLocation,
    1,
    GL_FALSE,
    cast[ptr float32](transform.addr)
  )
  setPropTint(tint)
  glBindVertexArray(model.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, model.vertexCount)
  glBindVertexArray(0)
  glUseProgram(0)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)

## Terrain parameters

const
  TerrainTextureSize = 1024
  GeneratedTextureSize = 256
  TerrainVertexSize = 21
  WaterNormalTextures = ["water_1_normal", "water_2_normal"]
  TerrainMaterials = [
    "grass",
    "sand",
    "cliff",
    "marsh",
    "stone",
    "dirt",
    "volcanic",
    "underwater"
  ]
  GrassMaterial* = 0.0'f32
  SandMaterial* = 1.0'f32
  CliffMaterial* = 2.0'f32
  MarshMaterial* = 3.0'f32
  StoneMaterial* = 4.0'f32
  DirtMaterial* = 5.0'f32
  VolcanicMaterial* = 6.0'f32
  UnderwaterMaterial* = 7.0'f32

var
  amplitude* = 2.91'f32   # height scale for shading; also sets the floor
  borderWidth* = 0.05'f32 # width of the passability border strips
  terrainTextureScale* = 0.27'f
    ## Texture repeats per tile, with higher values making smaller patterns.
  terrainBlendDepth* = 0.12'f32  # blend band width; smaller is more abrupt
  terrainHeightBlend* = 1.2'f32  # how strongly height maps steer the blend
  terrainHeightBlending* = true
  terrainSplats* = true
  terrainSplatCount* = 1
  terrainSplatChance* = 0.4'f
  terrainSplatAmount* = 1.0'f
  terrainGrassPatchSize* = 24.0'f
  terrainSplatPlacements*, terrainPeakSplats*: int
  treeHeight* = 6.0'f32   # tallest tree in tiles, before per-tree jitter
  treeWidth* = 0.0'f
    ## Maximum crown diameter in tiles, or zero to keep the pack proportions.
  autumnTrees* = false    # leafy trees may also wear red and yellow
  seed* = 1988            # seeds the per-tile tree rng in bakeTreeTiles
  layerVertexRanges*: seq[Slice[int]]
    ## Filled by bakeTerrain: which baked vertices belong to which layer, so
    ## callers can draw a subset without re-emitting anything.

type TileMaterial* = object
  top*: Vec3
  skirt*: Vec3
  topMaterial*: float32
  skirtMaterial*: float32
  blendPriority*: int32

# Tile material index: texture layers, tints, and blending priority by kind.
var tileMaterialTable* = @[
  TileMaterial(
    top: vec3(1),
    skirt: vec3(0.85),
    topMaterial: GrassMaterial,
    skirtMaterial: DirtMaterial,
    blendPriority: 1
  ),
  TileMaterial(
    top: vec3(1),
    skirt: vec3(0.85),
    topMaterial: SandMaterial,
    skirtMaterial: DirtMaterial,
    blendPriority: 5
  ),
  TileMaterial(
    top: vec3(1),
    skirt: vec3(0.9),
    topMaterial: CliffMaterial,
    skirtMaterial: VolcanicMaterial,
    blendPriority: 4
  ),
  TileMaterial(
    top: vec3(1),
    skirt: vec3(0.8, 0.8, 0.75),
    topMaterial: MarshMaterial,
    skirtMaterial: DirtMaterial,
    blendPriority: 2
  ),
  TileMaterial(
    top: vec3(1),
    skirt: vec3(0.9),
    topMaterial: StoneMaterial,
    skirtMaterial: StoneMaterial,
    blendPriority: 6
  ),
  TileMaterial(
    top: vec3(1),
    skirt: vec3(0.85),
    topMaterial: GrassMaterial,
    skirtMaterial: DirtMaterial,
    blendPriority: 0
  ),
]

proc setTileColor*(kind: int, top, skirt: Vec3) =
  ## Replaces one tile kind's tint without changing its texture materials.
  while tileMaterialTable.len <= kind:
    tileMaterialTable.add TileMaterial(
      top: vec3(1, 0, 1),
      skirt: vec3(0.5, 0, 0.5),
      topMaterial: StoneMaterial,
      skirtMaterial: DirtMaterial,
      blendPriority: int32(tileMaterialTable.len + 10)
    )
  tileMaterialTable[kind].top = top
  tileMaterialTable[kind].skirt = skirt

proc setTileMaterial*(
    kind: int,
    topMaterial,
    skirtMaterial: float32,
    top,
    skirt: Vec3,
    blendPriority: int32
) =
  ## Registers one textured tile style, growing the flat style table.
  setTileColor(kind, top, skirt)
  tileMaterialTable[kind].topMaterial = topMaterial
  tileMaterialTable[kind].skirtMaterial = skirtMaterial
  tileMaterialTable[kind].blendPriority = blendPriority

proc averageColor(image: Image): Vec3 =
  ## Averages premultiplied texture colors by their coverage, before lighting.
  var sums: array[4, uint64]
  for pixel in image.data:
    sums[0] += pixel.r.uint64
    sums[1] += pixel.g.uint64
    sums[2] += pixel.b.uint64
    sums[3] += pixel.a.uint64
  if sums[3] == 0:
    return vec3(0)
  vec3(sums[0].float32, sums[1].float32, sums[2].float32) /
    sums[3].float32

proc loadTerrainMaterials(): seq[seq[Image]] =
  ## Each material's basecolor with its height map packed into alpha. The
  ## alpha isn't coverage here, so mips must not premultiply by it: build
  ## the chain from the opaque color and re-pack height per level.
  terrainAverageColors.setLen(0)
  for name in TerrainMaterials:
    let
      colors = mipChain(readImage(
        &"{DataRoot}/terrain/cartoon_textures/{name}_color.png"))
      heights = mipChain(readImage(
        &"{DataRoot}/terrain/cartoon_textures/{name}_height.png"))
    if colors[0].width != TerrainTextureSize or
        colors[0].height != TerrainTextureSize or
        heights.len != colors.len:
      raise newException(
        QuadTerrainError,
        "terrain material has the wrong dimensions: " & name
      )
    terrainAverageColors.add averageColor(colors[0])
    for level in 0 ..< colors.len:
      for i in 0 ..< colors[level].data.len:
        colors[level].data[i].a = heights[level].data[i].r
    result.add colors

proc generatedMaterial(directory, name: string): tuple[color, height: Image] =
  ## Loads an aligned generated pair and attaches color coverage to relief.
  try:
    result.color = readImage(
      DataRoot & "/terrain/" & directory & "/" & name & ".rgb.png"
    )
    result.height = readImage(
      DataRoot & "/terrain/" & directory & "/" & name & ".height.png"
    )
  except PixieError:
    raise newException(QuadTerrainError, getCurrentExceptionMsg())
  if result.color.width != GeneratedTextureSize or
    result.color.height != GeneratedTextureSize or
    result.height.width != GeneratedTextureSize or
    result.height.height != GeneratedTextureSize:
      raise newException(QuadTerrainError, "Expected 256x256 material: " & name)
  for i, value in result.height.data:
    let alpha = result.color.data[i].a
    if value.a != 255 or value.r != value.g or value.g != value.b or
      (directory == "tiles" and alpha != 255):
        raise newException(QuadTerrainError, "Invalid terrain channels: " & name)
    if directory == "stamps":
      let gray = ((value.r.int * alpha.int + 127) div 255).uint8
      result.height.data[i] = rgbx(gray, gray, gray, alpha)

proc loadGeneratedTiles(extraTiles: openArray[string]): seq[seq[Image]] =
  ## Packs independently filtered color and height into the terrain array.
  terrainAverageColors.setLen(0)
  for name in @SurfaceNames & @extraTiles:
    let
      pair = generatedMaterial("tiles", name)
      colors = mipChain(pair.color)
      heights = mipChain(pair.height)
    terrainAverageColors.add averageColor(colors[0])
    for level in 0 ..< colors.len:
      for i in 0 ..< colors[level].data.len:
        colors[level].data[i].a = heights[level].data[i].r
    result.add colors

proc loadGeneratedStamps(): tuple[colors, heights: seq[seq[Image]]] =
  ## Keeps splat colors and relief in separate arrays with identical coverage.
  for name in SurfaceNames:
    let pair = generatedMaterial("stamps", name)
    result.colors.add mipChain(pair.color)
    result.heights.add mipChain(pair.height)

proc uploadTerrainData(texture: var GLuint, values: seq[float32]): Vec2 =
  ## Uploads flat RGBA records into a portable nearest-filtered float texture.
  if values.len == 0 or values.len mod 4 != 0:
    raise newException(QuadTerrainError, "Terrain data needs complete RGBA records.")
  let count = values.len div 4
  var maximum: GLint
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, maximum.addr)
  let
    width = min(min(1024, maximum.int), count)
    height = (count + width - 1) div width
  if count > 16_777_215 or height > maximum.int:
    raise newException(QuadTerrainError, "Terrain data exceeds GPU capacity.")
  var data = newSeq[float32](width * height * 4)
  copyMem(data[0].addr, unsafeAddr values[0], values.len * sizeof(float32))
  if texture == 0:
    glGenTextures(1, texture.addr)
  glBindTexture(GL_TEXTURE_2D, texture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA32F.GLint, width.GLsizei, height.GLsizei,
    0, GL_RGBA, cGL_FLOAT, data[0].addr
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)
  vec2(width.float32, height.float32)

proc rebuildTerrainData() =
  ## Refreshes visual sidecars without altering terrain or simulation flags.
  if not generatedTerrain:
    return
  var materials: seq[int]
  for style in tileMaterialTable:
    materials.add style.topMaterial.int
  try:
    generatedMap = buildTerrainMap(
      layers,
      materials,
      seed,
      1.0'f / terrainTextureScale,
      terrainGrassPatchSize,
      amplitude,
      terrainSplatCount,
      terrainSplatChance,
      terrainAverageColors.len
    )
  except TerrainMapError:
    raise newException(QuadTerrainError, getCurrentExceptionMsg())
  blendDimensions = uploadTerrainData(blendDataTexture, generatedMap.blends)
  splatDimensions = uploadTerrainData(splatDataTexture, generatedMap.brushes)
  terrainSplatPlacements = generatedMap.placements
  terrainPeakSplats = generatedMap.peak

proc bindTerrainData() =
  ## Binds generated material controls and brush records for either draw path.
  glUniform1f(generatedLocation, if generatedTerrain: 1 else: 0)
  glUniform1f(heightBlendEnabledLocation, if terrainHeightBlending: 1 else: 0)
  glUniform1f(splatsEnabledLocation, if terrainSplats: 1 else: 0)
  glUniform1f(splatAmountLocation, clamp(terrainSplatAmount, 0.0'f, 1.0'f))
  glUniform2f(splatDataSizeLocation, splatDimensions.x, splatDimensions.y)
  glUniform2f(blendDataSizeLocation, blendDimensions.x, blendDimensions.y)
  for (unit, target, texture, location) in [
    (5, GL_TEXTURE_2D_ARRAY, splatColorArray, splatColorsLocation),
    (6, GL_TEXTURE_2D_ARRAY, splatHeightArray, splatHeightsLocation),
    (7, GL_TEXTURE_2D, splatDataTexture, splatDataLocation),
    (8, GL_TEXTURE_2D, blendDataTexture, blendDataLocation)
  ]:
    glActiveTexture((GL_TEXTURE0.int + unit).GLenum)
    glBindTexture(target, texture)
    glUniform1i(location, unit.GLint)

proc loadWaterNormals(): seq[seq[Image]] =
  ## Water detail uses the same mipmapped texture-array path as terrain and
  ## trees, with one shared-data image per layer.
  for name in WaterNormalTextures:
    result.add mipChain(readImage(
      &"{DataRoot}/terrain/water_normals/{name}.jpg"))

proc setTerrainMaterial*(index: int, color, height: Image) =
  ## Replaces one material layer with a generated basecolor and height map,
  ## packed the same way as the shipped materials. Needs the texture array
  ## that initTerrain builds.
  if terrainTextureArray == 0:
    raise newException(
      QuadTerrainError,
      "terrain materials can only be replaced after initTerrain"
    )
  let
    materialCount = terrainAverageColors.len
    size =
      if generatedTerrain:
        GeneratedTextureSize
      else:
        TerrainTextureSize
  if index < 0 or index >= materialCount:
    raise newException(
      QuadTerrainError,
      "terrain material index out of range: " & $index
    )
  if color.width != size or
      color.height != size or
      height.width != color.width or height.height != color.height:
    raise newException(
      QuadTerrainError,
      "terrain material replacement has the wrong dimensions"
    )
  let
    colors = mipChain(color)
    heights = mipChain(height)
  terrainAverageColors[index] = averageColor(colors[0])
  glBindTexture(GL_TEXTURE_2D_ARRAY, terrainTextureArray)
  for level in 0 ..< colors.len:
    let mip = colors[level]
    for i in 0 ..< mip.data.len:
      mip.data[i].a = heights[level].data[i].r
    glTexSubImage3D(
      GL_TEXTURE_2D_ARRAY, level.GLint, 0, 0, index.GLint,
      mip.width.GLsizei, mip.height.GLsizei, 1,
      GL_RGBA, GL_UNSIGNED_BYTE, mip.data[0].addr
    )
  glBindTexture(GL_TEXTURE_2D_ARRAY, 0)

proc uploadTerrainVisibility*(values: openArray[uint8]) =
  ## Uploads one visibility value per world tile for terrain fog rendering.
  if visibilityTexture == 0:
    return
  if values.len != GridTiles * GridTiles:
    raise newException(
      QuadTerrainError,
      "terrain visibility must contain one value per world tile"
    )
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glTexSubImage2D(
    GL_TEXTURE_2D,
    0,
    0,
    0,
    GridTiles,
    GridTiles,
    GL_RED,
    GL_UNSIGNED_BYTE,
    unsafeAddr values[0]
  )
  glBindTexture(GL_TEXTURE_2D, 0)

proc uploadGroundMask*(values: openArray[uint8], size: int) =
  ## Uploads a square two-channel coverage mask (stone, dirt) the terrain
  ## shader samples by tile position, and switches the ground path on.
  if values.len != size * size * 2:
    raise newException(
      QuadTerrainError,
      "ground mask must hold two bytes per texel"
    )
  if groundMaskTexture == 0:
    glGenTextures(1, groundMaskTexture.addr)
    glBindTexture(GL_TEXTURE_2D, groundMaskTexture)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(
      GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(
      GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, groundMaskTexture)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RG8.GLint,
    size.GLsizei,
    size.GLsizei,
    0,
    GL_RG,
    GL_UNSIGNED_BYTE,
    unsafeAddr values[0]
  )
  glBindTexture(GL_TEXTURE_2D, 0)
  groundMaskActive = true

proc clearGroundMask*() =
  ## Returns the terrain to plain corner-material blending.
  groundMaskActive = false

proc setGroundLayers*(stone, dirt, grass: float32, curb = 0.0'f32) =
  ## Names the texture-array layers the ground mask path draws with. The
  ## curb layer only matters while a ground ring is set.
  groundLayerIndices = vec4(stone, dirt, grass, curb)

proc setGroundRing*(
    centerX, centerZ, inner, outer: float32,
    stones, cells: int, fade: float32
) =
  ## Draws a curb of cut stones around a circle in world xz: `stones` around
  ## the ring from a sheet holding `cells` stones per side, one stone row
  ## spanning inner .. outer, dropping out over `fade` past the outer edge.
  groundRingValues = vec4(centerX, centerZ, inner, outer)
  groundRingShapeValues = vec3(float32(stones), float32(cells), fade)

proc clearGroundRing*() =
  ## Removes the curb.
  groundRingShapeValues = vec3(0)

proc bindGroundMask() =
  ## Sets the ground mask uniforms for one terrain draw. Units 2 and 3 are
  ## the sun shadow maps.
  glUniform1f(
    groundMaskEnabledLocation, if groundMaskActive: 1.0 else: 0.0)
  glUniform4f(
    groundLayersLocation,
    groundLayerIndices.x, groundLayerIndices.y, groundLayerIndices.z,
    groundLayerIndices.w)
  glUniform4f(
    groundRingLocation,
    groundRingValues.x, groundRingValues.y, groundRingValues.z,
    groundRingValues.w)
  glUniform3f(
    groundRingShapeLocation,
    groundRingShapeValues.x, groundRingShapeValues.y,
    groundRingShapeValues.z)
  if groundMaskTexture == 0:
    glGenTextures(1, groundMaskTexture.addr)
    glBindTexture(GL_TEXTURE_2D, groundMaskTexture)
    var pixel = [0'u8, 0]
    glTexImage2D(
      GL_TEXTURE_2D, 0, GL_RG8.GLint, 1, 1, 0,
      GL_RG, GL_UNSIGNED_BYTE, pixel[0].addr
    )
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glActiveTexture(GL_TEXTURE4)
  glBindTexture(GL_TEXTURE_2D, groundMaskTexture)
  glUniform1i(groundMaskLocation, 4)

proc showAllTerrain*() =
  ## Restores fully lit terrain for an omniscient spectator view.
  var values = newSeq[uint8](GridTiles * GridTiles)
  for value in values.mitems:
    value = 255
  uploadTerrainVisibility(values)

## Prop scattering

proc scatterGrass*(count, randomSeed: int, matchTerrain = false) =
  ## Grass puffs: walkable decoration scattered on plain grass tiles only,
  ## jittered inside the tile, optionally colored from the terrain beneath.
  ## Call after the ground layer is built and before bakeTerrain.
  grassPlacements.setLen(0)
  grassMatchesTerrain = matchTerrain
  if grassModels.len == 0 or layers.len == 0:
    return
  template gtile(x, z: int): Tile =
    layers[0].tiles[(z) * layers[0].width + (x)]
  var grassRng = initRand(randomSeed.int64 * 31_337'i64 + 7'i64)
  var attempts = 0
  var placed = 0
  while placed < count and attempts < count * 20:
    inc attempts
    let
      x = grassRng.rand(layers[0].width - 1)
      z = grassRng.rand(layers[0].depth - 1)
    if not gtile(x, z).exists or gtile(x, z).impassable or
        gtile(x, z).kind != GrassTile:
      continue
    let
      h = gtile(x, z).tops.unpack
      offsetX = 0.15'f32 + grassRng.rand(0.7).float32
      offsetZ = 0.15'f32 + grassRng.rand(0.7).float32
      height = (h[0] * (1 - offsetX) + h[1] * offsetX) * (1 - offsetZ) +
        (h[2] * (1 - offsetX) + h[3] * offsetX) * offsetZ
    grassPlacements.add TreePlacement(
      model: grassRng.rand(grassModels.len - 1),
      position: vec3(
        (layers[0].originX + x).float32 - HalfGrid + offsetX,
        height,
        (layers[0].originZ + z).float32 - HalfGrid + offsetZ
      ),
      rotation: grassRng.rand(2.0 * PI).float32,
      scale: 0.7'f32 + grassRng.rand(0.7).float32
    )
    inc placed

proc scatterRocks*(count, randomSeed: int) =
  ## Scatters decorative half-buried boulders without changing gameplay.
  rockPlacements.setLen(0)
  if rockModels.len == 0 or layers.len == 0:
    return
  template gtile(x, z: int): Tile =
    layers[0].tiles[(z) * layers[0].width + (x)]
  var rockRng = initRand(randomSeed.int64 * 104_729'i64 + 3'i64)
  var attempts = 0
  while rockPlacements.len < count and attempts < count * 40:
    inc attempts
    let
      x = rockRng.rand(layers[0].width - 1)
      z = rockRng.rand(layers[0].depth - 1)
    if not gtile(x, z).exists or gtile(x, z).impassable or
        gtile(x, z).kind != RockTile:
      continue  # natural rock only; StoneTile construction gets none
    let
      h = gtile(x, z).tops.unpack
      model = rockRng.rand(rockModels.len - 1)
      boulderScale = rockScaleRange.x +
        rockRng.rand(rockScaleRange.y.float).float32
    rockPlacements.add TreePlacement(
      model: model,
      position: vec3(
        (layers[0].originX + x).float32 - HalfGrid + 0.5,
        (h[0] + h[1] + h[2] + h[3]) / 4.0 -
          rockModels[model].height * boulderScale * rockBurial,
        (layers[0].originZ + z).float32 - HalfGrid + 0.5
      ),
      rotation: rockRng.rand(2.0 * PI).float32,
      scale: boulderScale
    )

## Mesh

var
  vertexArray, vertexBuffer: GLuint
  mesh: seq[float32]
  meshVertexCount = 0
  propVertexArray, propVertexBuffer: GLuint
  propMesh: seq[float32]   # x y z r g b nx ny nz; grass, boulders, props
  treeVertexArray, treeVertexBuffer: GLuint
  treeMesh: seq[float32]   # x y z u v layer nx ny nz; textured trees
  waterVertexArray, waterVertexBuffer: GLuint
  waterMesh: seq[float32]  # x y z nx ny nz

const CornerWeights = [
  vec4(1, 0, 0, 0),
  vec4(0, 1, 0, 0),
  vec4(0, 0, 1, 0),
  vec4(0, 0, 0, 1)
]

proc bakeInstance(
    model: PropModel,
    position: Vec3,
    rotation,
    instanceScale: float32,
    writeIndex: var int,
    stretch = vec3(1, 1, 1)
) =
  ## Writes one transformed prop instance into the shared baked prop mesh.
  let
    cosine = cos(rotation)
    sine = sin(rotation)
  var i = 0
  while i < model.vertices.len:
    let
      x = model.vertices[i] * instanceScale * stretch.x
      y = model.vertices[i + 1] * instanceScale * stretch.y
      z = model.vertices[i + 2] * instanceScale * stretch.z
      normalX = model.vertices[i + 6]
      normalZ = model.vertices[i + 8]
    propMesh[writeIndex] = position.x + cosine * x - sine * z
    propMesh[writeIndex + 1] = position.y + y
    propMesh[writeIndex + 2] = position.z + sine * x + cosine * z
    propMesh[writeIndex + 3] = model.vertices[i + 3]
    propMesh[writeIndex + 4] = model.vertices[i + 4]
    propMesh[writeIndex + 5] = model.vertices[i + 5]
    propMesh[writeIndex + 6] = cosine * normalX - sine * normalZ
    propMesh[writeIndex + 7] = model.vertices[i + 7]
    propMesh[writeIndex + 8] = sine * normalX + cosine * normalZ
    writeIndex += 9
    i += 9

proc bakePlacements(
    models: openArray[PropModel],
    placements: openArray[TreePlacement],
    writeIndex: var int
) =
  ## Writes a set of prop placements into the shared baked prop mesh.
  for placement in placements:
    if models[placement.model].textureArray != 0:
      continue
    bakeInstance(
      models[placement.model], placement.position,
      placement.rotation, placement.scale, writeIndex)

proc terrainColorAt(position: Vec3): Vec3 =
  ## Blends texture averages at a grass root using the terrain's neighborhoods.
  let
    ground = layers[0]
    tileX = int(floor(position.x + HalfGrid)) - ground.originX
    tileZ = int(floor(position.z + HalfGrid)) - ground.originZ
    tileIndex = tileZ * ground.width + tileX
    style = tileMaterialTable[ground.tiles[tileIndex].kind.int]
  result = terrainAverageColors[style.topMaterial.int]
  if generatedTerrain:
    let
      tilePos = vec2(position.x, position.z)
      tileUv = tilePos - floor(tilePos)
      quadrant = int(floor(tileUv.x + 0.5'f)) +
        int(floor(tileUv.y + 0.5'f)) * 2
      centerUv = tilePos - floor(tilePos + vec2(0.5)) + vec2(0.5)
      first = (generatedMap.layers[0].ranges[tileIndex].z.int + quadrant) * 4
      materials = vec4(
        generatedMap.blends[first],
        generatedMap.blends[first + 1],
        generatedMap.blends[first + 2],
        generatedMap.blends[first + 3]
      )
      weights = materialWeights(radialWeights(centerUv), materials)
    result = vec3(0)
    for i in 0 .. 3:
      if materials[i] >= 0:
        result += terrainAverageColors[materials[i].int] * weights[i]
  let elevation = clamp(
    position.y / max(amplitude, 0.001'f) * 0.5'f + 0.5'f,
    0.0'f,
    1.0'f
  )
  result *= style.top * (0.75'f + 0.5'f * elevation)

proc bakeGrassPlacements(writeIndex: var int) =
  ## Replaces the grass mesh's green paint with the local terrain color.
  for placement in grassPlacements:
    let first = writeIndex
    bakeInstance(
      grassModels[placement.model],
      placement.position,
      placement.rotation,
      placement.scale,
      writeIndex
    )
    if grassMatchesTerrain:
      let color = terrainColorAt(placement.position)
      for i in countup(first, writeIndex - 9, 9):
        propMesh[i + 3] = color.x
        propMesh[i + 4] = color.y
        propMesh[i + 5] = color.z

proc bakeTree(
    model: TreeModel,
    textureLayer: int,
    position: Vec3,
    rotation,
    instanceScale,
    widthScale: float32,
    writeIndex: var int
) =
  ## Writes one transformed tree instance into the baked tree mesh.
  let
    cosine = cos(rotation)
    sine = sin(rotation)
  var i = 0
  while i < model.vertices.len:
    let
      x = model.vertices[i] * instanceScale * widthScale
      y = model.vertices[i + 1] * instanceScale
      z = model.vertices[i + 2] * instanceScale * widthScale
      normal = normalize(vec3(
        model.vertices[i + 5] / widthScale,
        model.vertices[i + 6],
        model.vertices[i + 7] / widthScale
      ))
    treeMesh[writeIndex] = position.x + cosine * x - sine * z
    treeMesh[writeIndex + 1] = position.y + y
    treeMesh[writeIndex + 2] = position.z + sine * x + cosine * z
    treeMesh[writeIndex + 3] = model.vertices[i + 3]
    treeMesh[writeIndex + 4] = model.vertices[i + 4]
    treeMesh[writeIndex + 5] = textureLayer.float32
    treeMesh[writeIndex + 6] = cosine * normal.x - sine * normal.z
    treeMesh[writeIndex + 7] = normal.y
    treeMesh[writeIndex + 8] = sine * normal.x + cosine * normal.z
    writeIndex += 9
    i += 8

proc treeTileSeed(x, z: int): int64 {.inline.} =
  ## Returns the deterministic decoration seed for one tree tile.
  x.int64 * 73_856_093'i64 +
    z.int64 * 19_349_663'i64 +
    seed.int64 * 83_492_791'i64 +
    1'i64

type TreeChoice = object
  ## What one tree tile grows: model, painting, rotation, and size, all
  ## derived deterministically from the tile coordinates.
  model: int
  textureLayer: int
  rotation: float32
  scale: float32
  widthScale: float32

proc chooseTree(x, z: int): TreeChoice =
  ## Chooses a stable tree appearance within the configured size limits.
  var rng = initRand(treeTileSeed(x, z))
  result.model = pickTreeModel(rng)
  let layers =
    if autumnTrees: treeModels[result.model].autumnLayers
    else: treeModels[result.model].summerLayers
  result.textureLayer = layers[rng.rand(layers.len - 1)]
  result.rotation = rng.rand(2.0 * PI).float32
  result.scale = (0.85'f32 + rng.rand(0.45).float32) * treeHeight / 8.4'f32
  result.widthScale = 1
  if treeWidth > 0:
    result.widthScale = min(
      1.0'f,
      treeWidth / max(
        treeModels[result.model].width * result.scale,
        0.001'f
      )
    )

proc treeMeshFloatCount(): int =
  ## Counts the exact float storage needed by the baked tree mesh.
  if treeModels.len > 0 and layers.len > 0:
    let ground = layers[0]
    for z in 0 ..< ground.depth:
      for x in 0 ..< ground.width:
        let tile = ground.tiles[z * ground.width + x]
        if tile.exists and tile.kind == TreeTile:
          # 8 floats per source vertex become 9 (uv gains the layer).
          result += treeModels[chooseTree(x, z).model].vertices.len div 8 * 9

proc propMeshFloatCount(): int =
  ## Counts the exact float storage needed by the baked prop mesh.
  for placement in grassPlacements:
    result += grassModels[placement.model].vertices.len
  for placement in rockPlacements:
    if rockModels[placement.model].textureArray == 0:
      result += rockModels[placement.model].vertices.len
  for placement in propPlacements:
    if placement.model.textureArray == 0:
      result += placement.model.vertices.len

proc bakeTexturedInstance(
    model: PropModel,
    position: Vec3,
    rotation,
    instanceScale: float32,
    tint: Vec3,
    stretch: Vec3,
    mesh: var seq[float32]
) =
  ## Appends one transformed textured prop to a batch mesh.
  let
    cosine = cos(rotation)
    sine = sin(rotation)
  var i = 0
  while i < model.vertices.len:
    let
      x = model.vertices[i] * instanceScale * stretch.x
      y = model.vertices[i + 1] * instanceScale * stretch.y
      z = model.vertices[i + 2] * instanceScale * stretch.z
      normalX = model.vertices[i + 6]
      normalZ = model.vertices[i + 8]
      uv = i div 9 * 3
    mesh.add position.x + cosine * x - sine * z
    mesh.add position.y + y
    mesh.add position.z + sine * x + cosine * z
    mesh.add model.uvs[uv]
    mesh.add model.uvs[uv + 1]
    mesh.add model.uvs[uv + 2]
    mesh.add cosine * normalX - sine * normalZ
    mesh.add model.vertices[i + 7]
    mesh.add sine * normalX + cosine * normalZ
    mesh.add tint.x
    mesh.add tint.y
    mesh.add tint.z
    i += 9

proc initTexturedVertexArrays(batch: var TexturedBatch) =
  ## Creates the vertex arrays for one textured batch: the tinted lit draw
  ## and the position-plus-uv view for the cutout depth pass.
  const stride = (12 * sizeof(float32)).GLsizei
  glGenBuffers(1, batch.vertexBuffer.addr)
  glGenVertexArrays(1, batch.vertexArray.addr)
  glBindVertexArray(batch.vertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, batch.vertexBuffer)
  for attribute in [
    (name: "vertPos", count: 3, offset: 0),
    (name: "vertUv", count: 3, offset: 3 * sizeof(float32)),
    (name: "normal", count: 3, offset: 6 * sizeof(float32)),
    (name: "vertTint", count: 3, offset: 9 * sizeof(float32))
  ]:
    let location = glGetAttribLocation(
      texturedPropProgram, attribute.name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(
      location.GLuint, attribute.count.GLint, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](attribute.offset))
  glGenVertexArrays(1, batch.depthVertexArray.addr)
  glBindVertexArray(batch.depthVertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, batch.vertexBuffer)
  for attribute in [
    (name: "vertPos", count: 3, offset: 0),
    (name: "vertUv", count: 3, offset: 3 * sizeof(float32))
  ]:
    let location = glGetAttribLocation(
      sunCutoutProgramId(), attribute.name.cstring)
    doAssert location >= 0
    glEnableVertexAttribArray(location.GLuint)
    glVertexAttribPointer(
      location.GLuint, attribute.count.GLint, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](attribute.offset))
  glBindVertexArray(0)

proc bakeTexturedPlacement(placement: PropPlacement) =
  ## Adds one painted prop to the batch for its material textures.
  let textureArray = placement.model.textureArray
  if textureArray == 0:
    return
  var found = -1
  for i, batch in texturedBatches:
    if batch.textureArray == textureArray:
      found = i
      break
  if found < 0:
    texturedBatches.add TexturedBatch(textureArray: textureArray)
    found = texturedBatches.high
  bakeTexturedInstance(
    placement.model,
    placement.position,
    placement.rotation,
    placement.scale,
    placement.tint,
    placement.stretch,
    texturedBatches[found].mesh
  )

proc rebuildTexturedBatches() =
  ## Bakes every textured placement into its pack's batch and uploads it.
  # Reserve each batch once. Growing multi-million-vertex foliage buffers
  # otherwise temporarily retains both the old and new WASM allocations.
  var counts: Table[GLuint,int]
  for placement in rockPlacements:
    let model=rockModels[placement.model]
    if model.textureArray!=0:counts.mgetOrPut(model.textureArray,0)+=model.vertices.len div 9*12
  for placement in propPlacements:
    if placement.model.textureArray!=0:
      counts.mgetOrPut(placement.model.textureArray,0)+=placement.model.vertices.len div 9*12
  for batch in texturedBatches.mitems:
    batch.mesh = @[]
  for texture,count in counts:
    var found = -1
    for i,batch in texturedBatches:
      if batch.textureArray==texture:found=i;break
    if found<0:
      texturedBatches.add TexturedBatch(textureArray:texture)
      found=texturedBatches.high
    texturedBatches[found].mesh=newSeqOfCap[float32](count)
  for placement in rockPlacements:
    bakeTexturedPlacement(PropPlacement(
      model: rockModels[placement.model],
      position: placement.position,
      rotation: placement.rotation,
      scale: placement.scale,
      tint: vec3(1),
      stretch: vec3(1)
    ))
  for placement in propPlacements:
    bakeTexturedPlacement(placement)
  for batch in texturedBatches.mitems:
    if batch.mesh.len == 0:
      continue
    if batch.vertexBuffer == 0:
      initTexturedVertexArrays(batch)
    glBindBuffer(GL_ARRAY_BUFFER, batch.vertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      batch.mesh.len * sizeof(float32),
      batch.mesh[0].addr,
      GL_STATIC_DRAW
    )

proc bakeTreeTiles(writeIndex: var int) =
  ## Tree tiles carry their tree in the tile data.
  if treeModels.len == 0 or layers.len == 0:
    return
  let ground = layers[0]
  for z in 0 ..< ground.depth:
    for x in 0 ..< ground.width:
      let t = ground.tiles[z * ground.width + x]
      if not t.exists or t.kind != TreeTile:
        continue
      let
        h = t.tops.unpack
        choice = chooseTree(x, z)
      bakeTree(
        treeModels[choice.model],
        choice.textureLayer,
        vec3(
          (ground.originX + x).float32 - HalfGrid + 0.5,
          (h[0] + h[1] + h[2] + h[3]) / 4.0,
          (ground.originZ + z).float32 - HalfGrid + 0.5
        ),
        choice.rotation,
        choice.scale,
        choice.widthScale,
        writeIndex
      )

proc rebuildTreeMesh() =
  ## Bakes trees, grass, rocks, and props into their colored or textured lists.
  if treeVertexBuffer == 0:
    return  # initTerrain hasn't created the buffers yet
  treeMesh = newSeq[float32](treeMeshFloatCount())
  var treeIndex = 0
  bakeTreeTiles(treeIndex)
  doAssert treeIndex == treeMesh.len
  if treeMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      treeMesh.len * sizeof(float32),
      treeMesh[0].addr,
      GL_STATIC_DRAW
    )
  propMesh = newSeq[float32](propMeshFloatCount())
  var writeIndex = 0
  bakeGrassPlacements(writeIndex)
  bakePlacements(rockModels, rockPlacements, writeIndex)
  for placement in propPlacements:
    if placement.model.textureArray != 0:
      continue
    bakeInstance(
      placement.model,
      placement.position,
      placement.rotation,
      placement.scale,
      writeIndex,
      placement.stretch
    )
  doAssert writeIndex == propMesh.len
  rebuildTexturedBatches()
  if propMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, propVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      propMesh.len * sizeof(float32),
      propMesh[0].addr,
      GL_STATIC_DRAW
    )

proc addTriangle(
    a,
    b,
    c,
    normalA,
    normalB,
    normalC,
    tint: Vec3,
    materials: Vec4,
    weightA,
    weightB,
    weightC: Vec4,
    edgeMask = 0.0'f,
    splatRange = vec3(0, 0, -1)
) =
  ## Appends one textured terrain triangle to the interleaved mesh.
  let start = mesh.len
  mesh.setLen(start + TerrainVertexSize * 3)
  template writeVertex(
      offset: int,
      vertex: Vec3,
      normal: Vec3,
      weight: Vec4
  ) =
    ## Writes one terrain vertex at a known mesh offset.
    mesh[start + offset] = vertex.x
    mesh[start + offset + 1] = vertex.y
    mesh[start + offset + 2] = vertex.z
    mesh[start + offset + 3] = edgeMask
    mesh[start + offset + 4] = normal.x
    mesh[start + offset + 5] = normal.y
    mesh[start + offset + 6] = normal.z
    mesh[start + offset + 7] = tint.x
    mesh[start + offset + 8] = tint.y
    mesh[start + offset + 9] = tint.z
    mesh[start + offset + 10] = materials.x
    mesh[start + offset + 11] = materials.y
    mesh[start + offset + 12] = materials.z
    mesh[start + offset + 13] = materials.w
    mesh[start + offset + 14] = weight.x
    mesh[start + offset + 15] = weight.y
    mesh[start + offset + 16] = weight.z
    mesh[start + offset + 17] = weight.w
    mesh[start + offset + 18] = splatRange.x
    mesh[start + offset + 19] = splatRange.y
    mesh[start + offset + 20] = splatRange.z
  writeVertex(0, a, normalA, weightA)
  writeVertex(TerrainVertexSize, b, normalB, weightB)
  writeVertex(TerrainVertexSize * 2, c, normalC, weightC)

proc addWall(
    top0,
    top1,
    bottom0,
    bottom1,
    normal,
    tint: Vec3,
    material: float32
) =
  ## Connects two edges; degenerates to a single triangle when a corner
  ## pair coincides. Walls use one unblended skirt material.
  let
    materials = vec4(material)
    weight = CornerWeights[0]
  addTriangle(
    top0,
    top1,
    bottom0,
    normal,
    normal,
    normal,
    tint,
    materials,
    weight,
    weight,
    weight
  )
  addTriangle(
    top1,
    bottom1,
    bottom0,
    normal,
    normal,
    normal,
    tint,
    materials,
    weight,
    weight,
    weight
  )

proc faceNormal(h: array[4, float32]): Vec3 =
  ## Gradient normal of one tile's bilinear top surface (unit tile size).
  let
    slopeX = ((h[1] + h[3]) - (h[0] + h[2])) * 0.5
    slopeZ = ((h[2] + h[3]) - (h[0] + h[1])) * 0.5
  normalize(vec3(-slopeX, 1, -slopeZ))

proc cornerNormal(
    layer: QuadLayer, faceNormals: seq[Vec3], x, z, cornerIndex: int
): Vec3 =
  ## Averages the face normals of the tiles sharing this corner, but only
  ## those whose corner height matches exactly — smooth shading across
  ## continuous terrain, hard breaks at cliffs and disconnections.
  let
    cornerX = x + (cornerIndex and 1)
    cornerZ = z + (cornerIndex shr 1)
    myHeight = layer.tiles[z * layer.width + x].tops[cornerIndex]
  var total: Vec3
  for (tileX, tileZ, corner) in [
    (cornerX - 1, cornerZ - 1, 3), (cornerX, cornerZ - 1, 2),
    (cornerX - 1, cornerZ, 1), (cornerX, cornerZ, 0)
  ]:
    if tileX < 0 or tileX >= layer.width or tileZ < 0 or tileZ >= layer.depth:
      continue
    let i = tileZ * layer.width + tileX
    if not layer.tiles[i].exists or layer.tiles[i].tops[corner] != myHeight:
      continue
    total = total + faceNormals[i]
  if total.length < 0.001:
    vec3(0, 1, 0)
  else:
    total.normalize

proc tileMaterial(kind: uint32): TileMaterial =
  ## Returns one clamped tile material style.
  tileMaterialTable[min(kind, tileMaterialTable.high.uint32).int]

proc cornerMaterial(
    layer: QuadLayer,
    x,
    z,
    cornerIndex: int
): float32 =
  ## Chooses the highest-priority material meeting one exact-height corner.
  let
    cornerX = x + (cornerIndex and 1)
    cornerZ = z + (cornerIndex shr 1)
    myHeight = layer.tiles[z * layer.width + x].tops[cornerIndex]
  var best = layer.tiles[z * layer.width + x].kind
  for (tileX, tileZ, corner) in [
    (cornerX - 1, cornerZ - 1, 3),
    (cornerX, cornerZ - 1, 2),
    (cornerX - 1, cornerZ, 1),
    (cornerX, cornerZ, 0)
  ]:
    if tileX < 0 or tileX >= layer.width or
        tileZ < 0 or tileZ >= layer.depth:
      continue
    let index = tileZ * layer.width + tileX
    if not layer.tiles[index].exists or
        layer.tiles[index].tops[corner] != myHeight:
      continue
    let kind = layer.tiles[index].kind
    if tileMaterial(kind).blendPriority >
        tileMaterial(best).blendPriority:
      best = kind
  tileMaterial(best).topMaterial

proc emitLayer(
    layerIndex: int,
    layer: QuadLayer,
    floorY: float32,
    blockers: openArray[seq[int32]]
) =
  ## Emits one solid tile layer with tops, skirts, cliffs, and edge masks.
  let w = layer.width
  var faceNormals = newSeq[Vec3](layer.tiles.len)
  for i, t in layer.tiles:
    if t.exists:
      faceNormals[i] = faceNormal(t.tops.unpack)
  for z in 0 ..< layer.depth:
    for x in 0 ..< w:
      let
        i = z * w + x
        t = layer.tiles[i]
      if not t.exists:
        continue
      let
        x0 = (layer.originX + x).float32 - HalfGrid
        x1 = x0 + 1
        z0 = (layer.originZ + z).float32 - HalfGrid
        z1 = z0 + 1
        h = t.tops.unpack
        b = t.bottoms.unpack
        v00 = vec3(x0, h[0], z0)
        v10 = vec3(x1, h[1], z0)
        v01 = vec3(x0, h[2], z1)
        v11 = vec3(x1, h[3], z1)
        edgeMask = float32(pathing.edgeMask(layerIndex, x, z, blockers))

      let
        style = tileMaterial(t.kind)
        materials =
          if generatedTerrain:
            vec4(generatedMap.layers[layerIndex].materials[i].float32)
          else:
            vec4(
              cornerMaterial(layer, x, z, 0),
              cornerMaterial(layer, x, z, 1),
              cornerMaterial(layer, x, z, 2),
              cornerMaterial(layer, x, z, 3)
            )
        splatRange =
          if generatedTerrain:
            generatedMap.layers[layerIndex].ranges[i]
          else:
            vec3(0, 0, -1)
        n0 = cornerNormal(layer, faceNormals, x, z, 0)
        n1 = cornerNormal(layer, faceNormals, x, z, 1)
        n2 = cornerNormal(layer, faceNormals, x, z, 2)
        n3 = cornerNormal(layer, faceNormals, x, z, 3)
      addTriangle(
        v00,
        v10,
        v01,
        n0,
        n1,
        n2,
        style.top,
        materials,
        CornerWeights[0],
        CornerWeights[1],
        CornerWeights[2],
        edgeMask,
        splatRange
      )
      addTriangle(
        v10,
        v11,
        v01,
        n1,
        n3,
        n2,
        style.top,
        materials,
        CornerWeights[1],
        CornerWeights[3],
        CornerWeights[2],
        edgeMask,
        splatRange
      )

      if layer.slab:
        # Underside of the slab; never walkable.
        let
          down = vec3(0, -1, 0)
          skirtMaterials = vec4(style.skirtMaterial)
          weight = CornerWeights[0]
        addTriangle(
          vec3(x0, b[0], z0), vec3(x1, b[1], z0), vec3(x0, b[2], z1),
          down, down, down, style.skirt, skirtMaterials,
          weight, weight, weight)
        addTriangle(
          vec3(x1, b[1], z0), vec3(x1, b[3], z1), vec3(x0, b[2], z1),
          down, down, down, style.skirt, skirtMaterials,
          weight, weight, weight)

      # East edge: side wall when open, connecting wall when heights differ.
      # Mismatch walls are emitted from the east/south side only, so each
      # shared edge produces exactly one wall.
      if x == w - 1 or
        not layer.tiles[z * w + x + 1].exists or
        not t.connectedEast:
        let
          y0 = if layer.slab: b[1] else: floorY
          y1 = if layer.slab: b[3] else: floorY
        addWall(
          v10,
          v11,
          vec3(x1, y0, z0),
          vec3(x1, y1, z1),
          vec3(1, 0, 0),
          style.skirt,
          style.skirtMaterial
        )
      else:
        let n = layer.tiles[z * w + x + 1]
        let nh = n.tops.unpack
        if h[1] != nh[0] or h[3] != nh[2]:
          # The cliff face belongs to the higher side; use its skirt color.
          let cliffStyle =
            if h[1] + h[3] >= nh[0] + nh[2]:
              style
            else:
              tileMaterial(n.kind)
          addWall(
            v10,
            v11,
            vec3(x1, nh[0], z0),
            vec3(x1, nh[2], z1),
            vec3(1, 0, 0),
            cliffStyle.skirt,
            cliffStyle.skirtMaterial
          )
        if layer.slab:
          let nb = n.bottoms.unpack
          if b[1] != nb[0] or b[3] != nb[2]:
            addWall(
              vec3(x1, b[1], z0), vec3(x1, b[3], z1),
              vec3(x1, nb[0], z0), vec3(x1, nb[2], z1), vec3(1, 0, 0),
              style.skirt, style.skirtMaterial)

      # South edge.
      if z == layer.depth - 1 or
        not layer.tiles[(z + 1) * w + x].exists or
        not t.connectedSouth:
        let
          y0 = if layer.slab: b[2] else: floorY
          y1 = if layer.slab: b[3] else: floorY
        addWall(
          v01,
          v11,
          vec3(x0, y0, z1),
          vec3(x1, y1, z1),
          vec3(0, 0, 1),
          style.skirt,
          style.skirtMaterial
        )
      else:
        let n = layer.tiles[(z + 1) * w + x]
        let nh = n.tops.unpack
        if h[2] != nh[0] or h[3] != nh[1]:
          let cliffStyle =
            if h[2] + h[3] >= nh[0] + nh[1]:
              style
            else:
              tileMaterial(n.kind)
          addWall(
            v01,
            v11,
            vec3(x0, nh[0], z1),
            vec3(x1, nh[1], z1),
            vec3(0, 0, 1),
            cliffStyle.skirt,
            cliffStyle.skirtMaterial
          )
        if layer.slab:
          let nb = n.bottoms.unpack
          if b[2] != nb[0] or b[3] != nb[1]:
            addWall(
              vec3(x0, b[2], z1), vec3(x1, b[3], z1),
              vec3(x0, nb[0], z1), vec3(x1, nb[1], z1), vec3(0, 0, 1),
              style.skirt, style.skirtMaterial)

      # West and north edges only need side walls when open (the neighbor,
      # if present and connected, already emitted any mismatch wall).
      if x == 0 or not layer.tiles[z * w + x - 1].exists or
          not layer.tiles[z * w + x - 1].connectedEast:
        let
          y0 = if layer.slab: b[0] else: floorY
          y1 = if layer.slab: b[2] else: floorY
        addWall(
          v00,
          v01,
          vec3(x0, y0, z0),
          vec3(x0, y1, z1),
          vec3(-1, 0, 0),
          style.skirt,
          style.skirtMaterial
        )
      if z == 0 or not layer.tiles[(z - 1) * w + x].exists or
          not layer.tiles[(z - 1) * w + x].connectedSouth:
        let
          y0 = if layer.slab: b[0] else: floorY
          y1 = if layer.slab: b[1] else: floorY
        addWall(
          v00,
          v10,
          vec3(x0, y0, z0),
          vec3(x1, y1, z0),
          vec3(0, 0, -1),
          style.skirt,
          style.skirtMaterial
        )

proc emitWaterLayer(layer: QuadLayer) =
  ## Flat water surface plus side faces where the water ends; drawn in its
  ## own transparent pass, so it goes to a separate mesh.
  proc addWaterTriangle(a, b, c, normal: Vec3) =
    ## Appends one position-and-normal water triangle.
    for v in [a, b, c]:
      waterMesh.add v.x
      waterMesh.add v.y
      waterMesh.add v.z
      waterMesh.add normal.x
      waterMesh.add normal.y
      waterMesh.add normal.z
  # A uniform ocean is one surface; avoid hundreds of thousands of identical tiles.
  var flatOcean = not layer.slab and layer.tiles.len > 0
  for tile in layer.tiles:
    if not tile.exists or tile.tops != layer.tiles[0].tops:
      flatOcean = false
      break
  if flatOcean:
    let heights = layer.tiles[0].tops.unpack
    if heights[0] == heights[1] and heights[0] == heights[2] and heights[0] == heights[3]:
      let x = layer.originX.float32-HalfGrid
      let z = layer.originZ.float32-HalfGrid
      let w = layer.width.float32
      let d = layer.depth.float32
      let h = heights[0]
      addWaterTriangle(vec3(x,h,z), vec3(x+w,h,z), vec3(x,h,z+d), vec3(0,1,0))
      addWaterTriangle(vec3(x+w,h,z), vec3(x+w,h,z+d), vec3(x,h,z+d), vec3(0,1,0))
      return
  let w = layer.width
  for z in 0 ..< layer.depth:
    for x in 0 ..< w:
      let t = layer.tiles[z * w + x]
      if not t.exists:
        continue
      let
        x0 = (layer.originX + x).float32 - HalfGrid
        x1 = x0 + 1
        z0 = (layer.originZ + z).float32 - HalfGrid
        z1 = z0 + 1
        top = t.tops.unpack[0]
        bottom = t.bottoms.unpack[0]
        up = vec3(0, 1, 0)
      addWaterTriangle(
        vec3(x0, top, z0),
        vec3(x1, top, z0),
        vec3(x0, top, z1),
        up
      )
      addWaterTriangle(
        vec3(x1, top, z0),
        vec3(x1, top, z1),
        vec3(x0, top, z1),
        up
      )
      # Side faces on water boundaries.
      if x == w - 1 or not layer.tiles[z * w + x + 1].exists:
        addWaterTriangle(
          vec3(x1, top, z0),
          vec3(x1, top, z1),
          vec3(x1, bottom, z0),
          vec3(1, 0, 0)
        )
        addWaterTriangle(
          vec3(x1, top, z1),
          vec3(x1, bottom, z1),
          vec3(x1, bottom, z0),
          vec3(1, 0, 0)
        )
      if x == 0 or not layer.tiles[z * w + x - 1].exists:
        addWaterTriangle(
          vec3(x0, top, z0),
          vec3(x0, top, z1),
          vec3(x0, bottom, z0),
          vec3(-1, 0, 0)
        )
        addWaterTriangle(
          vec3(x0, top, z1),
          vec3(x0, bottom, z1),
          vec3(x0, bottom, z0),
          vec3(-1, 0, 0)
        )
      if z == layer.depth - 1 or not layer.tiles[(z + 1) * w + x].exists:
        addWaterTriangle(
          vec3(x0, top, z1),
          vec3(x1, top, z1),
          vec3(x0, bottom, z1),
          vec3(0, 0, 1)
        )
        addWaterTriangle(
          vec3(x1, top, z1),
          vec3(x1, bottom, z1),
          vec3(x0, bottom, z1),
          vec3(0, 0, 1)
        )
      if z == 0 or not layer.tiles[(z - 1) * w + x].exists:
        addWaterTriangle(
          vec3(x0, top, z0),
          vec3(x1, top, z0),
          vec3(x0, bottom, z0),
          vec3(0, 0, -1)
        )
        addWaterTriangle(
          vec3(x1, top, z0),
          vec3(x1, bottom, z0),
          vec3(x0, bottom, z0),
          vec3(0, 0, -1)
        )

## Public API

proc initTerrain*(
  treeStyle: TreeStyle = MixedTrees,
  terrainStyle: TerrainStyle = CartoonTerrain,
  rockStyle: RockStyle = LowPolyRocks,
  extraTiles: openArray[string] = []
) =
  ## Initializes rendering with a current GL context, once before bakeTerrain.
  ## Extra generated tile names append after SurfaceNames without splat stamps.
  ## Assets load from ../polyworld_data/terrain/ relative to the repo root.
  if terrainStyle != GeneratedTerrain and extraTiles.len > 0:
    raise newException(QuadTerrainError, "Extra tiles need generated terrain.")
  initSunShadows()
  generatedTerrain = terrainStyle == GeneratedTerrain
  if generatedTerrain:
    terrainTextureScale = 1.0'f / 2.5'f
    terrainBlendDepth = 0.43'f
    terrainHeightBlend = 1.30'f
    for kind, material in [
      GrassSurface, DirtSurface, GravelSurface,
      MarshSurface, CobbleSurface, ForestSurface
    ]:
      setTileMaterial(
        kind, material.float32, DirtSurface.float32,
        vec3(1), vec3(0.85), kind.int32
      )
  terrainProgram = compileProgram(
    toShader(terrainVert, OpenGlShaderTarget, shaderVertex),
    toShader(terrainFrag, OpenGlShaderTarget, shaderFragment)
  )
  mvpLocation = glGetUniformLocation(terrainProgram, "mvp")
  terrainEnv = envLocations(terrainProgram)
  terrainShadow = shadowLocations(terrainProgram)
  borderWidthLocation = glGetUniformLocation(
    terrainProgram,
    "borderWidthUniform"
  )
  heightScaleLocation = glGetUniformLocation(terrainProgram, "heightScale")
  edgesEnabledLocation = glGetUniformLocation(terrainProgram, "edgesEnabled")
  texScaleLocation = glGetUniformLocation(terrainProgram, "texScale")
  blendDepthLocation = glGetUniformLocation(terrainProgram, "blendDepth")
  heightBlendLocation = glGetUniformLocation(terrainProgram, "heightBlend")
  generatedLocation = glGetUniformLocation(terrainProgram, "generatedEnabled")
  heightBlendEnabledLocation = glGetUniformLocation(
    terrainProgram, "heightBlendEnabled"
  )
  splatsEnabledLocation = glGetUniformLocation(terrainProgram, "splatsEnabled")
  splatAmountLocation = glGetUniformLocation(terrainProgram, "splatAmount")
  splatColorsLocation = glGetUniformLocation(terrainProgram, "splatColors")
  splatHeightsLocation = glGetUniformLocation(terrainProgram, "splatHeights")
  splatDataLocation = glGetUniformLocation(terrainProgram, "splatData")
  blendDataLocation = glGetUniformLocation(terrainProgram, "blendData")
  splatDataSizeLocation = glGetUniformLocation(terrainProgram, "splatDataSize")
  blendDataSizeLocation = glGetUniformLocation(terrainProgram, "blendDataSize")
  terrainTexturesLocation = glGetUniformLocation(
    terrainProgram,
    "terrainTextures"
  )
  visibilityTexLocation = glGetUniformLocation(
    terrainProgram,
    "visibilityTex"
  )
  groundMaskLocation = glGetUniformLocation(terrainProgram, "groundMask")
  groundMaskEnabledLocation = glGetUniformLocation(
    terrainProgram,
    "groundMaskEnabled"
  )
  groundLayersLocation = glGetUniformLocation(terrainProgram, "groundLayers")
  groundRingLocation = glGetUniformLocation(terrainProgram, "groundRing")
  groundRingShapeLocation = glGetUniformLocation(
    terrainProgram,
    "groundRingShape"
  )
  visibilityOffsetLocation = glGetUniformLocation(
    terrainProgram,
    "visibilityOffset"
  )
  visibilityScaleLocation = glGetUniformLocation(
    terrainProgram,
    "visibilityScale"
  )
  if generatedTerrain:
    terrainTextureArray = buildTextureArray(
      loadGeneratedTiles(extraTiles), GL_REPEAT.GLint
    )
    let stamps = loadGeneratedStamps()
    splatColorArray = buildTextureArray(stamps.colors, GL_CLAMP_TO_EDGE.GLint)
    splatHeightArray = buildTextureArray(stamps.heights, GL_CLAMP_TO_EDGE.GLint)
  else:
    terrainTextureArray = buildTextureArray(
      loadTerrainMaterials(), GL_REPEAT.GLint
    )
    let placeholder = @[@[newImage(1, 1)]]
    splatColorArray = buildTextureArray(placeholder, GL_CLAMP_TO_EDGE.GLint)
    splatHeightArray = buildTextureArray(placeholder, GL_CLAMP_TO_EDGE.GLint)
  let empty = @[0.0'f, 0.0'f, 0.0'f, 0.0'f]
  splatDimensions = uploadTerrainData(splatDataTexture, empty)
  blendDimensions = uploadTerrainData(blendDataTexture, empty)
  treeTextureArray = buildTextureArray(loadTreeTextures(), GL_CLAMP_TO_EDGE.GLint)
  waterNormalTextureArray = buildTextureArray(loadWaterNormals(), GL_REPEAT.GLint)
  glGenTextures(1, visibilityTexture.addr)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_R8.GLint,
    GridTiles,
    GridTiles,
    0,
    GL_RED,
    GL_UNSIGNED_BYTE,
    nil
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MIN_FILTER,
    GL_LINEAR.GLint
  )
  glTexParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MAG_FILTER,
    GL_LINEAR.GLint
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
  glBindTexture(GL_TEXTURE_2D, 0)
  showAllTerrain()

  waterProgram = compileProgram(
    toShader(waterVert, OpenGlShaderTarget, shaderVertex),
    toShader(waterFrag, OpenGlShaderTarget, shaderFragment)
  )
  waterMvpLocation = glGetUniformLocation(waterProgram, "mvp")
  waterEnv = envLocations(waterProgram)
  waterCameraLocation = glGetUniformLocation(waterProgram, "cameraPos")
  waterTimeLocation = glGetUniformLocation(waterProgram, "waterTime")
  waterNormalsLocation = glGetUniformLocation(waterProgram, "waterNormals")
  waterVisibilityTexLocation = glGetUniformLocation(
    waterProgram,
    "visibilityTex"
  )
  waterVisibilityOffsetLocation = glGetUniformLocation(
    waterProgram,
    "visibilityOffset"
  )
  waterVisibilityScaleLocation = glGetUniformLocation(
    waterProgram,
    "visibilityScale"
  )

  propProgram = compileProgram(
    toShader(propVert, OpenGlShaderTarget, shaderVertex),
    toShader(propFrag, OpenGlShaderTarget, shaderFragment)
  )
  propMvpLocation = glGetUniformLocation(propProgram, "mvp")
  propTintLocation = glGetUniformLocation(propProgram, "propTint")
  propEnv = envLocations(propProgram)
  propShadow = shadowLocations(propProgram)
  propVisibilityTexLocation = glGetUniformLocation(
    propProgram,
    "visibilityTex"
  )
  propVisibilityOffsetLocation = glGetUniformLocation(
    propProgram,
    "visibilityOffset"
  )
  propVisibilityScaleLocation = glGetUniformLocation(
    propProgram,
    "visibilityScale"
  )

  treeProgram = compileProgram(
    toShader(treeVert, OpenGlShaderTarget, shaderVertex),
    toShader(treeFrag, OpenGlShaderTarget, shaderFragment)
  )
  treeMvpLocation = glGetUniformLocation(treeProgram, "mvp")
  treeEnv = envLocations(treeProgram)
  treeShadow = shadowLocations(treeProgram)
  treeVisibilityTexLocation = glGetUniformLocation(
    treeProgram,
    "visibilityTex"
  )
  treeVisibilityOffsetLocation = glGetUniformLocation(
    treeProgram,
    "visibilityOffset"
  )
  treeVisibilityScaleLocation = glGetUniformLocation(
    treeProgram,
    "visibilityScale"
  )
  texturedPropProgram = compileProgram(
    toShader(texturedPropVert, OpenGlShaderTarget, shaderVertex),
    toShader(texturedPropFrag, OpenGlShaderTarget, shaderFragment)
  )
  texturedPropMvpLocation = glGetUniformLocation(texturedPropProgram, "mvp")
  texturedPropEnv = envLocations(texturedPropProgram)
  texturedPropShadow = shadowLocations(texturedPropProgram)
  texturedPropVisibilityTexLocation = glGetUniformLocation(
    texturedPropProgram, "visibilityTex")
  texturedPropVisibilityOffsetLocation = glGetUniformLocation(
    texturedPropProgram, "visibilityOffset")
  texturedPropVisibilityScaleLocation = glGetUniformLocation(
    texturedPropProgram, "visibilityScale")
  texturedPropTexturesLocation = glGetUniformLocation(
    texturedPropProgram, "treeTextures")
  texturedPropAlphaCutoffLocation = glGetUniformLocation(
    texturedPropProgram, "treeAlphaCutoff")
  texturedInstantProgram = compileProgram(
    toShader(treeVert, OpenGlShaderTarget, shaderVertex),
    toShader(texturedInstantFrag, OpenGlShaderTarget, shaderFragment)
  )
  texturedInstantMvpLocation = glGetUniformLocation(
    texturedInstantProgram, "mvp")
  texturedInstantEnv = envLocations(texturedInstantProgram)
  texturedInstantShadow = shadowLocations(texturedInstantProgram)
  texturedInstantVisibilityTexLocation = glGetUniformLocation(
    texturedInstantProgram, "visibilityTex")
  texturedInstantVisibilityOffsetLocation = glGetUniformLocation(
    texturedInstantProgram, "visibilityOffset")
  texturedInstantVisibilityScaleLocation = glGetUniformLocation(
    texturedInstantProgram, "visibilityScale")
  texturedInstantTexturesLocation = glGetUniformLocation(
    texturedInstantProgram, "treeTextures")
  texturedInstantAlphaCutoffLocation = glGetUniformLocation(
    texturedInstantProgram, "treeAlphaCutoff")
  texturedInstantTintLocation = glGetUniformLocation(
    texturedInstantProgram, "propTint")
  treeTexturesLocation = glGetUniformLocation(treeProgram, "treeTextures")
  treeAlphaCutoffLocation = glGetUniformLocation(
    treeProgram,
    "treeAlphaCutoff"
  )

  glGenVertexArrays(1, vertexArray.addr)
  glBindVertexArray(vertexArray)
  glGenBuffers(1, vertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer)
  block:
    const stride = (TerrainVertexSize * sizeof(float32)).GLsizei
    let positionLocation = glGetAttribLocation(terrainProgram, "vertPos")
    doAssert positionLocation >= 0
    glEnableVertexAttribArray(positionLocation.GLuint)
    glVertexAttribPointer(
      positionLocation.GLuint,
      3,
      cGL_FLOAT,
      GL_FALSE,
      stride,
      nil
    )
    let edgeMaskLocation = glGetAttribLocation(terrainProgram, "edgeMask")
    doAssert edgeMaskLocation >= 0
    glEnableVertexAttribArray(edgeMaskLocation.GLuint)
    glVertexAttribPointer(
      edgeMaskLocation.GLuint, 1, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](3 * sizeof(float32))
    )
    let normalLocation = glGetAttribLocation(terrainProgram, "normal")
    doAssert normalLocation >= 0
    glEnableVertexAttribArray(normalLocation.GLuint)
    glVertexAttribPointer(
      normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](4 * sizeof(float32))
    )
    let tileColorLocation = glGetAttribLocation(terrainProgram, "tileColor")
    doAssert tileColorLocation >= 0
    glEnableVertexAttribArray(tileColorLocation.GLuint)
    glVertexAttribPointer(
      tileColorLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](7 * sizeof(float32))
    )
    let materialsLocation = glGetAttribLocation(terrainProgram, "materials")
    doAssert materialsLocation >= 0
    glEnableVertexAttribArray(materialsLocation.GLuint)
    glVertexAttribPointer(
      materialsLocation.GLuint, 4, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](10 * sizeof(float32))
    )
    let cornerWeightLocation = glGetAttribLocation(
      terrainProgram,
      "cornerWeight"
    )
    doAssert cornerWeightLocation >= 0
    glEnableVertexAttribArray(cornerWeightLocation.GLuint)
    glVertexAttribPointer(
      cornerWeightLocation.GLuint, 4, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](14 * sizeof(float32))
    )
    let splatRangeLocation = glGetAttribLocation(terrainProgram, "splatRange")
    doAssert splatRangeLocation >= 0
    glEnableVertexAttribArray(splatRangeLocation.GLuint)
    glVertexAttribPointer(
      splatRangeLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](18 * sizeof(float32))
    )

  glGenVertexArrays(1, propVertexArray.addr)
  glBindVertexArray(propVertexArray)
  glGenBuffers(1, propVertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, propVertexBuffer)
  block:
    const stride = (9 * sizeof(float32)).GLsizei
    let positionLocation = glGetAttribLocation(propProgram, "vertPos")
    doAssert positionLocation >= 0
    glEnableVertexAttribArray(positionLocation.GLuint)
    glVertexAttribPointer(
      positionLocation.GLuint,
      3,
      cGL_FLOAT,
      GL_FALSE,
      stride,
      nil
    )
    let colorLocation = glGetAttribLocation(propProgram, "vertColor")
    doAssert colorLocation >= 0
    glEnableVertexAttribArray(colorLocation.GLuint)
    glVertexAttribPointer(
      colorLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](3 * sizeof(float32))
    )
    let normalLocation = glGetAttribLocation(propProgram, "normal")
    doAssert normalLocation >= 0
    glEnableVertexAttribArray(normalLocation.GLuint)
    glVertexAttribPointer(
      normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](6 * sizeof(float32))
    )

  glGenVertexArrays(1, treeVertexArray.addr)
  glBindVertexArray(treeVertexArray)
  glGenBuffers(1, treeVertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
  block:
    const stride = (9 * sizeof(float32)).GLsizei
    let positionLocation = glGetAttribLocation(treeProgram, "vertPos")
    doAssert positionLocation >= 0
    glEnableVertexAttribArray(positionLocation.GLuint)
    glVertexAttribPointer(
      positionLocation.GLuint,
      3,
      cGL_FLOAT,
      GL_FALSE,
      stride,
      nil
    )
    let uvLocation = glGetAttribLocation(treeProgram, "vertUv")
    doAssert uvLocation >= 0
    glEnableVertexAttribArray(uvLocation.GLuint)
    glVertexAttribPointer(
      uvLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](3 * sizeof(float32))
    )
    let normalLocation = glGetAttribLocation(treeProgram, "normal")
    doAssert normalLocation >= 0
    glEnableVertexAttribArray(normalLocation.GLuint)
    glVertexAttribPointer(
      normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](6 * sizeof(float32))
    )

  glGenVertexArrays(1, waterVertexArray.addr)
  glBindVertexArray(waterVertexArray)
  glGenBuffers(1, waterVertexBuffer.addr)
  glBindBuffer(GL_ARRAY_BUFFER, waterVertexBuffer)
  block:
    const stride = (6 * sizeof(float32)).GLsizei
    let positionLocation = glGetAttribLocation(waterProgram, "vertPos")
    doAssert positionLocation >= 0
    glEnableVertexAttribArray(positionLocation.GLuint)
    glVertexAttribPointer(
      positionLocation.GLuint,
      3,
      cGL_FLOAT,
      GL_FALSE,
      stride,
      nil
    )
    let normalLocation = glGetAttribLocation(waterProgram, "normal")
    doAssert normalLocation >= 0
    glEnableVertexAttribArray(normalLocation.GLuint)
    glVertexAttribPointer(
      normalLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](3 * sizeof(float32))
    )

  # Sun depth pass vertex arrays: the same vertex buffers, but only the
  # position attribute (plus uv and layer for the tree cutout).
  glGenVertexArrays(1, terrainDepthVertexArray.addr)
  glBindVertexArray(terrainDepthVertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer)
  block:
    const stride = (TerrainVertexSize * sizeof(float32)).GLsizei
    let positionLocation = glGetAttribLocation(
      sunDepthProgramId(), "vertPos")
    doAssert positionLocation >= 0
    glEnableVertexAttribArray(positionLocation.GLuint)
    glVertexAttribPointer(
      positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  glGenVertexArrays(1, propDepthVertexArray.addr)
  glBindVertexArray(propDepthVertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, propVertexBuffer)
  block:
    const stride = (9 * sizeof(float32)).GLsizei
    let positionLocation = glGetAttribLocation(
      sunDepthProgramId(), "vertPos")
    doAssert positionLocation >= 0
    glEnableVertexAttribArray(positionLocation.GLuint)
    glVertexAttribPointer(
      positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
  glGenVertexArrays(1, treeDepthVertexArray.addr)
  glBindVertexArray(treeDepthVertexArray)
  glBindBuffer(GL_ARRAY_BUFFER, treeVertexBuffer)
  block:
    const stride = (9 * sizeof(float32)).GLsizei
    let positionLocation = glGetAttribLocation(
      sunCutoutProgramId(), "vertPos")
    doAssert positionLocation >= 0
    glEnableVertexAttribArray(positionLocation.GLuint)
    glVertexAttribPointer(
      positionLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride, nil)
    let uvLocation = glGetAttribLocation(sunCutoutProgramId(), "vertUv")
    doAssert uvLocation >= 0
    glEnableVertexAttribArray(uvLocation.GLuint)
    glVertexAttribPointer(
      uvLocation.GLuint, 3, cGL_FLOAT, GL_FALSE, stride,
      cast[pointer](3 * sizeof(float32))
    )
  glBindVertexArray(0)

  # Planting weights and texture array layers per tree model. Fir 03 is a
  # tall old-growth fir with a small crown, planted sparingly; the pack's
  # fir 04 is a bare snag and is left out of the forest entirely.
  case treeStyle
  of MixedTrees:
    treeModels.add loadTreeModel("tree_fir_01", 25, @[0], @[0])
    treeModels.add loadTreeModel("tree_fir_02", 20, @[0], @[0])
    treeModels.add loadTreeModel("tree_fir_03", 6, @[0], @[0])
    treeModels.add loadTreeModel(
      "tree_leafy_simple", 24, @[1, 2, 5, 6], @[1, 2, 3, 4, 5, 6])
    treeModels.add loadTreeModel(
      "tree_leafy_double", 23, @[7, 8, 11, 12], @[7, 8, 9, 10, 11, 12])
  of EvergreenTrees:
    # Compact layered firs dominate, with a few green broadleaf trees.
    treeModels.add loadTreeModel("tree_fir_01", 52, @[0], @[0])
    treeModels.add loadTreeModel("tree_fir_02", 42, @[0], @[0])
    treeModels.add loadTreeModel(
      "tree_leafy_simple", 6, @[2, 6], @[2, 6])
  of DenseTrees:
    treeModels.add loadTreeModel("tree_fir_01", 25, @[0], @[0])
    treeModels.add loadTreeModel("tree_fir_02", 20, @[0], @[0])
  treeModels.scaleTrees(8.4)
  collectPropModels(
    readGltfFile(DataRoot & "/terrain/low_poly_grass.glb").root, mat4(), grassModels)
  grassModels.scalePack(0.7)
  case rockStyle
  of LowPolyRocks:
    collectPropModels(
      readGltfFile(DataRoot & "/terrain/low_poly_rocks.glb").root,
      mat4(),
      rockModels
    )
    rockModels.normalizeModels()
    rockModels.brighten(2.4)
  of PaintedRocks:
    let pack = loadPropPack(
      DataRoot & "/terrain/toon_enchanted_meadow/rocks.glb",
      only = @["rock_large_02a", "rock_medium_01a"],
      textured = true,
      repeatTexture = true
    )
    rockModels = pack.models
    rockScaleRange = vec2(1.1, 1.1) * 0.75'f
    rockBurial = 0.43'f

proc bakeTerrain*(
    rebuildWalkability = true,
    blockers: openArray[seq[int32]] = []
) =
  ## Rebuilds and uploads terrain and props, with optional tile edge blockers.
  ## Nonzero per-layer blockers affect the overlay only. Omitted grids are open.
  ## Skip walkability rebuilding only after computing the final terrain edits.
  mesh.setLen(0)
  waterMesh.setLen(0)
  layerVertexRanges.setLen(0)
  let floorY = -amplitude - 6
  if rebuildWalkability:
    computeWalkable()
  rebuildTerrainData()
  for i in 0 ..< layers.len:
    let first = mesh.len div TerrainVertexSize
    if layers[i].water:
      emitWaterLayer(layers[i])
    else:
      emitLayer(i, layers[i], floorY, blockers)
    layerVertexRanges.add first ..< (mesh.len div TerrainVertexSize)
  rebuildTreeMesh()
  if waterVertexBuffer != 0 and waterMesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, waterVertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      waterMesh.len * sizeof(float32),
      waterMesh[0].addr,
      GL_DYNAMIC_DRAW
    )
  meshVertexCount = mesh.len div TerrainVertexSize
  if mesh.len > 0:
    glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      mesh.len * sizeof(float32),
      mesh[0].addr,
      GL_DYNAMIC_DRAW
    )

proc drawTerrainRange*(
    viewProjection: Mat4,
    firstVertex, vertexCount: int,
    showEdges = false
) =
  ## Draws part of the baked terrain. Layers are emitted in order, so any run
  ## of layers is one contiguous vertex range: a game that stacks its levels
  ## top to bottom can hide everything above the player with a single offset,
  ## which is what makes a cutaway view cost nothing.
  if vertexCount <= 0:
    return
  glDisable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glUseProgram(terrainProgram)
  setEnvUniforms(terrainEnv)
  setShadowUniforms(terrainShadow)
  mvp = viewProjection
  glUniformMatrix4fv(mvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
  glUniform1f(borderWidthLocation, borderWidth)
  glUniform1f(heightScaleLocation, amplitude)
  glUniform1f(edgesEnabledLocation, if showEdges: 1.0 else: 0.0)
  glUniform1f(texScaleLocation, terrainTextureScale)
  glUniform1f(blendDepthLocation, terrainBlendDepth)
  glUniform1f(heightBlendLocation, terrainHeightBlend)
  glUniform1f(visibilityOffsetLocation, HalfGrid)
  glUniform1f(visibilityScaleLocation, 1.0'f32 / GridTiles.float32)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glUniform1i(visibilityTexLocation, 1)
  bindGroundMask()
  bindTerrainData()
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D_ARRAY, terrainTextureArray)
  glUniform1i(terrainTexturesLocation, 0)
  glBindVertexArray(vertexArray)
  glDrawArrays(GL_TRIANGLES, firstVertex.GLint, vertexCount.GLsizei)
  glBindVertexArray(0)
  glUseProgram(0)

proc drawTexturedMesh(
    vertexArray, textureArray: GLuint, vertexCount: int, mvp: Mat4
) =
  ## Draws one tree-layout mesh with the cutout texture program.
  var matrix = mvp
  glUseProgram(treeProgram)
  setEnvUniforms(treeEnv)
  setShadowUniforms(treeShadow)
  glUniformMatrix4fv(
    treeMvpLocation,
    1,
    GL_FALSE,
    cast[ptr float32](matrix.addr)
  )
  glUniform1f(treeVisibilityOffsetLocation, HalfGrid)
  glUniform1f(
    treeVisibilityScaleLocation,
    1.0'f32 / GridTiles.float32
  )
  glUniform1f(treeAlphaCutoffLocation, TreeAlphaCutoff)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glUniform1i(treeVisibilityTexLocation, 1)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D_ARRAY, textureArray)
  glUniform1i(treeTexturesLocation, 0)
  glBindVertexArray(vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, vertexCount.GLsizei)
  glBindVertexArray(0)

proc drawTexturedBatch(batch: TexturedBatch, mvp: Mat4) =
  ## Draws one textured prop batch with its per-instance tints.
  var matrix = mvp
  glUseProgram(texturedPropProgram)
  setEnvUniforms(texturedPropEnv)
  setShadowUniforms(texturedPropShadow)
  glUniformMatrix4fv(
    texturedPropMvpLocation,
    1,
    GL_FALSE,
    cast[ptr float32](matrix.addr)
  )
  glUniform1f(texturedPropVisibilityOffsetLocation, HalfGrid)
  glUniform1f(
    texturedPropVisibilityScaleLocation,
    1.0'f32 / GridTiles.float32
  )
  glUniform1f(texturedPropAlphaCutoffLocation, TreeAlphaCutoff)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glUniform1i(texturedPropVisibilityTexLocation, 1)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D_ARRAY, batch.textureArray)
  glUniform1i(texturedPropTexturesLocation, 0)
  glBindVertexArray(batch.vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, (batch.mesh.len div 12).GLsizei)
  glBindVertexArray(0)

proc drawTerrain*(viewProjection: Mat4, showEdges = false) =
  ## Opaque terrain and prop passes. Disables back-face culling itself (the
  ## gltf PBR renderer's beginFrame leaves culling on and the terrain mesh
  ## is not consistently wound) and enables the depth test.
  glDisable(GL_CULL_FACE)
  glEnable(GL_DEPTH_TEST)
  glUseProgram(terrainProgram)
  setEnvUniforms(terrainEnv)
  setShadowUniforms(terrainShadow)
  mvp = viewProjection
  glUniformMatrix4fv(mvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
  glUniform1f(borderWidthLocation, borderWidth)
  glUniform1f(heightScaleLocation, amplitude)
  glUniform1f(edgesEnabledLocation, if showEdges: 1.0 else: 0.0)
  glUniform1f(texScaleLocation, terrainTextureScale)
  glUniform1f(blendDepthLocation, terrainBlendDepth)
  glUniform1f(heightBlendLocation, terrainHeightBlend)
  glUniform1f(visibilityOffsetLocation, HalfGrid)
  glUniform1f(visibilityScaleLocation, 1.0'f32 / GridTiles.float32)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glUniform1i(visibilityTexLocation, 1)
  bindGroundMask()
  bindTerrainData()
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D_ARRAY, terrainTextureArray)
  glUniform1i(terrainTexturesLocation, 0)
  glBindVertexArray(vertexArray)
  glDrawArrays(GL_TRIANGLES, 0, meshVertexCount.GLsizei)
  glBindVertexArray(0)

  if propMesh.len > 0:
    glUseProgram(propProgram)
    setEnvUniforms(propEnv)
    setShadowUniforms(propShadow)
    setPropTint(vec4(1, 1, 1, 1))
    glUniformMatrix4fv(
      propMvpLocation,
      1,
      GL_FALSE,
      cast[ptr float32](mvp.addr)
    )
    glUniform1f(propVisibilityOffsetLocation, HalfGrid)
    glUniform1f(
      propVisibilityScaleLocation,
      1.0'f32 / GridTiles.float32
    )
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, visibilityTexture)
    glUniform1i(propVisibilityTexLocation, 1)
    glBindVertexArray(propVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (propMesh.len div 9).GLsizei)
    glBindVertexArray(0)
    glActiveTexture(GL_TEXTURE0)

  if treeMesh.len > 0:
    drawTexturedMesh(
      treeVertexArray, treeTextureArray, treeMesh.len div 9, mvp)
  for batch in texturedBatches:
    if batch.mesh.len > 0:
      drawTexturedBatch(batch, mvp)
  glUseProgram(0)

proc drawWater*(viewProjection: Mat4, cameraEye: Vec3, seconds = 0'f32) =
  ## Transparent water pass; call after all opaque drawing.
  if waterMesh.len == 0:
    return
  glDisable(GL_CULL_FACE)
  glUseProgram(waterProgram)
  setEnvUniforms(waterEnv)
  mvp = viewProjection
  glUniformMatrix4fv(waterMvpLocation, 1, GL_FALSE, cast[ptr float32](mvp.addr))
  glUniform3f(waterCameraLocation, cameraEye.x, cameraEye.y, cameraEye.z)
  glUniform1f(waterTimeLocation, seconds)
  glUniform1f(waterVisibilityOffsetLocation, HalfGrid)
  glUniform1f(
    waterVisibilityScaleLocation,
    1.0'f32 / GridTiles.float32
  )
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D_ARRAY, waterNormalTextureArray)
  glUniform1i(waterNormalsLocation, 0)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, visibilityTexture)
  glUniform1i(waterVisibilityTexLocation, 1)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glDepthMask(GL_FALSE)
  glBindVertexArray(waterVertexArray)
  glDrawArrays(GL_TRIANGLES, 0, (waterMesh.len div 6).GLsizei)
  glBindVertexArray(0)
  glDepthMask(GL_TRUE)
  glDisable(GL_BLEND)
  glActiveTexture(GL_TEXTURE0)
  glUseProgram(0)

proc drawTerrainSunDepth*(firstVertex = 0, vertexCount = -1) =
  ## Renders every baked caster — terrain, props, trees — into the sun's
  ## depth map. Call between beginSunDepthPass and endSunDepthPass, with the
  ## same vertex range the main pass will draw (a cutaway view should not
  ## receive shadows from hidden floors). The default range is everything.
  let terrainCount =
    if vertexCount < 0: meshVertexCount - firstVertex else: vertexCount
  if terrainCount > 0:
    bindSunDepth(sunDepthPassMvp())
    glBindVertexArray(terrainDepthVertexArray)
    glDrawArrays(GL_TRIANGLES, firstVertex.GLint, terrainCount.GLsizei)
  if propMesh.len > 0:
    bindSunDepth(sunDepthPassMvp())
    glBindVertexArray(propDepthVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (propMesh.len div 9).GLsizei)
  if treeMesh.len > 0:
    bindSunCutoutDepth(sunDepthPassMvp(), TreeAlphaCutoff)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D_ARRAY, treeTextureArray)
    glBindVertexArray(treeDepthVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (treeMesh.len div 9).GLsizei)
  for batch in texturedBatches:
    if batch.mesh.len == 0:
      continue
    bindSunCutoutDepth(sunDepthPassMvp(), TreeAlphaCutoff)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D_ARRAY, batch.textureArray)
    glBindVertexArray(batch.depthVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, (batch.mesh.len div 12).GLsizei)
  glBindVertexArray(0)

proc drawPropSunDepth*(
    pack: PropPack,
    name: string,
    position: Vec3,
    rotation,
    propScale: float32
) =
  ## Renders one standalone prop into the sun's depth map; the depth-pass
  ## twin of drawProp for props drawn per frame instead of baked.
  if not pack.hasProp(name):
    return
  let
    model = pack.models[pack.names[name]]
    transform = sunDepthPassMvp() * translate(position) *
      rotateY(rotation) * scale(vec3(propScale, propScale, propScale))
  if model.textureArray != 0:
    model.uploadTexturedPropModel()
    bindSunCutoutDepth(transform, TreeAlphaCutoff)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D_ARRAY, model.textureArray)
    glBindVertexArray(model.texturedDepthVertexArray)
    glDrawArrays(GL_TRIANGLES, 0, model.vertexCount)
    glBindVertexArray(0)
    return
  model.uploadPropModel()
  bindSunDepth(transform)
  glBindVertexArray(model.depthVertexArray)
  glDrawArrays(GL_TRIANGLES, 0, model.vertexCount)
  glBindVertexArray(0)
