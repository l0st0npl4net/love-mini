-- love.graphics for love-mini: LOVE 11's drawing API on the CPU, with libmini2d.
--
-- Fonts, text wrapping and Text objects are based on the love.graphics replacement
-- of panelattack-miyoo by snyderman3000 (MIT License, see THIRD_PARTY_NOTICES.md);
-- the transforms, blend modes, stencil, primitives and screen mapping are love-mini's.
--
-- Model.
-- * Coordinates: the game draws in its own logical screen (its window size). The
--   current transform (2x3: x' = a*x + c*y + e, y' = b*x + d*y + f) takes them to
--   the target's logical space; the target maps that to its pixels (kx, ky, ox, oy):
--   the screen by love-mini's window (fit, fill, integer, stretch), a canvas by the
--   scale it is stored at.
-- * Textures (Image, Canvas) have a logical size (what the game sees) and a pixel
--   surface stored at a scale: about the screen's, so most blits are 1:1, but never
--   below 1 for textures no larger than the screen (small sprites keep their pixels).
-- * Draws without rotation or shear blit a rectangle (scaled, flipped; scaled copies
--   of static images are cached); others go through the affine blit.
-- * Shaders are accepted and not run (love-mini's report lists them).

local print = print  -- the log's: a game may make print() draw text (as in PICO-8)
local ffi = require("ffi")
local utf8 = require("utf8")
local M = require("lovemini.m2d")

local floor, ceil, max, min, abs, sqrt = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt
local cos, sin, pi = math.cos, math.sin, math.pi
local NOTINT = 0xffffffff

local G = {}
G._report = { unsupported = {}, shaders = {} }

local function unsupported(what)
  local r = G._report.unsupported
  r[what] = (r[what] or 0) + 1
end

---------------------------------------------------------------------------
-- screen and targets
---------------------------------------------------------------------------
local gameW, gameH = 800, 600         -- the game's logical screen
local back                            -- the back buffer surface
local storeScale = 1                  -- scale textures are stored at, by default
local stats = { drawcalls = 0, images = 0, canvases = 0, fonts = 0, texturememory = 0, drawcallsbatched = 0,
  canvasswitches = 0, shaderswitches = 0 }

local screenTarget = { isScreen = true, kx = 1, ky = 1, ox = 0, oy = 0 }
local target = screenTarget

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------
-- transform: x' = ta*x + tc*y + te, y' = tb*x + td*y + tf
local ta, tb, tc, td, te, tf = 1, 0, 0, 1, 0, 0
local tstack = {}
local cr, cg, cb, ca = 1, 1, 1, 1
local tint = NOTINT          -- premultiplied tint for textures
local fillColor = 0xffffffff -- premultiplied fill colour
local BLEND = { replace = 0, alpha = 1, add = 2, subtract = 3, multiply = 4, screen = 5, lighten = 6, darken = 7,
  none = 0 }
local blend = 1
local blendName, alphaModeName = "alpha", "alphamultiply"
local lineWidth, lineStyle, lineJoin = 1, "smooth", "miter"
local pointSize = 1
local curFont
local bgr, bgg, bgb, bga = 0, 0, 0, 1
local scissor = nil          -- {x,y,w,h} in the window's coordinates (no transform)
local stencilCompare, stencilValue = nil, 0
local shader = nil
local defaultFilterMin, defaultFilterMag = "linear", "linear"
local colorMask = { true, true, true, true }

local function premulColor(r, g, b, a)
  if a < 0 then a = 0 elseif a > 1 then a = 1 end
  if r < 0 then r = 0 elseif r > 1 then r = 1 end
  if g < 0 then g = 0 elseif g > 1 then g = 1 end
  if b < 0 then b = 0 elseif b > 1 then b = 1 end
  local A = floor(a * 255 + 0.5)
  local R = floor(r * a * 255 + 0.5)
  local Gc = floor(g * a * 255 + 0.5)
  local B = floor(b * a * 255 + 0.5)
  return A * 16777216 + R * 65536 + Gc * 256 + B
end

local function updateColor()
  fillColor = premulColor(cr, cg, cb, ca)
  if cr == 1 and cg == 1 and cb == 1 and ca == 1 then tint = NOTINT else tint = fillColor end
end

-- The composite map from the game's coordinates to the target's pixels.
local function pixmat()
  local kx, ky = target.kx, target.ky
  return kx * ta, ky * tb, kx * tc, ky * td, kx * te + target.ox, ky * tf + target.oy
end

local function toPixel(x, y)
  return target.kx * (ta * x + tc * y + te) + target.ox, target.ky * (tb * x + td * y + tf) + target.oy
end

local function axisAligned()
  return abs(tb) < 1e-9 and abs(tc) < 1e-9
end

-- the scissor as a pixel clip on the current target
-- What a draw can reach on the target, in its pixels: draws wholly outside are
-- dropped before any work (games draw whole maps and leave the culling to the GPU).
local cullX0, cullY0, cullX1, cullY1 = -1e9, -1e9, 1e9, 1e9

local function applyClip()
  local sw, sh = 1e9, 1e9
  if target.surf then sw, sh = target.surf.w, target.surf.h end
  if scissor then
    local kx, ky, ox, oy = target.kx, target.ky, target.ox, target.oy
    local x0, y0 = floor(scissor[1] * kx + ox + 0.5), floor(scissor[2] * ky + oy + 0.5)
    local x1, y1 = floor((scissor[1] + scissor[3]) * kx + ox + 0.5), floor((scissor[2] + scissor[4]) * ky + oy + 0.5)
    M.m2d_set_clip(x0, y0, max(0, x1 - x0), max(0, y1 - y0))
    cullX0, cullY0, cullX1, cullY1 = max(0, x0), max(0, y0), min(sw, x1), min(sh, y1)
  else
    M.m2d_reset_clip()
    cullX0, cullY0, cullX1, cullY1 = 0, 0, sw, sh
  end
end

local COMPARE = { always = 0, equal = 1, notequal = 2, less = 3, lequal = 4, greater = 5, gequal = 6, never = 7 }
local ACTION = { replace = 1, increment = 2, decrement = 3, incrementwrap = 4, decrementwrap = 5, invert = 6 }

local function applyStencilTest()
  M.m2d_stencil_test(stencilCompare and COMPARE[stencilCompare] or 0, stencilValue or 0)
end

---------------------------------------------------------------------------
-- object helpers
---------------------------------------------------------------------------
local function makeType(name, parents)
  local mt = {}
  mt.__index = mt
  mt.__typeName = name
  local types = { [name] = true, Object = true }
  for _, p in ipairs(parents or {}) do types[p] = true end
  function mt:typeOf(t) return types[t] == true end
  function mt:type() return name end
  function mt:release() return true end
  return mt
end

local function surfaceGone(p)
  stats.texturememory = stats.texturememory - p.w * p.h * 4
  M.m2d_surface_free(p)
end

local function newSurface(w, h)
  local s = M.m2d_surface_new(w, h)
  assert(s ~= nil, "out of memory allocating a " .. w .. "x" .. h .. " surface")
  stats.texturememory = stats.texturememory + w * h * 4
  return ffi.gc(s, surfaceGone)
end

-- free now, not when the collector gets to it
local function freeSurface(p)
  ffi.gc(p, nil)
  surfaceGone(p)
end

-- The scale a texture of logical size w x h is stored at: the screen's (most blits
-- 1:1), but a texture no larger than the screen keeps at least its own pixels, and
-- nothing is stored at more than twice its size.
local function scaleFor(w, h)
  local sw, sh = back and back.w or 640, back and back.h or 480
  local s = max(storeScale, min(1, sw / max(1, w), sh / max(1, h)))
  return min(s, 2)
end

---------------------------------------------------------------------------
-- Texture (Image / Canvas)
---------------------------------------------------------------------------
local Image = makeType("Image", { "Texture", "Drawable" })
local Canvas = makeType("Canvas", { "Texture", "Drawable" })

local function textureMethods(T)
  function T:getDimensions() return self.lw, self.lh end
  function T:getWidth() return self.lw end
  function T:getHeight() return self.lh end
  function T:getPixelDimensions() return self.lw * self.dpiscale, self.lh * self.dpiscale end
  function T:getPixelWidth() return self.lw * self.dpiscale end
  function T:getPixelHeight() return self.lh * self.dpiscale end
  function T:getDPIScale() return self.dpiscale end
  function T:setFilter(a, b) self.filterMin, self.filterMag = a, b or a end
  function T:getFilter() return self.filterMin or "linear", self.filterMag or "linear", 1 end
  function T:setWrap(h, v)
    self.wrapH, self.wrapV = h, v or h
    if h == "repeat" or h == "mirroredrepeat" then unsupported("Texture:setWrap(" .. h .. ")") end
  end
  function T:getWrap() return self.wrapH or "clamp", self.wrapV or "clamp" end
  function T:getMipmapCount() return 1 end
  function T:getFormat() return "rgba8" end
  function T:getTextureType() return "2d" end
  function T:isReadable() return true end
  function T:setMipmapFilter() end
  function T:getMipmapFilter() return nil end
  function T:getDepth() return 1 end
  function T:getLayerCount() return 1 end
  function T:isCanvas() return self.__isCanvas == true end
  function T:getMSAA() return 1 end
  function T:isFormatLinear() return false end
  function T:isCompressed() return false end
  function T:getDepthSampleMode() return nil end
  function T:setDepthSampleMode() end
end
textureMethods(Image)
textureMethods(Canvas)

local function makeTexture(mt, lw, lh, dpiscale, surf)
  local t = setmetatable({}, mt)
  t.lw, t.lh = lw, lh
  t.dpiscale = dpiscale or 1
  t.surf = surf
  t.filterMin, t.filterMag = defaultFilterMin, defaultFilterMag
  return t
end

local function detectDPI(path)
  if type(path) ~= "string" then return 1 end
  local s = path:match("@(%d+%.?%d*)x%.[%a]+$")
  return tonumber(s) or 1
end

local function isObject(v, typename)
  return (type(v) == "userdata" or type(v) == "table") and v.typeOf and v:typeOf(typename)
end

local function upload(img, imageData)
  local pw, ph = imageData:getDimensions()
  M.m2d_surface_upload_rgba(img.surf, ffi.cast("const uint8_t*", imageData:getFFIPointer()), pw, ph)
  img.opaque = M.m2d_surface_is_opaque(img.surf) == 1
  if not img.opaque then M.m2d_surface_build_spans(img.surf) end
  img.scaled, img.noScaleCache = nil, nil
end

-- The texture budget. Games load every picture up front (a GPU has room); a Mini
-- has 128 MB for everything. Pictures loaded from a file can be dropped and loaded
-- again: when the textures pass the budget (the profile's texture_budget_mb, 32 MB
-- by default), the pictures drawn longest ago go until they are under 3/4 of it, and
-- one that is drawn again is decoded again from its file (a short pause, not swap).
local budget = 32 * 1024 * 1024
local frameNo = 0
local reloadable = setmetatable({}, { __mode = "k" })  -- image -> its file
local evictions, reloads = 0, 0

local function dropSurface(img)
  img.fx = nil
  if img.scaled then
    for k, sc in pairs(img.scaled) do if k ~= "n" then freeSurface(sc) end end
    img.scaled = nil
  end
  if img.surf then freeSurface(img.surf); img.surf = nil end
end

local function reloadImage(img)
  local data = love.image.newImageData(reloadable[img])
  img.surf = newSurface(img.sw, img.sh)
  upload(img, data)
  data:release()
  reloads = reloads + 1
  return img.surf
end

local function keepBudget()
  if stats.texturememory <= budget then return end
  local list = {}
  for img in pairs(reloadable) do
    if img.surf and (img.used or 0) < frameNo - 1 then list[#list + 1] = img end
  end
  table.sort(list, function(a, b) return (a.used or 0) < (b.used or 0) end)
  local before = stats.texturememory
  for _, img in ipairs(list) do
    if stats.texturememory <= budget * 0.75 then break end
    dropSurface(img)
    evictions = evictions + 1
  end
  print(string.format("love-mini: textures over the budget: %d KB -> %d KB (%d pictures dropped, %d loaded again so far)",
    before / 1024, stats.texturememory / 1024, evictions, reloads))
end

function G._setBudget(mb) if mb then budget = mb * 1024 * 1024 end end

function G.newImage(src, settings)
  settings = settings or {}
  local dpiscale = settings.dpiscale
  local imageData
  if type(src) == "string" then
    dpiscale = dpiscale or detectDPI(src)
    imageData = love.image.newImageData(src)
  elseif isObject(src, "ImageData") then
    imageData = src
  elseif isObject(src, "FileData") or isObject(src, "File") then
    dpiscale = dpiscale or detectDPI(src.getFilename and src:getFilename() or nil)
    imageData = love.image.newImageData(src)
  elseif isObject(src, "CompressedImageData") then
    error("newImage: compressed textures are not supported by love-mini")
  else
    error("newImage: unsupported source " .. tostring(src))
  end
  dpiscale = dpiscale or 1
  local pw, ph = imageData:getDimensions()
  local lw, lh = pw / dpiscale, ph / dpiscale
  local s = scaleFor(lw, lh)
  local surf = newSurface(max(1, floor(lw * s + 0.5)), max(1, floor(lh * s + 0.5)))
  local img = makeTexture(Image, lw, lh, dpiscale, surf)
  upload(img, imageData)
  if imageData ~= src then imageData:release() end
  img.sw, img.sh = surf.w, surf.h
  if type(src) == "string" or isObject(src, "FileData") then reloadable[img] = src end
  stats.images = stats.images + 1
  if type(src) == "string" then img.debugName = src end
  return img
end
G.newArrayImage = function() error("newArrayImage is not supported by love-mini") end
G.newCubeImage = function() error("newCubeImage is not supported by love-mini") end
G.newVolumeImage = function() error("newVolumeImage is not supported by love-mini") end

function Image:replacePixels(imageData)
  -- its pixels are no longer the file's
  reloadable[self] = nil
  self.fx = nil
  if not self.surf then self.surf = newSurface(self.sw, self.sh) end
  upload(self, imageData)
end
function Image:isCompressed() return false end

function G.newCanvas(w, h, settings)
  if type(w) == "table" then settings, w, h = w, nil, nil end
  if type(h) == "table" then settings, h = h, nil end
  settings = settings or {}
  w = w or gameW
  h = h or gameH
  local s = scaleFor(w, h)
  local c = makeTexture(Canvas, w, h, settings.dpiscale or 1,
    newSurface(max(1, floor(w * s + 0.5)), max(1, floor(h * s + 0.5))))
  c.__isCanvas = true
  c.kx, c.ky = c.surf.w / w, c.surf.h / h
  stats.canvases = stats.canvases + 1
  return c
end

function Canvas:renderTo(fn, ...)
  local prev = G.getCanvas()
  G.setCanvas(self)
  local ok, err = pcall(fn, ...)
  G.setCanvas(prev)
  if not ok then error(err, 2) end
end

-- The pixels as a real ImageData, at the texture's own size.
local function readback(surf, lw, lh)
  local tmp = love.image.newImageData(surf.w, surf.h)
  M.m2d_surface_download_rgba(surf, ffi.cast("uint8_t*", tmp:getFFIPointer()))
  local w, h = max(1, floor(lw + 0.5)), max(1, floor(lh + 0.5))
  if w == surf.w and h == surf.h then return tmp end
  local out = love.image.newImageData(w, h)
  out:mapPixel(function(x, y)
    return tmp:getPixel(min(surf.w - 1, floor(x * surf.w / w)), min(surf.h - 1, floor(y * surf.h / h)))
  end)
  tmp:release()
  return out
end

function Canvas:newImageData(slice, mip, x, y, w, h)
  local d = readback(self.surf, self.lw, self.lh)
  if x then
    local part = love.image.newImageData(w, h)
    part:paste(d, 0, 0, x, y, w, h)
    d:release()
    return part
  end
  return d
end
Image.newImageData = Canvas.newImageData
Canvas.generateMipmaps = function() end
function G.readbackTexture(tex) return tex:newImageData() end

---------------------------------------------------------------------------
-- Quad
---------------------------------------------------------------------------
local Quad = makeType("Quad")
function G.newQuad(x, y, w, h, sw, sh)
  if type(sw) == "table" then sw, sh = sw:getDimensions() end
  return setmetatable({ x = x, y = y, w = w, h = h, sw = sw or w, sh = sh or h }, Quad)
end
function Quad:getViewport() return self.x, self.y, self.w, self.h end
function Quad:setViewport(x, y, w, h, sw, sh)
  self.x, self.y, self.w, self.h = x, y, w, h
  if sw then self.sw, self.sh = sw, sh end
end
function Quad:getTextureDimensions() return self.sw, self.sh end
function Quad:setLayer() end
function Quad:getLayer() return 1 end

---------------------------------------------------------------------------
-- drawing textures
---------------------------------------------------------------------------
local affine = ffi.new("float[6]")

-- The local transform of a draw (LOVE's x, y, r, sx, sy, ox, oy, kx, ky): a 2x3
-- matrix a, b, c, d, e, f.
local function localMatrix(x, y, r, sx, sy, ox, oy, kx, ky)
  x, y, r = x or 0, y or 0, r or 0
  sx = sx or 1; sy = sy or sx
  ox, oy, kx, ky = ox or 0, oy or 0, kx or 0, ky or 0
  local c, s = 1, 0
  if r ~= 0 then c, s = cos(r), sin(r) end
  -- T(x,y) R(r) S(sx,sy) K(kx,ky) T(-ox,-oy)
  local a = c * sx - s * sy * ky
  local b = s * sx + c * sy * ky
  local cc = c * sx * kx - s * sy
  local d = s * sx * kx + c * sy
  return a, b, cc, d, x - (a * ox + cc * oy), y - (b * ox + d * oy)
end

-- a 2x3 matrix (a, b, c, d, e, f) after the current pixel map
local function compose(a, b, c, d, e, f)
  local A, B, C, D, E, F = pixmat()
  return A * a + C * b, B * a + D * b, A * c + C * d, B * c + D * d, A * e + C * f + E, B * e + D * f + F
end

local function scaledCopy(tex, surf, dw, dh, spx, spy, spw, sph)
  if tex.__isCanvas or tex.noScaleCache then return nil end
  local kx, ky = dw / spw, dh / sph
  if kx <= 0.05 or kx >= 8 or ky <= 0.05 or ky >= 8 then return nil end
  local key = floor(kx * 512 + 0.5) * 65536 + floor(ky * 512 + 0.5)
  local cache = tex.scaled
  if not cache then cache = { n = 0 }; tex.scaled = cache end
  local sc = cache[key]
  if not sc then
    if cache.n >= 6 then
      tex.noScaleCache = true -- scaled to ever new sizes (an animation): stop caching
      return nil
    end
    sc = newSurface(max(1, floor(surf.w * kx + 0.5)), max(1, floor(surf.h * ky + 0.5)))
    M.m2d_surface_resample(sc, surf)
    M.m2d_surface_build_spans(sc)
    cache[key] = sc
    cache.n = cache.n + 1
  end
  return sc, kx, ky
end

-- The pixel matrix of the draw under way (game matrix composed with the current
-- transform and the target's map). Kept here, not passed: on 32-bit ARM, six numbers
-- returned and passed through several calls are too much for LuaJIT's compiler
-- ("register coalescing too complex"), and the draw path falls back to the interpreter.
local PA, PB, PC, PD, PE, PF = 1, 0, 0, 1, 0, 0

local drawTexturePx

-- Draw texture `tex` (part q, or all) through the 2x3 local matrix.
local function drawTextureM(tex, q, la, lb, lc, ld, le, lf, colorTint)
  local kx, ky = target.kx, target.ky
  local A, B, C, D = kx * ta, ky * tb, kx * tc, ky * td
  PA, PB, PC, PD = A * la + C * lb, B * la + D * lb, A * lc + C * ld, B * lc + D * ld
  PE, PF = A * le + C * lf + kx * te + target.ox, B * le + D * lf + ky * tf + target.oy
  return drawTexturePx(tex, q, colorTint)
end

local Shaders = require("lovemini.shaders")

-- `tex` as a shader's stand-in effect makes it: a copy kept with the texture (made
-- again each time for a canvas, whose pixels change)
local function effectTexture(tex, effect)
  local fx = tex.fx
  if not fx then fx = {}; tex.fx = fx end
  local e = fx[effect]
  if e and not tex.__isCanvas then return e end
  local src = tex.surf
  if not e then
    e = { surf = newSurface(src.w, src.h), lw = tex.lw, lh = tex.lh, dpiscale = tex.dpiscale,
      __isCanvas = tex.__isCanvas, noScaleCache = tex.__isCanvas }
    fx[effect] = e
  end
  M.m2d_surface_effect(e.surf, src, Shaders.EFFECTS[effect])
  if not tex.__isCanvas then M.m2d_surface_build_spans(e.surf) end
  return e
end

-- Draw texture `tex` (part q, or all) through PA..PF.
function drawTexturePx(tex, q, colorTint)
  -- off the target (or the scissor): nothing to do
  do
    local w, h
    if q then w, h = q.w, q.h else w, h = tex.lw, tex.lh end
    local ax, cx, by, dy = PA * w, PC * h, PB * w, PD * h
    local x0, x1 = PE, PE
    if ax < 0 then x0 = x0 + ax else x1 = x1 + ax end
    if cx < 0 then x0 = x0 + cx else x1 = x1 + cx end
    if x1 <= cullX0 or x0 >= cullX1 then return end
    local y0, y1 = PF, PF
    if by < 0 then y0 = y0 + by else y1 = y1 + by end
    if dy < 0 then y0 = y0 + dy else y1 = y1 + dy end
    if y1 <= cullY0 or y0 >= cullY1 then return end
  end
  local surf = tex.surf
  if not surf then surf = reloadImage(tex) end
  tex.used = frameNo
  if shader then
    shader.drawn = true
    local effect = shader.effect
    if effect then
      tex = effectTexture(tex, effect)
      surf = tex.surf
      if shader.solidTint then colorTint = shader.solidTint end
    end
  end
  local tnt = colorTint or tint
  local qw, qh, spx, spy, spw, sph
  local fx, fy -- source pixels per logical unit
  if q then
    fx, fy = surf.w / q.sw, surf.h / q.sh
    spx, spy = floor(q.x * fx + 0.5), floor(q.y * fy + 0.5)
    spw = max(1, floor((q.x + q.w) * fx + 0.5) - spx)
    sph = max(1, floor((q.y + q.h) * fy + 0.5) - spy)
    qw, qh = q.w, q.h
  else
    fx, fy = surf.w / tex.lw, surf.h / tex.lh
    spx, spy, spw, sph = 0, 0, surf.w, surf.h
    qw, qh = tex.lw, tex.lh
  end
  local a, b, c, d, e, f = PA, PB, PC, PD, PE, PF
  stats.drawcalls = stats.drawcalls + 1
  if shader then G._report.shaders[shader] = (G._report.shaders[shader] or 0) + 1 end

  local bl = blend
  if tex.opaque and bl == 1 and tnt == NOTINT then bl = 0 end

  if abs(b) < 1e-6 and abs(c) < 1e-6 then
    -- a rectangle: the corners (0,0) and (qw,qh)
    local px0, py0 = e, f
    local px1, py1 = a * qw + e, d * qh + f
    local flip = 0
    if px1 < px0 then px0, px1 = px1, px0; flip = flip + 1 end
    if py1 < py0 then py0, py1 = py1, py0; flip = flip + 2 end
    local dx, dy = floor(px0 + 0.5), floor(py0 + 0.5)
    local dw, dh = floor(px1 + 0.5) - dx, floor(py1 + 0.5) - dy
    if dw <= 0 or dh <= 0 then return end
    -- off by one from rounding: 1:1 instead of rescaling
    if dw ~= spw and (dw - spw == 1 or spw - dw == 1) then dw = spw end
    if dh ~= sph and (dh - sph == 1 or sph - dh == 1) then dh = sph end
    if dw ~= spw or dh ~= sph then
      local sc, kx, ky = scaledCopy(tex, surf, dw, dh, spx, spy, spw, sph)
      if sc then
        surf = sc
        spx, spy = floor(spx * kx + 0.5), floor(spy * ky + 0.5)
        spw, sph = dw, dh
        if spx + spw > sc.w then spx = max(0, sc.w - spw) end
        if spy + sph > sc.h then spy = max(0, sc.h - sph) end
      end
    end
    M.m2d_blit(surf, spx, spy, spw, sph, target.surf, dx, dy, dw, dh, tnt, bl, flip)
    return
  end
  -- rotated or sheared: source pixel (u, v) -> logical (u/fx, v/fy) -> pixels
  affine[0], affine[1], affine[2] = a / fx, c / fy, e
  affine[3], affine[4], affine[5] = b / fx, d / fy, f
  M.m2d_blit_affine(surf, spx, spy, spw, sph, target.surf, affine, tnt, bl)
end

local function drawTexture(tex, q, x, y, r, sx, sy, ox, oy, kx, ky)
  drawTextureM(tex, q, localMatrix(x, y, r, sx, sy, ox, oy, kx, ky))
end

---------------------------------------------------------------------------
-- Fonts
---------------------------------------------------------------------------
local Font = makeType("Font")
local PAGE = 256

-- Fonts are rasterised at the screen's scale: crisp where they end up.
local function fontScale() return max(0.25, storeScale) end

local function newFontFrom(rast, size, dpiscale)
  local f = setmetatable({}, Font)
  f.rast = rast
  f.size = size
  f.px = rast:getHeight()
  f.fs = fontScale()        -- pixels per logical unit
  f.dpiscale = dpiscale or 1
  f.glyphs = {}
  f.pages = {}
  f.penX, f.penY, f.rowH = PAGE, PAGE, 0 -- forces a new page on the first glyph
  f.lineHeight = 1
  f.height = rast:getHeight() / f.fs
  f.ascent = rast:getAscent() / f.fs
  f.descent = rast:getDescent() / f.fs
  f.baseline = f.ascent
  f.fallbacks = {}
  f.widthCache, f.widthCacheN = {}, 0
  f.wrapCache, f.wrapCacheN = {}, 0
  stats.fonts = stats.fonts + 1
  return f
end

function G.newFont(a, b, c, d)
  -- newFont(size) | newFont(size, hinting, dpiscale) | newFont(path|FileData|Rasterizer, size, hinting, dpiscale)
  if isObject(a, "Rasterizer") then
    return newFontFrom(a, a:getHeight(), b)
  end
  local src, size, hinting, dpiscale
  if type(a) == "number" or a == nil then
    size, hinting, dpiscale = a or 12, b, c
  else
    src, size, hinting, dpiscale = a, b or 12, c, d
  end
  local px = max(5, floor(size * fontScale() + 0.5))
  local ok, rast
  if src then
    ok, rast = pcall(love.font.newRasterizer, src, px, hinting or "normal")
    if not ok then
      -- an image font (glyphs in a picture) or a bad file
      ok, rast = pcall(love.font.newRasterizer, src)
      if not ok then
        print("love-mini: font " .. tostring(src) .. ": " .. tostring(rast) .. "; the default one instead")
        rast = love.font.newRasterizer(px, hinting or "normal")
      end
    end
  else
    rast = love.font.newRasterizer(px, hinting or "normal")
  end
  return newFontFrom(rast, size, dpiscale)
end

function G.newImageFont(src, glyphs, extraspacing)
  local rast = love.font.newImageRasterizer(type(src) == "string" and love.image.newImageData(src) or src, glyphs,
    extraspacing or 0)
  local f = newFontFrom(rast, rast:getHeight(), 1)
  -- an image font keeps its own pixels: one font pixel is one logical unit
  f.fs = 1
  f.height, f.ascent, f.descent = rast:getHeight(), rast:getAscent(), rast:getDescent()
  f.baseline = f.ascent
  return f
end

function G.setNewFont(...)
  local f = G.newFont(...)
  G.setFont(f)
  return f
end

local function newPage(f)
  local p = newSurface(PAGE, PAGE)
  f.pages[#f.pages + 1] = p
  f.penX, f.penY, f.rowH = 0, 0, 0
  return p
end

local function getGlyph(f, cp)
  local g = f.glyphs[cp]
  if g then return g end
  local rast = f.rast
  if not rast:hasGlyphs(cp) then
    for _, fb in ipairs(f.fallbacks) do
      if fb.rast:hasGlyphs(cp) then rast = fb.rast; break end
    end
  end
  local ok, gd = pcall(rast.getGlyphData, rast, cp)
  if not ok then
    g = { w = 0, h = 0, adv = f.px * 0.5 }
    f.glyphs[cp] = g
    return g
  end
  local gw, gh = gd:getDimensions()
  local bx, by = gd:getBearing()
  g = { w = gw, h = gh, bx = bx, by = by, adv = gd:getAdvance() }
  if gw > 0 and gh > 0 then
    if gw > PAGE or gh > PAGE then gw, gh = min(gw, PAGE), min(gh, PAGE) end
    if f.penX + gw > PAGE then
      f.penX = 0; f.penY = f.penY + f.rowH + 1; f.rowH = 0
    end
    if #f.pages == 0 or f.penY + gh > PAGE then newPage(f) end
    local page = f.pages[#f.pages]
    local fmt = gd:getFormat()
    if fmt == "la8" then
      M.m2d_surface_upload_la8(page, ffi.cast("const uint8_t*", gd:getFFIPointer()), f.penX, f.penY, gw, gh)
    else
      -- rgba8 (image fonts): through a view of the page
      local view = M.m2d_surface_view(page, f.penX, f.penY, gw, gh)
      M.m2d_surface_upload_rgba(view, ffi.cast("const uint8_t*", gd:getFFIPointer()), gw, gh)
      M.m2d_surface_view_free(view)
    end
    g.page, g.x, g.y = page, f.penX, f.penY
    f.penX = f.penX + gw + 1
    f.rowH = max(f.rowH, gh)
  end
  gd:release()
  f.glyphs[cp] = g
  return g
end

local byte = string.byte
local function asciiIter(s, i)
  i = i + 1
  local b = byte(s, i)
  if b then return i, b end
end
local function codepoints(s)
  if not s:find("[\128-\255]") then return asciiIter, s, 0 end
  if utf8.len(s) then return utf8.codes(s) end
  local i = 0 -- invalid UTF-8: bytes
  return function()
    i = i + 1
    if i <= #s then return i, s:byte(i) end
  end
end

function Font:getWidth(s)
  s = tostring(s)
  local wc = self.widthCache
  local cached = wc[s]
  if cached then return cached end
  if self.widthCacheN > 1024 then wc = {}; self.widthCache = wc; self.widthCacheN = 0 end
  local w, best = 0, 0
  for _, cp in codepoints(s) do
    if cp == 10 then best = max(best, w); w = 0
    else w = w + getGlyph(self, cp).adv end
  end
  local result = max(best, w) / self.fs
  wc[s] = result
  self.widthCacheN = self.widthCacheN + 1
  return result
end
function Font:getHeight() return self.height end
function Font:getLineHeight() return self.lineHeight end
function Font:setLineHeight(h) self.lineHeight = h end
function Font:getAscent() return self.ascent end
function Font:getDescent() return self.descent end
function Font:getBaseline() return self.baseline end
function Font:getDPIScale() return self.dpiscale end
function Font:setFilter() end
function Font:getFilter() return "linear", "linear", 1 end
function Font:hasGlyphs(...) return self.rast:hasGlyphs(...) end
function Font:getKerning() return 0 end
function Font:setFallbacks(...) self.fallbacks = { ... } end

local function plainText(text)
  if type(text) ~= "table" then return tostring(text) end
  local parts = {}
  for i = 1, #text do
    local v = text[i]
    if type(v) == "string" or type(v) == "number" then parts[#parts + 1] = tostring(v) end
  end
  return table.concat(parts)
end

-- greedy word wrap; returns maxWidth, lines
local function wrapUncached(self, text, limit)
  text = plainText(text)
  local lines, maxW = {}, 0
  for para in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line, lineW = "", 0
    local spaceW = self:getWidth(" ")
    for word, spaces in para:gmatch("(%S*)(%s*)") do
      if word == "" and spaces == "" then break end
      local wordW = self:getWidth(word)
      if line ~= "" and lineW + wordW > limit then
        lines[#lines + 1] = line
        maxW = max(maxW, lineW)
        line, lineW = "", 0
      end
      if wordW > limit and line == "" then
        -- an over-long word: broken by characters
        local chunk, chunkW = "", 0
        for _, cp in codepoints(word) do
          local ch = utf8.char(cp)
          local cw = self:getWidth(ch)
          if chunkW + cw > limit and chunk ~= "" then
            lines[#lines + 1] = chunk
            maxW = max(maxW, chunkW)
            chunk, chunkW = "", 0
          end
          chunk, chunkW = chunk .. ch, chunkW + cw
        end
        line, lineW = chunk, chunkW
      else
        line, lineW = line .. word, lineW + wordW
      end
      if spaces ~= "" then line, lineW = line .. spaces, lineW + #spaces * spaceW end
    end
    local trimmed = line:gsub("%s+$", "")
    lineW = self:getWidth(trimmed)
    lines[#lines + 1] = trimmed
    maxW = max(maxW, lineW)
  end
  return maxW, lines
end

function Font:getWrap(text, limit)
  if type(text) ~= "string" then return wrapUncached(self, text, limit) end
  local key = text .. "\0" .. limit
  local c = self.wrapCache[key]
  if not c then
    if self.wrapCacheN > 256 then self.wrapCache = {}; self.wrapCacheN = 0 end
    local w, lines = wrapUncached(self, text, limit)
    c = { w, lines }
    self.wrapCache[key] = c
    self.wrapCacheN = self.wrapCacheN + 1
  end
  local lines = {}
  for i = 1, #c[2] do lines[i] = c[2][i] end
  return c[1], lines
end

-- coloured text {c1, s1, c2, s2, ...} as segments
local function segments(text)
  if type(text) ~= "table" then return { { nil, tostring(text) } } end
  local segs = {}
  for i = 1, #text, 2 do
    local c, s = text[i], text[i + 1]
    if type(c) == "string" or type(c) == "number" then
      segs[#segs + 1] = { nil, tostring(c) }
      if s then segs[#segs + 1] = { nil, tostring(s) } end
    else
      segs[#segs + 1] = { c, tostring(s or "") }
    end
  end
  return segs
end

local glyphQuad = setmetatable({ x = 0, y = 0, w = 0, h = 0, sw = 1, sh = 1 }, Quad)
-- one stand-in texture for every glyph page: never through the scale cache
local glyphTex = { lw = 1, lh = 1, noScaleCache = true }

-- glyphs of string s from pen (font pixels) on baseline baseY (font pixels), through
-- the 2x3 matrix (font logical units -> game units)
local function drawGlyphRun(f, s, pen, baseY, la, lb, lc, ld, le, lf, colorTint)
  local fs = f.fs
  for _, cp in codepoints(s) do
    local g = getGlyph(f, cp)
    if g.page then
      local gx, gy = (pen + g.bx) / fs, (baseY - g.by) / fs
      glyphQuad.x, glyphQuad.y, glyphQuad.w, glyphQuad.h = g.x / fs, g.y / fs, g.w / fs, g.h / fs
      glyphQuad.sw, glyphQuad.sh = PAGE / fs, PAGE / fs
      glyphTex.surf = g.page
      drawTextureM(glyphTex, glyphQuad, la, lb, lc, ld, la * gx + lc * gy + le, lb * gx + ld * gy + lf, colorTint)
    end
    pen = pen + g.adv
  end
  return pen
end

local function tintFor(c)
  if not c then return tint end
  local r, g, b, a = c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1
  return premulColor(r * cr, g * cg, b * cb, a * ca)
end

local function drawText(f, text, limit, align, la, lb, lc, ld, le, lf)
  f = f or G.getFont()
  local fs = f.fs
  local lineStep = f.height * f.lineHeight * fs -- in font pixels
  local ascentPx = f.ascent * fs
  local segs = segments(text)
  if not limit then
    local pen, lineNo = 0, 0
    for _, seg in ipairs(segs) do
      local ct = tintFor(seg[1])
      local first = true
      for part in (seg[2] .. "\n"):gmatch("(.-)\n") do
        if not first then lineNo = lineNo + 1; pen = 0 end
        first = false
        pen = drawGlyphRun(f, part, pen, lineNo * lineStep + ascentPx, la, lb, lc, ld, le, lf, ct)
      end
    end
    return
  end
  local _, lines = f:getWrap(plainText(text), limit)
  local ct = tintFor(segs[1] and segs[1][1])
  for i, line in ipairs(lines) do
    local w = f:getWidth(line)
    local offset = 0
    if align == "center" then offset = (limit - w) / 2
    elseif align == "right" then offset = limit - w end
    drawGlyphRun(f, line, offset * fs, (i - 1) * lineStep + ascentPx, la, lb, lc, ld, le, lf, ct)
  end
end

local function isTransform(v) return type(v) == "userdata" and v.typeOf and v:typeOf("Transform") end

-- a Transform object's 2D part
local function transformMatrix(t)
  local e11, e12, _, e14, e21, e22, _, e24 = t:getMatrix()
  return e11, e21, e12, e22, e14, e24
end

-- print(text, [font,] x, y, ...) and print(text, [font,] transform)
function G.print(text, x, ...)
  stats.drawcalls = stats.drawcalls + 1
  local font = curFont
  if getmetatable(x) == Font then return G._printWith(x, text, ...) end
  return G._printWith(font, text, x, ...)
end
function G._printWith(font, text, x, ...)
  if isTransform(x) then return drawText(font, text, nil, nil, transformMatrix(x)) end
  local y, r, sx, sy, ox, oy, kx, ky = ...
  drawText(font, text, nil, nil, localMatrix(x, y, r, sx, sy, ox, oy, kx, ky))
end

-- printf(text, [font,] x, y, limit, align, ...) and printf(text, [font,] transform, limit, align)
function G.printf(text, x, ...)
  stats.drawcalls = stats.drawcalls + 1
  if getmetatable(x) == Font then return G._printfWith(x, text, ...) end
  return G._printfWith(curFont, text, x, ...)
end
function G._printfWith(font, text, x, ...)
  if isTransform(x) then
    local limit, align = ...
    return drawText(font, text, limit or 1e9, align or "left", transformMatrix(x))
  end
  local y, limit, align, r, sx, sy, ox, oy, kx, ky = ...
  drawText(font, text, limit or 1e9, align or "left", localMatrix(x, y, r, sx, sy, ox, oy, kx, ky))
end

---------------------------------------------------------------------------
-- Text objects
---------------------------------------------------------------------------
local Text = makeType("Text", { "Drawable", "TextBatch" })
function G.newText(font, text)
  local t = setmetatable({ font = font or G.getFont(), items = {} }, Text)
  if text then t:set(text) end
  return t
end
G.newTextBatch = G.newText
function Text:set(text) self.items = { { text = text, x = 0, y = 0 } } end
function Text:setf(text, limit, align) self.items = { { text = text, x = 0, y = 0, limit = limit, align = align } } end
function Text:add(text, x, y) self.items[#self.items + 1] = { text = text, x = x or 0, y = y or 0 }; return #self.items end
function Text:addf(text, limit, align, x, y)
  self.items[#self.items + 1] = { text = text, x = x or 0, y = y or 0, limit = limit, align = align }
  return #self.items
end
function Text:clear() self.items = {} end
function Text:setFont(f) self.font = f end
function Text:getFont() return self.font end
function Text:getDimensions(index)
  local w, h = 0, 0
  for i, it in ipairs(self.items) do
    if not index or index == i then
      local iw, n
      if it.limit then
        local lines
        iw, lines = self.font:getWrap(it.text, it.limit)
        if it.align == "center" or it.align == "right" then iw = it.limit end
        n = #lines
      else
        local plain = plainText(it.text)
        iw = self.font:getWidth(plain)
        n = 1
        for _ in plain:gmatch("\n") do n = n + 1 end
      end
      w = max(w, it.x + iw)
      h = max(h, it.y + n * self.font:getHeight() * self.font:getLineHeight())
    end
  end
  return w, h
end
function Text:getWidth(i) return (self:getDimensions(i)) end
function Text:getHeight(i) local _, h = self:getDimensions(i); return h end

local function drawTextObject(t, la, lb, lc, ld, le, lf)
  for _, it in ipairs(t.items) do
    drawText(t.font, it.text, it.limit, it.align, la, lb, lc, ld, la * it.x + lc * it.y + le, lb * it.x + ld * it.y + lf)
  end
end

---------------------------------------------------------------------------
-- SpriteBatch
---------------------------------------------------------------------------
local SpriteBatch = makeType("SpriteBatch", { "Drawable" })
function G.newSpriteBatch(texture, size, usage)
  return setmetatable({ texture = texture, items = {}, n = 0 }, SpriteBatch)
end
local setItem
function SpriteBatch:add(q, ...)
  self.n = self.n + 1
  if type(q) == "table" and getmetatable(q) == Quad then return setItem(self, self.n, q, ...) end
  return setItem(self, self.n, nil, q, ...)
end
function SpriteBatch:set(id, q, ...)
  if type(q) == "table" and getmetatable(q) == Quad then return setItem(self, id, q, ...) end
  return setItem(self, id, nil, q, ...)
end
-- q: a Quad or nil (the whole texture); the rest: x, y, r, … or a Transform
function setItem(self, id, q, ...)
  local it = self.items[id]
  if not it then it = {}; self.items[id] = it end
  -- like LOVE, the quad's viewport as it is now: games reuse one quad between adds
  if q then
    local cq = it.cq
    if not cq then cq = setmetatable({}, Quad); it.cq = cq end
    cq.x, cq.y, cq.w, cq.h, cq.sw, cq.sh = q.x, q.y, q.w, q.h, q.sw, q.sh
    it.q = cq
  else
    it.q = nil
  end
  local x = ...
  if isTransform(x) then
    it.a, it.b, it.c, it.d, it.e, it.f = transformMatrix(x)
  else
    it.a, it.b, it.c, it.d, it.e, it.f = localMatrix(...)
  end
  it.color = self.color
  if id > self.n then self.n = id end
  return id
end
function SpriteBatch:addLayer(...) unsupported("SpriteBatch:addLayer"); return self:add(...) end
function SpriteBatch:clear() self.n = 0 end
function SpriteBatch:flush() end
function SpriteBatch:setColor(r, g, b, a)
  if r == nil then self.color = nil; return end
  if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
  self.color = { r, g, b, a or 1 }
end
function SpriteBatch:getColor() if self.color then return unpack(self.color) end return 1, 1, 1, 1 end
function SpriteBatch:getCount() return self.n end
function SpriteBatch:getBufferSize() return max(self.n, 1000) end
function SpriteBatch:getTexture() return self.texture end
function SpriteBatch:setTexture(t) self.texture = t end
function SpriteBatch:setDrawRange(i, n) self.range = i and { i, n } or nil end
function SpriteBatch:getDrawRange() if self.range then return self.range[1], self.range[2] end end
function SpriteBatch:attachAttribute() unsupported("SpriteBatch:attachAttribute") end

local function mul(a1, b1, c1, d1, e1, f1, a2, b2, c2, d2, e2, f2)
  return a1 * a2 + c1 * b2, b1 * a2 + d1 * b2, a1 * c2 + c1 * d2, b1 * c2 + d1 * d2,
    a1 * e2 + c1 * f2 + e1, b1 * e2 + d1 * f2 + f1
end

local function drawSpriteBatch(sb, la, lb, lc, ld, le, lf)
  local tex = sb.texture
  local first, last = 1, sb.n
  if sb.range then first, last = sb.range[1], min(sb.n, sb.range[1] + sb.range[2] - 1) end
  for i = first, last do
    local it = sb.items[i]
    local ct = tint
    if it.color then ct = premulColor(it.color[1] * cr, it.color[2] * cg, it.color[3] * cb, it.color[4] * ca) end
    if ct == 0xffffffff then ct = NOTINT end
    local a, b, c, d, e, f = mul(la, lb, lc, ld, le, lf, it.a, it.b, it.c, it.d, it.e, it.f)
    drawTextureM(tex, it.q, a, b, c, d, e, f, ct)
  end
end

---------------------------------------------------------------------------
-- Mesh (textured or coloured triangles, drawn as polygons and affine blits)
---------------------------------------------------------------------------
local Mesh = makeType("Mesh", { "Drawable" })
function G.newMesh(a, b, c, d)
  -- newMesh(vertices, mode, usage) | newMesh(count, mode, usage) | newMesh(format, vertices|count, mode, usage)
  local verts, mode
  if type(a) == "table" and type(a[1]) == "table" and type(a[1][1]) == "string" then
    verts, mode = b, c -- custom vertex format: positions first, as LOVE's default order
  else
    verts, mode = a, b
  end
  local m = setmetatable({ vertices = {}, mode = mode or "fan" }, Mesh)
  if type(verts) == "number" then
    for i = 1, verts do m.vertices[i] = { 0, 0, 0, 0, 1, 1, 1, 1 } end
  else
    for i, v in ipairs(verts or {}) do m.vertices[i] = { v[1], v[2], v[3] or 0, v[4] or 0, v[5] or 1, v[6] or 1, v[7] or 1, v[8] or 1 } end
  end
  unsupported("newMesh (drawn flat-coloured)")
  return m
end
function Mesh:setTexture(t) self.texture = t end
function Mesh:getTexture() return self.texture end
function Mesh:setVertex(i, x, y, u, v, r, g, b, a)
  if type(x) == "table" then x, y, u, v, r, g, b, a = unpack(x) end
  self.vertices[i] = { x, y, u or 0, v or 0, r or 1, g or 1, b or 1, a or 1 }
end
function Mesh:getVertex(i) return unpack(self.vertices[i]) end
function Mesh:setVertices(vs, start)
  start = start or 1
  for i, v in ipairs(vs) do self.vertices[start + i - 1] = { v[1], v[2], v[3] or 0, v[4] or 0, v[5] or 1, v[6] or 1, v[7] or 1, v[8] or 1 } end
end
function Mesh:getVertexCount() return #self.vertices end
function Mesh:setVertexMap(...) local m = ...; if type(m) ~= "table" then m = { ... } end; self.map = m end
function Mesh:getVertexMap() return self.map end
function Mesh:setDrawMode(m) self.mode = m end
function Mesh:getDrawMode() return self.mode end
function Mesh:setDrawRange(i, n) self.range = i and { i, n } or nil end
function Mesh:getDrawRange() if self.range then return self.range[1], self.range[2] end end
function Mesh:setAttributeEnabled() end
function Mesh:isAttributeEnabled() return true end
function Mesh:attachAttribute() end
function Mesh:getVertexFormat() return { { "VertexPosition", "float", 2 }, { "VertexTexCoord", "float", 2 }, { "VertexColor", "byte", 4 } } end
function Mesh:flush() end

local polyBuf = ffi.new("float[?]", 512)
local function fillPixelPolygon(pts, n, color)
  if n * 2 > 512 then polyBuf = ffi.new("float[?]", n * 2) end
  for i = 1, n * 2 do polyBuf[i - 1] = pts[i] end
  M.m2d_polygon(target.surf, polyBuf, n, color, blend)
end

local function drawMesh(m, la, lb, lc, ld, le, lf)
  local idx = {}
  local map = m.map
  local count = map and #map or #m.vertices
  for i = 1, count do idx[i] = map and map[i] or i end
  local tris = {}
  if m.mode == "triangles" then
    for i = 1, count - 2, 3 do tris[#tris + 1] = { idx[i], idx[i + 1], idx[i + 2] } end
  elseif m.mode == "strip" then
    for i = 1, count - 2 do tris[#tris + 1] = { idx[i], idx[i + 1], idx[i + 2] } end
  elseif m.mode == "points" then
    unsupported("Mesh points")
    return
  else -- fan
    for i = 2, count - 1 do tris[#tris + 1] = { idx[1], idx[i], idx[i + 1] } end
  end
  local a, b, c, d, e, f = compose(la, lb, lc, ld, le, lf)
  for _, t in ipairs(tris) do
    local p, r, g, bb, aa = {}, 0, 0, 0, 0
    for k = 1, 3 do
      local v = m.vertices[t[k]]
      p[#p + 1] = a * v[1] + c * v[2] + e
      p[#p + 1] = b * v[1] + d * v[2] + f
      r, g, bb, aa = r + v[5], g + v[6], bb + v[7], aa + v[8]
    end
    -- flat: the vertices' average colour (texture not sampled yet)
    fillPixelPolygon(p, 3, premulColor(r / 3 * cr, g / 3 * cg, bb / 3 * cb, aa / 3 * ca))
  end
end

---------------------------------------------------------------------------
-- ParticleSystem (LOVE's emitter, simulated here and drawn as sprites)
---------------------------------------------------------------------------
local ParticleSystem = makeType("ParticleSystem", { "Drawable" })

function G.newParticleSystem(texture, buffer)
  local ps = setmetatable({
    texture = texture, buffer = buffer or 1000, particles = {}, active = true, paused = false,
    emissionRate = 0, emitAcc = 0, lifetime = -1, life = -1, pLifeMin = 0, pLifeMax = 0,
    x = 0, y = 0, direction = 0, spread = 0, speedMin = 0, speedMax = 0,
    lax = 0, lay = 0, uax = 0, uay = 0, radialMin = 0, radialMax = 0, tangMin = 0, tangMax = 0,
    dampMin = 0, dampMax = 0, sizes = { 1 }, sizeVar = 0, rotMin = 0, rotMax = 0, spinMin = 0, spinMax = 0, spinVar = 0,
    colors = { { 1, 1, 1, 1 } }, quads = nil, offsetX = nil, offsetY = nil, relativeRotation = false,
    areaDist = "none", areaDx = 0, areaDy = 0, areaAngle = 0, insertMode = "top",
  }, ParticleSystem)
  return ps
end

local function rnd(a, b) return a + (b - a) * love.math.random() end

function ParticleSystem:clone()
  local c = setmetatable({}, ParticleSystem)
  for k, v in pairs(self) do c[k] = v end
  c.particles = {}
  return c
end
function ParticleSystem:setEmissionRate(r) self.emissionRate = r end
function ParticleSystem:getEmissionRate() return self.emissionRate end
function ParticleSystem:setEmitterLifetime(t) self.lifetime = t; self.life = t end
function ParticleSystem:getEmitterLifetime() return self.lifetime end
function ParticleSystem:setParticleLifetime(a, b) self.pLifeMin, self.pLifeMax = a, b or a end
function ParticleSystem:getParticleLifetime() return self.pLifeMin, self.pLifeMax end
function ParticleSystem:setPosition(x, y) self.x, self.y = x, y end
function ParticleSystem:getPosition() return self.x, self.y end
function ParticleSystem:moveTo(x, y) self.x, self.y = x, y end
function ParticleSystem:setDirection(d) self.direction = d end
function ParticleSystem:getDirection() return self.direction end
function ParticleSystem:setSpread(s) self.spread = s end
function ParticleSystem:getSpread() return self.spread end
function ParticleSystem:setSpeed(a, b) self.speedMin, self.speedMax = a, b or a end
function ParticleSystem:getSpeed() return self.speedMin, self.speedMax end
function ParticleSystem:setLinearAcceleration(xmin, ymin, xmax, ymax)
  self.lax, self.lay, self.uax, self.uay = xmin or 0, ymin or 0, xmax or xmin or 0, ymax or ymin or 0
end
function ParticleSystem:getLinearAcceleration() return self.lax, self.lay, self.uax, self.uay end
function ParticleSystem:setRadialAcceleration(a, b) self.radialMin, self.radialMax = a, b or a end
function ParticleSystem:getRadialAcceleration() return self.radialMin, self.radialMax end
function ParticleSystem:setTangentialAcceleration(a, b) self.tangMin, self.tangMax = a, b or a end
function ParticleSystem:getTangentialAcceleration() return self.tangMin, self.tangMax end
function ParticleSystem:setLinearDamping(a, b) self.dampMin, self.dampMax = a, b or a end
function ParticleSystem:getLinearDamping() return self.dampMin, self.dampMax end
function ParticleSystem:setSizes(...) self.sizes = { ... } end
function ParticleSystem:getSizes() return unpack(self.sizes) end
function ParticleSystem:setSizeVariation(v) self.sizeVar = v end
function ParticleSystem:getSizeVariation() return self.sizeVar end
function ParticleSystem:setRotation(a, b) self.rotMin, self.rotMax = a, b or a end
function ParticleSystem:getRotation() return self.rotMin, self.rotMax end
function ParticleSystem:setSpin(a, b) self.spinMin, self.spinMax = a, b or a end
function ParticleSystem:getSpin() return self.spinMin, self.spinMax end
function ParticleSystem:setSpinVariation(v) self.spinVar = v end
function ParticleSystem:setRelativeRotation(r) self.relativeRotation = r end
function ParticleSystem:hasRelativeRotation() return self.relativeRotation end
function ParticleSystem:setColors(...)
  local args, cols = { ... }, {}
  if type(args[1]) == "table" then
    for i, c in ipairs(args) do cols[i] = { c[1], c[2], c[3], c[4] or 1 } end
  else
    for i = 1, #args, 4 do cols[#cols + 1] = { args[i], args[i + 1], args[i + 2], args[i + 3] or 1 } end
  end
  self.colors = cols
end
function ParticleSystem:getColors() local out = {}; for i, c in ipairs(self.colors) do out[i] = { unpack(c) } end; return unpack(out) end
function ParticleSystem:setQuads(...)
  local q = { ... }
  if type(q[1]) == "table" and getmetatable(q[1]) ~= Quad then q = q[1] end
  self.quads = #q > 0 and q or nil
end
function ParticleSystem:getQuads() return self.quads or {} end
function ParticleSystem:setOffset(x, y) self.offsetX, self.offsetY = x, y end
function ParticleSystem:getOffset() return self.offsetX, self.offsetY end
function ParticleSystem:setTexture(t) self.texture = t end
function ParticleSystem:getTexture() return self.texture end
function ParticleSystem:setBufferSize(n) self.buffer = n end
function ParticleSystem:getBufferSize() return self.buffer end
function ParticleSystem:setInsertMode(m) self.insertMode = m end
function ParticleSystem:getInsertMode() return self.insertMode end
function ParticleSystem:setEmissionArea(dist, dx, dy, angle)
  self.areaDist, self.areaDx, self.areaDy, self.areaAngle = dist or "none", dx or 0, dy or 0, angle or 0
end
ParticleSystem.setAreaSpread = function(self, dist, dx, dy) self:setEmissionArea(dist, dx, dy) end
function ParticleSystem:getEmissionArea() return self.areaDist, self.areaDx, self.areaDy, self.areaAngle end
function ParticleSystem:getCount() return #self.particles end
function ParticleSystem:start() self.active = true; self.paused = false end
function ParticleSystem:stop() self.active = false; self.life = self.lifetime; self.emitAcc = 0 end
function ParticleSystem:pause() self.paused = true end
function ParticleSystem:reset() self.particles = {}; self.life = self.lifetime; self.emitAcc = 0 end
function ParticleSystem:isActive() return self.active and not self.paused end
function ParticleSystem:isPaused() return self.paused end
function ParticleSystem:isStopped() return not self.active end
function ParticleSystem:hasLinearAcceleration() return true end

local function spawn(ps)
  if #ps.particles >= ps.buffer then return end
  local life = rnd(ps.pLifeMin, ps.pLifeMax)
  local dir = ps.direction + rnd(-ps.spread / 2, ps.spread / 2)
  local speed = rnd(ps.speedMin, ps.speedMax)
  local px, py = ps.x, ps.y
  if ps.areaDist == "uniform" or ps.areaDist == "normal" then
    px, py = px + rnd(-ps.areaDx, ps.areaDx), py + rnd(-ps.areaDy, ps.areaDy)
  elseif ps.areaDist == "ellipse" or ps.areaDist == "borderellipse" then
    local t = rnd(0, 2 * pi)
    local k = ps.areaDist == "ellipse" and sqrt(love.math.random()) or 1
    px, py = px + cos(t) * ps.areaDx * k, py + sin(t) * ps.areaDy * k
  elseif ps.areaDist == "borderrectangle" then
    if love.math.random() < 0.5 then px, py = px + rnd(-ps.areaDx, ps.areaDx), py + (love.math.random() < 0.5 and -ps.areaDy or ps.areaDy)
    else px, py = px + (love.math.random() < 0.5 and -ps.areaDx or ps.areaDx), py + rnd(-ps.areaDy, ps.areaDy) end
  end
  local p = {
    x = px, y = py, ox = ps.x, oy = ps.y, vx = cos(dir) * speed, vy = sin(dir) * speed, life = life, maxLife = life,
    ax = rnd(ps.lax, ps.uax), ay = rnd(ps.lay, ps.uay), radial = rnd(ps.radialMin, ps.radialMax),
    tang = rnd(ps.tangMin, ps.tangMax), damp = rnd(ps.dampMin, ps.dampMax),
    rot = rnd(ps.rotMin, ps.rotMax), spin = rnd(ps.spinMin, ps.spinMax) * (1 - ps.spinVar * love.math.random()),
    sizeOff = ps.sizeVar * love.math.random(),
  }
  if ps.insertMode == "bottom" then table.insert(ps.particles, 1, p)
  elseif ps.insertMode == "random" then table.insert(ps.particles, love.math.random(1, #ps.particles + 1), p)
  else ps.particles[#ps.particles + 1] = p end
end

function ParticleSystem:emit(n) for _ = 1, n do spawn(self) end end

function ParticleSystem:update(dt)
  local ps = self.particles
  local i = 1
  while i <= #ps do
    local p = ps[i]
    p.life = p.life - dt
    if p.life <= 0 then
      table.remove(ps, i)
    else
      local rx, ry = p.x - p.ox, p.y - p.oy
      local len = sqrt(rx * rx + ry * ry)
      if len > 0 then rx, ry = rx / len, ry / len end
      local ax = p.ax + rx * p.radial - ry * p.tang
      local ay = p.ay + ry * p.radial + rx * p.tang
      p.vx, p.vy = p.vx + ax * dt, p.vy + ay * dt
      if p.damp ~= 0 then local k = 1 / (1 + p.damp * dt); p.vx, p.vy = p.vx * k, p.vy * k end
      p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
      p.rot = p.rot + p.spin * dt
      i = i + 1
    end
  end
  if self.active and not self.paused then
    if self.life >= 0 then
      self.life = self.life - dt
      if self.life < 0 then self.active = false end
    end
    if self.active and self.emissionRate > 0 then
      self.emitAcc = self.emitAcc + dt * self.emissionRate
      while self.emitAcc >= 1 do spawn(self); self.emitAcc = self.emitAcc - 1 end
    end
  end
end

local function lerpList(list, t)
  local n = #list
  if n == 1 then return list[1] end
  local s = t * (n - 1)
  local i = min(n - 1, floor(s))
  return list[i + 1], list[i + 2], s - i
end

local function drawParticles(ps, la, lb, lc, ld, le, lf)
  local tex = ps.texture
  if not tex then return end
  local n = #ps.particles
  for k = 1, n do
    local p = ps.particles[k]
    local t = 1 - p.life / p.maxLife
    local s1, s2, fs = lerpList(ps.sizes, t)
    local size = s2 and (s1 + (s2 - s1) * fs) or s1
    size = size * (1 - p.sizeOff)
    local c1, c2, fc = lerpList(ps.colors, t)
    local col = c1
    if c2 then col = { c1[1] + (c2[1] - c1[1]) * fc, c1[2] + (c2[2] - c1[2]) * fc, c1[3] + (c2[3] - c1[3]) * fc, c1[4] + (c2[4] - c1[4]) * fc } end
    local q = nil
    local qw, qh = tex.lw, tex.lh
    if ps.quads then
      q = ps.quads[min(#ps.quads, 1 + floor(t * #ps.quads))]
      qw, qh = q.w, q.h
    end
    local ox, oy = ps.offsetX or qw / 2, ps.offsetY or qh / 2
    local rot = p.rot
    if ps.relativeRotation then rot = rot + math.atan2(p.vy, p.vx) end
    local a, b, c, d, e, f = mul(la, lb, lc, ld, le, lf, localMatrix(p.x, p.y, rot, size, size, ox, oy))
    local ct = premulColor(col[1] * cr, col[2] * cg, col[3] * cb, (col[4] or 1) * ca)
    drawTextureM(tex, q, a, b, c, d, e, f, ct == 0xffffffff and NOTINT or ct)
  end
end

---------------------------------------------------------------------------
-- draw dispatch
---------------------------------------------------------------------------
-- G.draw of an Image or Canvas with numbers (the common case), the matrices worked
-- out in place.
local function drawImage(tex, q, x, y, r, sx, sy, ox, oy, kx, ky)
  if target.canvas == tex then error("Cannot render a Canvas to itself!", 3) end
  x, y, r = x or 0, y or 0, r or 0
  sx = sx or 1; sy = sy or sx
  ox, oy, kx, ky = ox or 0, oy or 0, kx or 0, ky or 0
  local c, s = 1, 0
  if r ~= 0 then c, s = cos(r), sin(r) end
  local la = c * sx - s * sy * ky
  local lb = s * sx + c * sy * ky
  local lc = c * sx * kx - s * sy
  local ld = s * sx * kx + c * sy
  local le, lf = x - (la * ox + lc * oy), y - (lb * ox + ld * oy)
  local tkx, tky = target.kx, target.ky
  local A, B, C, D = tkx * ta, tky * tb, tkx * tc, tky * td
  PA, PB, PC, PD = A * la + C * lb, B * la + D * lb, A * lc + C * ld, B * lc + D * ld
  PE, PF = A * le + C * lf + tkx * te + target.ox, B * le + D * lf + tky * tf + target.oy
  return drawTexturePx(tex, q, nil)
end

function G.draw(drawable, a, ...)
  if drawable == nil then return end
  local mt = getmetatable(drawable)
  if mt == Image or mt == Canvas then
    if type(a) == "table" and getmetatable(a) == Quad then
      local x = ...
      if type(x) ~= "userdata" then return drawImage(drawable, a, ...) end
    elseif type(a) ~= "userdata" then
      return drawImage(drawable, nil, a, ...)
    end
  end
  local quad = nil
  if type(a) == "table" and getmetatable(a) == Quad then
    quad = a
    a = ...
    if isTransform(a) then return G._drawWith(drawable, quad, transformMatrix(a)) end
    return G._drawWith(drawable, quad, localMatrix(select(1, ...)))
  end
  if isTransform(a) then return G._drawWith(drawable, nil, transformMatrix(a)) end
  return G._drawWith(drawable, nil, localMatrix(a, ...))
end

function G._drawWith(drawable, quad, la, lb, lc, ld, le, lf)
  local mt = getmetatable(drawable)
  if mt == Image or mt == Canvas then
    if target.canvas == drawable then error("Cannot render a Canvas to itself!", 3) end
    drawTextureM(drawable, quad, la, lb, lc, ld, le, lf)
  elseif mt == Text then
    stats.drawcalls = stats.drawcalls + 1
    drawTextObject(drawable, la, lb, lc, ld, le, lf)
  elseif mt == SpriteBatch then
    drawSpriteBatch(drawable, la, lb, lc, ld, le, lf)
  elseif mt == ParticleSystem then
    drawParticles(drawable, la, lb, lc, ld, le, lf)
  elseif mt == Mesh then
    drawMesh(drawable, la, lb, lc, ld, le, lf)
  else
    unsupported("draw(" .. tostring(drawable) .. ")")
  end
end

function G.drawLayer(texture, layer, ...) unsupported("drawLayer"); return G.draw(texture, ...) end
function G.drawInstanced(mesh, n, ...) unsupported("drawInstanced"); return G.draw(mesh, ...) end

---------------------------------------------------------------------------
-- primitives
---------------------------------------------------------------------------
-- line width in pixels: the transform's scale on it
local function lineWidthPx()
  local A, B, C, D = pixmat()
  return max(1, floor(lineWidth * sqrt(abs(A * D - B * C)) + 0.5))
end

-- game points (flat list) -> pixel points
local function pixelPoints(pts)
  local A, B, C, D, E, F = pixmat()
  local out = {}
  for i = 1, #pts - 1, 2 do
    local x, y = pts[i], pts[i + 1]
    out[i] = A * x + C * y + E
    out[i + 1] = B * x + D * y + F
  end
  return out
end

local function strokePixels(pp, closed)
  local lw = lineWidthPx()
  local n = #pp
  local surf = target.surf
  for i = 1, n - 3, 2 do
    M.m2d_line(surf, floor(pp[i] + 0.5), floor(pp[i + 1] + 0.5), floor(pp[i + 2] + 0.5), floor(pp[i + 3] + 0.5), lw, fillColor, blend)
  end
  if closed and n >= 6 then
    M.m2d_line(surf, floor(pp[n - 1] + 0.5), floor(pp[n] + 0.5), floor(pp[1] + 0.5), floor(pp[2] + 0.5), lw, fillColor, blend)
  end
end

local function shape(mode, pts)
  stats.drawcalls = stats.drawcalls + 1
  local pp = pixelPoints(pts)
  if mode == "fill" then
    fillPixelPolygon(pp, #pp / 2, fillColor)
  else
    strokePixels(pp, true)
  end
end

local function ellipsePoints(x, y, rx, ry, segments, a1, a2)
  local pts = {}
  a1, a2 = a1 or 0, a2 or 2 * pi
  local n = segments or max(8, min(64, floor((rx + ry) * storeScale / 2 + 8)))
  for i = 0, n - (a2 - a1 >= 2 * pi and 1 or 0) do
    local t = a1 + (a2 - a1) * i / n
    pts[#pts + 1] = x + cos(t) * rx
    pts[#pts + 1] = y + sin(t) * ry
  end
  return pts
end

function G.rectangle(mode, x, y, w, h, rx, ry, segments)
  if rx and rx > 0 then
    ry = ry or rx
    rx, ry = min(rx, abs(w) / 2), min(ry, abs(h) / 2)
    local pts = {}
    local n = segments or 6
    local corners = { { x + w - rx, y + ry, -pi / 2 }, { x + w - rx, y + h - ry, 0 }, { x + rx, y + h - ry, pi / 2 }, { x + rx, y + ry, pi } }
    for _, c in ipairs(corners) do
      for i = 0, n do
        local t = c[3] + (pi / 2) * i / n
        pts[#pts + 1] = c[1] + cos(t) * rx
        pts[#pts + 1] = c[2] + sin(t) * ry
      end
    end
    return shape(mode, pts)
  end
  if not axisAligned() then return shape(mode, { x, y, x + w, y, x + w, y + h, x, y + h }) end
  stats.drawcalls = stats.drawcalls + 1
  local px0, py0 = toPixel(x, y)
  local px1, py1 = toPixel(x + w, y + h)
  if px1 < px0 then px0, px1 = px1, px0 end
  if py1 < py0 then py0, py1 = py1, py0 end
  local dx, dy = floor(px0 + 0.5), floor(py0 + 0.5)
  local dw, dh = floor(px1 + 0.5) - dx, floor(py1 + 0.5) - dy
  local surf = target.surf
  if mode == "fill" then
    M.m2d_fill(surf, dx, dy, dw, dh, fillColor, blend)
  else
    local lw = lineWidthPx()
    local half = floor(lw / 2)
    dx, dy = dx - half, dy - half
    dw, dh = dw + lw, dh + lw
    M.m2d_fill(surf, dx, dy, dw, lw, fillColor, blend)
    M.m2d_fill(surf, dx, dy + dh - lw, dw, lw, fillColor, blend)
    M.m2d_fill(surf, dx, dy + lw, lw, dh - 2 * lw, fillColor, blend)
    M.m2d_fill(surf, dx + dw - lw, dy + lw, lw, dh - 2 * lw, fillColor, blend)
  end
end

function G.line(...)
  local pts = { ... }
  if type(pts[1]) == "table" then pts = pts[1] end
  stats.drawcalls = stats.drawcalls + 1
  strokePixels(pixelPoints(pts), false)
end

function G.circle(mode, x, y, r, segments)
  local A, B, C, D, E, F = pixmat()
  if abs(B) < 1e-9 and abs(C) < 1e-9 and abs(abs(A) - abs(D)) < 1e-6 and not segments then
    stats.drawcalls = stats.drawcalls + 1
    M.m2d_circle(target.surf, floor(A * x + E + 0.5), floor(D * y + F + 0.5), floor(r * abs(A) + 0.5), fillColor, blend,
      mode == "fill" and 1 or 0, lineWidthPx())
    return
  end
  shape(mode, ellipsePoints(x, y, r, r, segments))
end

function G.ellipse(mode, x, y, rx, ry, segments) shape(mode, ellipsePoints(x, y, rx, ry or rx, segments)) end

function G.arc(mode, arctype, x, y, r, a1, a2, segments)
  if type(arctype) == "number" then arctype, x, y, r, a1, a2, segments = "pie", arctype, x, y, r, a1, a2 end
  local pts = ellipsePoints(x, y, r, r, segments or max(8, floor(abs(a2 - a1) * r * storeScale / 8 + 4)), a1, a2)
  if arctype == "pie" then
    pts[#pts + 1], pts[#pts + 2] = x, y
  end
  if mode == "fill" or arctype ~= "open" then return shape(mode, pts) end
  stats.drawcalls = stats.drawcalls + 1
  strokePixels(pixelPoints(pts), false)
end

function G.polygon(mode, ...)
  local pts = { ... }
  if type(pts[1]) == "table" then pts = pts[1] end
  shape(mode, pts)
end

function G.points(...)
  local pts = { ... }
  if type(pts[1]) == "table" then pts = pts[1] end
  stats.drawcalls = stats.drawcalls + 1
  local size = max(1, floor(pointSize * target.kx + 0.5))
  local half = floor(size / 2)
  local surf = target.surf
  local colored = type(pts[1]) == "table"
  for i = 1, #pts, colored and 1 or 2 do
    local x, y, col
    if colored then
      local p = pts[i]
      x, y = p[1], p[2]
      col = premulColor((p[3] or 1) * cr, (p[4] or 1) * cg, (p[5] or 1) * cb, (p[6] or 1) * ca)
    else
      x, y, col = pts[i], pts[i + 1], fillColor
    end
    local px, py = toPixel(x, y)
    M.m2d_fill(surf, floor(px) - half, floor(py) - half, size, size, col, blend)
  end
end

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------
function G.setColor(r, g, b, a)
  if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
  r, g, b, a = r or 1, g or 1, b or 1, a or 1
  if r == cr and g == cg and b == cb and a == ca then return end
  cr, cg, cb, ca = r, g, b, a
  updateColor()
end
function G.getColor() return cr, cg, cb, ca end

function G.setBackgroundColor(r, g, b, a)
  if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
  bgr, bgg, bgb, bga = r or 0, g or 0, b or 0, a or 1
end
function G.getBackgroundColor() return bgr, bgg, bgb, bga end

function G.setBlendMode(mode, alphamode)
  mode = mode or "alpha"
  if not BLEND[mode] then error("Invalid blend mode '" .. tostring(mode) .. "'", 2) end
  blendName, alphaModeName = mode, alphamode or "alphamultiply"
  blend = BLEND[mode]
end
function G.getBlendMode() return blendName, alphaModeName end

function G.setLineWidth(w) lineWidth = w or 1 end
function G.getLineWidth() return lineWidth end
function G.setLineStyle(s) lineStyle = s or "smooth" end
function G.getLineStyle() return lineStyle end
function G.setLineJoin(j) lineJoin = j or "miter" end
function G.getLineJoin() return lineJoin end
function G.setPointSize(s) pointSize = s or 1 end
function G.getPointSize() return pointSize end

function G.setFont(f) if f then curFont = f end end
function G.getFont()
  if not curFont then curFont = G.newFont(12) end
  return curFont
end

function G.setDefaultFilter(a, b) defaultFilterMin, defaultFilterMag = a, b or a end
function G.getDefaultFilter() return defaultFilterMin, defaultFilterMag, 1 end
function G.setColorMask(r, g, b, a)
  if r == nil then colorMask = { true, true, true, true } else colorMask = { r, g, b, a } end
  if not (colorMask[1] and colorMask[2] and colorMask[3]) then unsupported("setColorMask") end
end
function G.getColorMask() return colorMask[1], colorMask[2], colorMask[3], colorMask[4] end
function G.setWireframe() end
function G.isWireframe() return false end
function G.setDepthMode() end
function G.getDepthMode() return "always", false end
function G.setMeshCullMode() end
function G.getMeshCullMode() return "none" end
function G.setFrontFaceWinding() end
function G.getFrontFaceWinding() return "ccw" end

-- shaders: accepted and not run
local Shader = makeType("Shader")
function Shader:send(name, ...) self.uniforms[name] = { ... } end
Shader.sendColor = Shader.send
function Shader:hasUniform(name) return self.code:find(name, 1, true) ~= nil end
function Shader:getWarnings() return "" end
function Shader:getExternVariable() return nil end
local gameProfile = {}
function G._setProfile(p) gameProfile = p or {} end

-- newShader takes GLSL or the names of files with it (LOVE: a string that names a file)
local function shaderSource(v)
  if type(v) ~= "string" then
    if v and v.getString then return v:getString() end   -- FileData
    return ""
  end
  if not v:find("[\n;{]") and love.filesystem.getInfo(v, "file") then
    return love.filesystem.read(v) or ""
  end
  return v
end

function G.newShader(code, code2)
  local s = setmetatable({ uniforms = {}, code = shaderSource(code) .. "\n" .. shaderSource(code2) }, Shader)
  -- where the game made it: for the report and profiles
  local info = debug.getinfo(2, "Sl")
  s.origin = info and (info.short_src .. ":" .. tostring(info.currentline)) or "?"
  s.origin = s.origin:gsub("^%.%.%.", ""):gsub("^/", "")
  local norm = Shaders.normalize(s.code)
  s.hash = Shaders.hash(norm)
  local effect, post = Shaders.fromProfile(gameProfile, s.origin, s.hash)
  local color
  if effect == nil then effect, color = Shaders.recognize(norm) end
  -- a solid colour of the shader's own (a shadow: vec4(0.1, 0.1, 0.1, t.a * 0.5))
  if color then s.solidTint = premulColor(color[1], color[2], color[3], color[4]) end
  if effect and not Shaders.EFFECTS[effect] then
    print("love-mini: profile: no shader effect \"" .. tostring(effect) .. "\"")
    effect = nil
  end
  s.effect, s.post = effect or nil, post
  G._report.shaders[s] = 0
  return s
end

-- the uniforms as a post function sees them: name -> value (a table for vectors)
local function uniformValues(s)
  local u = {}
  for k, v in pairs(s.uniforms) do u[k] = (#v == 1) and v[1] or v end
  return u
end

local inPost = false
-- after the draws made with a shader that has a post function: run it, once
local function runPost(s)
  if not s or not s.post or not s.drawn or inPost then return end
  s.drawn = false
  inPost = true
  local was = shader
  shader = nil
  G.push("all")
  G.setShader()
  G.origin()
  local ok, err = pcall(s.post, uniformValues(s), G)
  G.pop()
  shader = was
  inPost = false
  if not ok then print("love-mini: shader post (" .. s.origin .. "): " .. tostring(err)) end
end
G._runPost = function() runPost(shader) end

function G.setShader(s)
  if s ~= shader then runPost(shader) end
  shader = s
  stats.shaderswitches = stats.shaderswitches + 1
end
function G.getShader() return shader end
function G.validateShader() return true end

-- scissor: in the window's coordinates, not transformed
function G.setScissor(x, y, w, h)
  if x then scissor = { x, y, w, h } else scissor = nil end
  applyClip()
end
function G.intersectScissor(x, y, w, h)
  if not scissor then return G.setScissor(x, y, w, h) end
  local x0, y0 = max(scissor[1], x), max(scissor[2], y)
  local x1 = min(scissor[1] + scissor[3], x + w)
  local y1 = min(scissor[2] + scissor[4], y + h)
  G.setScissor(x0, y0, max(0, x1 - x0), max(0, y1 - y0))
end
function G.getScissor()
  if scissor then return scissor[1], scissor[2], scissor[3], scissor[4] end
end

-- stencil: drawing in fn changes the stencil buffer (where its pixels are not
-- transparent), then setStencilTest limits drawing by it
function G.stencil(fn, action, value, keepvalues)
  action = action or "replace"
  if not ACTION[action] then error("Invalid stencil draw action '" .. tostring(action) .. "'", 2) end
  if not keepvalues then M.m2d_stencil_clear(target.surf, 0) end
  M.m2d_stencil_test(0, 0)
  M.m2d_stencil_write(ACTION[action], value or 1)
  local ok, err = pcall(fn)
  M.m2d_stencil_write(0, 0)
  applyStencilTest()
  if not ok then error(err, 2) end
end
function G.setStencilTest(compare, value)
  if compare and not COMPARE[compare] then error("Invalid compare mode '" .. tostring(compare) .. "'", 2) end
  stencilCompare, stencilValue = compare, value or 0
  if compare then M.m2d_surface_stencil(target.surf) end
  applyStencilTest()
end
function G.getStencilTest() return stencilCompare or "always", stencilValue end

-- render targets
local function targetFor(c)
  return { surf = c.surf, kx = c.kx, ky = c.ky, ox = 0, oy = 0, canvas = c }
end

function G.setCanvas(c, ...)
  if type(c) == "table" and getmetatable(c) ~= Canvas then
    -- {canvas, ..., stencil=, depth=} : the first one only
    c = c[1] and (type(c[1]) == "table" and getmetatable(c[1]) ~= Canvas and c[1][1] or c[1]) or nil
    if select("#", ...) > 0 then unsupported("setCanvas with several canvases") end
  elseif select("#", ...) > 0 and type(select(1, ...)) == "table" then
    unsupported("setCanvas with several canvases")
  end
  if c then target = targetFor(c) else target = screenTarget end
  stats.canvasswitches = stats.canvasswitches + 1
  applyClip()
  if stencilCompare then M.m2d_surface_stencil(target.surf) end
end
function G.getCanvas()
  if target.isScreen then return nil end
  return target.canvas
end

function G.clear(r, g, b, a, clearstencil, cleardepth)
  local color
  if type(r) == "table" then
    -- clear({r,g,b,a}, ...) or clear({..}, {..}, stencil, depth)
    local c = r
    if type(c[1]) == "table" then c = c[1] end
    clearstencil = (type(g) == "boolean" or type(g) == "number") and g or clearstencil
    r, g, b, a = c[1], c[2], c[3], c[4]
  elseif type(r) == "boolean" then
    clearstencil = g
    r = nil
  end
  if r == nil then color = 0 else color = premulColor(r, g or 0, b or 0, a or 1) end
  M.m2d_clear(target.surf, color, scissor and 1 or 0)
  if clearstencil ~= false and target.surf.sten ~= nil then
    local v = type(clearstencil) == "number" and clearstencil or 0
    M.m2d_stencil_clear(target.surf, v)
  end
end
function G.discard() end

-- transforms
function G.push(kind)
  local s = { ta, tb, tc, td, te, tf }
  if kind == "all" then
    s.all = true
    s.color = { cr, cg, cb, ca }
    s.bg = { bgr, bgg, bgb, bga }
    s.blend = { blendName, alphaModeName }
    s.font = curFont
    s.lineWidth, s.lineStyle, s.lineJoin, s.pointSize = lineWidth, lineStyle, lineJoin, pointSize
    s.scissor = scissor
    s.target = target
    s.shader = shader
    s.stencil = { stencilCompare, stencilValue }
    s.colorMask = colorMask
  end
  tstack[#tstack + 1] = s
  if #tstack > 64 then error("Maximum stack depth reached (more pushes than pops?)", 2) end
end
function G.pop()
  local s = tstack[#tstack]
  if not s then error("Minimum stack depth reached (more pops than pushes?)", 2) end
  tstack[#tstack] = nil
  ta, tb, tc, td, te, tf = s[1], s[2], s[3], s[4], s[5], s[6]
  if s.all then
    cr, cg, cb, ca = s.color[1], s.color[2], s.color[3], s.color[4]
    updateColor()
    bgr, bgg, bgb, bga = s.bg[1], s.bg[2], s.bg[3], s.bg[4]
    G.setBlendMode(s.blend[1], s.blend[2])
    curFont = s.font
    lineWidth, lineStyle, lineJoin, pointSize = s.lineWidth, s.lineStyle, s.lineJoin, s.pointSize
    scissor = s.scissor
    target = s.target
    shader = s.shader
    stencilCompare, stencilValue = s.stencil[1], s.stencil[2]
    colorMask = s.colorMask
    applyClip()
    applyStencilTest()
  end
end
function G.origin() ta, tb, tc, td, te, tf = 1, 0, 0, 1, 0, 0 end
function G.translate(x, y)
  x, y = x or 0, y or 0
  te, tf = ta * x + tc * y + te, tb * x + td * y + tf
end
function G.scale(sx, sy)
  sx = sx or 1
  sy = sy or sx
  ta, tb, tc, td = ta * sx, tb * sx, tc * sy, td * sy
end
function G.rotate(r)
  local c, s = cos(r or 0), sin(r or 0)
  ta, tb, tc, td = ta * c + tc * s, tb * c + td * s, tc * c - ta * s, td * c - tb * s
end
function G.shear(kx, ky)
  kx, ky = kx or 0, ky or 0
  ta, tb, tc, td = ta + tc * ky, tb + td * ky, ta * kx + tc, tb * kx + td
end
function G.applyTransform(t)
  local a, b, c, d, e, f = transformMatrix(t)
  ta, tb, tc, td, te, tf = mul(ta, tb, tc, td, te, tf, a, b, c, d, e, f)
end
function G.replaceTransform(t) ta, tb, tc, td, te, tf = transformMatrix(t) end
function G.transformPoint(x, y) return ta * x + tc * y + te, tb * x + td * y + tf end
function G.inverseTransformPoint(x, y)
  local det = ta * td - tb * tc
  if det == 0 then return x, y end
  x, y = x - te, y - tf
  return (td * x - tc * y) / det, (ta * y - tb * x) / det
end

function G.reset()
  G.origin()
  G.setColor(1, 1, 1, 1)
  G.setBlendMode("alpha")
  lineWidth, lineStyle, lineJoin, pointSize = 1, "smooth", "miter", 1
  scissor = nil
  stencilCompare, stencilValue = nil, 0
  shader = nil
  target = screenTarget
  bgr, bgg, bgb, bga = 0, 0, 0, 1
  colorMask = { true, true, true, true }
  applyClip()
  applyStencilTest()
end

---------------------------------------------------------------------------
-- queries / misc
---------------------------------------------------------------------------
function G.getWidth() return gameW end
function G.getHeight() return gameH end
function G.getDimensions() return gameW, gameH end
function G.getPixelWidth() return gameW end
function G.getPixelHeight() return gameH end
function G.getPixelDimensions() return gameW, gameH end
function G.getDPIScale() return 1 end
function G.isActive() return true end
function G.isCreated() return true end
function G.isGammaCorrect() return false end
function G.getRendererInfo() return "mini2d", "1.0", "love-mini", "CPU" end
function G.getStats() return stats end
function G.getSystemLimits()
  return { texturesize = 4096, multicanvas = 1, canvasmsaa = 1, pointsize = 64, texturelayers = 1, volumetexturesize = 1,
    cubetexturesize = 1, anisotropy = 1 }
end
function G.getSupported()
  return { clampzero = false, lighten = true, multicanvasformats = false, glsl3 = false, instancing = false,
    fullnpot = true, pixelshaderhighp = false, shaderderivatives = false }
end
function G.getCanvasFormats() return { normal = true, rgba8 = true } end
function G.getImageFormats() return { rgba8 = true } end
function G.getTextureTypes() return { ["2d"] = true } end
function G.flushBatch() end
function G.getStackDepth() return #tstack end

-- the screen as the game sees it: ImageData of its logical size
function G.captureScreenshot(arg)
  local s = screenTarget
  local w, h = floor(gameW * s.kx + 0.5), floor(gameH * s.ky + 0.5)
  local view = M.m2d_surface_view(back, floor(s.ox + 0.5), floor(s.oy + 0.5), w, h)
  local data = readback(view, gameW, gameH)
  M.m2d_surface_view_free(view)
  if type(arg) == "function" then arg(data)
  elseif type(arg) == "string" then data:encode("png", arg)
  elseif type(arg) == "userdata" then arg:push(data) end
end
G.newScreenshot = function() local d; G.captureScreenshot(function(x) d = x end); return d end

G.present = function()
  runPost(shader)
  if G._beforePresent then G._beforePresent(G) end
  M.m2d_present()
  frameNo = frameNo + 1
  if frameNo % 30 == 0 then keepBudget() end
  stats.drawcalls = 0
  stats.canvasswitches = 0
  stats.shaderswitches = 0
end

G._types = { Image = Image, Canvas = Canvas, Quad = Quad, Font = Font, Text = Text, SpriteBatch = SpriteBatch,
  Mesh = Mesh, ParticleSystem = ParticleSystem, Shader = Shader }

-- The game's logical screen and how it lies on the back buffer (kx, ky, ox, oy).
function G._setScreen(w, h, kx, ky, ox, oy)
  gameW, gameH = w, h
  screenTarget.kx, screenTarget.ky, screenTarget.ox, screenTarget.oy = kx, ky, ox, oy
  storeScale = gameProfile.storage_scale or min(kx, ky)
  if target == screenTarget then applyClip() end
end

function G._init(screenW, screenH)
  local rc = M.m2d_init(screenW, screenH)
  if rc ~= 0 then error("love-mini: mini2d init failed (" .. rc .. ")") end
  back = M.m2d_backbuffer()
  screenTarget.surf = back
  G.reset()
end

return G
