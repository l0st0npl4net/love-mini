-- love.timer for love-mini: LOVE's own, but short sleeps are skipped when the
-- Mini's kernel cannot do them. LOVE's main loop sleeps 1 ms after every frame; with
-- a coarse kernel timer that sleep lasts until the next tick (up to 10 ms), and a
-- frame of 9 ms work takes 20. love-mini's present() already waits for the screen,
-- so the loop does not run faster than the screen without the sleep.

local print = print  -- the log's: a game may make print() draw text (as in PICO-8)
local T = {}

function T.install()
  local timer = love.timer
  if not timer or not timer.sleep then return end
  local sleep, getTime = timer.sleep, timer.getTime
  -- how long a 1 ms sleep really takes (the median of a few)
  local d = {}
  for i = 1, 5 do
    local t0 = getTime()
    sleep(0.001)
    d[i] = getTime() - t0
  end
  table.sort(d)
  local tick = d[3]
  print(string.format("love-mini: a 1 ms sleep takes %.1f ms", tick * 1000))
  T.tick = tick
  if tick > 0.003 then
    timer.sleep = function(s)
      if s and s >= tick then sleep(s) end
    end
  end
end

return T
