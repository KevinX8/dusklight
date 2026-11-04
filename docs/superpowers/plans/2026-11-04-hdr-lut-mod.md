# HDR+ LUT Mod Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `com.kevinx8.hdr-lut` — a Dusklight HDR grade where the entire look lives in 36 standard `.cube` LUTs (16 field/settlement regions, 12 dungeons, caves, 3 minigames, title, menus, default, neutral), loaded by the mod at startup and sampled per-stage by a WebGPU pass.

**Architecture:** New mod repo copied from the `hdr-mod` skeleton (CMake `add_mod`, FetchDusklight, 8-platform CI + `merge_mod.py`). No hooks needed for stage lookup (`dComIfGp_getStartStageName()` is a direct call; one pre-hook on `Z2SceneMgr::setSceneName` for scene names). The shader decodes the frame in gamma-encoded space, samples the stage's LUT (2 resident GPU slices, crossfade), and re-encodes in the engine's HDR convention. A Python generator authors each LUT and previews it offline on web-sourced reference screenshots.

**Tech Stack:** C++20 (ModC mod SDK), WGSL, `.cube` 33³, Python (numpy/PIL), GitHub Actions (8 platforms), GfxService 1.5.

**Spec:** `docs/superpowers/specs/2026-11-04-hdr-lut-mod-design.md` (in the dusklight repo; travels with this plan)

## Global Constraints

- Repo: local `/media/ESSD/Dusklight/hdr-lut-mod`, remote `https://github.com/KevinX8/dusklight-hdr-lut-mod` (create via `gh repo create`).
- Engine pin: `set(DUSKLIGHT_VERSION "e303253dcf5a3cfd190b79c6ae6148b4f4f8c57b")` (fork `KevinX8/dusklight-hdr` tag `v2.0.3-hdr.2`); `DUSKLIGHT_REPOSITORY` = the fork URL.
- `add_mod(hdr_lut_mod FEATURES webgpu fmt game ... BUNDLE)` — supported features are exactly `fmt game webgpu`.
- LUTs: 33³, `LUT_3D_SIZE 33`, DOMAIN 0 1, gamma-encoded space, output ≤ 1.0 (1.0 = display peak); shader owns nits.
- Encode convention (must match hdr mod, engine decodes `sign*|c|^2.2 · 80/paper`): output `e = copy_sign(pow(nits80/luma_scale, 1/2.2))` with `nits80 = graded * peak/80`, `luma_scale = paper/80`; zero pixels stay zero.
- 2 resident 3D slices only (WebGPU has no 3D texture arrays); slice rotation on fade end; no per-frame texture upload.
- Settings cvars only: `intensity` (1000), `paperWhite` (200), `peak` (1000), `eotf` (0), `debugView` (0). Float cvars stored ×1000 (hdr mod convention).
- Never launch the game on user devices (Legion Go 2, phones, Macs) — Linux dev-machine runs only; user judges from screenshots/their own devices.
- HDR mode off ⇒ mod idles (hdr mod pattern: `get_hdr_mode` → `GFX_HDR_OFF` ⇒ `MOD_OK` early-return).
- Commits: conventional, `feat(hdr-lut): …` style, one per task step as listed.
- CI tag pattern: releases on tags `hdr-lut-*`; combine job artifact pattern stays `mod-*-*`.
- References for looks: web screenshots only, >560p (PIL-verified), Dusklight preferred, TPHD analogs; archive under `refs/<key>/` + `SOURCES.md` URL lines; `thin-ref` flag allowed.

## Review Focus

1. **Unknown/renamed stage name** (new patch, debug stage) → must land on `default` LUT, no crash, no per-frame error log.
2. **Malformed/truncated/missing `.cube`** → that key falls back to `neutral` + one log line at startup; mod still loads.
3. **Texture upload geometry**: 33×rgba16float rows need 256-byte alignment (264 B/row → pad 512) — unpadded writes fail silently on some backends; verify padded `bytesPerRow` and that uploads happen only on stage change, never per frame.
4. **Title ↔ file-select ↔ gameplay transitions**: key switches must not flash the gameplay LUT over system scenes (scene hook wins over stage name).
5. **Banding on 8-bit palette art**: after each authored LUT, the preview pack must show dark-gradient regions (sky, water, torchlight falloff) with no new steps vs. ungraded; check gradients, not only mid-tones.
6. **Both HDR mods enabled** → double-graded frame; accepted, documented; must not crash or leak (each mod keeps its own target).
7. **HDR off** with the LUT mod enabled → frame byte-identical to no mod (idle path).

---

### Task 1: Repo scaffold + 8-platform CI green (idle mod)

**Files:**
- Create repo tree: copy from `/media/ESSD/Dusklight/hdr-mod`: `CMakeLists.txt`, `mod.json.in`, `cmake/FetchDusklight.cmake`, `tools/merge_mod.py`, `tools/check-wgsl.sh`, `.github/workflows/build.yml`, `.gitattributes`, `.gitignore`
- Create: `src/mod.cpp` (idle: `DEFINE_MOD();`, `IMPORT_SERVICE(LogService, svc_log)`, `mod_initialize/update/shutdown` returning `MOD_OK`), `mod.json.in` (`id com.kevinx8.hdr-lut`, `name HDR+ LUT`, desc mentions per-area LUTs + HDR Output requirement)
- Modify: `CMakeLists.txt` — `project(hdr_lut_mod VERSION 1.0.0 LANGUAGES CXX)`; `add_mod(hdr_lut_mod FEATURES webgpu fmt game SOURCES src/mod.cpp MOD_JSON … RES_DIR res BUNDLE)`; pin `e303253dcf5a3cfd190b79c6ae6148b4f4f8c57b`
- Modify: `.github/workflows/build.yml` — matrix/artifacts unchanged from hdr-mod (8 platforms, `name: mod-${{matrix.platform}}`); release step on tags

**Interfaces:**
- Produces: repo layout all later tasks extend; `hdr_lut_mod.dusk` zip layout `mod.json + lib/<triple>/mod.so(.dll) + res/…`; triples: linux-x86_64, linux-aarch64, macos-arm64, macos-x86_64, ios-arm64, windows-amd64 (mod.dll), windows-arm64 (mod.dll), android-aarch64.

- [ ] **Step 1: Create local repo from skeleton, apply the renames above, `git init` + first commit `feat(hdr-lut): scaffold mod repo from hdr-mod skeleton`**
- [ ] **Step 2: Verify local build:** `cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build build` in the new repo; expect `build/mods/hdr_lut_mod.dusk` (zip, one `lib/linux-x86_64/mod.so`); `unzip -l` shows `mod.json`
- [ ] **Step 3: `gh repo create KevinX8/dusklight-hdr-lut-mod --private --push` (push `main`), watch CI: all 8 build jobs + `Combine bundles` green, artifact `mod-combined` contains one 8-lib `hdr_lut_mod.dusk`**
- [ ] **Step 4: Commit/push any fixes; record commit SHA**

### Task 2: `.cube` loader (pure parse) + host tests

**Files:**
- Create: `src/lut_loader.h`, `src/lut_loader.cpp`, `test/lut_loader_test.cpp` (assert-based, `main()` returns nonzero on failure), `test/fixtures/valid_33.cube`, `test/fixtures/truncated.cube`, `test/fixtures/bad_size.cube`
- Modify: `CMakeLists.txt` — `option(DUSKLUT_HOST_TESTS "Build host tests" OFF)`; standalone builds with `DUSKLUT_HOST_TESTS=ON` add executable `lut_loader_test` from `src/lut_loader.cpp test/lut_loader_test.cpp`
- Modify: `.github/workflows/build.yml` — linux-x86_64 job: configure with `-DDUSKLUT_HOST_TESTS=ON`, run `./build/lut_loader_test` after build

**Interfaces:**
- Produces: `namespace lut { struct Cube { int size = 0; std::vector<float> rgb; };  // rgb size = size³*3, index ((b*size+r)*size+g)*3, R first, g fastest (matches .cube R-inner fastest order).
  bool parse_cube(const char* text, size_t len, Cube& out, char* err, size_t err_cap); }` — accepts comments (`#`), `LUT_3D_SIZE n` (32≤n≤64), `LUT_3D_DOMAIN 0 1` (value 1) / DOMAIN absent = 1, float triplets; rejects 1D/size-mismatch/missing header/non-finite/extra rows.

- [ ] **Step 1: Write failing `test/lut_loader_test.cpp`: `parse_cube` on `valid_33.cube` (generated 33³ identity fixture) → size 33, `rgb[0]=0`, corner `b=32,g=32,r=32` == 1.0 triplets, comments ignored; `truncated.cube` → false, `err` non-empty; `bad_size.cube` (`LUT_3D_SIZE 17`) → false; DOMAIN `0 1` accepted, DOMAIN `0 2` rejected**
- [ ] **Step 2: Run: `cmake -B build -G Ninja -DDUSKLUT_HOST_TESTS=ON && cmake --build build && ./build/lut_loader_test` — expect FAIL (missing symbols)**
- [ ] **Step 3: Implement `parse_cube` (no exceptions, no fmt; strtol/strtof scanning; counts rows; caps size³*3)**
- [ ] **Step 4: Run test → PASS**
- [ ] **Step 5: Commit `feat(hdr-lut): .cube parser with host tests`** (CI: linux job runs the test)

### Task 3: Generator + preview tools (neutral, default)

**Files:**
- Create: `tools/gen_luts.py` (argparse: `--out res/luts`, emits every key from a per-key author-function registry), `tools/keys.json` (the key list — single source of truth, consumed by gen, selfcheck, check_refs), `tools/preview.py` (`--cube f --in png --out png` applies a LUT in gamma space, PIL+numpy), `tools/selfcheck.py` (round-trip: emit → parse (python twin of parser rules) → compare + fixture check)
- Create: `res/luts/neutral.cube` (identity), `res/luts/default.cube` (mild base recipe: saturation 1.08, paper-white lift `out = in^1.04 · 1.12` clamped ≤1, highlights 0.94→1.0 rolloff, 8-bit safe: no clipping of pure black/white)

**Interfaces:**
- Produces: `tools/keys.json` = the 36 roster keys (seeded from spec roster now; Task 4 prunes/extends per the stage dump — the final word); `author_<key>(x: np.ndarray) -> np.ndarray` functions over a 33³ grid in gamma space; every emitted file passes `LUT_3D_SIZE 33` and max ≤ 1.0.

- [ ] **Step 1: Write `tools/selfcheck.py` failing: it runs `gen_luts.py --out /tmp/luts`, loads `tools/keys.json`, then asserts for every key: file exists, parses (python), size 33, all values in [0,1], `neutral.cube` is identity (`v == index/32` triplets), `default.cube` strictly between neutral and neutral*1.15 on midtones; prints OK per key**
- [ ] **Step 2: Run `python3 tools/selfcheck.py` → FAIL (no gen_luts.py)**
- [ ] **Step 3: Implement `gen_luts.py` with `authors/neutral_identity()`, `authors/default_base()` + emit loop; implement `preview.py` (LUT trilinear sample of PNG, in gamma space, `mix(in, graded, intensity=1)`)**
- [ ] **Step 4: `python3 tools/selfcheck.py` → PASS; generated files committed to `res/luts/`**
- [ ] **Step 5: Commit `feat(hdr-lut): generator emits neutral+default, preview tool, self-check`**

### Task 4: Stage/scene registry → mapping table (decodes D_MN54)

**Files:**
- Create: `tools/dump_stages.py` (regex-parses `/media/ESSD/Dusklight/dusklight/src/d/d_com_static.cpp` + `src/d/d_stage.cpp` room-control/room-type tables and `src/Z2AudioLib/SpotName.h` for all `F_/D_/R_/T_/S_` stage codes; prints deduped list), `docs/mapping.md` (table: code → key + evidence), `src/scene_map.h`, `src/scene_map.cpp`, `test/scene_map_test.cpp`
- Modify: `CMakeLists.txt` (add `src/scene_map.cpp` to mod sources + to `lut_loader_test` target: `scene_map_test.cpp` joins the host test target list)

**Interfaces:**
- Produces: `namespace hdr_lut { enum { kLutCount = <N> }; extern const char* const kLutKeys[kLutCount];  // index order = stable, committed
  int lut_for_stage(const char* stage_name);   // exact strcmp table, else index of default
  int lut_for_scene(const char* scene_name);   // -1 = no override; S_MV000 → menus/title group
  const char* lut_key_for_stage(const char* s); // debug string }` — every non-default key in `kLutKeys` has a `.cube` (Task 3 registry check).

- [ ] **Step 1: Run `python3 tools/dump_stages.py` > docs/mapping.md skeleton; author the mapping per spec (16+12+8 keys, boss/cutscene inheritance rows); decode `D_MN54` from the room tables (room names in `d_com_static.cpp` / actor files referencing it) and record the finding in docs/mapping.md; keys only from codes the dump proves (spec anti-hallucination rule)**
- [ ] **Step 2: Write failing `scene_map_test.cpp`: every `mods/randomizer/src/stages.h` real-stage code (allStages array) maps to a key (never crash, default ok); `lut_for_stage("ZZZ9")` → default index; `lut_for_scene("S_MV000")` ≥ 0; `lut_for_scene("F_SP102")` = -1 or title key; `kLutKeys` contains neutral/default and count matches**
- [ ] **Step 3: Run host test → FAIL**
- [ ] **Step 4: Implement `scene_map.cpp` static tables (exact strings from the dump); test → PASS**
- [ ] **Step 5: Commit `feat(hdr-lut): stage/scene mapping from base-game tables, decodes D_MN54`**

### Task 5: Reference sourcing (36 keys)

**Files:**
- Create: `refs/<key>/` (1+ screenshot per key), `refs/<key>/SOURCES.md` (URL, site, date, resolution), `tools/check_refs.py` (walks refs: every key in `KEYS` has ≥1 jpg/png ≥ 561p height-or-width; prints MISSING list; `thin-ref` keylist file `refs/thin.txt`), `docs/refs.md` (key → image + source table)

- [ ] **Step 1: Write `tools/check_refs.py` failing (refs/ empty): keys read from `tools/keys.json`; commit `test(hdr-lut): refs completeness checker`**
- [ ] **Step 2: Source refs per key: `websearch` "Dusklight <area> screenshot" (Fandom/GameBanana/Steam/YouTube thumbnails >560p), fallback TPHD (Zelda Universe, Fandom); download via curl + browser UA, dedupe; Dusklight-original staging (title screens) from the fork README screenshots**
- [ ] **Step 3: Run `python3 tools/check_refs.py` → all keys present, >560p; thin keys flagged listed in docs/refs.md**
- [ ] **Step 4: Commit `docs(hdr-lut): reference screenshots for all 36 keys`**

### Task 6: Shader + render pipeline (fixed `default` LUT) + settings

**Files:**
- Create: `res/hdr_lut.wgsl`, `src/settings.hpp/.cpp`, replace `src/mod.cpp`
- Key structures (exact): WGSL `Params { intensity: f32, fade: f32, paper: f32, peak: f32, eotf: f32, debug_stage: u32, lut_cur: u32, lut_prev: u32 }` (32 B); C++ `struct alignas(16) LutParams { float intensity=1f, fade=1f, paper=200f, peak=1000f, eotf=2.2f; uint32_t debug_stage=0, lut_cur=0, lut_prev=0; };` `static_assert(sizeof(LutParams)==32)`. Bindings: 0 uniform, 1 `texture_2d<f32>` scene, 2 sampler (Linear/ClampToEdge), 3+4 `texture_3d<f32>` lut_cur/prev. Slice format `rgba16float`, `bytesPerRow = 512` (33×8=264→pad), rows 33, slices 33. LUT coord: `uv3 = (in.rgb*(32.0/33.0)) + (0.5/33.0)`; sample both slices, `mix(prev,cur,fade)`, then `graded = mix(in, lut, intensity)` (in gamma space), `e = pow(clamp(graded*peak/paper,0,FLT_MAX), 1/2.2)` sign-preserving, `vec4(e, alpha)`; pure-black pixels stay 0.
- Settings panel rows (section "HDR+ LUT"): `Intensity` NUMBER 0–1000 step 10 (x1000), `Paper White (nits)` 50–1000 step 10, `Peak (nits)` 100–10000 step 50, `SDR EOTF` SELECT {Power 2.2, sRGB curve}, `Debug view` SELECT {Off, Show active key, Split grade/orig} — cvar `debugView` reset at startup (hdr mod line pattern).
- EOTF decode: reuse hdr mod `eotf_decode` semantics for `eotf` 2.2 vs −2.2 on the **input** before LUT lookup (LUT authored for 2.2 space; sRGB-curve mode decodes to 2.2 space before sampling), encode always 1/2.2 (engine convention).

**Interfaces:**
- Consumes: Task 2 `lut::parse_cube`; Task 4 `hdr_lut::kLutKeys/lut_key_for_stage`; Task 3 `res/luts/*.cube`.
- Produces: `src/lut_texture.h/.cpp`: `struct LutStore { std::vector<std::vector<float>> slices; }; bool lut_store_load_all(ModContext* ctx, LutStore& out, char* err, size_t err_cap);` (uses `svc_resource->load(mod_ctx, "luts/<key>.cube", &buf)` per key + `lut::parse_cube`; missing/bad file → neutral slice + `err` names each fallback key; one startup log line listing them); `void lut_upload_slice(WGPUQueue queue, WGPUTexture tex, const std::vector<float>& rgb)` (f32→f16 rgba, `bytesPerRow = 512` padded rows); pipeline `g_pipeline` + `g_target` (RGBA16Float) per hdr mod (`ensure_target`, `on_grade`, `on_frame_after_hud` → `set_hdr_frame` with `scene_linear=false`, `paper_white_nits`, `peak_nits`).

- [ ] **Step 1: Write host test additions: `lut_coord(0,0,0)`/`(1,1,1)` corner formulas (pure function in lut_loader: `lut_uv_scale()/lut_uv_bias()` consts) assert `32/33` and `0.5/33`**
- [ ] **Step 2: Implement `lut_texture.cpp` + f16 convert (round-to-nearest even on half bits) — self-check asserts: 1.0→0x3C00, 0.0→0, 0.5→0x3800**
- [ ] **Step 3: Write `res/hdr_lut.wgsl` (fullscreen triangle = hdr mod's); validate: `bash tools/check-wgsl.sh res/hdr_lut.wgsl` (naga) → no errors**
- [ ] **Step 4: Implement `mod.cpp`: initialize = settings_register → `get_hdr_mode` (OFF ⇒ idle) → load shader/pipeline → `LutStore::load_all` → register compute type + `GFX_STAGE_FRAME_AFTER_HUD` hook; frame hook: `resolve_pass` → params from cvars (lut_cur=lut_prev=index of default, fade=1) → `push_uniform`/`push_compute`; `on_grade`: bind 5 entries, draw 3; `set_hdr_frame`; shutdown frees shader/store/targets**
- [ ] **Step 5: CI 8-platform green; then Linux smoke: `./build/x-linux-ci-gcc/... Dusklight` (dev machine), HDR=HDR10, LUT mod enabled: log shows `HDR+ LUT active`, no wgpu validation errors, screenshot: game frame graded through `default` LUT; HDR OFF run: frame identical to modless (screenshot diff)**
- [ ] **Step 6: Commit `feat(hdr-lut): LUT pipeline with default slice, settings panel`**

### Task 7: Stage/scene tracking + 2-slice crossfade

**Files:**
- Modify: `src/mod.cpp` (poll + fade state + uploads), `src/scene_map.cpp` (title vs menus mapping for `S_MV000` sub-states from smoke log)
- Create: `docs/keys-log.md` (observed key sequence from smoke run, pasted from log)

**Interfaces:**
- Produces: `struct KeyState { int cur_key, prev_key; double t0; double fade_s = 0.5; }`; game-thread `mod_update()` (game feature on): `const char* dComIfGp_getStartStageName()` poll (`#include "d/d_com_inf_game.h"`), scene-name pre-hook `DEFINE_HOOK(&Z2SceneMgr::setSceneName, SceneSetSceneName);` + `mods::hook::add_pre<SceneSetSceneName>(...)` caching `mods::arg<const char*>(args, 0)`; scene override wins; on change → fade 0→1 over 0.5 s (system-scene switches instant, fade=1).
- `on_grade` payload gains `int tex_cur_key, tex_prev_key`; upload happens on render thread in `on_grade` when `g_uploads[]` marks pending (single `queue.writeTexture` ≤ 512 B×33 rows per slice, never per frame).

- [ ] **Step 1: Implement state machine + uploads; debug view 1 tints frame with key index stripes (u32 → R channel stripe pattern) so screenshots name the key**
- [ ] **Step 2: Linux smoke: boot → title (`title` key) → file select (`menus`) → gameplay field (`hyrule_field`) → enter town (crossfade to `castle_town`) → log lines per key change; paste to docs/keys-log.md; assert visually from 3 screenshots: title LUT ≠ field LUT visibly differs, no flash of field LUT on title**
- [ ] **Step 3: Capture GPU stats line: uploads per stage change = 1 (log count), 0 steady-state**
- [ ] **Step 4: Smoke with BOTH HDR mods enabled: mod loads, renders (double-graded accepted per spec), log clean, frame presents — no crash/leak across 2 stage changes**
- [ ] **Step 5: Commit `feat(hdr-lut): per-stage LUT selection with scene override and crossfade`**

### Task 8: Author 16 field/settlement LUTs

**Files:**
- Modify: `tools/gen_luts.py` — replace the 16 `author_<region>` stubs (currently neutral) with authored functions
- Create: `docs/looks/field/<key>.md` (key: art notes from refs, grade intent: e.g. `zora_domain: teal water light lift, sapphire mids, sparkle highlights`), `previews/field/<key>_before_after.png` (preview.py output over that key's ref)

**Interfaces:**
- Consumes: Task 3 generator/preview; Task 5 refs.
- Produces: 16 authored `.cube` in `res/luts/`, self-check green (≤1.0, 33³).

- [ ] **Step 1: For each of the 16 keys: study `refs/<key>/`, write art notes in docs/looks, implement `author_<key>`, generate + preview on 2+ refs, eyeball Review Focus #5 (dark gradients) via previews**
- [ ] **Step 2: `python3 tools/selfcheck.py` → PASS for all 36**
- [ ] **Step 3: Linux smoke: region tour quickpass (debug key stripes on), capture 4 screenshots (field/town/dusk)**
- [ ] **Step 4: Commit `feat(hdr-lut): authored field/settlement LUTs (16)`**

### Task 9: Author 12 dungeon LUTs

Same structure as Task 8 over `docs/looks/dungeon/<key>.md` + `previews/dungeon/`; dungeon intent: torch/fire highlight volume (goron, fire), water (lakebed), ice (snowpeak), dusk/magic (palace), sand (arbiters).
- [ ] Steps 1–4 as Task 8; commit `feat(hdr-lut): authored dungeon LUTs (12)`

### Task 10: Author 6 shared-scene LUTs (caves, fishing_pond, star_game, hidden_skill, title, menus)

Same structure; `title` = logo-shot mood from refs; `menus` = system-scene safe grade (mild, no color casts on UI colors); minigames per their art.
- [ ] Steps 1–4 as Task 8; commit `feat(hdr-lut): authored shared-scene LUTs (6)`

### Task 11: User review loop (gate for release)

**Files:** Create: `docs/review.md` (per-key: preview links, user verdict, iteration notes, sign-off date)

- [ ] **Step 1: Package preview pack (36 before/after PNGs + the 4 smoke screenshots); hand to user with the thin-ref list**
- [ ] **Step 2: Iterate requested changes per key (edit author fn → regen → new preview → record); re-run self-check each round**
- [ ] **Step 3: Record sign-off per key; all 36 signed ⇒ gate open; commit `docs(hdr-lut): look sign-off v1.0.0`**

### Task 12: v1.0.0 release + device spot-checks

- [ ] **Step 1: `project(hdr_lut_mod VERSION 1.0.0)` stays; tag `hdr-lut-v1.0.0`, push, CI release → GitHub release `hdr_lut_mod.dusk` (8-lib combined) with install notes (mods folder path; "enable one HDR grade"; iOS requires a bundled app build — note deferred bundling)**
- [ ] **Step 2: User-side checks (user runs; we report from their feedback): Windows PC + Android: drop `.dusk`, HDR10: keys per docs/keys-log; iPhone: note limitation; macOS arm64: scRGB**
- [ ] **Step 3: README.md in mod repo (install, per-area roster, `.cube` authoring guide for devs, HDR requirement)**
- [ ] **Step 4: Commit/push; announce; (GameBanana copy = hdr mod pattern)**

## Deferred (out of this plan)

App-bundling into the fork (iOS runs LUT mod only bundled; fork `mods/hdr-lut` + CMake entry + 8-app rebuild) — separate plan after v1.0.0, same shape as hdr bundling commit `b51e56b`. Upstream PR — after user decides on the AI-contribution rule.
