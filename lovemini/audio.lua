-- love.audio for love-mini: LOVE's own, with one change. A "static" source is
-- decoded whole into memory: a long piece of music takes tens of MB, more than a
-- Mini has to spare ("Not enough memory"). A static source from a file bigger than
-- the profile's stream_over_kb (1024 KB by default) is made a "stream" instead,
-- read and decoded as it plays.

local print = print  -- the log's: a game may make print() draw text (as in PICO-8)
local A = {}

function A.install(boot)
  local audio = love.audio
  if not audio or not audio.newSource then return end
  local limit = (boot.profile.stream_over_kb or 1024) * 1024
  local newSource = audio.newSource
  audio.newSource = function(src, kind, ...)
    if kind == "static" and type(src) == "string" and love.filesystem then
      local info = love.filesystem.getInfo(src)
      if info and info.size and info.size > limit then
        print(string.format("love-mini: %s (%d KB) streamed, not decoded whole", src, info.size / 1024))
        kind = "stream"
      end
    end
    return newSource(src, kind, ...)
  end
end

return A
