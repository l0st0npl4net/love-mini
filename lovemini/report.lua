-- What a game asked of love-mini that it could not give, for the compatibility list:
-- love.graphics / love.window functions it does not have (they do nothing and are
-- counted, rather than stop the game), features drawn otherwise (rotation in an image
-- font, a mesh without its texture), shaders made and used, errors, frames and time.
-- Written as JSON to LOVEMINI_REPORT when set, when the game ends; the missing and
-- unsupported are also said in the log once each.

local print = print  -- the log's: a game may make print() draw text (as in PICO-8)
local R = {}
local missing = {}
local errors = {}
local started

local function stub(module, name)
  return function()
    local key = module .. "." .. name
    if not missing[key] then print("love-mini: " .. key .. " is not there; it does nothing") end
    missing[key] = (missing[key] or 0) + 1
  end
end

local api = require("lovemini.api")
local M2D = require("lovemini.m2d")
local statsBuf = require("ffi").new("double[8]")
local timesBuf = require("ffi").new("double[5]")

-- The love.graphics calls counted for the log (how many a frame, the most first)
local COUNTED = { "draw", "print", "printf", "rectangle", "polygon", "line", "circle", "setColor",
  "push", "pop", "setCanvas", "setShader", "stencil", "setScissor", "clear" }

local function guard(module, t, names)
  local known = {}
  for _, k in ipairs(names) do known[k] = true end
  setmetatable(t, {
    __index = function(_, k)
      if not known[k] then return nil end
      return stub(module, k)
    end,
  })
end

local function jstr(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function counts(t)
  local parts = {}
  for k, v in pairs(t) do parts[#parts + 1] = jstr(k) .. ": " .. tostring(v) end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

function R.write(path)
  local G = love.graphics
  local shaders = {}
  for s, n in pairs(G._report.shaders) do
    local firstLine = s.code:match("[^\n]*%S[^\n]*") or ""
    shaders[#shaders + 1] = string.format('{"origin": %s, "hash": %s, "effect": %s, "post": %s, "uses": %d, "first": %s}',
      jstr(s.origin), jstr(s.hash or ""), jstr(s.effect or "none"), s.post and "true" or "false", n, jstr(firstLine))
  end
  local elapsed = love.timer and (love.timer.getTime() - started) or 0
  local frames = require("lovemini.m2d").m2d_frame_count()
  local f = io.open(path, "w")
  if not f then return end
  f:write("{\n")
  f:write('  "frames": ', frames, ',\n')
  f:write('  "seconds": ', string.format("%.2f", elapsed), ',\n')
  local ms = {}
  for _, v in ipairs(R.frameMs or {}) do ms[#ms + 1] = string.format("%.1f", v) end
  f:write('  "frame_ms": [', table.concat(ms, ", "), '],\n')
  local work = {}
  for _, v in ipairs(R.workMs or {}) do work[#work + 1] = string.format("%.1f", v) end
  f:write('  "work_ms": [', table.concat(work, ", "), '],\n')
  f:write('  "missing": ', counts(missing), ',\n')
  f:write('  "unsupported": ', counts(G._report.unsupported), ',\n')
  f:write('  "shaders": [', table.concat(shaders, ", "), '],\n')
  local es = {}
  for _, e in ipairs(errors) do es[#es + 1] = jstr(e) end
  f:write('  "errors": [', table.concat(es, ", "), ']\n')
  f:write("}\n")
  f:close()
end

function R.install(boot)
  started = love.timer and love.timer.getTime() or 0
  guard("love.graphics", love.graphics, api.graphics)
  guard("love.window", love.window, api.window)
  -- errors: recorded, then LOVE's own handler (or the game's)
  local function wrapHandler()
    local handler = love.errorhandler or love.errhand
    return function(msg)
      errors[#errors + 1] = tostring(msg)
      if os.getenv("LOVEMINI_REPORT") then R.write(os.getenv("LOVEMINI_REPORT")) end
      if os.getenv("LOVEMINI_EXIT_ON_ERROR") then
        print("love-mini: error: " .. tostring(msg))
        print(debug.traceback())
        return nil
      end
      return handler(msg)
    end
  end
  love.errorhandler = wrapHandler()
  -- Frame times, said in the log every 10 seconds (how near 60 a second the Mini
  -- comes); LOVEMINI_FRAMES=N ends the game after N frames (test runs).
  local limit = tonumber(os.getenv("LOVEMINI_FRAMES") or "")
  local present, n = love.graphics.present, 0
  local getTime = love.timer and love.timer.getTime or os.clock
  -- waiting: time spent in present() waiting for the screen (the frame before still
  -- being shown); the rest of a frame is the game's work: update, draw, LOVE.
  local last, since, count, total, worst, waiting = getTime(), getTime(), 0, 0, 0, 0
  -- where the work goes: the game's update and draw, sleeping, and of all that the
  -- drawing mini2d does (by kind); the love.graphics calls a frame makes
  local upd, drw, slp = 0, 0, 0
  local wrappedU, wrappedD
  local function timeLoop()
    if love.update ~= wrappedU then
      local f = love.update
      wrappedU = f and function(...) local t = getTime(); f(...); upd = upd + getTime() - t end
      love.update = wrappedU
    end
    if love.draw ~= wrappedD then
      local f = love.draw
      wrappedD = f and function(...) local t = getTime(); f(...); drw = drw + getTime() - t end
      love.draw = wrappedD
    end
  end
  if love.timer and love.timer.sleep then
    local sleep = love.timer.sleep
    love.timer.sleep = function(s) local t = getTime(); sleep(s); slp = slp + getTime() - t end
  end
  local calls = {}
  for i, name in ipairs(COUNTED) do
    local f = love.graphics[name]
    calls[i] = 0
    if f then love.graphics[name] = function(...) calls[i] = calls[i] + 1; return f(...) end end
  end
  love.graphics.present = function(...)
    timeLoop()
    if n < 2 then boot.trace("frame " .. (n + 1) .. " drawn, presenting") end
    local t0 = getTime()
    present(...)
    n = n + 1
    if n <= 2 then boot.trace("frame " .. n .. " shown") end
    local t = getTime()
    local dt = t - last
    last = t
    count, total, worst, waiting = count + 1, total + dt, math.max(worst, dt), waiting + (t - t0)
    if t - since >= 10 then
      print(string.format("love-mini: frames: %d in %.1f s, %.1f ms each (%.1f ms work, %.1f ms waiting for the screen), %.1f ms at most, %.0f KB of textures",
        count, t - since, total / count * 1000, (total - waiting) / count * 1000, waiting / count * 1000,
        worst * 1000, love.graphics.getStats().texturememory / 1024))
      R.frameMs = R.frameMs or {}
      R.frameMs[#R.frameMs + 1] = total / count * 1000
      -- what mini2d did, a frame on average (thousands of pixels by path, calls)
      local st = statsBuf
      M2D.m2d_stats(st)
      local k = function(i) return st[i] / count / 1000 end
      print(string.format("love-mini: a frame: %d blits, %d fills; pixels (K): %.0f copied, %.0f blended, %.0f other (%.0f scaled), %.0f filled, %.0f cleared",
        st[0] / count, st[6] / count, k(1), k(2), k(3), k(7), k(4), k(5)))
      local tm = timesBuf
      M2D.m2d_times(tm)
      local ms = function(v) return v / count * 1000 end
      local work = total - waiting
      print(string.format("love-mini: a frame's work: %.1f ms update, %.1f ms draw, %.1f ms sleeping, %.1f ms else; mini2d drew for %.1f ms of it: %.1f blits, %.1f fills, %.1f shapes, %.1f clearing, %.1f textures",
        ms(upd), ms(drw), ms(slp), ms(work - upd - drw - slp), ms(tm[0] + tm[1] + tm[2] + tm[3] + tm[4]),
        ms(tm[0]), ms(tm[1]), ms(tm[2]), ms(tm[3]), ms(tm[4])))
      local order = {}
      for i = 1, #COUNTED do if calls[i] > 0 then order[#order + 1] = i end end
      table.sort(order, function(a, b) return calls[a] > calls[b] end)
      local parts = {}
      for _, i in ipairs(order) do
        parts[#parts + 1] = string.format("%.0f %s", calls[i] / count, COUNTED[i])
        calls[i] = 0
      end
      print("love-mini: a frame's calls: " .. (#parts > 0 and table.concat(parts, ", ") or "none"))
      upd, drw, slp = 0, 0, 0
      R.workMs = R.workMs or {}
      R.workMs[#R.workMs + 1] = (total - waiting) / count * 1000
      since, count, total, worst, waiting = t, 0, 0, 0, 0
    end
    if n == limit then love.event.quit() end
  end
  -- the report when the game ends (the Lua state closes)
  local path = os.getenv("LOVEMINI_REPORT")
  if path then
    local sentinel = newproxy(true)
    getmetatable(sentinel).__gc = function() pcall(R.write, path) end
    R._sentinel = sentinel
  end
end

return R
