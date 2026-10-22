-- The screen keyboard: text for games that ask for it (love.keyboard.setTextInput(true),
-- as on a phone) or, in any game, Select + Y. While it is open it takes the buttons:
--   d-pad   move            A      type the key (love.textinput)
--   B       delete (backspace)     Y      space
--   X       capitals on / off      Start  Enter, and close
--   Select  close
-- Backspace and Enter reach the game as keypressed / keyreleased, as from a keyboard.
local print = print  -- the log's: a game may make print() draw text (as in PICO-8)

local O = {}

local ROWS = {
  { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
  { "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" },
  { "a", "s", "d", "f", "g", "h", "j", "k", "l", "'" },
  { "z", "x", "c", "v", "b", "n", "m", ",", ".", "-" },
  { "shift", "space", "del", "enter" },
}
local SHIFTED = { ["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%", ["6"] = "^", ["7"] = "&",
  ["8"] = "*", ["9"] = "(", ["0"] = ")", ["'"] = '"', [","] = ";", ["."] = ":", ["-"] = "_" }
local LABEL = { shift = "Shift", space = "Space", del = "Del", enter = "Enter" }

local I
local open = false
local wanted = false     -- the game asked for text input
local row, col = 2, 1
local caps = false
local font, fontH

local function key(k)
  I.push("keypressed", k, k, false)
  I.push("keyreleased", k, k)
end

local function typeKey(k)
  if k == "shift" then caps = not caps
  elseif k == "space" then I.push("textinput", " ")
  elseif k == "del" then key("backspace")
  elseif k == "enter" then key("return"); O.close()
  else
    local t = k
    if caps then t = SHIFTED[k] or k:upper() end
    I.push("textinput", t)
  end
end

function O.open() open = true end
function O.close() open = false end
function O.isOpen() return open end

local C = {}
function C.active() return true end
function C.press(b, isrepeat)
  if not open then
    -- Select + Y opens it in any game
    if b == "y" and I.down.select then O.open(); return true end
    return false
  end
  local r = ROWS[row]
  if b == "up" then row = (row - 2) % #ROWS + 1
  elseif b == "down" then row = row % #ROWS + 1
  elseif b == "left" then col = (col - 2) % #r + 1
  elseif b == "right" then col = col % #r + 1
  elseif isrepeat then return true
  elseif b == "a" then typeKey(r[math.min(col, #r)])
  elseif b == "b" then key("backspace")
  elseif b == "y" then I.push("textinput", " ")
  elseif b == "x" then caps = not caps
  elseif b == "start" then key("return"); O.close()
  elseif b == "select" then O.close()
  end
  col = math.min(col, #ROWS[row])
  return true
end
function C.release() end
function C.update() end

function C.draw()
  if not open then return end
  local G = love.graphics
  local w, h = G.getDimensions()
  local kh = math.floor(h / 13)
  local top = h - kh * #ROWS - kh / 2
  if not font or fontH ~= kh then
    fontH = kh
    font = G.newFont(math.max(8, math.floor(kh * 0.55)))
  end
  G.push("all")
  G.setCanvas()
  G.setShader()
  G.setScissor()
  G.origin()
  G.setBlendMode("alpha")
  G.setColor(0, 0, 0, 0.8)
  G.rectangle("fill", 0, top - kh / 4, w, h - top + kh / 4)
  G.setFont(font)
  for ri, r in ipairs(ROWS) do
    local kw = w / #r
    for ci, k in ipairs(r) do
      local x, y = (ci - 1) * kw, top + (ri - 1) * kh
      local sel = ri == row and ci == math.min(col, #r)
      if sel then G.setColor(0.95, 0.75, 0.2, 1) else G.setColor(0.25, 0.27, 0.32, 1) end
      G.rectangle("fill", x + 2, y + 2, kw - 4, kh - 4, 3, 3)
      local label = LABEL[k] or ((caps and (SHIFTED[k] or k:upper())) or k)
      if k == "shift" and caps then label = "SHIFT" end
      if sel then G.setColor(0, 0, 0, 1) else G.setColor(1, 1, 1, 1) end
      G.printf(label, x, y + (kh - font:getHeight()) / 2, kw, "center")
    end
  end
  G.pop()
end

function O.install(input, boot)
  I = input
  I.addCapture(C)
  local K = love.keyboard
  function K.setTextInput(on)
    if on and not wanted then O.open() elseif not on then O.close() end
    wanted = on and true or false
  end
  function K.hasTextInput() return wanted or open end
  function K.hasScreenKeyboard() return true end
end

return O
