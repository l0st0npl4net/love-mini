# love-mini

[LÖVE](https://love2d.org) 11.5 games on the Miyoo Mini and Mini Plus running
[OnionOS](https://github.com/OnionUI/Onion), without a port for each game.

The Mini has no GPU. love-mini runs stock LÖVE 11.5 with its window and OpenGL graphics
switched off and puts its own `love.graphics`, `love.window` and input in their place: a
software renderer (`mini2d`, drawn by the CPU, shown with the SoC's 2D engine) and the Mini's
buttons as both a keyboard and a gamepad. Everything else — `love.audio`, `love.filesystem`,
`love.math`, `love.physics`, `love.timer`, threads — is LÖVE's own.

**Status: 0.4.0.** Runs on a Mini Plus; many LÖVE 11 games run there at 60 frames a second.
Games packed for it, and how well each plays: [love-mini games](https://github.com/l0st0npl4net/love-mini-games).

## What a game gets

- **Graphics:** images, quads, canvases, text (TrueType and image fonts), SpriteBatch,
  ParticleSystem, primitives (rectangles, rounded too, lines, circles, ellipses, arcs,
  polygons, points), all of LÖVE's transforms (`push`/`pop`, `translate`, `rotate`, `scale`,
  `shear`, `Transform` objects), scissor, stencil, the blend modes `alpha`, `replace`, `add`,
  `subtract`, `multiply`, `screen`, `lighten`, `darken`; screenshots.
- **Screen:** the game keeps its own size (`t.window.width`/`height`); love-mini scales it to
  the Mini's 640×480: `fit` (default, letterboxed), `fill`, `integer` or `stretch`.
- **Buttons:** as keys (the same keys the Mini's SDL reports, so key bindings of other Mini ports
  apply) and as a gamepad called "Miyoo Mini":

  | Mini | Key | Gamepad |
  |---|---|---|
  | D-pad | arrows | `dpup` … |
  | A / B / X / Y | `space` / `lctrl` / `lshift` / `lalt` | `b` / `a` / `y` / `x` (by position, as on an Xbox pad) |
  | L1 / R1 | `e` / `t` | `leftshoulder` / `rightshoulder` |
  | L2 / R2 | `tab` / `backspace` | `triggerleft` / `triggerright` |
  | Select / Start / Menu | `rctrl` / `return` / `escape` | `back` / `start` / `guide` |

  Select + Start held for a second quits any game.
- **Sound:** OpenAL through OnionOS's audioserver; the volume buttons and other apps' sound keep
  working.
- **Saves:** `Saves/CurrentProfile/saves/love-mini/love/<identity>` on the SD card.

- **Shaders:** no GLSL runs. Common ones are recognised and stood in for (a sprite's flash
  in one colour, grayscale, inverted colours, black left out as for masks, a shader that never
  reads its texture as the shape in one colour); a profile can name
  a shader's stand-in or draw what it does in Lua (`post`). The rest are drawn without, and the
  report lists them.
- **Text:** a screen keyboard when a game asks for text (`love.keyboard.setTextInput(true)`,
  as on a phone), or Select + Y in any game: d-pad, A types, B deletes, Y space, X capitals,
  Start Enter.
- **Mouse** (profile `mouse`): a cursor the d-pad moves, A and B the buttons, L1 / R1 the
  wheel; with `mouse = "toggle"` Select switches between the cursor and the game's buttons.
- **Memory:** pictures loaded from files are dropped when textures pass a budget (32 MB) and
  loaded again when drawn; long sounds loaded whole are streamed.

**Not there (yet):** full-screen shader effects (blur, glow, CRT), 3D meshes (a Mesh is drawn
flat-coloured), `love.video`, touch.

## Install

With [Port Store](https://github.com/l0st0npl4net/PortStore-Catalog-MiyooMini) (1.3.0 or later):
install a game of the [love-mini games](https://github.com/l0st0npl4net/love-mini-games)
catalog and Port Store installs love-mini first; or install **love-mini** itself (Apps).

By hand: unzip `love-mini-<version>.zip` onto the SD card's root, merging `Roms`. It adds:

```
Roms/PORTS/Games/love-mini/       the runtime: bin/love, lib/, lovemini/, run.sh
  games/check/                    the check game (below)
Roms/PORTS/Shortcuts/LOVE games/  love-mini check.port
```

Then *Ports* in the game list (if it is not there: install *Ports Collection* in OnionOS's
Package Manager; if the game is missing from it, run *~Import ports* at the top of the Ports
list). Run **love-mini check**.

## Adding a game

1. Make a folder `Roms/PORTS/Games/love-mini/games/<id>/` (`<id>`: a short name, no spaces) and put
   the game in it: `game.love`, any other `.love`, a Windows build's `.exe` (a fused LÖVE game:
   the game is the zip at the end of the file), or the game's unpacked folder with `main.lua`.
2. Copy `Roms/PORTS/Shortcuts/LOVE games/love-mini check.port` to `<Game name>.port` and change
   `GameName` and `Arguments="<id>"`.

Only LÖVE 11.x games run as they are. A game that needs something adjusted gets a profile.

### Profile

`games/<id>/profile.lua` next to a `.love` (or `profiles/<id>.lua` in the runtime folder, which
is also where it goes for a game kept as a folder) returns a table:

```lua
return {
  screen = "integer",        -- fit (default) | fill | integer | stretch
  storage_scale = 1,         -- keep images at this scale (default: the screen's)
  keys = { a = "z", b = "x" }, -- buttons to other keys: up down left right a b x y l1 r1 l2 r2 select start menu
  gamepad_layout = "nintendo", -- face buttons by name, not position
  keyboard = true, gamepad = true,
  stream_over_kb = 1024,     -- "static" sounds from bigger files are streamed (memory)
  texture_budget_mb = 32,    -- pictures over this are dropped and loaded again when drawn
  mouse = "toggle",          -- the cursor: true (always) | "toggle" (Select switches)
  jit = true,                -- false: LuaJIT's compiler off (LOVE's own choice on ARM)
  shaders = {                -- by where the game made a shader ("file.lua:12") or its hash
    ["src/fx.lua:10"] = "solid",   -- solid | gray | invert | noblack | flat | "none"
    ["shaders/bg.fs"] = { effect = "flat", color = "colour_1" },  -- by its file: one colour
    ["bfde70f8"] = { post = function(u, lg) --[[ draw what it would, uniforms in u ]] end },
  },
  -- the game adjusted as it loads, its file never changed (a game the player owns):
  env = { SETTING = "1" },   -- what os.getenv answers
  lua = "lua",               -- Lua modules of the profile's own, next to it (require finds them first)
  edits = {                  -- a game's Lua file changed as it loads: plain old text, new text, times
    ["main.lua"] = { { 'require "a"', 'require "a"\nrequire "fix"', 1 } },
  },
  files = { ["resources/font.ttf"] = "fonts/other.ttf" },  -- the game's files read from next to the profile
  saves_from = "/mnt/SDCARD/Saves/CurrentProfile/saves/Game",  -- another port's saves, copied once
}
```

An edit that does not fit (the game changed) leaves that file as it is, and the log says so.

A shader's place and hash are in the report (`LOVEMINI_REPORT`, `report.json`).

## Trying it on a Mini

Run **love-mini check**. It shows the frames a second, the last keys and gamepad buttons, a
square the d-pad moves, tones on A and B, and how many times it ran (a save). Then send:

- `Roms/PORTS/Games/love-mini/games/check/log.txt` — every 10 seconds love-mini writes there how
  long frames took (`love-mini: frames: …`);
- what you saw and heard: picture right way up? tones played? buttons right?

If a game does not start, run **love-mini diagnose** (in the same Ports folder): it checks
love-mini piece by piece — libraries, LÖVE, LuaJIT, the screen alone, the check game without and
with sound, about 15 seconds in all — and writes everything, crashes included, to
`Roms/PORTS/Games/love-mini/diag.txt`.

For any game, `log.txt` is in its folder, the run before it in `log.prev.txt`. A crash leaves its place in
`log.txt` (registers and memory map). Uncomment `LOVEMINI_REPORT` in `run.sh` to also get
`report.json` (missing functions, shaders, errors, frame times), `LOVEMINI_TRACE` for each step
of the start.

## Building

On Linux x86-64, with the Miyoo Mini toolchain (GCC 8.3, glibc 2.28) in
`~/.local/opt/miyoomini-toolchain` (or `MIYOO_TOOLCHAIN`), [zig](https://ziglang.org) (a
32-bit compiler for LuaJIT's build tools; `ZIG`), cmake (`CMAKE`), curl, python3, qemu-arm
for tests.

```sh
build/deps.sh       # SDL2, Ogg/Vorbis/Theora, ModPlug, OpenAL Soft, LuaJIT, LÖVE 11.5 → .deps/arm/prefix
build/mini2d.sh     # libmini2d: for the Mini, and a stub for qemu and this machine
build/package.sh    # out/love-mini-<version>.zip and the OpenAL source to go with it
```

Sources are downloaded into `.deps/src` and checked against `build/sources.sha256`.

### A release

`tools/release.sh` builds the package, checks the NEON code against the plain C one
(`tools/neoncheck.sh`) and says what to upload for a GitHub release `v<version>` (the zip,
OpenAL Soft's source; notes in `docs/releases/`).

### Running games without a Mini

```sh
tools/run.sh path/to/game[.love] [frames] [out] [input]
```

runs the Mini's build of LÖVE under qemu with the renderer drawing into memory, and saves every
30th frame as PNG and `report.json` in `out/run/<game>/`. `input` scripts button presses
(`frame code value` per line, evdev codes: `57` A, `29` B, `103`/`108`/`105`/`106` the d-pad,
`28` Start). `PROFILE=profile.lua`, `SIZE=752x560` and `EVERY=10` change the rest.

## How it fits together

```
run.sh <id>          LD_PRELOAD libdspfix + libpadsp (sound), saves, log
  bin/love <game>    LÖVE 11.5, one change in boot.lua (build/love-boot.patch)
    lovemini/boot.lua      before the game: LÖVE's window and graphics off
    lovemini/window.lua    love.window, the game's size on the screen
    lovemini/graphics.lua  love.graphics over mini2d (LuaJIT FFI)
    lovemini/input.lua     buttons → keys, gamepad, events
    lovemini/report.lua    missing functions, errors, frame times
      lib/libmini2d.so     drawing on the CPU; MI_GFX rotates the frame onto /dev/fb0
```

The full design and plan (in Russian): [DESIGN.md](DESIGN.md).

## License

MIT, see [LICENSE](LICENSE). The renderer and the sound shim come from
[panelattack-miyoo](https://github.com/snyderman3000/panelattack-miyoo) by snyderman3000 (MIT);
LÖVE, LuaJIT, SDL2, OpenAL Soft and the other bundled libraries keep their own licenses: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
