-- love-mini's boot: called from LOVE's boot.lua (one line patched in, see
-- build/love-boot.patch) after the game's conf.lua and before any module loads.
--   conf(c)  — remembers the game's window size, turns LOVE's window and OpenGL off;
--   start(c) — puts love-mini's graphics, window and input in place.
-- The game's profile (LOVEMINI_PROFILE, a Lua file returning a table) adjusts both.

local print = print  -- the log's: a game may make print() draw text (as in PICO-8)
local B = {}

-- The log is a file: LOVE's output would sit in a buffer and be lost if the game
-- crashes. LOVEMINI_TRACE=1 also says each step of the start.
io.stdout:setvbuf("line")
local tracing = os.getenv("LOVEMINI_TRACE") == "1"
function B.trace(msg)
  if tracing then io.stdout:write("love-mini: trace: ", msg, "\n") end
end

local function loadProfile()
  local path = os.getenv("LOVEMINI_PROFILE")
  if not path or path == "" then return {} end
  local chunk, err = loadfile(path)
  if not chunk then
    print("love-mini: profile " .. path .. ": " .. tostring(err))
    return {}
  end
  local ok, p = pcall(chunk)
  if not ok or type(p) ~= "table" then
    print("love-mini: profile " .. path .. ": " .. tostring(p))
    return {}
  end
  return p
end

B.profile = loadProfile()

-- LOVE turns LuaJIT's compiler off on ARM (its jitsetup.lua: on phones the compiled
-- code's memory was hard to get near enough). love-mini's graphics are Lua over FFI,
-- which without the compiler costs several times more. LOVE has already reserved the
-- compiler's memory early, so it is turned back on; the profile's jit = false or
-- LOVEMINI_JIT=0 keeps it off.
if jit and B.profile.jit ~= false and os.getenv("LOVEMINI_JIT") ~= "0" then
  jit.on()
end

function B.conf(c)
  B.trace("conf")
  local w = c.window or {}
  -- What the game asked for: its logical screen.
  B.width, B.height = w.width or 800, w.height or 600
  B.fullscreen, B.fullscreentype = w.fullscreen, w.fullscreentype
  B.identity, B.appendidentity = c.identity, c.appendidentity
  B.title = (w.title or c.title or "LOVE")
  B.version = tostring(c.version or "11.5")
  -- No window or OpenGL: love-mini draws (mini2d) and owns the screen.
  c.modules.window = false
  c.modules.graphics = false
  -- Video needs graphics; touch has nothing to read.
  c.modules.video = false
  c.modules.touch = false
end

-- LOVEMINI_JITPROF=FILE: LuaJIT's profiler (jit.p) over the whole run, functions
-- and lines by time, written to FILE at the end (tools/run.sh sets LUA_PATH for it).
local function startProfiler()
  -- LOVEMINI_JITV=FILE: LuaJIT's trace log (jit.v): what is compiled, what aborts
  local v = os.getenv("LOVEMINI_JITV")
  if v and v ~= "" then
    local ok, jv = pcall(require, "jit.v")
    if ok then
      jv.start(v)
      local sentinel = newproxy(true)
      getmetatable(sentinel).__gc = function() jv.off() end
      B._tracelog = sentinel
    end
  end
  local out = os.getenv("LOVEMINI_JITPROF")
  if not out or out == "" then return end
  local ok, p = pcall(require, "jit.p")
  if not ok then print("love-mini: no jit.p: " .. tostring(p)); return end
  p.start(os.getenv("LOVEMINI_JITPROF_MODE") or "Fl3", out)
  local sentinel = newproxy(true)
  getmetatable(sentinel).__gc = function() p.stop() end
  B._profiler = sentinel
end

function B.start(c)
  B.trace("start")
  startProfiler()
  local window = require("lovemini.window")
  local graphics = require("lovemini.graphics")
  local input = require("lovemini.input")
  B.trace("modules loaded")
  window.install(B, graphics)
  B.trace("window and graphics in place")
  input.install(B)
  require("lovemini.report").install(B)
  require("lovemini.stubs").install()
  require("lovemini.audio").install(B)
  require("lovemini.timer").install()
  require("lovemini.patch").install(B)
  B.trace("input and report in place")
  print(string.format("love-mini: %s, %dx%d on a %dx%d screen (%s), LuaJIT compiler %s", B.title, B.width, B.height,
    window.screenW, window.screenH, window.mode, (jit and jit.status()) and "on" or "off"))
end

return B
