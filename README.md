# LayoutTint

A tiny, UI-less macOS utility that changes your desktop wallpaper based on the active keyboard layout. It adds a solid color band behind the menu bar, giving you a prominent indicator of the current input source. The app only manages the main display.

## How it works

1. On launch it reads your current wallpaper. If it's a plain static image, it copies it into `~/Library/Application Support/LayoutTint/`. If it's a dynamic wallpaper or a video, the app does nothing.
2. It generates one wallpaper per configured band color: the source wallpaper scaled and cropped to fill the screen, with a solid band added at the top.
3. It listens for keyboard layout changes and switches wallpapers accordingly. Layouts beyond the configured colors are ignored.

## Requirements

- macOS Sequoia. Newer versions have not been tested.
- A Swift toolchain, via Xcode Command Line Tools.
- "Reduce Transparency" must be off in _System Settings → Accessibility → Display_.

## Configuration

Band colors and other options are defined in the Config enum near the top of `LayoutTint.swift`.

- `bandColors` — colors in input-source order. Add or remove entries to support more or fewer layouts.
- `forceRegenerate` — rebuild all wallpapers on every launch (handy while tuning colors, turn off once you're happy).
- `menuBarFallbackHeightPx` — used when the menu bar height can't be detected (e.g. auto-hide is enabled).

Recompile after changing the configuration.

## Building

The binary only:

```sh
swiftc LayoutTint.swift
```

The `LayoutTint.app` bundle:

```sh
./build.sh
```

## Running

### From the command line

```sh
nohup ./LayoutTint &
```

Logs are printed to stdout (or `nohup.out`), which is useful for verifying the layout → color mapping.

### As an app bundle

Double-click LayoutTint.app in Finder. The app launches without a Dock icon or a menu bar icon.

The app has no UI, so stop it from the command line:

```sh
pkill LayoutTint
```
