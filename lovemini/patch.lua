-- A game adjusted for the Mini without changing its file: what the profile asks of
-- it, done as it loads.
--   env     = { NAME = "value" }       os.getenv answers these (settings a game reads)
--   lua     = "lua"                    a folder next to the profile with Lua modules of
--                                      the profile's own, found by require before the
--                                      game's (require "portmaster.small_screen")
--   edits   = { ["game.lua"] = { { "old text", "new text", 1 }, … } }
--                                      a game's Lua file changed as it is loaded: each
--                                      old text (plain, not a pattern) replaced, the
--                                      number, if given, how many times it must be
--                                      there; a file whose edits do not fit is loaded as
--                                      it is, and the log says so. { …, optional = true }:
--                                      an edit that may find nothing
--   saves_from = "/mnt/SDCARD/Saves/CurrentProfile/saves/Game"
--                                      another port's saves of the game, copied into
--                                      love-mini's save folder for it on the first
--                                      start (when that one is empty); left where they are
--   files   = { ["resources/fonts/x.ttf"] = "fonts/y.ttf" }
--                                      files of the game read from next to the profile
--                                      instead (love.filesystem, newFont, newImage, …)
local print = print  -- the log's: a game may make print() draw text (as in PICO-8)

local P = {}

local dir = ""         -- the profile's folder, with a trailing /
local files = {}       -- game path -> real path
P.files = files

local function readReal(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function norm(path)
  return (path:gsub("\\", "/"):gsub("^/+", ""):gsub("^%./", ""))
end

-- The FileData of a replaced file, or nil: for loaders given a path.
function P.fileData(path)
  if type(path) ~= "string" then return nil end
  local real = files[norm(path)]
  if not real then return nil end
  local data = readReal(real)
  if not data then
    print("love-mini: profile: " .. real .. " is not there")
    return nil
  end
  return love.filesystem.newFileData(data, path)
end

local function plainReplace(s, old, new)
  local out, n, i = {}, 0, 1
  while true do
    local a, b = s:find(old, i, true)
    if not a then break end
    out[#out + 1] = s:sub(i, a - 1)
    out[#out + 1] = new
    i, n = b + 1, n + 1
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out), n
end

local function edited(path, list)
  local src = love.filesystem.read(path)
  if not src then return nil end
  for k, e in ipairs(list) do
    local out, n = plainReplace(src, e[1], e[2])
    if e.optional and n == 0 then
      -- nothing to change here
    elseif (e[3] and n ~= e[3]) or n == 0 then
      print(string.format("love-mini: profile: %s: edit %d found %d times, not %s: the file is loaded as it is",
        path, k, n, tostring(e[3] or "1 or more")))
      return nil
    end
    src = out
  end
  return src
end

local function searcher(edits, luaDir)
  return function(name)
    local rel = name:gsub("%.", "/")
    if luaDir then
      for _, p in ipairs({ luaDir .. rel .. ".lua", luaDir .. rel .. "/init.lua" }) do
        local src = readReal(p)
        if src then
          local chunk, err = loadstring(src, "@" .. p)
          if not chunk then error(err, 2) end
          return chunk
        end
      end
    end
    for _, p in ipairs({ rel .. ".lua", rel .. "/init.lua" }) do
      if edits[p] then
        local src = edited(p, edits[p])
        if src then
          local chunk, err = loadstring(src, "@" .. p)
          if not chunk then error(err, 2) end
          return chunk
        end
      end
    end
    return "\n\tno '" .. rel .. "' in love-mini's profile"
  end
end

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function importSaves(from, boot)
  if type(from) ~= "string" or from == "" then return end
  -- LOVE sets the game's identity (its save folder) later in its start: now, the same
  if boot.identity then pcall(love.filesystem.setIdentity, boot.identity, boot.appendidentity) end
  local to = love.filesystem.getSaveDirectory()
  -- only into an empty folder, and only what is there: the other port's stay
  local cmd = string.format('[ -d %s ] && mkdir -p %s && [ -z "$(ls -A %s)" ] && cp -R %s/. %s && echo copied',
    shq(from), shq(to), shq(to), shq(from), shq(to))
  local h = io.popen(cmd)
  local out = h and h:read("*a") or ""
  if h then h:close() end
  if out:find("copied") then print("love-mini: saves copied from " .. from .. " to " .. to) end
end

function P.install(boot)
  local p = boot.profile
  local path = os.getenv("LOVEMINI_PROFILE") or ""
  dir = path:match("^(.*/)") or ""
  importSaves(p.saves_from, boot)

  if type(p.env) == "table" then
    local getenv = os.getenv
    os.getenv = function(name)
      local v = p.env[name]
      if v ~= nil then return tostring(v) end
      return getenv(name)
    end
  end

  if type(p.files) == "table" then
    for game, real in pairs(p.files) do files[norm(game)] = dir .. real end
    local fs = love.filesystem
    local read, newFileData, getInfo = fs.read, fs.newFileData, fs.getInfo
    fs.read = function(a, b, ...)
      -- read(name, size) or read(container, name, size)
      local name = (a == "string" or a == "data") and b or a
      local real = type(name) == "string" and files[norm(name)]
      if real then
        local data = readReal(real)
        if data then return data, #data end
      end
      return read(a, b, ...)
    end
    fs.newFileData = function(a, b, ...)
      if b == nil and type(a) == "string" and files[norm(a)] then
        local fd = P.fileData(a)
        if fd then return fd end
      end
      return newFileData(a, b, ...)
    end
    fs.getInfo = function(name, ...)
      local real = type(name) == "string" and files[norm(name)]
      if real then
        local f = io.open(real, "rb")
        if f then
          local size = f:seek("end")
          f:close()
          return { type = "file", size = size, modtime = 0 }
        end
      end
      return getInfo(name, ...)
    end
  end

  if next(files) then
    -- loaders given a file's name: the replacement's data instead
    local function wrap(t, name)
      local f = t and t[name]
      if type(f) ~= "function" then return end
      t[name] = function(a, ...)
        local fd = P.fileData(a)
        if fd then return f(fd, ...) end
        return f(a, ...)
      end
    end
    for _, n in ipairs({ "newFont", "setNewFont", "newImage", "newImageFont" }) do wrap(love.graphics, n) end
    wrap(love.audio, "newSource")
    wrap(love.sound, "newSoundData")
    wrap(love.sound, "newDecoder")
    wrap(love.image, "newImageData")
    for _, n in ipairs({ "newRasterizer", "newTrueTypeRasterizer", "newBMFontRasterizer", "newImageRasterizer" }) do
      wrap(love.font, n)
    end
  end

  local edits = type(p.edits) == "table" and p.edits or {}
  local luaDir = type(p.lua) == "string" and (dir .. p.lua:gsub("/*$", "") .. "/") or nil
  if next(edits) or luaDir then
    table.insert(package.loaders, 2, searcher(edits, luaDir))
  end
end

return P
