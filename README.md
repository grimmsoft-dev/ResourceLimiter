# Resource Limiter

An Unreal Engine 5 editor plugin that adds a one-click toggle to the Level Editor toolbar for limiting how much of the machine the editor uses. It's useful when you want to keep working in other programs, stream or record, or keep a laptop cool while the editor is open.

The button is a CPU icon. Click it to cycle **Off → 90 → 70 → 50 → Off**. The number is the CPU cap, and the background colour shows the level:

| Button | CPU | Priority | RAM | Video memory | GPU |
|---|---|---|---|---|---|
| No colour, **Off** | No limit | Normal | Normal | Engine default | No change |
| Green, **90** | 90% of all cores | Normal | Normal | Texture pool at 90% | 120 fps cap |
| Orange, **70** | 70% | Below normal | Lower memory priority | Texture pool at 70% | 60 fps cap |
| Red, **50** | 50% | Below normal | Low memory priority | Texture pool at 50% | 30 fps cap |

The choice is saved per user, for all projects (`EditorSettings.ini`, section `[ResourceLimiter]`), and applied the next time the editor starts. The plugin is editor-only and Windows-only: it is never included in packaged games.

## How each limit works

- **CPU:** Windows enforces this as a hard cap. As soon as its config loads, the editor puts itself in a Windows job object, so the shader compile workers and other processes it starts later share the same cap. "50" means the editor and its helpers together never use more than half of the machine's total CPU time. Builds such as shader compiles and lighting builds take longer while capped.
- **Priority:** at 70 and 50 the editor runs at below-normal priority, so other programs win when they compete for the CPU.
- **RAM:** the plugin lowers the editor's Windows memory priority instead of setting a hard limit. When RAM runs short, Windows pages out the editor's memory before other programs' memory. A hard memory limit would crash Unreal when exceeded, so the plugin doesn't use one.
- **Video memory:** the texture streaming pool, which is the editor's main user of video memory, shrinks to a share of the size the engine chose. Distant or large textures may stream in at lower resolution.
- **GPU:** Windows has no per-program GPU limit, so a frame cap holds GPU load down instead. It applies only when no other cap is set, so a cap from a `t.MaxFPS` console command or the [FPS Lock](https://github.com/grimmsoft-dev/FpsLock) plugin takes precedence.

To change the level from the console for the current session only (not saved), use `ResourceLimiter.Level 90`, `70`, `50` or `off`. Each change is logged under `LogResourceLimiter`.

## Install

1. Download `ResourceLimiter-<version>-Installer.zip` from [Releases](../../releases) and unzip it.
2. Run `Install.bat`.
3. Tick the engines to install into (every project using that engine gets the plugin), or pick a single `.uproject`. If an engine isn't listed (moved, copied or source-built), click **Add engine folder...** and choose its folder.
4. Click **Install**, then restart Unreal Editor.

If an engine is installed under `Program Files`, right-click `Install.bat` and choose **Run as administrator**.

From a console:

```bat
Install.bat -Engine 5.3
Install.bat -Engine "D:\Engines\UE_5.6"
Install.bat -Project "D:\MyGame\MyGame.uproject"
Install.bat -Engine 5.3 -Uninstall
```

## Compatibility

The 1.0.0 release is prebuilt for **UE 5.3** only. For other 5.x versions, install into a C++ project and the editor compiles the plugin when the project opens, or build it yourself as described below.

## Building from source

```powershell
.\Scripts\Build.ps1 -Engines 5.3  # or leave out -Engines for every UE5 engine installed
.\Scripts\Test.ps1 -Engines 5.3   # installs into a test project, opens a hidden editor, checks the limits took effect
```

The build script needs Visual Studio 2022 with the C++ workload. UE 5.0–5.3 also need the MSVC 14.36 toolchain, which the script selects automatically.

## Releasing

1. Bump `Version` and `VersionName` in `ResourceLimiter/ResourceLimiter.uplugin` and add a line to `CHANGELOG.md`.
2. Run `.\Scripts\Build.ps1` and `.\Scripts\Test.ps1`.
3. Tag and upload:

```powershell
git tag v1.0.0; git push --tags
gh release create v1.0.0 Dist\ResourceLimiter-1.0.0-Installer.zip --notes-file CHANGELOG.md
```
