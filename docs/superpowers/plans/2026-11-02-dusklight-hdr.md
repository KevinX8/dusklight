# Dusklight HDR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Real HDR output (HDR10/PQ or scRGB) from Dusklight on Linux KWin Wayland and gamescope. A patched Dawn and aurora provide the swapchain and float pipeline. A `.dusk` mod does the Special K style SDR→HDR upgrade.

**Architecture:** Dawn gets an env-var opt-in that picks the Vulkan HDR color space. When HDR is on, aurora renders internally to `RGBA16Float`, draws UI into an RGBA8 overlay, and does one final encode pass (gamma-2.2 fallback or mod-supplied linear, then PQ/scRGB). Dusklight exposes the mode as a restart-required setting, plus GfxService 1.5 calls for the mod. The mod (`com.kevinx8.hdr`) ports Special K's `basic_hdr_shader_ps.hlsl` main path to WGSL at `GFX_STAGE_FRAME_AFTER_HUD`.

**Tech Stack:** C++20, CMake/Ninja, Dawn (WebGPU, Vulkan backend), WGSL, gtest (aurora tests), Dusklight mod SDK, linuxdeploy AppImage.

**Spec:** `docs/superpowers/specs/2026-11-02-dusklight-hdr-design.md`

## Global Constraints

- Linux Vulkan only. Leave the D3D12, Metal and GL paths untouched.
- **HDR off must be byte-for-byte the current behavior.** Every new branch is gated on `hdrMode != Off`, and with HDR off `colorFormat == surfaceConfiguration.format`.
- Keep the patches small and rebase-friendly. Dawn changes live in one `.patch` file. Engine work is on branch `hdr` in both `dusklight/` and `dusklight/extern/aurora/`.
- Append new GfxService functions at the end of the struct. `GFX_SERVICE_MINOR` goes 4 → 5.
- HDR mode is fixed per run. Changing it shows "Changes require a restart." If the surface lacks the (format, color space) pair: log it, toast it, fall back to Off.
- Engine defaults: paper white 200 nits, peak 1000 nits.
- Mod defaults (Special K v1): Perceptual Boost on, params `1.0, 0.1, 1.273, 0.5`, Color Boost 0.333, saturation 1.0, gamut expansion 0.01, content EOTF 2.2, paper white 200, peak 1000. Unclip B/C default off.
- Never search outside `/media/ESSD/Dusklight` on the dev machine.
- Test machine: `ssh -o BatchMode=yes kevinx8@192.168.1.176`. For Wayland, export `XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1`. Mods go in `~/.local/share/TwilitRealm/Dusklight/mods`.

## Decisions made while planning (my calls; the user may override)

- **Dawn opt-in:** env var `DAWN_VK_SWAPCHAIN_COLORSPACE=hdr10|scrgb`, read by the Vulkan backend. Aurora sets it with `setenv` before creating the instance. Chosen over `wgpu::SurfaceColorManagement` because that struct only models `srgb`/`display-p3` plus a tone-mapping mode, not PQ, so mapping it onto HDR10 would be a bigger and less honest patch.
- **Mod linear contract:** when the mod marks the frame as linear, scene values are **scRGB (1.0 = 80 nits)**, exactly what Special K produces before its output encode. The spec said "1.0 = paper white". This change lets the Special K math port 1:1 (its brightness step is `nits/80`). Paper white from the mod is then used only for the UI overlay.
- **Unclip C limit N = 4:** clamped TEV stages use `[0,4]`, the same bound unclamped stages already use. **Unclip B:** lighting uses `max(lighting, 0)`.
- **Peak handling:** the encode clamps each channel to `peak/80` (scRGB units). The compositor does any further tone mapping.
- **Unclip timing:** shader config is built during scene draws, before `FRAME_AFTER_HUD`. So unclip flags set during frame N apply to frame N+1. `sceneLinear` and nits apply to the same frame's encode.

## Review Focus

1. **The surface lacks the HDR format, for example on an SDR monitor or with HDR disabled in KDE.** Expected: the game starts in SDR, logs the reason, and shows a toast once. No crash and no black screen. *(Task 2 test plus Task 6 check.)*
2. **The mod is disabled or reloaded mid-game, or a frame skips `FRAME_AFTER_HUD` (loading or logo screens).** Expected: the very next frame uses the gamma-2.2 fallback at paper white, unclip reverts one frame later, and nothing stays stuck linear. *(Task 3 test `HdrFrame.ResetsEachFrame`, Task 7 check.)*
3. **Window resize or fullscreen toggle with HDR on.** Expected: the UI overlay and float framebuffer are recreated at the new size, with no validation error. *(Task 3 step, Task 6 check.)*
4. **Bad values from a mod into `set_hdr_frame`** (NaN, 0, negative, above 10000 nits, wrong `struct_size`). Expected: `MOD_INVALID_ARGUMENT` and the frame is left unchanged. *(Task 5 test.)*
5. **NaN or Inf in the float framebuffer from unclipped shading.** Expected: the encode sanitizes it to 0 rather than showing black or white blocks. *(Task 3 encode `select` plus test of the C++ mirror.)*

---

### Task 1: Patched Dawn package

**Files:**
- Create: `dusklight/extern/aurora/cmake/patches/dawn-hdr-colorspace.patch`
- Create: `dusklight/tools/hdr/build-dawn.sh`

**Interfaces:**
- Produces: `/media/ESSD/Dusklight/build-dawn/dawn-linux-x86_64.tar.gz`. It's an install tree with the same layout as the `encounter/dawn` release `v20260807.225922` (`dawn-*/lib/cmake/Dawn/DawnConfig.cmake`, static monolithic `webgpu_dawn`). It's consumed via `-DAURORA_DAWN_PROVIDER=package -DAURORA_DAWN_PACKAGE_URL=file:///media/ESSD/Dusklight/build-dawn/dawn-linux-x86_64.tar.gz`.
- Produces the env var contract: `DAWN_VK_SWAPCHAIN_COLORSPACE` unset gives the current behavior. `hdr10` maps `RGB10A2Unorm` to `VK_COLOR_SPACE_HDR10_ST2084_EXT`. `scrgb` maps `RGBA16Float` to `VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT`. Any other format keeps `SRGB_NONLINEAR`.

- [ ] **Step 1:** Create branch `hdr` in `dusklight/` and in `dusklight/extern/aurora/` (`git switch -c hdr`). Then run `git submodule update --init --recursive` in `dusklight/`.
- [ ] **Step 2:** Clone `https://github.com/encounter/dawn` into `/media/ESSD/Dusklight/build-dawn/src` at `AURORA_DAWN_REF` `1155e0ed531126f33a1279afa029349651ca1c93`. Read that repo's release workflow (`.github/workflows/*`) for the Linux CMake flags used to produce `dawn-linux-x86_64.tar.gz`. Write `build-dawn.sh` to apply the patch and then configure, build, install and tar with exactly those flags. It must be idempotent and must not patch twice.
- [ ] **Step 3: Write the patch** against `src/dawn/native/vulkan/`:
  - Add `VK_EXT_swapchain_colorspace` to the known instance extensions so it is enabled when present.
  - Surface capabilities: when the env var is set, report `RGB10A2Unorm` (hdr10) or `RGBA16Float` (scrgb) only if `vkGetPhysicalDeviceSurfaceFormatsKHR` lists that format with the matching color space.
  - `SwapChainVk.cpp`: replace the hardcoded `config.colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR` with the mapping above. Also fix any format/colorspace support check that assumes SRGB_NONLINEAR.
  - Log the chosen color space once with `dawn::InfoLog()`.
  - Save the result with `git diff > dusklight/extern/aurora/cmake/patches/dawn-hdr-colorspace.patch`.
- [ ] **Step 4: Verify:** run `tools/hdr/build-dawn.sh`. Expected: the tarball exists, and `tar tzf … | grep DawnConfig.cmake` prints one path.
- [ ] **Step 5: Verify the baseline build with it:** `cmake --preset x-linux-ci-gcc -DAURORA_DAWN_PROVIDER=package -DAURORA_DAWN_PACKAGE_URL=file:///…/dawn-linux-x86_64.tar.gz`, then `cmake --build --preset x-linux-ci-gcc`. Expected: the build succeeds with no source changes yet.
- [ ] **Step 6: Commit** the patch (aurora) and the script (dusklight): `feat(hdr): Dawn Vulkan HDR color space patch and build script`.

### Task 2: Aurora HDR mode, format split, fallback

**Files:**
- Modify: `extern/aurora/include/aurora/aurora.h` (enum, config fields, C API)
- Modify: `extern/aurora/lib/webgpu/gpu.cpp` (`best_surface_format` ~207, surface config ~1062, `resize_swapchain_internal` ~1125, users at 269/519/579), `gpu.hpp` (add `colorFormat` to the graphics config struct)
- Modify: `lib/gfx/frame.cpp:278`, `lib/gfx/recording.cpp:168-169,377`, `lib/gfx/tex_copy_conv.cpp:520`, `lib/gfx/texture.cpp:196`, `lib/imgui.cpp:103`, `lib/rmlui.cpp:365`
- Create: `extern/aurora/lib/webgpu/hdr.hpp` (pure helpers, no GPU)
- Test: `extern/aurora/tests/hdr_test.cpp`, plus a target registered in `tests/CMakeLists.txt` following the `io_tests` pattern

**Interfaces:**
- Produces (in `aurora.h`):
  ```c
  typedef enum { AURORA_HDR_OFF = 0, AURORA_HDR_HDR10 = 1, AURORA_HDR_SCRGB = 2 } AuroraHdrMode;
  // appended to AuroraConfig:
  AuroraHdrMode hdrMode; float hdrPaperWhiteNits; float hdrPeakNits;   // 0 nits => 200 / 1000
  AuroraHdrMode aurora_get_hdr_mode(void);   // active mode after fallback
  ```
- Produces (in `hdr.hpp`, namespace `aurora::webgpu::hdr`):
  `wgpu::TextureFormat required_format(AuroraHdrMode)` returns `RGB10A2Unorm` / `RGBA16Float` / `Undefined`.
  `AuroraHdrMode resolve_mode(AuroraHdrMode requested, std::span<const wgpu::TextureFormat> offered)` returns `requested` if `required_format` is offered, else `AURORA_HDR_OFF`.
  `const char* colorspace_env(AuroraHdrMode)` returns `"hdr10"` / `"scrgb"` / `nullptr`.
- Produces in the graphics config: `colorFormat` (internal). `aurora::webgpu::ui_format()` returns `RGBA8Unorm` when HDR is active, else the surface format.

- [ ] **Step 1: Write failing tests** in `hdr_test.cpp`:
  ```cpp
  TEST(HdrMode, KeepsWhenOffered) { std::array f{wgpu::TextureFormat::BGRA8Unorm, wgpu::TextureFormat::RGB10A2Unorm};
    EXPECT_EQ(resolve_mode(AURORA_HDR_HDR10, f), AURORA_HDR_HDR10); }
  TEST(HdrMode, FallsBackWhenMissing) { std::array f{wgpu::TextureFormat::BGRA8Unorm};
    EXPECT_EQ(resolve_mode(AURORA_HDR_SCRGB, f), AURORA_HDR_OFF); }
  TEST(HdrMode, OffStaysOff) { std::array f{wgpu::TextureFormat::RGBA16Float};
    EXPECT_EQ(resolve_mode(AURORA_HDR_OFF, f), AURORA_HDR_OFF); }
  TEST(HdrMode, EnvNames) { EXPECT_STREQ(colorspace_env(AURORA_HDR_HDR10), "hdr10");
    EXPECT_STREQ(colorspace_env(AURORA_HDR_SCRGB), "scrgb"); EXPECT_EQ(colorspace_env(AURORA_HDR_OFF), nullptr); }
  ```
- [ ] **Step 2:** Build and run with `ctest --test-dir build/<preset dir> -R HdrMode`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement `hdr.hpp`.** Wire it in: `setenv(colorspace_env(...), …)` before Dawn instance creation, only when the mode is not Off. After `GetCapabilities`, call `resolve_mode`. If HDR is active, the surface format is `required_format` and `colorFormat = RGBA16Float`. Otherwise run the existing `best_surface_format` path untouched and set `colorFormat = surface format`. On fallback, `Log.warn` the requested mode and the offered formats.
- [ ] **Step 4: Switch internal users to `colorFormat`.** The rule is: anything rendering into the EFB/framebuffer, snapshots, offscreen passes, render textures or the EFB-copy blit uses `colorFormat`. imgui and rmlui targets use `ui_format()`. Only swapchain-target pipelines keep the surface format. This makes RGBA8 EFB copies float (unclip A). Leave the I8/RGB565/etc. conversions on `RGBA8Unorm`.
- [ ] **Step 5:** Run the tests. Expected: PASS. Also run the full aurora test suite, which must still pass.
- [ ] **Step 6: Commit** (aurora): `feat(hdr): HDR mode, internal float color format, surface fallback`.

### Task 3: Present encode, UI overlay, per-frame HDR state

**Files:**
- Modify: `extern/aurora/lib/webgpu/hdr.hpp` (encode math mirror, frame state)
- Modify: `extern/aurora/lib/webgpu/gpu.cpp` (encode pipeline plus WGSL next to the copy shader ~455-480; `g_uiOverlay` texture created in `resize_swapchain_internal`; the premultiplied copy pipeline built for `ui_format()` when HDR is active)
- Modify: `extern/aurora/lib/aurora.cpp` (`begin_frame` ~236 reset; `end_frame` ~318-365 HDR pass ordering)
- Modify: `extern/aurora/include/aurora/aurora.h`
- Test: `extern/aurora/tests/hdr_test.cpp`

**Interfaces:**
- Produces:
  ```c
  typedef struct { bool sceneLinear; bool unclipLighting; bool unclipTev; float paperWhiteNits; float peakNits; } AuroraHdrFrame;
  void aurora_set_hdr_frame(const AuroraHdrFrame* frame); // current frame only; ignored when HDR is off
  ```
- In `hdr.hpp`: `float pq_encode(float nits)` and `float pq_decode(float pq)` (ST 2084 with m1=0.1593017578125, m2=78.84375, c1=0.8359375, c2=18.8515625, c3=18.6875; nits/10000 in). `float fallback_nits(float gammaValue, float paperWhiteNits)` computes `sign·|v|^2.2 · paperWhite`. `float sanitize(float)` maps NaN/Inf to 0. `struct FrameState { AuroraHdrFrame pending, unclip; }` with `void begin_frame()`: `unclip = pending` (for the unclip flags), then `pending = {false, false, false, cfgPaperWhite, cfgPeak}`.
- Produces for Task 4: `const AuroraHdrFrame& aurora::webgpu::hdr::active_unclip()`.

- [ ] **Step 1: Write failing tests:**
  ```cpp
  TEST(HdrPq, Endpoints) { EXPECT_NEAR(pq_encode(0.f), 0.f, 1e-6); EXPECT_NEAR(pq_encode(10000.f), 1.f, 1e-5);
    EXPECT_NEAR(pq_encode(100.f), 0.508078f, 1e-4); }
  TEST(HdrPq, RoundTrip) { for (float n : {0.1f, 1.f, 80.f, 200.f, 1000.f, 4000.f, 10000.f})
    EXPECT_NEAR(pq_decode(pq_encode(n)), n, n * 1e-4f); }
  TEST(HdrFallback, WhiteIsPaperWhite) { EXPECT_FLOAT_EQ(fallback_nits(1.f, 200.f), 200.f);
    EXPECT_NEAR(fallback_nits(0.5f, 200.f), 200.f * 0.217638f, 1e-2); EXPECT_LT(fallback_nits(-0.5f, 200.f), 0.f); }
  TEST(HdrSanitize, NanInf) { EXPECT_EQ(sanitize(NAN), 0.f); EXPECT_EQ(sanitize(INFINITY), 0.f); EXPECT_EQ(sanitize(2.f), 2.f); }
  TEST(HdrFrame, ResetsEachFrame) { FrameState s; s.pending.sceneLinear = true; s.pending.unclipTev = true;
    s.begin_frame(); EXPECT_FALSE(s.pending.sceneLinear); EXPECT_TRUE(s.unclip.unclipTev);
    s.begin_frame(); EXPECT_FALSE(s.unclip.unclipTev); }
  ```
- [ ] **Step 2:** Run with `ctest -R 'Hdr'`. Expected: FAIL.
- [ ] **Step 3: Implement the helpers.** Generate the WGSL PQ constants from the same C++ constants with `fmt::format`, so shader and test can't drift.
- [ ] **Step 4: Implement the encode pipeline** `fs_hdr_encode`. It targets the surface format and binds the scene texture (`present_source()`), `g_uiOverlay` and a uniform `{u32 mode, u32 sceneLinear, f32 paperWhite, f32 peak}`. The algorithm, all in scRGB units (1.0 = 80 nits):
  ```
  c = sanitize(scene.rgb)
  lin = sceneLinear ? c : sign(c)*pow(abs(c), 2.2) * paperWhite/80
  ui = overlay (premultiplied); uiLin = ui.a > 0 ? pow(ui.rgb/ui.a, 2.2)*ui.a*paperWhite/80 : 0
  o = min(lin*(1-ui.a) + uiLin, peak/80)
  HDR10: out = pq((max(Rec709→2020(o), 0))*80)        // matrix rows: .627404 .329283 .043313 / .069097 .919540 .011362 / .016391 .088013 .895595
  scRGB: out = o
  ```
- [ ] **Step 5: HDR pass ordering in `end_frame`, only when HDR is active.** Pass 1 clears `g_uiOverlay` to 0 and draws the rml overlay with the premultiplied pipeline. Pass 2 draws imgui into `g_uiOverlay` (LoadOp Load). Pass 3 runs the encode into the swapchain view. The HDR-off branch is the existing code, unchanged. Call `FrameState::begin_frame()` from `aurora::begin_frame`. `aurora_set_hdr_frame` validates nothing (Dusklight validates) and copies into `pending`.
- [ ] **Step 6:** Run the tests. Expected: PASS. Run a build plus a local smoke test (`build/install/dusklight` with HDR Off on the dev machine): the game renders as before.
- [ ] **Step 7: Commit** (aurora): `feat(hdr): final PQ/scRGB encode with SDR UI overlay`.

### Task 4: Unclip B/C in GX shader generation

**Files:**
- Modify: `extern/aurora/lib/gx/gx.hpp:492-509` (`ShaderConfig`): change `pad1 : 5` to `unclipLighting : 1, unclipTev : 1, pad1 : 3`
- Modify: the place that fills `ShaderConfig` from GX state (grep `fogRangeEnabled =` in `lib/gx/`). Set the bits from `hdr::active_unclip()`, only when HDR is active.
- Modify: `extern/aurora/lib/gx/shader.cpp:406-417` (TEV), `:864` (lighting)
- Test: `extern/aurora/tests/hdr_test.cpp`

**Interfaces:** consumes `hdr::active_unclip()` (Task 3). `tev_color_op` and `tev_alpha_op` gain a `bool unclip` parameter.

- [ ] **Step 1: Write failing tests** that call `build_shader_source(config, …)` on a default `ShaderConfig` with one clamped TEV stage. With `unclipTev = 0`, the source contains `vec3f(1.0))`. With `unclipTev = 1`, it contains `clamp(…, vec3f(0.0), vec3f(4.0))` and not the `[0,1]` clamp. With `unclipLighting = 1`, it contains `max(lighting, vec4f(0.0))` and not `clamp(lighting`. A default config's source must be identical to the pre-change output; compare against a string captured before editing.
- [ ] **Step 2:** Run with `ctest -R HdrShader`. Expected: FAIL.
- [ ] **Step 3:** Implement. The bits are part of `ShaderConfig`, so the memcmp and hash cache key picks them up automatically.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5: Commit** (aurora): `feat(hdr): optional lighting/TEV unclip in shader gen`.

### Task 5: Dusklight setting, toast, GfxService 1.5

**Files:**
- Modify: `src/dusk/settings.h` (~178), `src/dusk/settings.cpp` (~15, ~322): `video.hdrMode` `ConfigVar<int>` default 0, `video.hdrPaperWhiteNits` default 200, `video.hdrPeakNits` default 1000
- Modify: `src/m_Do/m_Do_main.cpp:681-713`: fill `config.hdrMode` and the nits values. After init, if `aurora_get_hdr_mode() != requested`, call `dusk::ui::push_toast({.title = "HDR unavailable", .content = "Display does not offer the HDR format; running in SDR."})`
- Modify: `src/dusk/ui/settings.cpp` (~699): a select "HDR Output" with Off / HDR10 (PQ) / scRGB, using the Graphics Backend restart-pending pattern (`settings.cpp:234-237,619-643`; record the initial value in `prelaunch_state()`) and `<br/>Changes require a restart.`
- Modify: `sdk/include/mods/svc/gfx.h` (minor 4 → 5), `src/dusk/mods/svc/gfx.cpp` (~1434), `docs/modding.md` (GfxService section, one paragraph on 1.5)
- Test: a gtest for `validate_hdr_frame` in `extern/aurora/tests/hdr_test.cpp`, since Dusklight has no test target. The pure validator lives in `hdr.hpp`.

**Interfaces:**
- Produces in `gfx.h`:
  ```c
  typedef enum GfxHdrMode { GFX_HDR_OFF = 0, GFX_HDR_HDR10 = 1, GFX_HDR_SCRGB = 2 } GfxHdrMode;
  typedef struct GfxHdrFrameDesc { uint32_t struct_size; bool scene_linear; bool unclip_lighting; bool unclip_tev;
      float paper_white_nits; float peak_nits; } GfxHdrFrameDesc;
  #define GFX_HDR_FRAME_DESC_INIT {sizeof(GfxHdrFrameDesc), false, false, false, 200.0f, 1000.0f}
  /* Minor version 5 */
  ModResult (*get_hdr_mode)(ModContext* ctx, GfxHdrMode* out_mode);
  ModResult (*set_hdr_frame)(ModContext* ctx, const GfxHdrFrameDesc* desc); // scene_linear => scRGB (1.0 = 80 nits); current frame only
  ```
  `set_hdr_frame` returns `MOD_UNAVAILABLE` when HDR is off. It returns `MOD_INVALID_ARGUMENT` when `validate_hdr_frame` fails. Otherwise it calls `aurora_set_hdr_frame`.
- In `hdr.hpp`: `bool validate_hdr_frame(uint32_t structSize, size_t expected, float paperWhite, float peak)` checks size `>= expected`, both values finite and in `[1, 10000]`, and `peak >= paperWhite`.

- [ ] **Step 1: Write failing tests** `HdrValidate.*`: valid `(sizeof, sizeof, 200, 1000)` is true. Each of these is false: NaN paper white, 0, -5, 10001, peak < paper white, and `structSize = 4`.
- [ ] **Step 2:** Run with `ctest -R HdrValidate`. Expected: FAIL.
- [ ] **Step 3:** Implement the validator, the service functions, the settings, the menu and the toast. Then update `modding.md`.
- [ ] **Step 4:** Run the tests and do a full build. Expected: PASS. The settings menu shows "HDR Output", and changing it marks restart pending.
- [ ] **Step 5: Commit** (dusklight, including the aurora submodule bump): `feat(hdr): HDR output setting and GfxService 1.5`.

### Task 6: AppImage and engine-only check on the test machine

**Files:**
- Create: `dusklight/tools/hdr/deploy.sh`. It runs `APP_VERSION=<git describe>-hdr ci/build-appimage.sh`, then scps `build/install/Dusklight-*.AppImage` to `kevinx8@192.168.1.176:~/Applications/` and any `*.dusk` arguments to the mods dir.

- [ ] **Step 1:** Run the CI preset build with the package URL from Task 1, then `tools/hdr/deploy.sh`. Expected: the AppImage is on the test machine.
- [ ] **Step 2: HDR Off.** Launch on KWin with `video.hdrMode` 0 and take a screenshot (Spectacle) at the title screen and in one field scene. Expected: visually identical to the upstream AppImage on the same scene, and the log shows the SRGB_NONLINEAR color space.
- [ ] **Step 3: HDR10, then scRGB, no mod.** Expected: the Dawn log shows `HDR10_ST2084` or `EXTENDED_SRGB_LINEAR`. The game looks like SDR at about 200 nits on DP-1, with the UI and console readable. Resize or toggle fullscreen with no validation errors in the log.
- [ ] **Step 4: Fallback.** Disable HDR on the output (`kscreen-doctor output.DP-1.hdr.disable`), launch with HDR10, then re-enable HDR. Expected: SDR output, a warning in the log, and the "HDR unavailable" toast.
- [ ] **Step 5: Gamescope.** Run `gamescope --hdr-enabled -f -- ./Dusklight-*.AppImage` with HDR10. Expected: gamescope reports HDR content (`--hdr-debug-force-output` not needed), and the image is correct.
- [ ] **Step 6:** Commit `deploy.sh`. Report the results to the user before starting the mod.

### Task 7: The mod `com.kevinx8.hdr`

**Files:**
- Create: `/media/ESSD/Dusklight/hdr-mod/` as a copy of `mod-template/` (`git init`). Project `hdr_mod`, `mod.json.in` id `com.kevinx8.hdr`, `add_mod(hdr_mod FEATURES webgpu fmt SOURCES src/mod.cpp src/settings.cpp MOD_JSON … RES_DIR res)`, configured with `-DDUSKLIGHT_DIR=/media/ESSD/Dusklight/dusklight`
- Create: `res/hdr.wgsl` (the Special K port), `src/mod.cpp` (gfx hook and pipeline), `src/settings.cpp` / `settings.hpp` (config vars and panel)

**Interfaces:**
- Consumes GfxService 1.5 (`IMPORT_SERVICE(GfxService, svc_gfx)`, which requires minor 5), plus `ConfigService`, `UiService`, `ResourceService` and `LogService`.
- WGSL uniform `Params { eotf: f32 (2.2, or -2.2 for the sRGB curve), pb_enable: u32, pb: vec4f (p0..p3), color_boost: f32, saturation: f32, gamut: f32, luma_scale: f32 (paper_white/80) }`.
- Config vars (ints; floats are stored ×1000 because floats aren't bindable): `paperWhite` 200, `peak` 1000, `eotf` 0 (2.2) / 1 (sRGB) dropdown, `pbEnable` true, `pb0` 1000, `pb1` 100, `pb2` 1273, `pb3` 500, `colorBoost` 333, `saturation` 1000, `gamut` 10, `unclipLighting` false, `unclipTev` false.

- [ ] **Step 1: Port the math to `res/hdr.wgsl`** from `SpecialK/resource/shaders/HDR/basic_hdr_shader_ps.hlsl` (main path only) and `common_defs.hlsl`: `Rec709_to_XYZ` (332), `XYZ_to_Rec709` (345), `Saturation` (490), `LinearToPQ`/`PQToLinear` (~760-870), `expandGamut` (2046, with its AP1 matrices), `Clamp_scRGB` (123) and the sanitize step. Order: `max(1, max|rgb|)` divide → EOTF → multiply back → PB/Color Boost → Saturation → `*luma_scale` → expandGamut → Clamp_scRGB → zero if `dot(orig,1) <= FP16_MIN`. Output is scRGB.
- [ ] **Step 2: Implement `mod.cpp`,** following `dusklight/mods/ao_mod/src/mod.cpp` (resolve 607-612, pipeline from layout 216-260, rebuild on `layout.key`). In `mod_initialize`: `get_hdr_mode`. If it's Off, `mods::log::info("HDR output is off in Graphics settings; mod idle")` and register nothing. Otherwise register a `GFX_STAGE_FRAME_AFTER_HUD` hook: `resolve_pass` (color only), `push_uniform`, a fullscreen `push_draw` (no blend), then `set_hdr_frame({scene_linear = true, unclip flags, paper, peak})`. Release GPU objects in `mod_shutdown`.
- [ ] **Step 3: Implement `settings.cpp`.** Register the vars and a mods panel with NUMBER/TOGGLE/DROPDOWN controls bound to them. The panel layout is the builder's choice.
- [ ] **Step 4: Build** with `cmake -S hdr-mod -B hdr-mod/build -DDUSKLIGHT_DIR=… && cmake --build hdr-mod/build`. Expected: `build/mods/hdr_mod.dusk`. Check that WGSL compile errors surface in the game log, not as a crash: `wgpuDeviceCreateShaderModule` errors fail the mod via `svc_host->fail`.
- [ ] **Step 5: Deploy** with `tools/hdr/deploy.sh hdr-mod/build/mods/hdr_mod.dusk`.
- [ ] **Step 6: Commit** (hdr-mod repo): `feat: Special K style SDR→HDR mod`.

### Task 8: End-to-end check on the test machine

- [ ] **Step 1: HDR10 with the mod on KWin.** Fire, sun and lens flare go visibly above paper white. The HUD sits at paper white. Changing paper white or saturation in the Mods panel updates live.
- [ ] **Step 2:** Disable the mod in the Mods panel mid-game. Expected: the next frame looks like the Task 6 no-mod output, with nothing stuck. Re-enable it and it recovers.
- [ ] **Step 3:** Toggle unclip B and C. Expected: shading changes after one frame, pipelines rebuild (with a brief hitch), and nothing turns NaN black or white.
- [ ] **Step 4:** Repeat Step 1 in scRGB mode and under `gamescope --hdr-enabled`.
- [ ] **Step 5:** Report to the user with screenshots or descriptions and any blown-out effects found under unclip.
