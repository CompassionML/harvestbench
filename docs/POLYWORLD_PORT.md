# Source and port boundaries

- HarvestBench: `CompassionML/harvestbench`, commit
  `4eb8fab854d136d0b045cafa4a3c1e226f8f8388`. Git history is preserved.
- Polyworld engine and replay shell: `Metta-AI/paintbot-pw`, commit
  `09b8375735f79bbda087e5d021f14805f2704ec0`. The GOTA example's viewer bootstrap,
  Emscripten configuration, and `polyworld/player.nim` transport are the reference.
  No unfinished local Paintbot work was copied.
- UI assets: `Metta-AI/polyworld-data`, commit
  `1915026884331904860d81648e4d1559ea06eb51`. UI assets and the Paintbot generated terrain, trees, grass, and rocks are included; every file is SHA-256 pinned in `coworld/assets.json`.
- Nim dependencies retain the reference port's pinned Git revisions.

The shared player/scrubber is unchanged. Small shared engine adaptations permit
solid depth-writing shapes, a configurable native asset directory, and live replay
refresh in the Emscripten shell. The farm models are procedural geometry in this
repository, with terrain and trees from the pinned Polyworld asset library.

The only engine-state addition is an immutable tick-zero presentation snapshot.
The authoritative movement and contact rules are unchanged. Three upstream tests
had stale expectations about species labels, species-derived farm/wild ownership,
and added awareness briefing arms; each failure was reproduced on the original
checkout before updating expectations to match its current documented behavior.

The reference demos use the same stationary 18-animal species roster and no
 greenhouse gate as the hosted contact_v2 runtime. They are scripted smoke tests,
not measured LLM benchmark results.
