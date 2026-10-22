-- Native modules some LOVE games load that have no place on a Mini (a store's SDK):
-- a stand-in that takes any field and any call and does nothing, so the game runs
-- without it. Installed in package.preload before the game's main.lua.

local print = print  -- the log's: a game may make print() draw text (as in PICO-8)
local S = {}

local null
null = setmetatable({}, {
  __index = function() return null end,
  __call = function() return nil end,
})

S.modules = { "luasteam" }

function S.install()
  for _, name in ipairs(S.modules) do
    if not package.preload[name] then
      package.preload[name] = function()
        print("love-mini: " .. name .. " is not there; a stand-in that does nothing is used")
        return null
      end
    end
  end
end

return S
