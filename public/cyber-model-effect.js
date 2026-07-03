// ═══════════════════════════════════════════════════
//  粒子特效导出代码
//  名称: 模型声波剥离
//  描述: 3D模型粒子·音频驱动向外剥离与声波流转
//  生成时间: 2026-07-02 18:51:11
//
//  接入说明（可复刻工作流）:
//  预设 8: 重命名为 cyber-model-effect.js + cyber-model-particles.bin
//  预设 9: 重命名为 cyber-model-effect-2.js + cyber-model-particles-2.bin
//  放到 public/ 目录覆盖旧文件，重启应用即可
// ═══════════════════════════════════════════════════

var EFFECT_CONFIG = {
  name: '模型声波剥离',
  desc: '3D模型粒子·音频驱动向外剥离与声波流转',
  camera: { radius: 5.00, phi: 0.20, theta: 0.00 },
  particleCount: 200000,
  dataFile: 'cyber-model-particles.bin',
  modelScale: 2.45,
  modelRotation: [0.0000, 0.0000, 0.0000],
};

var EFFECT_VERTEX_SHADER = `
precision highp float;
attribute vec2 aUv;
attribute float aRand;
attribute vec3 aColor;
uniform float uTime,uPixel,uPointScale,uColorBoost;
uniform float uBass,uMid,uTreble,uBeat,uBeatBurst,uEnergy,uIntensity,uOpacity,uLoading;
varying float vAlpha;
varying float vBright;
varying vec3 vColor;
void main(){
  float K = uIntensity * 1.6;
  vec3 modelPos = position;
  vec3 dir = normalize(modelPos + vec3(0.001));

  // 低频呼吸膨胀
  float breathe = sin(uTime * 0.10 + aRand * 6.28) * uBass * 0.05;

  // 节拍爆发
  float burst = uBeat * uEnergy * 0.10 * aRand;

  // 中频表面流动
  vec3 up = abs(dir.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
  vec3 tangent = normalize(cross(dir, up));
  float flow = sin(uTime * 0.10 + modelPos.y * 3.0) * uMid * 0.05;

  vec3 pos = modelPos + dir * (breathe + burst) * K + tangent * flow * K;

  // 颜色：以模型原色 (aColor) 为主，tint 仅做极轻微的高度层次调整
  float heightFactor = smoothstep(-1.50, 1.50, modelPos.y + (aRand - 0.5) * 0.4);
  vec3 tint = mix(vec3(0.0000,0.7059,1.0000), vec3(1.0000,1.0000,1.0000), heightFactor);
  vec3 baseColor = aColor;
  // 每粒子亮度微变化 (0.85 ~ 1.15)，下限提高以保证形状可辨
  float perParticleBright = 0.85 + aRand * 0.3;
  vColor = mix(baseColor, vec3(1.0), uBeat * 0.05);
  vAlpha = (0.85 + uEnergy * 0.05) * uOpacity * (0.7 + aRand * 0.3);
  vBright = (1.0 + uBeat * 0.10 + uTreble * 0.10) * uColorBoost * perParticleBright;

  // 粒子大小（每粒子 0.8x ~ 1.3x，下限提高以填满表面空隙）
  float perParticleSize = 0.8 + aRand * 0.5;
  float size = (0.05 + uBass * 0.10 + burst * 1.5) * uPointScale * perParticleSize;
  vec4 mv = modelViewMatrix * vec4(pos, 1.0);
  float dist = max(0.5, -mv.z);
  gl_PointSize = clamp(size * uPixel * 180.0 / dist, 1.0, 64.0);
  gl_Position = projectionMatrix * mv;
}
`;

var EFFECT_FRAGMENT_SHADER = `
precision highp float;
uniform float uOpacity, uLoading;
varying float vAlpha;
varying float vBright;
varying vec3 vColor;
void main(){
  vec2 pc = gl_PointCoord - vec2(0.5);
  float d = length(pc);
  if (d > 0.5) discard;
  float falloff = pow(1.0 - d * 2.0, 0.50);
  vec3 col = vColor * vBright * falloff;
  float loadingFade = 1.0 - uLoading;
  gl_FragColor = vec4(col, vAlpha * falloff * loadingFade);
}
`;
