return {
  env = { LOVEMINI_TEST = "42" },
  lua = "lua",
  files = { ["data.txt"] = "data.txt" },
  edits = {
    ["main.lua"] = {
      { "function love.load()", 'require "extra"\nEDITED = true\nfunction love.load()', 1 },
      { "not in the game", "x", optional = true },
    },
  },
}
