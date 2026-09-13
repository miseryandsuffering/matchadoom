# matchadoom

A pure-Lua Doom port adapted for the [Matcha](https://doc.wabisabi.mom/matcha/) LuaVM environment.

## Quickstart

Run via `loadstring` in Matcha:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/miseryandsuffering/matchadoom/main/matchadoom.lua"))()
```

## How It Works

- **Framebuffer Drawing Adapter**: Uses an in-memory uncompressed PNG pipeline to stream rendered 320x200 8-bit paletted frames directly into Matcha's `Drawing.new("Image")`.
- **Matcha Filesystem Support**: Automatically handles restricted workspace extensions (`.dat`, `.txt`) and caches downloaded WADs to `workspace/doom1.dat`.
- **Auto-Download Fallback**: Automatically downloads `DOOM1.WAD` from this repository if no local WAD is found in your Matcha workspace.

## Controls

| Action | Key |
| --- | --- |
| **Move** | `W` / `S` |
| **Turn** | `A` / `D` or Left / Right Arrows |
| **Strafe** | `Q` / `E` |
| **Run** | `Shift` |
| **Shoot** | `Ctrl` |
| **Open / Use** | `Space` |
| **Select Weapon** | `1` - `4` |
| **Cycle Weapon** | `Tab` |
| **Restart Level** | `Backspace` |
