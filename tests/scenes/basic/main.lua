-- A scene with most of love.graphics: images (scaled, rotated, flipped, quads),
-- primitives, text, a canvas, blend modes, the stencil, a particle system.
local img, quad, canvas, font, ps, t

local function checker(w, h, s)
  local d = love.image.newImageData(w, h)
  d:mapPixel(function(x, y)
    local c = ((math.floor(x / s) + math.floor(y / s)) % 2 == 0) and 1 or 0.2
    local a = (x < 2 or y < 2) and 0 or 1
    return c, 0.6 * c + 0.2, 1 - c * 0.7, a
  end)
  return love.graphics.newImage(d)
end

function love.load()
  img = checker(64, 64, 8)
  quad = love.graphics.newQuad(0, 0, 32, 32, img:getDimensions())
  canvas = love.graphics.newCanvas(200, 150)
  font = love.graphics.newFont(24)
  local dot = love.image.newImageData(8, 8)
  dot:mapPixel(function() return 1, 1, 1, 1 end)
  ps = love.graphics.newParticleSystem(love.graphics.newImage(dot), 200)
  ps:setParticleLifetime(1, 2)
  ps:setEmissionRate(60)
  ps:setSpeed(40, 120)
  ps:setSpread(math.pi * 2)
  ps:setColors(1, 1, 0, 1, 1, 0, 0, 0)
  ps:setSizes(1, 0.2)
  t = 0
end

function love.update(dt)
  t = t + (1 / 30)
  ps:update(1 / 30)
end

function love.draw()
  love.graphics.clear(0.1, 0.1, 0.15)
  -- images
  love.graphics.draw(img, 20, 20)
  love.graphics.draw(img, 100, 20, 0, 2, 1)
  love.graphics.draw(img, 300, 84, 0, -1, 1)
  love.graphics.draw(img, quad, 320, 20, 0, 2, 2)
  love.graphics.draw(img, 460, 52, t, 1, 1, 32, 32)
  love.graphics.setColor(1, 0.5, 0.5, 0.7)
  love.graphics.draw(img, 540, 20, 0, 1, 1, 0, 0, 0.5, 0)
  love.graphics.setColor(1, 1, 1)
  -- primitives
  love.graphics.setColor(0.2, 0.8, 0.3)
  love.graphics.rectangle("fill", 20, 180, 120, 60)
  love.graphics.setColor(1, 1, 1)
  love.graphics.setLineWidth(3)
  love.graphics.rectangle("line", 160, 180, 120, 60, 12)
  love.graphics.circle("fill", 340, 210, 30)
  love.graphics.ellipse("line", 430, 210, 50, 25)
  love.graphics.polygon("fill", 500, 240, 540, 180, 580, 240)
  love.graphics.line(600, 180, 680, 240, 760, 180)
  love.graphics.arc("fill", 700, 300, 40, 0, math.pi * 1.5)
  love.graphics.setLineWidth(1)
  -- text
  love.graphics.setFont(font)
  love.graphics.print("Hello, love-mini!", 20, 260)
  love.graphics.printf("Centred, wrapped text in a column 200 wide.", 300, 260, 200, "center")
  love.graphics.print("rotated", 600, 330, -0.4)
  -- canvas
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.3, 0.1, 0.4, 1)
  love.graphics.setColor(1, 1, 0)
  love.graphics.circle("fill", 100, 75, 50)
  love.graphics.setColor(1, 1, 1)
  love.graphics.setCanvas()
  love.graphics.draw(canvas, 20, 380)
  -- blend modes
  love.graphics.setColor(1, 0, 0)
  love.graphics.rectangle("fill", 260, 400, 60, 60)
  love.graphics.setBlendMode("add")
  love.graphics.setColor(0, 0.8, 0)
  love.graphics.rectangle("fill", 290, 430, 60, 60)
  love.graphics.setBlendMode("multiply", "premultiplied")
  love.graphics.setColor(0.5, 0.5, 1)
  love.graphics.rectangle("fill", 275, 415, 60, 60)
  love.graphics.setBlendMode("alpha")
  love.graphics.setColor(1, 1, 1)
  -- stencil: an image through a circle
  love.graphics.stencil(function() love.graphics.circle("fill", 440, 450, 50) end, "replace", 1)
  love.graphics.setStencilTest("greater", 0)
  love.graphics.draw(img, 380, 390, 0, 2, 2)
  love.graphics.setStencilTest()
  -- transforms
  love.graphics.push()
  love.graphics.translate(620, 470)
  love.graphics.rotate(t * 0.5)
  love.graphics.setColor(0.4, 0.7, 1)
  love.graphics.rectangle("fill", -40, -20, 80, 40)
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1)
  -- particles
  love.graphics.draw(ps, 720, 520)
end
