-- Input for love-mini: the Mini's buttons (evdev, read by libmini2d) as LOVE sees a
-- keyboard and a gamepad at once.
--
-- * Keys: by default the keys the Mini's own SDL reports (Space, LCtrl, LShift,
--   LAlt, E, T, Tab, Backspace, RCtrl, Enter, Escape, arrows), so love-mini agrees
--   with other ports; a profile maps buttons to other keys (keys = { a = "z" }).
-- * Gamepad: one virtual "Miyoo Mini" joystick, a gamepad (love.joystick); its face
--   buttons by position, as on an Xbox pad (the Mini's bottom button B is the
--   gamepad's "a"), or by name with the profile's gamepad_layout = "nintendo".
-- * Select + Start held for a second quits.
-- Events go through a queue of love-mini's own ahead of LOVE's, so they carry Lua
-- objects (the Joystick) as LOVE's own events would.

local ffi = require("ffi")
local M = require("lovemini.m2d")

local I = {}

-- evdev codes of the Mini's buttons (OnionOS's keymap_hw.h)
local BUTTON = { [103] = "up", [108] = "down", [105] = "left", [106] = "right", [57] = "a", [29] = "b", [42] = "x",
  [56] = "y", [18] = "l1", [20] = "r1", [15] = "l2", [14] = "r2", [97] = "select", [28] = "start", [1] = "menu" }
local ORDER = { "a", "b", "x", "y", "l1", "r1", "l2", "r2", "select", "start", "menu", "up", "down", "left", "right" }

local KEYS = { up = "up", down = "down", left = "left", right = "right", a = "space", b = "lctrl", x = "lshift",
  y = "lalt", l1 = "e", r1 = "t", l2 = "tab", r2 = "backspace", select = "rctrl", start = "return", menu = "escape" }

local PAD_POSITION = { a = "b", b = "a", x = "y", y = "x" }
local PAD_NAME = { a = "a", b = "b", x = "x", y = "y" }
local PAD_COMMON = { l1 = "leftshoulder", r1 = "rightshoulder", select = "back", start = "start", menu = "guide",
  up = "dpup", down = "dpdown", left = "dpleft", right = "dpright" }

local queue = {}
local down = {}       -- buttons held: name -> true
local keyDown = {}    -- LOVE keys held
local padDown = {}    -- gamepad buttons held
local keyRepeat = false
local repeatAt = {}   -- button -> time of its next repeat
local comboSince = nil
local useKeys, usePad = true, true
local keys, pad = {}, {}
local joystick

local function push(...) queue[#queue + 1] = { n = select("#", ...), ... } end
local function now() return love.timer and love.timer.getTime() or os.clock() end

---------------------------------------------------------------------------
-- the virtual Joystick
---------------------------------------------------------------------------
local Joystick = {}
Joystick.__index = Joystick
function Joystick:type() return "Joystick" end
function Joystick:typeOf(t) return t == "Joystick" or t == "Object" end
function Joystick:release() return true end
function Joystick:getName() return "Miyoo Mini" end
function Joystick:getID() return 1, 1 end
function Joystick:getConnectedIndex() return 1 end
function Joystick:getGUID() return "4d69796f6f204d696e69000000000000" end
function Joystick:getDeviceInfo() return 0, 0, 0 end
function Joystick:isConnected() return true end
function Joystick:isGamepad() return true end
function Joystick:getButtonCount() return #ORDER end
function Joystick:getAxisCount() return 6 end
function Joystick:getHatCount() return 1 end
function Joystick:isDown(...)
  for _, i in ipairs({ ... }) do if ORDER[i] and down[ORDER[i]] then return true end end
  return false
end
function Joystick:isGamepadDown(...)
  for _, b in ipairs({ ... }) do if padDown[b] then return true end end
  return false
end
local function triggerValue(b) return down[b] and 1 or 0 end
function Joystick:getGamepadAxis(axis)
  if axis == "triggerleft" then return triggerValue("l2") end
  if axis == "triggerright" then return triggerValue("r2") end
  return 0
end
function Joystick:getAxis(i)
  if i == 5 then return triggerValue("l2") end
  if i == 6 then return triggerValue("r2") end
  return 0
end
function Joystick:getAxes() return 0, 0, 0, 0, triggerValue("l2"), triggerValue("r2") end
function Joystick:getHat()
  local v = (down.up and "u" or "") .. (down.down and "d" or "")
  local h = (down.left and "l" or "") .. (down.right and "r" or "")
  local s = v .. h
  return s == "" and "c" or s
end
function Joystick:getGamepadMapping() return nil end
function Joystick:getGamepadMappingString() return nil end
function Joystick:isVibrationSupported() return false end
function Joystick:setVibration() return false end
function Joystick:getVibration() return 0, 0 end

---------------------------------------------------------------------------
-- button events
---------------------------------------------------------------------------
local function press(b, isrepeat)
  if useKeys and keys[b] then
    local k = keys[b]
    keyDown[k] = true
    push("keypressed", k, k, isrepeat or false)
  end
  if isrepeat then return end
  if usePad then
    if b == "l2" or b == "r2" then
      push("gamepadaxis", joystick, b == "l2" and "triggerleft" or "triggerright", 1)
    elseif pad[b] then
      padDown[pad[b]] = true
      push("gamepadpressed", joystick, pad[b])
    end
    for i, name in ipairs(ORDER) do if name == b then push("joystickpressed", joystick, i) end end
  end
end

local function release(b)
  if useKeys and keys[b] then
    local k = keys[b]
    keyDown[k] = nil
    push("keyreleased", k, k)
  end
  if usePad then
    if b == "l2" or b == "r2" then
      push("gamepadaxis", joystick, b == "l2" and "triggerleft" or "triggerright", 0)
    elseif pad[b] then
      padDown[pad[b]] = nil
      push("gamepadreleased", joystick, pad[b])
    end
    for i, name in ipairs(ORDER) do if name == b then push("joystickreleased", joystick, i) end end
  end
end

---------------------------------------------------------------------------
-- captures: love-mini's own overlays (the screen keyboard, the cursor) take the
-- buttons they use before the game sees them. A capture is a table with
-- active(), press(b, isrepeat) -> true if it took the button, release(b),
-- update(dt) and draw(); the first that takes a press also gets its release.
---------------------------------------------------------------------------
local captures = {}
local takenBy = {}   -- button -> the capture that took its press

function I.addCapture(c) captures[#captures + 1] = c end
I.push = push
I.down = down

local function pressButton(b, isrepeat)
  if not isrepeat then takenBy[b] = nil end
  local owner = takenBy[b]
  if owner then owner.press(b, isrepeat); return end
  if not isrepeat then
    for _, c in ipairs(captures) do
      if c.active() and c.press(b, false) then takenBy[b] = c; return end
    end
  end
  press(b, isrepeat)
end

local function releaseButton(b)
  local owner = takenBy[b]
  takenBy[b] = nil
  if owner then owner.release(b) else release(b) end
end

local code, value = ffi.new("int[1]"), ffi.new("int[1]")
local lastPump

function I.pump()
  while M.m2d_poll_key(code, value) == 1 do
    local b = BUTTON[code[0]]
    if b then
      if value[0] == 1 and not down[b] then
        down[b] = true
        repeatAt[b] = now() + 0.4
        pressButton(b)
      elseif value[0] == 0 and down[b] then
        down[b] = nil
        repeatAt[b] = nil
        releaseButton(b)
      end
    end
  end
  local t = now()
  for b, at in pairs(repeatAt) do
    -- the game's key repeat, or a capture's (the screen keyboard's d-pad)
    if t >= at and (keyRepeat or takenBy[b]) then
      repeatAt[b] = t + (takenBy[b] and 0.08 or 0.05)
      pressButton(b, true)
    end
  end
  local dt = lastPump and (t - lastPump) or 0
  lastPump = t
  for _, c in ipairs(captures) do c.update(dt) end
  -- Select + Start held: quit
  if down.select and down.start then
    comboSince = comboSince or t
    if t - comboSince > 1 then
      comboSince = nil
      love.event.quit()
    end
  else
    comboSince = nil
  end
end

---------------------------------------------------------------------------
-- install
---------------------------------------------------------------------------
function I.install(boot)
  local p = boot.profile
  for b, k in pairs(KEYS) do keys[b] = k end
  for b, k in pairs(p.keys or {}) do keys[b] = k end
  local face = p.gamepad_layout == "nintendo" and PAD_NAME or PAD_POSITION
  for b, v in pairs(PAD_COMMON) do pad[b] = v end
  for b, v in pairs(face) do pad[b] = v end
  useKeys = p.keyboard ~= false
  usePad = p.gamepad ~= false
  joystick = setmetatable({}, Joystick)

  -- love.keyboard: the buttons' keys
  local K = love.keyboard or {}
  love.keyboard = K
  function K.isDown(...)
    for _, k in ipairs({ ... }) do if keyDown[k] then return true end end
    return false
  end
  K.isScancodeDown = K.isDown
  function K.setKeyRepeat(on) keyRepeat = on and true or false end
  function K.hasKeyRepeat() return keyRepeat end
  function K.getKeyFromScancode(s) return s end
  function K.getScancodeFromKey(k) return k end
  function K.setTextInput() end
  function K.hasTextInput() return false end
  function K.hasScreenKeyboard() return false end
  function K.isModifierActive() return false end

  -- love.joystick: the one virtual gamepad
  local J = love.joystick or {}
  love.joystick = J
  function J.getJoysticks() return usePad and { joystick } or {} end
  function J.getJoystickCount() return usePad and 1 or 0 end
  function J.setGamepadMapping() return true end
  function J.loadGamepadMappings() end
  function J.saveGamepadMappings() return "" end
  function J.getGamepadMappingString() return nil end

  -- love.mouse: none
  local Mo = love.mouse or {}
  love.mouse = Mo
  function Mo.getPosition() return 0, 0 end
  function Mo.getX() return 0 end
  function Mo.getY() return 0 end
  function Mo.isDown() return false end
  function Mo.setPosition() end
  function Mo.setVisible() end
  function Mo.isVisible() return false end
  function Mo.setGrabbed() end
  function Mo.isGrabbed() return false end
  function Mo.setRelativeMode() end
  function Mo.getRelativeMode() return false end
  function Mo.isCursorSupported() return false end
  function Mo.newCursor() return {} end
  function Mo.getSystemCursor() return {} end
  function Mo.setCursor() end
  function Mo.getCursor() return nil end

  -- events: love-mini's queue first, then LOVE's
  local E = love.event
  local origPump, origPoll = E.pump, E.poll
  function E.pump()
    origPump()
    I.pump()
  end
  function E.poll()
    local it = origPoll()
    return function()
      local e = table.remove(queue, 1)
      if e then return unpack(e, 1, e.n) end
      return it()
    end
  end
  if usePad then push("joystickadded", joystick) end

  require("lovemini.osk").install(I, boot)
  require("lovemini.pointer").install(I, boot)
  -- the overlays, drawn over the game's frame
  love.graphics._beforePresent = function()
    for _, c in ipairs(captures) do if c.active() then c.draw() end end
  end
end

return I
