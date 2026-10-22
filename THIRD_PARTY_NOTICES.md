# Third-party notices

love-mini's own code (`lovemini/`, `build/`, `pkg/`, `tools/`, `demo/`, `tests/`) is MIT
licensed, see `LICENSE`. Two parts come from
[panelattack-miyoo](https://github.com/snyderman3000/panelattack-miyoo) by snyderman3000,
under the MIT License (full text below):

- `mini2d/mini2d.c`, the software renderer, extended for love-mini (blend modes, affine blits,
  polygons, a stencil buffer);
- `dspfix/dspfix.c`, with two fixes for libpadsp (primed before the first `/dev/dsp`; OSS
  requests without an argument get one);
- `pkg/alsoft.conf`, unchanged.

The release zip also contains the following software, each under its own license.

| Component | License | Source |
|---|---|---|
| LÖVE 11.5 | zlib. **Altered:** `src/modules/love/boot.lua` loads love-mini (`build/love-boot.patch`) | https://github.com/love2d/love |
| LuaJIT 2.1 | MIT | https://github.com/LuaJIT/LuaJIT |
| SDL2 2.30.9 | zlib | https://github.com/libsdl-org/SDL |
| OpenAL Soft 1.21.1 | LGPL-2.1-or-later, dynamically linked | https://github.com/kcat/openal-soft (source attached to every release as `openal-soft-1.21.1-source.tar.gz`) |
| FreeType | FreeType License (FTL) | https://freetype.org |
| libpng, zlib | libpng / zlib licenses | http://www.libpng.org, https://zlib.net |
| libogg, libvorbis, libtheora | BSD-3-Clause | https://xiph.org |
| libmodplug | public domain | https://github.com/Konstanty/libmodplug |
| GCC runtime (libgcc_s, libstdc++, libatomic) | GPL-3.0 with the GCC Runtime Library Exception | https://gcc.gnu.org |

SDL2, OpenAL Soft, LuaJIT, LÖVE and the Xiph libraries are built from the sources named in
`build/deps.sh` (checksums in `build/sources.sha256`); FreeType, libpng, zlib and the GCC
runtime come unmodified from the Miyoo Mini toolchain's sysroot. OpenAL Soft is a separate
shared library (`lib/libopenal.so.1`) and can be replaced with any compatible build.

## panelattack-miyoo (mini2d, dspfix, alsoft.conf)

```
MIT License

Copyright (c) 2026 snyderman3000


Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
