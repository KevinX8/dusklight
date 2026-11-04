# HDR+ LUT — per-stage LUT-based HDR grade (design)

Date: 2026-11-04 · Status: draft for approval · Author: brainstorming session with KevinX8

## Intent

The Dusklight devs (Discord) would prefer an HDR mod whose look lives in a **LUT**
rather than Special K's parametric math. The existing Special K mod
(`KevinX8/dusklight-hdr-mod`, bundled in the fork app) is self-contained and stays
untouched. This is a **new, separate mod**: the grade is 36 baked 3D LUTs, one per
game stage group, applied by a shader that does nothing else.

## Goals

- New mod `com.kevinx8.hdr-lut` ("HDR+ LUT"): the entire color grade is a 3D LUT
  sampled per stage; no Special K code in the mod.
- Look is **data**: standard `.cube` LUT files shipped in the mod; tunable in DaVinci
  Resolve / Photoshop / LutBox with no code and no rebuild.
- Per-stage granularity: field/settlement regions, each dungeon, minigames, title,
  system-menu scenes — not per-room.
- The grade is a **designed HDR look anchored to each scene's art**: study SDR
  references, then use HDR for luminance separation, highlight volume on authored
  highlights, palette-respecting saturation.
- Ships as `.dusk` bundles for all 8 platforms, same release shape as the hdr mod.
- **v1 = fully approved looks** (user's call): no release until each of the 36
  LUTs has been reviewed (before/after previews) and signed off by the user, then
  spot-checked on device.

## Non-goals

- Touching the Special K mod, the engine, or the fork app bundling (v1 is a
  standalone mod; app-bundling is a later decision, iOS-only motivation).
- An upstream PR (upstream's AI-contribution rule; re-open when the user decides).
- Per-room grading, dynamic scene analysis, bloom, side-buffer (gain/glow) restore.
- Auto-disabling other mods when both HDR mods are enabled (docs only: enable one).

## Anti-goals

- Any parametric grade math in the shader (that's what the devs rejected).
- LUT pop/flash at stage transitions (crossfade required).
- Shredding the game's 8-bit palette-quantized art: banded, clipped, oversaturated.
- Grading pre-rendered FMVs (they ship pre-graded → neutral passthrough).

## Constraints

- ModC SDK (`sdk/include/mods/svc/`): config.h, ui.h, hook.h, file.h; no stage API —
  stage/game-mode detection via hooks, same pattern as the official randomizer
  (`daAlink_c::checkStageName`). **Stage authority is base-game data only**: the
  engine's room-type/stage registry (`src/d/d_stage.cpp`, `d_com_static.cpp`) and
  the game's audio spot table (`src/Z2AudioLib/SpotName.h`, 79 unique stage codes).
  The randomizer's `stages.h` is rando-scoped — a naming convenience for known
  codes, never the roster source (it omits base-game stages, e.g. `D_MN54`, which
  SpotName.h contains).
- Engine HDR encode convention (from the hdr mod): the pass writes
  `sign(c)·|c|^(1/2.2) · 80/paper_white` so the engine encodes HDR10 (PQ) / scRGB.
- 33³ LUTs, `LUT_3D_SIZE 33`, DOMAIN 0 1, applied in **display-encoded (gamma)
  space**, not linear: 33 nodes then cover the 8-bit source codes evenly (a linear
  grid bands in shadows, where the no-banding goal bites), the source art is
  8-bit gamma-quantized, and `.cube` stays tool-compatible. Output normalized
  0..1 with **1.0 = display peak**; the shader owns the nits scale (`paper_white`
  cvar + engine peak), so LUT files never exceed 1.0 and Resolve/Photoshop/
  LutBox round-trip cleanly. `neutral` = identity; with the same EOTF in and out
  (`eotf` cvar, 2.2 default, mirroring the hdr mod) it round-trips exactly.
- Storage: WebGPU has **no 3D texture arrays** — keep **2 resident GPU slices**
  (current + previous), re-uploaded on stage change (~290 KB fp16 each, ~580 KB
  VRAM); all 36 parsed LUTs stage in RAM at startup (~10 MB).
- Engine pin: fork `hdr` SHA (needs HDR GfxService 1.5 **and** game features);
  mod declares both; first CI build verifies the combination on all 8 targets.
- No sudo, one build at a time, never launch the game on user devices (user judges);
  deploy engine only to Legion Go 2.

## Approaches considered

1. **Baked texture array** (generator → binary asset in res/; smallest mod code).
   Trade-off: LUT file is opaque; tuning needs the script + rebuild.
2. **Standard `.cube` files + tiny loader** — chosen (user picked). The generator
   emits per-stage `.cube`; the mod parses them at startup into the texture array.
   Cost: ~100-line parser. Benefit: this *is* the devs' "LUT-based" contract —
   anyone can tune a look in standard color tools.
3. Parametric per-region tables in the shader — excluded: not LUT-based.

## Architecture

### Mod (`KevinX8/dusklight-hdr-lut-mod`, skeleton copied from `hdr-mod`)

- `src/mod.cpp`: registers the post-composite pass; hooks for
  (a) current **stage name** → LUT slice index (cached on scene change),
  (b) **game mode** → title / file-select / system scenes,
  (c) **FMV playback** → force neutral slice.
- `src/settings.cpp`: cvars — `intensity` (0–100 %, default 100),
  `paper_white` (nits, same default as hdr mod), `debug_view` (shows active LUT key
  + slice index; cheap, supports user-side verification).
- `res/luts/<key>.cube` — 36 text LUTs; `res/hdr_lut.wgsl`.
- Loader: parse `.cube` (header + float grid, validate size/count) → 33³ slices;
  parse failure → neutral fallback + log line. Unit-testable on host.
- Shader (the whole grade): sample frame (encoded) → `LUT(input)` in the encoded
  domain → 2-slice crossfade (current/prev) → `mix(input, graded, intensity)` →
  EOTF decode × nits scale (`paper_white`/peak) → encode engine convention.
  Neutral identity round-trips exactly (FMV passthrough, intensity 0).
- Crossfade 0.5 s on stage change; FMV/game-mode switches are instant (no lerp
  from gameplay looks into system scenes — they read as scene cuts).

### Generator (`tools/gen_luts.py`, in the mod repo)

- Python; per-key author functions composed of simple documented ops
  (lift/gamma/gain, luma-vs-saturation curve, hue-targeted boosts, highlight
  roll-off that preserves hue above paper white, per-key nits scale).
- Samples the 33³ grid in the encoded domain; emits all `.cube` files; `default`
  and `neutral` are generated programmatically (neutral = pure identity — nits
  scaling lives in the shader, never baked into a LUT file).
- **Offline preview loop**: applies each LUT in numpy to captured frames and writes
  before/after comparison PNGs — the look-approval loop runs on screenshots, no
  game launch needed.

### Reference policy (v1: web-sourced)

- User has no captures of their own; **every reference is web-sourced**, filtered
  to **> 560p** (GC/Wii native is 480p — below the bar; the Wii U TPHD remaster
  at 720p+ and any modern captures/emulation shots qualify).
- Per LUT key: 1+ screenshots of the area (Dusklight captures preferred,
  **Twilight Princess / TPHD** equivalents as fallback), archived in the mod repo
  under `refs/<key>/` with source URLs.
- Look approval runs on **offline before/after PNG previews** of those shots
  (numpy applies the LUT in software) — no game launch in the loop.
- Known gap: Dusklight's own photo coverage is sparse for minor stages
  (`star_game`, fishing interiors, grottos) — all its stages are TP-derived, so
  the nearest **TPHD analog** covers the art; author from it and flag the key
  `thin-ref` in the review pack so sign-off is informed.
- Later refinement (optional): a real SDR capture tour from the HDR build on the
  Legion Go 2 replaces web references region by region.

## LUT roster (36)

Field/settlement (16): `hyrule_field`, `outside_town`, `castle_town`, `kakariko`,
`graveyard`, `faron`, `sacred_grove`, `ordon`, `zora_river`, `zora_domain`,
`lake_hylia`, `death_mountain`, `gerudo_desert`, `snowpeak`, `hidden_village`,
`the_dusk` (Bulblin camps / mirror world).

Dungeons (12): `forest_temple`, `goron_mines`, `lakebed`, `city_in_sky`,
`snowpeak_ruins`, `palace_dusk`, `temple_time`, `hyrule_castle`, `arbiters`,
`cave_ordeals`, `mirror_chamber`, `fire_temple`.

Shared (8): `caves` (grottos + long caves + stockcave + ice cave + faron cave),
`fishing_pond`, `star_game`, `hidden_skill`, `title`, `menus` (file select +
system scenes; **not** the pause/inventory/map overlays, which grade with the
region LUT underneath), `default` (any unmapped stage), `neutral` (FMV).

Mapping rules: boss arenas + real-time cutscene stages inherit the parent stage's
LUT (Zant → `palace_dusk`, Ganondorf → field/castle, Deku Toad → `zora_domain`, …).
Task 0 of the plan: dump the **base game's** full stage registry (engine room-type
tables + audio SpotName + DMap region data; the game's stage archives attest) and
complete the stage-code → key mapping data-driven from that dump; the randomizer's
enum names only the codes the dump proves exist. Anything unmapped lands on
`default` — completeness is guaranteed, not assumed, and **LUT keys come only
from stages the dump proves exist** (lesson from review: a `shadow_temple` key
was hallucinated from the name of `mods/shadow_mod`, a dynamic-shadow rendering
demo — OoT's dungeon, absent here). `D_MN54` (audio data only) is an open code
to decode in Task 0, no key presumed.

## Coexistence

Two HDR mods, one frame: enabling both double-grades. Settings panel shows the
active LUT key (debug_view) so state is visible; README states "enable one HDR
grade". No inter-mod communication (non-goal).

## Distribution & versions

- v1.0.0 standalone `.dusk` bundles (8 platform libs), CI copied from the hdr mod
  repo with `hdr-lut-*` tag pattern (no merge-combined regression).
- App-bundling (fork `mods/hdr-lut`) deferred until the look is approved; iOS
  requires bundling to run it at all (signing rule) — documented.
- GameBanana: same story as the hdr mod release.

## Testing

- Loader parser: host unit test on a fixture `.cube` (valid + malformed → neutral).
- Generator: self-check asserts (round-trip cube → sample → parse equals authored).
- Runtime: Linux local (bundled-engine deploy on Legion Go 2), then user devices:
  Windows PC, Android, iPhone/iPad, Mac — user judges, we never launch on devices.
- Region tour comparison pack (before/after PNGs) per review round.

## Calls made in this session (user to sanity-check)

- LUT applied in **encoded (gamma) space**; output normalized, 1.0 = display
  peak; shader owns nits (`paper_white` + engine peak). Settled at builder check.
- 2 resident GPU slices (no 3D texture arrays in WebGPU); 36 LUTs staged in RAM.
- `eotf` cvar mirrors the hdr mod (2.2 default); `neutral` = exact identity.
- Engine pin = fork `hdr` SHA, features webgpu + game, verified in first CI build.
- v1 scope = fully approved 36 looks, refs web-sourced (> 560p), review on
  offline before/after previews, device spot-check before release.
- 33³ LUTs; frame input assumed ≤ 1.0 (no side buffers).
- Crossfade 0.5 s; FMV/system switches instant.
- Settings = intensity + paper_white + eotf + debug_view only.
- `menus` covers full-screen system scenes only.
- Standalone `.dusk` first; app-bundling later (then iOS works).
- Mod id `com.kevinx8.hdr-lut`, panel name "HDR+ LUT".
- Shadow Temple key **removed after user correction** (OoT dungeon; my
  hallucination, evidenced by name-pattern from a shadow-rendering demo mod).
  Fire Temple kept (TP canon). Roster = 36 LUTs.
- Offline numpy preview drives the look-approval loop.
