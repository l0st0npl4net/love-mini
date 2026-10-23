-- The texture budget and scaled copies (lovemini/graphics.lua). Run with
--   LOVEMINI_TEXTURE_MB=2 tools/run.sh tests/scenes/budget 200
-- and every "T" line should say ok.
local function check(what, ok) print("T " .. what .. ": " .. (ok and "ok" or "WRONG")) end
local function picture(w, h, r, g, b)
  local d = love.image.newImageData(w, h)
  d:mapPixel(function() return r, g, b, 1 end)
  return love.graphics.newImage(d:encode("png"))   -- FileData: one that can be loaded again
end
local kept, old, atlas, small
local frame = 0
function love.load()
  kept = picture(512, 512, 1, 0, 0)   -- 1 MB, drawn every frame
  old = picture(512, 512, 0, 1, 0)    -- 1 MB, drawn once
  atlas = picture(1024, 1024, 0, 0, 1)
  small = picture(64, 64, 1, 1, 0)
end
function love.draw()
  frame = frame + 1
  love.graphics.draw(kept, 0, 0, 0, 0.25)
  if frame == 1 then love.graphics.draw(old, 200, 0, 0, 0.25) end
  love.graphics.draw(atlas, 0, 200, 0, 0.8)   -- a copy would be bigger than the screen
  love.graphics.draw(small, 300, 200, 0, 2)
  if frame == 2 then
    check("no copy bigger than the screen", atlas.scaled == nil)
    check("a copy of a small one", small.scaled ~= nil)
    local c = love.graphics.newCanvas(64, 64)
    love.graphics.setCanvas(c)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.draw(atlas, 0, 0, 0, 0.05)
    love.graphics.setCanvas()
    local r, g, b = c:newImageData():getPixel(10, 10)
    check("the atlas drawn scaled", r < 0.1 and g < 0.1 and b > 0.9)
  end
  if frame == 190 then
    check("what is drawn stays", kept.surf ~= nil)
    check("what was not drawn for a while goes", old.surf == nil)
  end
end
