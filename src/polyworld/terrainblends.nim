import vmath

proc radialWeights*(position: Vec2): Vec4 {.raises: [].} =
  ## Gives four nearby tile centers circular support with a smooth falloff.
  let
    northWest = position
    northEast = position - vec2(1, 0)
    southWest = position - vec2(0, 1)
    southEast = position - vec2(1, 1)
    weights = max(vec4(1.0) - vec4(
      dot(northWest, northWest),
      dot(northEast, northEast),
      dot(southWest, southWest),
      dot(southEast, southEast)
    ), vec4(0.0))
  result = weights * weights

proc materialWeights*(weights, materials: Vec4): Vec4 {.raises: [].} =
  ## Removes absent surfaces and combines identical materials before blending.
  result = weights
  if materials.x < 0:
    result.x = 0
  if materials.y < 0:
    result.y = 0
  if materials.z < 0:
    result.z = 0
  if materials.w < 0:
    result.w = 0
  if materials.y == materials.x:
    result.x += result.y
    result.y = 0
  if materials.z == materials.x:
    result.x += result.z
    result.z = 0
  elif materials.z == materials.y:
    result.y += result.z
    result.z = 0
  if materials.w == materials.x:
    result.x += result.w
    result.w = 0
  elif materials.w == materials.y:
    result.y += result.w
    result.w = 0
  elif materials.w == materials.z:
    result.z += result.w
    result.w = 0
  result = result / max(result.x + result.y + result.z + result.w, 0.00001)

proc reliefWeights*(
  weights, heights: Vec4,
  strength, depth: float32
): Vec4 {.raises: [].} =
  ## Lets height shape transitions without introducing an absent material.
  var coverage = vec4(0.0)
  if weights.x > 0:
    coverage.x = 1
  if weights.y > 0:
    coverage.y = 1
  if weights.z > 0:
    coverage.z = 1
  if weights.w > 0:
    coverage.w = 1
  let
    influence = clamp(weights * 4.0, vec4(0.0), vec4(1.0))
    fade = influence * influence * (vec4(3.0) - influence * 2.0)
    scores = weights + heights * strength * fade
    eligible = scores - (vec4(1.0) - coverage) * 100.0
    cutoff = max(max(eligible.x, eligible.y), max(eligible.z, eligible.w)) -
      max(depth, 0.0001)
  result = max(scores - vec4(cutoff), vec4(0.0)) * coverage
  result = result / max(result.x + result.y + result.z + result.w, 0.00001)

proc materialColor*(material: float32): Vec3 {.raises: [].} =
  ## Colors grass green, roads orange, gravel magenta, and marsh blue.
  result = vec3(0.0)
  if material >= 0:
    if material < 0.5:
      result = vec3(0.2, 0.8, 0.15)
    elif material < 1.5:
      result = vec3(0.7, 0.7, 0.1)
    elif material < 2.5:
      result = vec3(0.1, 0.5, 0.35)
    elif material < 3.5:
      result = vec3(0.55, 0.4, 0.15)
    elif material < 4.5:
      result = vec3(1.0, 0.5, 0.05)
    elif material < 5.5:
      result = vec3(0.55, 0.65, 0.8)
    elif material < 6.5:
      result = vec3(0.85, 0.15, 0.7)
    elif material < 7.5:
      result = vec3(0.25, 0.15, 0.05)
    else:
      result = vec3(0.1, 0.3, 0.9)
