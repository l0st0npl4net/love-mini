-- A mouse for games that need one: a cursor the d-pad moves (faster the longer it is
-- held), A the left button, B the right, L1 / R1 the wheel. The profile turns it on:
--   mouse = true        always (the d-pad, A, B, L1 and R1 are the mouse's)
--   mouse = "toggle"    Select switches between the cursor and the game's own buttons
--                       (a game with mouse menus and button play)
-- love.mouse reports it in the game's coordinates; the game gets mousemoved,
-- mousepressed, mousereleased and wheelmoved.
local print = print  -- the log's: a game may make print() draw text (as in PICO-8)

local P = {}

local I, osk
local mode = false      -- false | true | "toggle"
local on = false        -- the cursor has the buttons now
local x, y = 0, 0
local held = {}         -- d-pad direction -> seconds held
local buttons = {}      -- 1, 2 -> down
local visible = true
local TAKES = { up = true, down = true, left = true, right = true, a = true, b = true, l1 = true, r1 = true }

local function size() return love.graphics.getDimensions() end

local function moveTo(nx, ny)
  local w, h = size()
  nx = math.max(0, math.min(w - 1, nx))
  ny = math.max(0, math.min(h - 1, ny))
  local dx, dy = nx - x, ny - y
  if dx ~= 0 or dy ~= 0 then
    x, y = nx, ny
    I.push("mousemoved", x, y, dx, dy, false)
  end
end

local C = {}
function C.active() return mode ~= false and not osk.isOpen() end
function C.press(b, isrepeat)
  if mode == "toggle" and b == "select" then
    on = not on
    for d in pairs(held) do held[d] = nil end
    return true
  end
  if not on or not TAKES[b] then return false end
  if isrepeat then return true end
  if b == "a" or b == "b" then
    local n = b == "a" and 1 or 2
    buttons[n] = true
    I.push("mousepressed", x, y, n, false, 1)
  elseif b == "l1" then I.push("wheelmoved", 0, 1)
  elseif b == "r1" then I.push("wheelmoved", 0, -1)
  else held[b] = 0 end
  return true
end
function C.release(b)
  if b == "a" or b == "b" then
    local n = b == "a" and 1 or 2
    if buttons[n] then
      buttons[n] = nil
      I.push("mousereleased", x, y, n, false, 1)
    end
  else
    held[b] = nil
  end
end
function C.update(dt)
  if not on then return end
  local w = size()
  local vx, vy = 0, 0
  for d, t in pairs(held) do
    held[d] = t + dt
    -- a quarter of the screen's width a second, up to a whole one after half a second
    local v = w * (0.25 + 0.75 * math.min(1, t / 0.5))
    if d == "left" then vx = vx - v elseif d == "right" then vx = vx + v
    elseif d == "up" then vy = vy - v elseif d == "down" then vy = vy + v end
  end
  if vx ~= 0 or vy ~= 0 then moveTo(x + vx * dt, y + vy * dt) end
end
function C.draw()
  if not on or not visible then return end
  local G = love.graphics
  local w, h = size()
  local s = math.max(8, h / 30)
  G.push("all")
  G.setCanvas()
  G.setShader()
  G.setScissor()
  G.origin()
  G.setBlendMode("alpha")
  local pts = { x, y, x, y + s * 1.4, x + s * 0.4, y + s * 1.05, x + s, y + s }
  G.setColor(0, 0, 0, 1)
  G.polygon("fill", pts)
  G.setColor(1, 1, 1, 1)
  local i = { x + 1, y + 2.5, x + 1, y + s * 1.4 - 3, x + s * 0.4, y + s * 1.05 - 1.5, x + s - 3, y + s - 1 }
  G.polygon("fill", i)
  G.pop()
end

function P.install(input, boot)
  I = input
  osk = require("lovemini.osk")
  mode = boot.profile.mouse or false
  on = mode == true
  I.addCapture(C)
  local w, h = size()
  x, y = w / 2, h / 2
  if mode == false then return end
  local Mo = love.mouse
  function Mo.getPosition() return x, y end
  function Mo.getX() return x end
  function Mo.getY() return y end
  function Mo.setPosition(nx, ny) x, y = nx or x, ny or y end
  function Mo.setX(nx) x = nx end
  function Mo.setY(ny) y = ny end
  function Mo.isDown(...)
    for _, n in ipairs({ ... }) do if buttons[n] then return true end end
    return false
  end
  function Mo.setVisible(v) visible = v and true or false end
  function Mo.isVisible() return visible end
  function Mo.isCursorSupported() return true end
end

return P
