# Dusklight HDR Cross-Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** HDR output (and the HDR+ Grade mod) on every Dusklight platform with an HDR-capable backend: Linux/Android/Windows via Vulkan, Windows via D3D12, macOS/iOS via Metal.

**Architecture:** Everything above the swapchain (8-bit game frame, HdrGain/HdrGlow side buffers, scene_texture, HDR encode, float UI) is backend-neutral WebGPU and stays as is. Only "tell the OS the swapchain is HDR" is per-backend: Dawn's standard `SurfaceColorManagement` struct (declared, currently rejected) gets implemented in our Dawn patch for Vulkan, D3D12 and Metal, replacing the `DAWN_VK_SWAPCHAIN_COLORSPACE` env-var hack. Aurora's vendored-Dawn provider applies the patch, so every platform's CI builds a patched Dawn.

**Tech Stack:** Dawn (encounter/dawn @ `1155e0ed531126f33a1279afa029349651ca1c93`), Vulkan `VK_EXT_swapchain_colorspace`, DXGI 1.4+ (`IDXGISwapChain3`, `IDXGIOutput6`), CAMetalLayer EDR, aurora (C++20), gtest.

**Spec:** This plan's Design section (agreed in conversation 2026-11-03), building on `docs/superpowers/plans/2026-11-02-dusklight-hdr.md`.

## Design

- Modes: `AURORA_HDR_SCRGB` = `SurfaceColorManagement{colorSpace = SRGBLinear, toneMappingMode = Extended}` + RGBA16Float (Vulkan EXTENDED_SRGB_LINEAR, DXGI `G10_NONE_P709`, Metal `kCGColorSpaceExtendedLinearSRGB` EDR). `AURORA_HDR_HDR10` = a fork-only enum value `PredefinedColorSpace::Rec2100PQ` (value 6, tag `dawn`) + RGB10A2Unorm (Vulkan HDR10_ST2084, DXGI `G2084_NONE_P2020`). Metal has no HDR10 path: HDR10 requests resolve to scRGB there.
- Support detection stays format-based: with color management on a surface, `GetSurfaceCapabilities` returns only the formats usable in that color space (empty when the display/OS can't do it), so aurora's `resolve_mode` falls back to SDR + the existing "HDR unavailable" toast.
- Apple EDR: 1.0 = the OS's SDR white, not 80 nits. The encode divides scRGB by `paperWhite/80` and clamps to the screen's current EDR headroom.
- Order: Vulkan (Go 2 regression) → Windows D3D12 → macOS/iOS → Android. tvOS out of scope.

## Global Constraints

- HDR off must stay byte-for-byte current behavior on every platform.
- Never use sudo; one build at a time; report on-screen results instead of deciding them.
- Every engine task ends with the Go 2 regression: `SSH_KEY=~/.ssh/legion_go2 tools/hdr/build-steamos.sh deck@192.168.1.90`, user confirms grade + waterfall + menus unchanged.
- Shader changes pass `hdr-mod/tools/check-wgsl.sh`; aurora suite (`ctest` in `build/x-linux-ci-gcc/extern/aurora`, rebuild `hdr_tests` explicitly) stays green.
- Windows/Android/iOS binaries come from GitHub Actions on the user's fork (prerequisite: user pushes `dusklight` + `hdr-mod` branches); iOS installs by sideloading.

## Review Focus

- OS HDR switched off (Windows "Use HDR" off, macOS/iOS display without EDR headroom, Android device without HDR10) → SDR + toast, never a black or crashing swapchain. Tests: Task 3 (D3D capabilities), Task 4 (Metal capabilities).
- Window moved to an SDR monitor mid-run → keeps presenting (mode is fixed per run); no device loss. Manual check in Task 3.
- iOS/macOS brightness change alters EDR headroom per frame → clamp follows it, no flashing. Test: Task 4 `HdrEdr.ClampsToHeadroom`.
- HDR10 requested on Metal → scRGB, not SDR. Test: Task 4 `HdrMode.Hdr10OnMetalUsesScrgb`.
- Older third-party mods on the new layout (extra attachments) keep working: unchanged from current code; spot-check vbao on Windows in Task 3.

---

### Task 1: Dawn `SurfaceColorManagement` + Vulkan on it (Linux regression)

**Files:**
- Modify (Dawn, then regenerate `extern/aurora/cmake/patches/dawn-hdr-colorspace.patch`): `src/dawn/dawn.json` (add `rec 2100 PQ` = 6 to `predefined color space`, tag `dawn`), `src/dawn/native/Surface.cpp`/`Surface.h` (accept and store the struct: `std::optional<SurfaceColorManagement> GetColorManagement() const`; reject combinations other than SRGBLinear+Extended and Rec2100PQ+Standard), `vulkan/BackendVk.cpp` (enable `VK_EXT_swapchain_colorspace` whenever available, no env var), `vulkan/PhysicalDeviceVk.cpp` (filter formats by `surface->GetColorManagement()`), `vulkan/SwapChainVk.cpp`, `vulkan/UtilsVulkan.cpp/.h` (map color management → `VkColorSpaceKHR`).
- Modify: `tools/hdr/build-dawn.sh` (unchanged flow; rebuild tarball).

**Interfaces:**
- Produces: `wgpu::SurfaceColorManagement{colorSpace, toneMappingMode}` accepted in `wgpu::SurfaceDescriptor` chain; `wgpu::PredefinedColorSpace::Rec2100PQ`; `GetCapabilities` formats filtered per color space on Vulkan.

- [x] **Step 1:** Remove every `DAWN_VK_SWAPCHAIN_COLORSPACE` read; drive the same Vulkan logic from `GetColorManagement()`.
- [x] **Step 2:** Rebuild Dawn (`tools/hdr/build-dawn.sh`), regenerate the patch with `git -C build-dawn/src diff > extern/aurora/cmake/patches/dawn-hdr-colorspace.patch`, confirm `git apply --check` on a clean checkout of the ref.
- [x] **Step 3:** Commit (aurora: patch).

### Task 2: Aurora requests HDR through the surface, not the environment

**Files:**
- Modify: `extern/aurora/lib/webgpu/hdr.hpp` (replace `colorspace_env` with `std::optional<wgpu::SurfaceColorManagement> color_management(AuroraHdrMode mode)`), `lib/dawn/BackendBinding.cpp` (`create_window_surface` chains it after the platform source struct), `lib/webgpu/gpu.cpp` (delete `set_colorspace_env`; replace the Vulkan-only gate with `hdr_backend_supported(wgpu::BackendType)` = Vulkan, D3D12, Metal).
- Test: `extern/aurora/tests/hdr_test.cpp`

**Interfaces:**
- Consumes: Task 1 struct/enum.
- Produces: `color_management`, `hdr_backend_supported` (both in `aurora::webgpu::hdr`).

- [x] **Step 1: Failing tests**

```cpp
TEST(HdrMode, ColorManagement) {
  EXPECT_FALSE(color_management(AURORA_HDR_OFF).has_value());
  const auto scrgb = color_management(AURORA_HDR_SCRGB);
  EXPECT_EQ(scrgb->colorSpace, wgpu::PredefinedColorSpace::SRGBLinear);
  EXPECT_EQ(scrgb->toneMappingMode, wgpu::ToneMappingMode::Extended);
  EXPECT_EQ(color_management(AURORA_HDR_HDR10)->colorSpace, wgpu::PredefinedColorSpace::Rec2100PQ);
}
TEST(HdrMode, Backends) {
  EXPECT_TRUE(hdr_backend_supported(wgpu::BackendType::D3D12));
  EXPECT_TRUE(hdr_backend_supported(wgpu::BackendType::Metal));
  EXPECT_FALSE(hdr_backend_supported(wgpu::BackendType::D3D11));
  EXPECT_FALSE(hdr_backend_supported(wgpu::BackendType::OpenGL));
}
```
(Delete `HdrMode.EnvNames`.)
- [ ] **Step 2:** Run `hdr_tests` → fail. **Step 3:** Implement. **Step 4:** Suite green (307/307).
- [ ] **Step 5:** Go 2 regression (Global Constraints) + log shows `EXTENDED_SRGB_LINEAR`. Committed (aurora 07fdb85, dusklight 4712077def); deploy running, user visual check pending.

### Task 3: Windows D3D12

**Files:**
- Modify (Dawn patch): `src/dawn/native/d3d/SwapChainD3D.cpp` (after `CreateSwapChainForHwnd` and after `ResizeBuffers`: `IDXGISwapChain3::CheckColorSpaceSupport` then `SetColorSpace1` with `DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709` / `_G2084_NONE_P2020`), `src/dawn/native/d3d/PhysicalDeviceD3D.cpp` (`GetSurfaceCapabilities`: with color management, return only the matching format, and nothing unless the window's monitor reports `IDXGIOutput6::GetDesc1().ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020`).
- Modify: `extern/aurora/cmake/AuroraDawnProvider.cmake` (vendor provider: `PATCH_COMMAND git apply --ignore-whitespace <each cmake/patches/dawn-*.patch>`), and `auto` resolves to vendor whenever HDR patches are present (aurora 7dc9607: the prebuilt packages and system Dawn lack the patches and silently degrade HDR — CI's auto picked the stock package, every job failed on `Rec2100PQ`).

**Interfaces:**
- Consumes: Task 1 `GetColorManagement()`, Task 2 engine path.

- [x] **Step 1:** Implement the DXGI color-space calls and the capabilities filter (aurora 75ffc7c; Dawn patch).
- [x] **Step 2:** Vendor provider applies patches (needs `cmake -E env GIT_DIR=` — plain git apply anchors to an enclosing repo and silently skips all hunks in build trees); verified: fresh vendor fetch auto-patched, host suite 307/307.
- [ ] **Step 3:** CI Windows build on the user's fork (run 41688603341, code: aurora 7dc9607); user tests on the HDR Windows PC: D3D12 + scRGB, D3D12 + HDR10, Windows HDR toggle off → SDR + toast, window dragged to SDR monitor keeps presenting, vbao still renders. Commit.

### Task 4: Metal (macOS + iOS) with EDR scaling

Code done: Dawn patch (EDR layer, RGBA16Float-only caps), encode edrScale/edrPeak, EdrHeadroom.mm (aurora 7f512d8 + 53a370f edr namespace fix); host tests green (HdrEdr.ClampsToHeadroom, HdrMode.Hdr10OnMetalUsesScrgb, tint-valid encode). First Metal compile = CI run 41688603341 (macOS jobs, build-only: no Mac hardware).

**Files:**
- Modify (Dawn patch): `src/dawn/native/metal/SwapChainMTL.mm` (with SRGBLinear+Extended: `wantsExtendedDynamicRangeContent = YES`, `pixelFormat = MTLPixelFormatRGBA16Float`, `colorspace = kCGColorSpaceExtendedLinearSRGB`), Metal `GetSurfaceCapabilities` (only RGBA16Float, and only if the screen's potential EDR headroom > 1).
- Create: `extern/aurora/lib/dawn/EdrHeadroom.mm` — `float aurora_edr_headroom(SDL_Window*)` (macOS `NSScreen.maximumExtendedDynamicRangeColorComponentValue`, iOS `UIScreen.currentEDRHeadroom`; 1.0 when unavailable).
- Modify: `lib/webgpu/hdr.hpp` (`resolve_mode` takes the backend: HDR10 on Metal → SCRGB), `lib/webgpu/gpu.cpp` (`HdrEncodeUniformBlock` + encode WGSL: `edrScale`, `edrPeak`; for Metal output `min(o * edrScale, edrPeak)` with `edrScale = 80/paperWhite`, `edrPeak = headroom` queried each frame).
- Test: `extern/aurora/tests/hdr_test.cpp`

- [x] **Step 1: Failing tests** — `HdrMode.Hdr10OnMetalUsesScrgb` (`resolve_mode(AURORA_HDR_HDR10, {RGBA16Float}, Metal) == AURORA_HDR_SCRGB`), `HdrEdr.ClampsToHeadroom` (pure `edr_output(o, paperWhite, headroom)`: paper white → 1.0, values above headroom clamp to it).
- [x] **Step 2–4:** fail → implement → green; encode WGSL validated with tint (extract as in `/tmp/opencode/hdr_encode.wgsl` flow).
- [ ] **Step 5:** iOS build via GitHub macOS runner (`x-ios-ci`), sideload; user checks HDR on iPhone/iPad incl. brightness changes and Low Power Mode. macOS: build only (no test device). Commit.

### Task 5: Android

**Files:**
- Modify: none expected (Vulkan path from Tasks 1–2); `cmake/AndroidExports.cmake` only if the mod SDK stub is missing for `hdr_mod`.

- [ ] **Step 1:** CI Android build (`x-android-ci-arm64`, vendor Dawn) + hdr-mod via mod-template CI; user installs on the Android phone.
- [ ] **Step 2:** Check HDR10 and scRGB; device without HDR → SDR + toast. Fix only what fails. Commit.

### Task 6: Ship the mod for all platforms

- [x] **Step 1:** hdr-mod CI on KevinX8/dusklight-hdr-mod (mod-template matrix): 8 platforms green, `Combine bundles` produces one `hdr_mod.dusk` with all native libs + res/hdr.wgsl (run 41686350348; artifact kept at `/media/ESSD/Dusklight/artifacts/hdr_mod-9536d42-combined.dusk`).
- [ ] **Step 2:** Install on each test device; confirm the grade activates (`HDR grade active` in the log). Commit.

## CI cross-platform fix rounds (all pushed)

| # | Platform(s) | Failure | Fix |
|---|-------------|---------|-----|
| 1 | all | `Rec2100PQ` not a member — `auto` provider resolved to stock prebuilt Dawn | provider: `auto` picks patched vendor whenever `cmake/patches/dawn-*.patch` exist (aurora 7dc9607) |
| 2 | Linux | CMake generate: `dawncpp_module` has no import-graph scanner | `DAWN_SUPPORTS_CXX_MODULES OFF` (aurora 72fa1e2; gcc-13 CI probe true, ships no scanner) |
| 3 | iOS/Android | protobuf.cmake: cross-compile needs host protoc | `DAWN_BUILD_PROTOBUF OFF` + `TINT_BUILD_IR_BINARY OFF` (aurora 4984656; tint IR falls back to spirv-cross serialization) |
| 4 | Android | magic_enum: no matching `is_valid` for C enum `AuroraHdrMode` (NDK clang, unsigned-int underlying type) | `hdr::mode_name()` 3-value switch (aurora 2e3d6fa) |
| 5 | Windows | LNK1189 65535-export limit on `webgpu_dawn.dll` | clear `WINDOWS_EXPORT_ALL_SYMBOLS` on that target — dusklight sets it globally, Dawn exports its C API via its own dllexport macros (aurora 2a8f509; shared linkage = official layout, mods link the import lib) |
| 6 | iOS | `property 'maximumExtendedEDRContentHeadroom' not found on UIScreen` | `maximumExtendedEDRHeadroom` (Dawn patch capability), `currentExtendedEDRContentHeadroom.maximumEDRHeadroom` (EdrHeadroom.mm live) (aurora 3be1823) |
| 7 | macOS | `no member named 'wantsExtendedDynamicRangeContent' in dawn::NSRef<CAMetalLayer>'` | dereference `*mLayer` (NSRef has no ObjC dot syntax); single CoreGraphics path `CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB)` for macOS+iOS (aurora a12ffe4) |
| 8 | iOS + macOS | iOS: fabricated EDR symbol names; macOS job: `'webgpu/hdr.hpp' file not found` in EdrHeadroom.mm | Verified real APIs: `UIScreen.mainScreen.potentialEDRHeadroom` (capability, iOS 16+), `.currentEDRHeadroom` (live), `NSScreen.mainScreen.maximumExtendedDynamicRangeColorComponentValue` (macOS 10.11+) — confirmed via Apple docs JSON + Chromium/Godot/robovm usage; include `../webgpu/hdr.hpp` (aurora e2cdf34) |

State: **RELEASE LIVE: https://github.com/KevinX8/dusklight/releases/tag/v2.0.3-hdr.1** (tag run 41763475727 all-success: 8 builds + Release artifacts job; assets: linux AppImage x2, win32 zip x2, macos zip x2, ios ipa, signed apk - APK Signing Block verified on the published asset). Release-job CI rounds 9-10: gh release create needs --repo in the checkout-less job; --verify-tag/--generate-notes dropped (git-dependent). Earlier: gate green 8d4dc224e3, all 8 platforms build - Linux x86_64/aarch64, Windows x86_64/arm64 (D3D12), Android arm64, iOS arm64 + macOS arm64/x86_64 (Metal EDR). Tag v2.0.3-hdr.1 pushed; release job publishes official-style 8 assets (AppImage x2 raw, win zip x2, mac zip x2, ipa, signed apk). Release job: official-style 8 assets (AppImage×2 raw, win zip×2, mac zip×2, ipa Payload, signed apk) wired on tag push, auto-tag `v2.0.3-hdr.1` on green.
