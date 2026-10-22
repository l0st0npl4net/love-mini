-- love-mini check: the first game to run on a Mini. Everything love-mini gives a game,
-- each in a corner of the screen:
-- * picture: a rotating, scaled image, primitives, text, particles; frames a second;
-- * buttons: the last keys and gamepad buttons, the d-pad moves the square;
-- * sound: A plays a tone (OpenAL through OnionOS's audioserver), B a lower one;
-- * saves: a count of runs, kept in the save folder.
-- Select + Start held for a second quits.

local img, ps, font, small
local x, y = 320, 300
local keys, pads = {}, {}
local beepHigh, beepLow
local runs = 0
local t = 0

local function remember(list, s)
  table.insert(list, 1, s)
  if #list > 5 then list[6] = nil end
end

local function tone(freq, seconds)
  local rate = 22050
  local n = math.floor(rate * seconds)
  local d = love.sound.newSoundData(n, rate, 16, 1)
  for i = 0, n - 1 do
    local fade = 1 - i / n
    d:setSample(i, math.sin(2 * math.pi * freq * i / rate) * 0.4 * fade)
  end
  return love.audio.newSource(d, "static")
end

function love.load()
  local d = love.image.newImageData(48, 48)
  d:mapPixel(function(px, py)
    local c = ((math.floor(px / 8) + math.floor(py / 8)) % 2 == 0) and 1 or 0.3
    return c, 0.5 + 0.5 * c, 1 - 0.6 * c, 1
  end)
  img = love.graphics.newImage(d)
  local dot = love.image.newImageData(6, 6)
  dot:mapPixel(function() return 1, 1, 1, 1 end)
  ps = love.graphics.newParticleSystem(love.graphics.newImage(dot), 150)
  ps:setParticleLifetime(0.6, 1.4)
  ps:setEmissionRate(50)
  ps:setSpeed(30, 90)
  ps:setSpread(math.pi * 2)
  ps:setColors(1, 0.9, 0.2, 1, 1, 0.2, 0.1, 0)
  ps:setSizes(1.2, 0.2)
  font = love.graphics.newFont(22)
  small = love.graphics.newFont(16)
  beepHigh, beepLow = tone(880, 0.25), tone(330, 0.35)

  if love.filesystem.getInfo("runs.txt") then
    runs = tonumber((love.filesystem.read("runs.txt"))) or 0
  end
  runs = runs + 1
  love.filesystem.write("runs.txt", tostring(runs))
end

function love.update(dt)
  t = t + dt
  local speed = 160 * dt
  if love.keyboard.isDown("left") then x = x - speed end
  if love.keyboard.isDown("right") then x = x + speed end
  if love.keyboard.isDown("up") then y = y - speed end
  if love.keyboard.isDown("down") then y = y + speed end
  x = math.max(20, math.min(620, x))
  y = math.max(180, math.min(460, y))
  ps:setPosition(x, y)
  ps:update(dt)
end

function love.keypressed(key)
  remember(keys, key)
  if key == "space" then beepHigh:stop() beepHigh:play() end
  if key == "lctrl" then beepLow:stop() beepLow:play() end
end

function love.gamepadpressed(_, button)
  remember(pads, button)
end

function love.draw()
  local G = love.graphics
  G.clear(0.08, 0.09, 0.12)

  -- picture
  G.setColor(0.2, 0.25, 0.35)
  G.rectangle("fill", 0, 0, 640, 40)
  G.setColor(1, 1, 1)
  G.setFont(font)
  G.print("love-mini check", 12, 8)
  G.setFont(small)
  G.printf(string.format("%d fps", love.timer.getFPS()), 0, 12, 628, "right")

  G.draw(img, 110, 110, t, 1 + 0.3 * math.sin(t * 2), nil, 24, 24)
  G.setColor(0.9, 0.4, 0.3)
  G.circle("line", 110, 110, 50 + 6 * math.sin(t * 3))
  G.setColor(1, 1, 1)

  -- buttons
  G.print("keys:", 240, 60)
  G.print("gamepad:", 420, 60)
  for i, k in ipairs(keys) do G.print(k, 240, 60 + i * 20) end
  for i, b in ipairs(pads) do G.print(b, 420, 60 + i * 20) end

  -- the square and its particles
  G.draw(ps)
  G.setColor(0.3, 0.9, 0.5)
  G.rectangle("fill", x - 12, y - 12, 24, 24, 4, 4)

  -- sound and saves
  G.setColor(0.75, 0.8, 0.9)
  G.print("A: high tone   B: low tone   d-pad: move", 12, 420)
  G.print(string.format("runs: %d (saved in %s)", runs, love.filesystem.getSaveDirectory()), 12, 440)
  G.print("Select + Start (hold): quit", 12, 460)
  G.setColor(1, 1, 1)
end
