<div align="center">
  <img src="res/logo.png" alt="Logo" width="640">

  <p align="center">
    <a href="https://twilitrealm.dev">Official Website</a>
    •
    <a href="https://discord.gg/6NpMhefCK9">Discord</a>
  </p>
</div>

# Dusklight HDR (unofficial fork)

> [!WARNING]
> This is an **unofficial fork** by KevinX8, not affiliated with TwilitRealm. Please report issues
> [here](https://github.com/KevinX8/dusklight-hdr/issues), not to the upstream project. It was built with
> AI assistance, so upstream does not accept it as a contribution.

This fork adds **HDR output** to Dusklight: a Graphics > **HDR Output** setting (HDR10 or scRGB), an
HDR present path in the engine, and a mod API (GfxService 1.5) that HDR mods use to grade the
picture. Everything else matches upstream; with HDR Output off it behaves exactly like upstream
Dusklight.

| Platform | HDR modes | Status |
|---|---|---|
| Linux (Vulkan) | HDR10, scRGB | Tested (Legion Go 2) |
| Windows (D3D12) | HDR10, scRGB | Builds; testing |
| Android (Vulkan) | HDR10, scRGB | Builds; testing |
| iOS (Metal) | scRGB (EDR) | Builds; testing |
| macOS (Metal) | scRGB (EDR) | Builds; untested |

> [!IMPORTANT]
> **You also need the HDR mod.** The engine only provides HDR output; the game itself renders an SDR
> picture. Without the mod you get that SDR picture inside an HDR signal. The
> [HDR+ Grade mod](https://github.com/KevinX8/dusklight-hdr-mod) expands it into real HDR.

### Install

1. Download the build for your platform from the
   **[latest fork release](https://github.com/KevinX8/dusklight-hdr/releases/latest)**.
   It installs the same way as the official build (see the
   [official installation guide](https://twilitrealm.dev/install/)), with two differences:
   - **Android**: the APK is signed with a test key, not the official one. Uninstall the official
     app first (back up your saves).
   - **iOS**: the IPA is unsigned. Sideload it, e.g. with [AltStore](docs/ios-install-altstore.md).
2. Download `hdr_mod.dusk` from the
   **[HDR mod release](https://github.com/KevinX8/dusklight-hdr-mod/releases/latest)**. It is a single
   file for every platform. Put it in your mods folder:
   - Windows: `%APPDATA%\TwilitRealm\Dusklight\mods`
   - Linux: `~/.local/share/TwilitRealm/Dusklight/mods`
   - macOS: `~/Library/Application Support/TwilitRealm/Dusklight/mods`
   - Android / iOS: the `mods` folder in Dusklight's data directory.
3. In Dusklight, set **Graphics > HDR Output** to HDR10 or scRGB, then restart. Your display or OS
   HDR mode must be on (Windows: Settings > Display > Use HDR). If the display can't do it, the game says so and
   runs SDR.

The engine reports version 2.0.3, so mods that check the game version keep working.

---

# Overview

Dusklight is a reverse-engineered reimplementation of Twilight Princess.

It aims to be as accurate as possible to the original while also providing new options, enhancements, and tools to customize your experience.

> [!IMPORTANT]
> Dusklight's official website is https://twilitrealm.dev/, any other website is not affiliated and may be promoting AI-generated misinformation.

# Setup

> [!IMPORTANT]
> Dusklight does *not* provide any copyrighted assets. You must provide your own copy of the original game.

> [!IMPORTANT]
> At a minimum, Dusklight requires a GPU with support for D3D12, Vulkan 1.1+, or Metal. For older devices, best-effort support is provided for D3D11 and OpenGL ES (Android), but will not achieve full accuracy or performance. Your experience with specific hardware, operating systems, and drivers may vary.

### 1. Dump your game

You must dump your own copy of the game. Please see [this article](https://wiki.dolphin-emu.org/index.php?title=Ripping_Games) for instructions. After dumping, you can use a program like [Dolphin](https://dolphin-emu.org/) or [nodtool](https://github.com/encounter/nod/releases) to convert the `.iso` to `.rvz` to save space.

Dusklight currently supports all commercial discs except for Wii's Korean release.

> [!NOTE]
> Dusklight is based on the [Twilight Princess decompilation](https://github.com/zeldaret/tp), which is currently only matching for GameCube. As a result, even when playing Dusklight with a Wii disc, you will be presented with the GameCube version's HUD and certain other specificities.

### 2. Install Dusklight

Visit the [official installation guide](https://twilitrealm.dev/install/) for full instructions.

# Building

If you'd like to build Dusklight from source, please read the [build instructions](docs/building.md).

Pull requests are welcomed! Note that we do not accept contributions that are primarily AI-generated and will close your PR if we suspect as much. Please also see the [code conventions](docs/code-conventions.md).

# Credits

Special thanks to the [TP decompilation](https://github.com/zeldaret/tp) team, the GC/Wii decompilation community, the [Aurora](https://github.com/encounter/aurora) developers, the [TP speedrunning community](https://zsrtp.link), and all [contributors](https://github.com/TwilitRealm/dusklight/graphs/contributors).

<br/>
<div align="center">
    <a href="https://github.com/encounter/aurora">
        <img src="assets/aurora-powered.png" alt="Powered by Aurora" width="800">
    </a>
</div>
