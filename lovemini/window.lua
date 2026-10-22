-- love.window for love-mini: the game keeps its window size (its logical screen),
-- laid on the Mini's screen by the profile's mode:
--   fit      the whole of it, as large as fits, centred (bands if the shapes differ)
--   fill     the whole screen, the game's sides (or top and bottom) cut off
--   integer  fit at a whole-number scale (pixel art), or fit when it is smaller
--   stretch  the whole screen, the shape changed
-- A fullscreen window ("desktop" fullscreen, LOVE's default) is the size of the
-- screen, as in LOVE: such games lay themselves out for 640x480. "exclusive"
-- fullscreen keeps the asked size (LOVE would change the display's mode).
local print = print  -- the log's: a game may make print() draw text (as in PICO-8)
local ffi = require("ffi")
local M = require("lovemini.m2d")

local W = { mode = "fit" }
local G, boot
local gameW, gameH = 800, 600
local winW, winH = 800, 600   -- the window size asked for (when not fullscreen)
local title = "LOVE"
local flags = { fullscreen = false, fullscreentype = "desktop", vsync = 1, msaa = 0, stencil = true, depth = 0,
  resizable = false, borderless = true, centered = true, display = 1, minwidth = 1, minheight = 1, highdpi = false,
  refreshrate = 60, x = 0, y = 0, usedpiscale = false }

function W.layout()
  local sw, sh = W.screenW, W.screenH
  local fx, fy = sw / gameW, sh / gameH
  local kx, ky
  if W.mode == "stretch" then
    kx, ky = fx, fy
  elseif W.mode == "fill" then
    kx = math.max(fx, fy); ky = kx
  elseif W.mode == "integer" and math.min(fx, fy) >= 1 then
    kx = math.floor(math.min(fx, fy)); ky = kx
  else
    kx = math.min(fx, fy); ky = kx
  end
  G._setScreen(gameW, gameH, kx, ky, (sw - gameW * kx) / 2, (sh - gameH * ky) / 2)
end

local Win = {}
-- The game's size from the window asked for and the fullscreen flags; love.resize
-- when it changes and `notify` (LOVE: setFullscreen does, setMode does not).
local function applySize(notify)
  local w, h = winW, winH
  if flags.fullscreen and flags.fullscreentype ~= "exclusive" then w, h = W.screenW, W.screenH end
  if w == 0 then w = W.screenW end
  if h == 0 then h = W.screenH end
  local changed = w ~= gameW or h ~= gameH
  gameW, gameH = w, h
  W.layout()
  if changed and notify and love.event then love.event.push("resize", w, h) end
end

function Win.getMode() return gameW, gameH, flags end
function Win.setMode(w, h, f)
  winW, winH = w or winW, h or winH
  -- as in LOVE, flags not given are the defaults
  flags.fullscreen = (f and f.fullscreen) or false
  flags.fullscreentype = (f and f.fullscreentype) or "desktop"
  for k, v in pairs(f or {}) do flags[k] = v end
  applySize(false)
  return true
end
function Win.updateMode(w, h, f) return Win.setMode(w, h, f) end
function Win.getDesktopDimensions() return W.screenW, W.screenH end
function Win.getPosition() return 0, 0, 1 end
function Win.setPosition() end
function Win.isMaximized() return false end
function Win.isMinimized() return false end
function Win.maximize() end
function Win.minimize() end
function Win.restore() end
function Win.getFullscreen() return flags.fullscreen, flags.fullscreentype end
function Win.setFullscreen(on, kind)
  flags.fullscreen = on and true or false
  if kind then flags.fullscreentype = kind end
  applySize(true)
  return true
end
function Win.getFullscreenModes() return { { width = W.screenW, height = W.screenH } } end
function Win.setTitle(t) title = t end
function Win.getTitle() return title end
function Win.setIcon() return true end
function Win.getIcon() return nil end
function Win.showMessageBox(t, msg, buttons)
  print("love-mini: [message] " .. tostring(t) .. ": " .. tostring(msg))
  return 1
end
function Win.requestAttention() end
function Win.isOpen() return true end
function Win.close() end
function Win.hasFocus() return true end
function Win.hasMouseFocus() return false end
function Win.isVisible() return true end
function Win.isCreated() return true end
function Win.getDisplayCount() return 1 end
function Win.getDisplayName() return "Miyoo Mini" end
function Win.getDisplayOrientation() return "landscape" end
function Win.getDPIScale() return 1 end
function Win.getNativeDPIScale() return 1 end
function Win.toPixels(v, v2) if v2 then return v, v2 end return v end
function Win.fromPixels(v, v2) if v2 then return v, v2 end return v end
function Win.setVSync() end
function Win.getVSync() return 1 end
function Win.getSafeArea() return 0, 0, gameW, gameH end
function Win.isDisplaySleepEnabled() return false end
function Win.setDisplaySleepEnabled() end

function W.install(b, graphics)
  boot, G = b, graphics
  local w, h = ffi.new("int[1]"), ffi.new("int[1]")
  b.trace("m2d_screen_size")
  M.m2d_screen_size(w, h)
  W.screenW, W.screenH = w[0], h[0]
  b.trace(string.format("screen %dx%d; m2d_init", W.screenW, W.screenH))
  W.mode = (b.profile.screen or os.getenv("LOVEMINI_SCREEN") or "fit")
  winW, winH = b.width, b.height
  flags.fullscreen = b.fullscreen or false
  flags.fullscreentype = b.fullscreentype or "desktop"
  title = b.title
  G._init(W.screenW, W.screenH)
  G._setBudget(b.profile.texture_budget_mb or tonumber(os.getenv("LOVEMINI_TEXTURE_MB") or ""))
  G._setProfile(b.profile)
  applySize(false)
  b.width, b.height = gameW, gameH
  love.graphics = G
  package.loaded["love.graphics"] = G
  love.window = Win
  package.loaded["love.window"] = Win
  W.graphics, W.window = G, Win
end

return W
