-- A shader that never reads its texture (profile: "flat"), drawn on a sprite and on a
-- rectangle into a canvas, as Balatro draws its background. Run with
--   PROFILE=tests/scenes/flat/prof/profile.lua tools/run.sh tests/scenes/flat/game 3
-- and every "T" line should say ok.
local function check(what, ok) print("T " .. what .. ": " .. (ok and "ok" or "WRONG")) end
local function green(c, x, y)
  local r, g, b = c:newImageData():getPixel(x, y)
  return r < 0.1 and g > 0.9 and b < 0.1
end
function love.load()
  local sh = love.graphics.newShader("shaders/bg.fs")
  sh:send("colour_1", { 0, 1, 0, 1 })
  local c = love.graphics.newCanvas(32, 32)
  love.graphics.setCanvas(c)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 16, 32)
  love.graphics.setShader()
  love.graphics.rectangle("fill", 16, 0, 16, 32)
  love.graphics.setCanvas()
  check("rectangle", green(c, 4, 4))
  check("after", not green(c, 20, 4))
end
function love.draw() end
