-- A still scene for comparing renderer builds pixel for pixel (no time in it): the
-- blend paths of mini2d — alpha, tinted, scaled, flipped, canvases, alpha fills.
local img, canvas
function love.load()
  local d = love.image.newImageData(37, 29)
  d:mapPixel(function(x, y)
    local a = ((x * 7 + y * 13) % 256) / 255
    if x % 9 == 0 then a = 1 end
    if y % 7 == 0 then a = 0 end
    return x / 37, y / 29, 0.6, a
  end)
  img = love.graphics.newImage(d)
  canvas = love.graphics.newCanvas(200, 120)
end
function love.draw()
  local G = love.graphics
  G.clear(0.3, 0.2, 0.25)
  for i = 0, 7 do
    G.setColor(1, 1, 1, 1)
    G.draw(img, 10 + i * 45, 10)                          -- unscaled alpha
    G.setColor(0.2 + i * 0.1, 0.9 - i * 0.1, 0.5, 0.4 + i * 0.07)
    G.draw(img, 10 + i * 45, 50)                          -- tinted
    G.draw(img, 10 + i * 45, 120, 0, 1.3 + i * 0.2, 1.7)  -- tinted, scaled
    G.setColor(1, 1, 1, 1)
    G.draw(img, 50 + i * 45, 200, 0, -1.1 - i * 0.1, 1)   -- flipped, scaled
    G.setColor(0.9, 0.3, 0.1, 0.05 + i * 0.12)
    G.rectangle("fill", 5 + i * 40, 260, 61, 30)          -- alpha fills
    G.circle("fill", 30 + i * 40, 320, 23)
  end
  G.setCanvas(canvas)
  G.clear(0, 0, 0, 0)
  G.setColor(1, 1, 1, 1)
  for i = 0, 5 do G.draw(img, i * 30, i * 15, 0, 1.5, 1.5) end
  G.setColor(0.2, 0.8, 1, 0.5)
  G.rectangle("fill", 20, 20, 150, 40)
  G.setCanvas()
  G.setColor(1, 1, 1, 1)
  G.draw(canvas, 360, 260, 0, 1.37, 1.37)                -- a canvas enlarged
  G.setColor(1, 0.5, 0.5, 0.7)
  G.draw(canvas, 400, 40, 0, 1, 1)                       -- a canvas tinted
end
