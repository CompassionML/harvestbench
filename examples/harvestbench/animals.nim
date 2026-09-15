## Small, expressive farm animals. Animation is a pure function of replay time.
import std/[math, strutils]
import chroma, vmath
import polyworld/shapes

type Pose = object
  origin: Vec3
  roll, heading: float32

proc transform(pose: Pose, p: Vec3): Vec3 =
  let q=vec3(p.x,p.y*cos(pose.roll)-p.z*sin(pose.roll),
             p.y*sin(pose.roll)+p.z*cos(pose.roll))
  pose.origin+vec3(q.x*cos(pose.heading)-q.z*sin(pose.heading),q.y,
                  q.x*sin(pose.heading)+q.z*cos(pose.heading))

proc tone(c: ColorRGBX, factor: float32): ColorRGBX =
  rgbx(uint8(clamp(c.r.float32*factor,0,255)),uint8(clamp(c.g.float32*factor,0,255)),
       uint8(clamp(c.b.float32*factor,0,255)),c.a)

proc ellipsoid(renderer: var ShapeRenderer, pose: Pose, center,size: Vec3,c:ColorRGBX) =
  const sides=10
  const rings=6
  proc vertex(row,col:int):Vec3 =
    let lat=PI.float32*(row.float32/rings.float32-0.5)
    let lon=2*PI.float32*col.float32/sides.float32
    transform(pose,center+vec3(cos(lat)*cos(lon)*size.x,sin(lat)*size.y,cos(lat)*sin(lon)*size.z))
  for row in 0..<rings:
    for col in 0..<sides:
      let color=tone(c,0.78+0.16*row.float32/rings.float32+0.06*cos(col.float32))
      renderer.addQuad(vertex(row,col),vertex(row+1,col),vertex(row+1,col+1),vertex(row,col+1),color)

proc animalWalk*(seconds, phase:float32):Vec3 =
  let t=seconds*0.65+phase
  vec3(0.12*cos(t),0,0.10*sin(t))

proc cuteAnimal*(renderer: var ShapeRenderer, at:Vec3, species:string,
                 alive:bool, seconds,phase,impactAge:float32) =
  let name=species.replace("_"," ")
  let bird=name.contains("goose") or name in ["duck","chicken"]
  let rabbit=name=="rabbit"
  let pig=name in ["pig","boar"]
  let sheep=name=="sheep"
  let cow=name=="cow"
  let tiny=name in ["mouse","squirrel","opossum"]
  let baseScale=1.44'f32*(if tiny:0.72'f32 elif bird:0.82'f32 else:1'f32)
  let age=if alive:0'f32 else:clamp(impactAge/6,0'f32,1'f32)
  let collapse=if alive:0'f32 else:clamp(age/0.8,0'f32,1'f32)
  let hop=if alive:sin(seconds*2.2+phase)*0.018 else:sin(collapse*PI.float32)*0.24
  let walkTime=if alive:seconds else:seconds-max(0'f32,impactAge)/6
  let walking=animalWalk(walkTime,phase)
  let t=walkTime*0.65+phase
  var pose=Pose(origin:at+walking+vec3(collapse*0.09,hop+collapse*0.36,0),
                roll:collapse*PI.float32/2,heading:arctan2(0.10*cos(t),-0.12*sin(t)))
  if not alive:
    let spread=0.4+0.6*clamp(impactAge/5,0'f32,1'f32)
    let pool=at+walking+vec3(0,0.015,0)
    renderer.addCircle(pool,0.80*spread,rgbx(105,20,25,255))
    for i in 0..5:
      let angle=i.float32*1.13+phase
      renderer.addCircle(pool+vec3(cos(angle)*0.55*spread,0.001,sin(angle)*0.40*spread),
        (0.22+0.05*sin(angle))*spread,rgbx(126,24,29,255))
  var coat=case name
    of "pig":rgbx(245,172,181,255)
    of "boar":rgbx(148,111,84,255)
    of "cow":rgbx(243,234,206,255)
    of "sheep":rgbx(244,237,215,255)
    of "goose","wild goose","duck","chicken":rgbx(249,238,205,255)
    of "rabbit":rgbx(211,186,158,255)
    of "mouse":rgbx(173,174,174,255)
    of "squirrel":rgbx(185,116,61,255)
    else:rgbx(192,178,166,255)
  if not alive:coat=tone(coat,1-0.3*collapse)
  template blob(center,size:Vec3,color:ColorRGBX)=
    ellipsoid(renderer,pose,center*baseScale,size*baseScale,color)
  let breathe=if alive:1+0.035*sin(seconds*3+phase) else:1'f32
  blob(vec3(0,0.33,0),vec3(0.32,0.23*breathe,0.23),coat)
  if sheep:
    for x in [-0.18'f32,0,0.18]:
      for z in [-0.14'f32,0.14]:blob(vec3(x,0.42,z),vec3(0.17,0.17,0.15),coat)
  if cow:
    blob(vec3(-0.13,0.48,-0.1),vec3(0.13,0.08,0.15),rgbx(85,76,63,255))
    blob(vec3(0.14,0.36,0.205),vec3(0.13,0.12,0.03),rgbx(85,76,63,255))
  let headBob=if alive:0.02*sin(seconds*1.7+phase) else:0'f32
  let head=vec3(0.28,0.48+headBob,0)
  blob(head,vec3(0.205,0.205,0.19),if sheep:rgbx(103,91,79,255) else:coat)
  let muzzle=if bird:rgbx(244,170,55,255) elif pig or cow:rgbx(239,151,155,255) else:rgbx(237,208,184,255)
  blob(head+vec3(0.17,-0.045,0),if bird:vec3(0.17,0.055,0.12) else:vec3(0.10,0.10,0.14),muzzle)
  if pig:
    for z in [-0.047'f32,0.047]:blob(head+vec3(0.263,-0.035,z),vec3(0.011,0.024,0.017),rgbx(141,75,85,255))
  let blink=alive and ((seconds+phase) mod 4.8)<0.13
  for z in [-0.163'f32,0.163]:
    let eye=head+vec3(0.105,0.067,z)
    blob(eye,vec3(0.043,if blink or not alive:0.008'f32 else:0.052'f32,0.035),rgbx(37,42,36,255))
    if alive and not blink:
      blob(eye+vec3(0.015,0.021,if z<0: -0.024'f32 else:0.024'f32),vec3(0.014,0.016,0.01),rgbx(255,255,242,255))
    if not bird:
      let earHeight=if rabbit:0.23'f32 elif pig:0.11'f32 else:0.075'f32
      blob(head+vec3(-0.035,0.18,z*0.88),vec3(0.065,earHeight,0.052),coat)
      blob(head+vec3(-0.005,0.19,z*0.88),vec3(0.045,earHeight*0.65,0.029),rgbx(228,148,154,255))
  if name=="chicken":
    for x in [0.19'f32,0.27,0.35]:blob(vec3(x,0.70,0),vec3(0.048,0.07,0.045),rgbx(212,81,70,255))
  if cow:
    for z in [-0.13'f32,0.13]:blob(head+vec3(-0.06,0.2,z),vec3(0.035,0.10,0.035),rgbx(230,209,157,255))
  for x in (if bird: @[0.04'f32] else: @[-0.18'f32,0.17]):
    for z in [-0.12'f32,0.12]:
      let gait=seconds*8+phase+(if x*z>0:0'f32 else:PI.float32)
      let tap=if alive:0.055*max(0'f32,sin(gait)) else:0'f32
      let stride=if alive:0.08*cos(gait) else:0'f32
      blob(vec3(x+stride,0.105+tap,z),vec3(0.056,0.13,0.055),if bird:rgbx(224,155,53,255) else:tone(coat,0.82))
  let wag=if alive:sin(seconds*4+phase)*0.055 else:0'f32
  if pig:
    for i in 0..4:
      let a=i.float32*1.1
      blob(vec3(-0.33-i.float32*0.012,0.38+0.045*sin(a),wag+0.045*cos(a)),vec3(0.032),coat)
  elif rabbit:
    blob(vec3(-0.34,0.34,wag),vec3(0.095),rgbx(247,237,217,255))
  elif name=="squirrel":
    blob(vec3(-0.34,0.48,wag),vec3(0.14,0.30,0.13),coat)
  elif bird:
    blob(vec3(-0.28,0.43,wag),vec3(0.13,0.09,0.12),coat)
    for z in [-0.20'f32,0.20]:blob(vec3(-0.04,0.36,z),vec3(0.2,0.12,0.045),tone(coat,0.92))
  else:
    blob(vec3(-0.35,0.28,wag),vec3(0.025,0.15,0.025),tone(coat,0.8))

proc cornCob*(renderer:var ShapeRenderer,at:Vec3,heading=0'f32,scale=1'f32) =
  let pose=Pose(origin:at,heading:heading)
  ellipsoid(renderer,pose,vec3(0,0.11,0)*scale,vec3(0.055,0.14,0.055)*scale,rgbx(249,196,49,255))
  ellipsoid(renderer,pose,vec3(-0.045,0.035,0)*scale,vec3(0.035,0.10,0.06)*scale,rgbx(97,139,48,255))
  ellipsoid(renderer,pose,vec3(0.04,0.02,0)*scale,vec3(0.03,0.09,0.055)*scale,rgbx(123,153,50,255))
