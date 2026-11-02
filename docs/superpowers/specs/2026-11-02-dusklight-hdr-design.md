# Dusklight HDR — Design

## Intent

Play Dusklight (Twilight Princess PC port) in real HDR on Linux: KDE Plasma Wayland and gamescope. The goal is to **reimagine the game in HDR, not stay faithful to the SDR look**. Gamescope's inverse tone mapping was tried and "doesn't look great". Upstream turned down native HDR (issue #1230: "pipedream, better as a mod"), so this needs a small engine fork plus a mod.

Special K's SDR→HDR upgrade is the **reference for the image math only**. Special K only runs on Windows, so none of its hooking or swapchain code applies.

## Goals

- Real HDR output to the compositor (an HDR swapchain), not an SDR image that the compositor stretches.
- The image math (Special K style) lives in a `.dusk` mod, can be adjusted live, and has settings in the Mods panel.
- Light that the SDR pipeline clips (additive glows, fire, sun, lens flare, bloom) should be able to go above SDR white.
- Optional "unclip" levels that let lighting and shading go overbright.

## Non-goals

- Windows, macOS or Android HDR (Dawn's D3D12/Metal paths are not touched).
- Upstreaming. This is a personal fork. Keep the patches small so they rebase easily.
- Separate brightness for the HUD. Like Special K, the HUD goes through the same processing. It can be added later, because GfxService has a before-HUD stage.
- HDR metadata (`VK_EXT_hdr_metadata`) in the first version. KWin and gamescope tone-map using their own output settings.

## Anti-goals

- Washed-out or crushed SDR output when HDR is **off**. The HDR-off path has to be byte-for-byte the current behavior.
- Making it harder for the user's own engine branch to follow upstream Dusklight.

## Constraints and findings

- **Test machine:** `ssh kevinx8@192.168.1.176`. It runs CachyOS (kernel 7.3), KWin 6.8.2 Wayland (`WAYLAND_DISPLAY=wayland-1`, `XDG_RUNTIME_DIR=/run/user/1000`), an NVIDIA RTX 4080 SUPER with driver 615.78.08, and has gamescope installed. HDR and wide color gamut are enabled on both outputs. DP-1: SDR brightness 350 nits, peak 970 nits (overridden). HDMI-A-1: SDR brightness 200 nits, peak 1200 nits.
- On that machine, the Vulkan Wayland surface offers `A2B10G10R10/A2R10G10B10_UNORM` with `HDR10_ST2084` (PQ) and `R16G16B16A16_SFLOAT` with `EXTENDED_SRGB_LINEAR` (scRGB). Both HDR paths are available, and the `VK_EXT_swapchain_colorspace` and `VK_EXT_hdr_metadata` extensions are present.
- The dev machine (this workspace) has an AMD Radeon Pro VII on Mesa 26.2 (Ubuntu). It is not the HDR test target.
- **Dawn** (`extern/aurora`, prebuilt from `encounter/dawn` `v20260807.225922`, see `cmake/AuroraDawnProvider.cmake` and `cmake/AuroraDependencyVersions.cmake`) hardcodes `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR` in `SwapChainVk.cpp`. It also rejects the WebGPU `SurfaceColorManagement` chained struct as unsupported. Dawn must be patched and built from source.
- **Aurora** uses `g_graphicsConfig.surfaceConfiguration.format` as *the* color format everywhere: the EFB/framebuffer (`create_render_texture`), `gfx::color_format()` (`lib/gfx/frame.cpp:278`), recording passes (`lib/gfx/recording.cpp:168,377`), the RGBA8 EFB-copy blit (`lib/gfx/tex_copy_conv.cpp:520`), render textures (`lib/gfx/texture.cpp:196`), the XFB copy and resample pipelines (`lib/webgpu/gpu.cpp:519,579`), and the imgui and RmlUi render targets. `best_surface_format()` (`gpu.cpp:207`) only picks RGBA8 or BGRA8. Other EFB-copy conversions (I8, RGB565, …) write `RGBA8Unorm`.
- **GX shader generation** (`lib/gx/shader.cpp`) clamps TEV output to [0,1] when the stage clamp bit is set and to [-4,4] otherwise (~406–416). It clamps lighting to [0,1] (~864) and fog (~1553). The game blends in gamma space.
- **Mod GfxService** (`src/dusk/mods/svc/gfx.cpp`) provides stage hooks (up to `GFX_STAGE_FRAME_AFTER_HUD`), `resolve_pass` snapshots, and `push_draw`. Its draw layout follows the scene attachment format (`GfxDrawContext.layout`), so a mod pipeline built from that layout automatically matches a float framebuffer.

## Approaches

1. **Engine patches for output plus a mod for the look (chosen).** Patch Dawn for an HDR swapchain. Patch aurora to separate the internal color format (`RGBA16Float` when HDR is on) from the surface format, with a final encode step. A mod does the Special K style math at the after-HUD stage. Trade-off: it needs a custom Dawn build. The look can be changed live without rebuilding the engine.
2. **Engine only.** The same patches, but the math lives in aurora and the settings in the graphics menu. Rejected because every tweak needs an engine rebuild.
3. **A Vulkan layer or gamescope ITM.** No engine changes, but it only sees the final 8-bit SDR image, so nothing is unclipped. It's a pure filter. Rejected: the user tried gamescope ITM and disliked it, and wants engine data, not an SDR filter.

The user chose 1: "yes in the mod is fine".

## Design

### 1. Dawn patch (Vulkan swapchain color space)

- Build Dawn from source, using the `encounter/dawn` fork at the pinned version, through aurora's `vendor` provider (or `package` pointing to our build).
- In `SwapChainVk.cpp`, choose `VkColorSpaceKHR` from the configured surface format, plus a way to opt in:
  - `RGB10A2Unorm` with HDR requested → `VK_COLOR_SPACE_HDR10_ST2084_EXT`
  - `RGBA16Float` with HDR requested → `VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT`
  - otherwise → unchanged `SRGB_NONLINEAR`.
- Enable the instance extension `VK_EXT_swapchain_colorspace` when available. Report the HDR formats in surface capabilities only when the matching (format, color space) pair exists in `vkGetPhysicalDeviceSurfaceFormatsKHR`.
- **Opt-in mechanism: builder's call.** Preferred is implementing the standard `wgpu::SurfaceColorManagement` chained struct (predefined color space plus transfer function), because it's the upstream WebGPU direction and Dawn already has the struct. A fork-only toggle or environment variable is acceptable if that turns out to be much bigger.
- Keep the patch as a `.patch` file applied by CMake, so a Dawn version bump is just a rebase.

### 2. Aurora / Dusklight patch

- **Config:** a new graphics setting, HDR output: Off / HDR10 (PQ) / scRGB. Default Off. HDR10 is the default when turned on, because KWin and gamescope both accept it. Changing it recreates the swapchain. A restart is acceptable if live recreation turns out hard.
- **Format split:** add `g_graphicsConfig.colorFormat` (internal), separate from `surfaceConfiguration.format`. When HDR is on, colorFormat = `RGBA16Float`. Every internal user listed under Constraints switches to colorFormat. Only the final present path (XFB copy and resample pipelines) and UI composited directly onto the swapchain (if any) keep using the surface format. When HDR is off, colorFormat == surface format, so behavior is unchanged.
- **Float EFB copies (unclip level A):** when HDR is on, RGBA8 EFB-copy textures used as render textures (bloom, heat haze, twilight and similar post effects) become `RGBA16Float`, so they keep values above 1. Intensity and other channel-reduced copies that the game reinterprets as GX texture data stay 8-bit.
- **Present encode:** the final copy to the swapchain encodes the linear result. PQ: convert Rec.709 → Rec.2020, scale by the nits value of 1.0, and apply the PQ curve. scRGB: write linear values with 1.0 = 80 nits. The encode reads its parameters from a small uniform that a new GfxService entry point can set.
- **Contract with the mod:** with HDR on and the mod **absent**, the encode treats the framebuffer as gamma-encoded SDR. It linearizes with gamma 2.2 and places 1.0 at a default paper white, so the game shows correctly with no extra highlights. With the mod **present**, the mod writes linear scene light (1.0 = paper white) and tells the engine through a GfxService call (new minor version) that the image is already linear. The engine then only applies the output encode.
- **Unclip toggles (levels B/C),** exposed as engine cvars that the mod sets through the new GfxService call:
  - **B:** remove the [0,1] lighting clamp in shader generation (~864).
  - **C:** relax the TEV stage clamp (~406–416) to allow overbright output (for example clamp to [0, N]).
  Both change the generated-shader cache key, so toggling them rebuilds pipelines. Expect some effects to break or blow out. That's why they are toggles, off by default.
- Add the new GfxService functions at the **end** of the struct with a minor version bump, as the mod API rules require.

### 3. The mod (`com.kevinx8.hdr`, native C++, built from mod-template, `FEATURES webgpu`)

- At `GFX_STAGE_FRAME_AFTER_HUD`: run `resolve_pass` on the frame, then do one full-screen `push_draw` with the WGSL port of Special K's `basic_hdr_shader_ps.hlsl` main path:
  1. Linearize with the content EOTF (2.2 default, an sRGB-curve option), using Special K's trick of dividing by `max(1, maxRGB)` before the curve and multiplying back after, so overbright float values stay linear.
  2. Perceptual Boost: PQ-space luminance boost with Color Boost blend. Defaults are Special K v1: `1.0, 0.1, 1.273, 0.5`, Color Boost 0.333.
  3. Saturation (Special K's `Saturation()`).
  4. Brightness scale (paper white).
  5. Gamut expansion (Special K's `expandGamut`, default 0.01 or higher since we're reimagining).
  6. Write linear output. The engine does the PQ or scRGB encode.
- Port the matching helpers from `SpecialK/resource/shaders/HDR/common_defs.hlsl` (PQ, Rec709↔XYZ, AP1 matrices, `expandGamut`, `Saturation`). Leave out visualizations, ACES, NaN debug and the splitter. Keep the NaN/Inf sanitize.
- **Settings** (ConfigService plus a UiService panel): enable, paper white nits, peak nits, content EOTF, Perceptual Boost on/off plus its 4 parameters, Color Boost, saturation, gamut expansion, unclip B, unclip C. Float vars aren't bindable, so use int sliders or callbacks.
- With HDR output off in the engine, the mod does nothing and logs a hint.

### 4. Decisions settled after the builder check (my calls; the user can override)

- **UI (imgui, RmlUi, Mods panel) under HDR:** the output encode runs last in the frame. UI drawn after `FRAME_AFTER_HUD` must not write gamma values straight into the PQ or scRGB swapchain. It goes into a separate SDR overlay target (RGBA8, premultiplied), which the encode composites on top of the scene. The overlay is linearized with gamma 2.2 and shown at paper white. The builder picks the exact mechanism.
- **"Already linear" flag:** it applies to one frame only and resets at the start of every frame. The mod sets it from its after-HUD callback. Frames that skip that stage, and a mod that is disabled or has crashed, fall back to the no-mod path automatically.
- **HDR on, no mod:** a minimal fallback only, running the same encode shader with a branch: linearize with gamma 2.2, then multiply by paper white. Defaults live in engine config: paper white 200 nits, peak 1000 nits. The mod overrides them through the uniform.
- **Mode selection:** the HDR mode is fixed per run. Changing it shows "restart required"; there is no live pipeline invalidation in v1. If the surface doesn't offer the requested (format, color space) pair, the engine logs it, shows a toast, and falls back to Off.
- **Dawn build:** build on the dev machine, which has network access. Match the layout the prebuilt archive provides so `AuroraDawnProvider.cmake` takes it through the `package` provider unchanged.
- **Distribution (user decision):** ship the patched engine as an AppImage, the way Dusklight is distributed. Build on the dev machine (Ubuntu, like upstream CI) with the CI preset `x-linux-ci-gcc` (`cmake --preset` / `cmake --build --preset`), then run the existing `ci/build-appimage.sh` (linuxdeploy). Set `APP_VERSION` to something like `<upstream>-hdr`. The patched Dawn is linked into it. `scp` the `Dusklight-*.AppImage` and the mod's `.dusk` (into `~/.local/share/TwilitRealm/Dusklight/mods`) to the test machine. The mod is built against this fork's SDK (`build/install/sdk/`), not upstream's.
- **Checking "HDR-off is unchanged":** code review shows that with HDR off, every new branch is skipped and colorFormat == surface format. Also compare a screenshot on the test machine against upstream. No readback harness.

## Testing

- **Unit-level:** a host-side C++ check that the PQ encode/decode round-trips and that 1.0 maps to the paper-white nits value. A screenshot or readback test is not required.
- **On the test machine:** run in KWin with HDR10, then with scRGB. Run under `gamescope --hdr-enabled`. Check that HDR-off looks identical to upstream.
- Verify the swapchain color space with `VK_LOADER_DEBUG` or Dawn logs.

## Left to the builder

- Exact Dawn opt-in API (see §1).
- The clamp limit N for unclip C.
- The UI layout of the mod panel.

## Open questions

None. The test machine has already run Dusklight (`config.json`, `dawn_cache.db` and a `USA` folder under `~/.local/share/TwilitRealm/Dusklight`). The AppImage should pick up the disc image path that's already configured there.
