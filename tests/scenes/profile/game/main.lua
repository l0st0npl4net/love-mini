-- A profile's changes to a game as it loads (lovemini/patch.lua), with what a game
-- does around them: a thread from a file, file data made by hand. Run with
--   PROFILE=tests/scenes/profile/prof/profile.lua tools/run.sh tests/scenes/profile/game 5
-- and every "T" line should say ok.
local function check(what, ok) print("T " .. what .. ": " .. (ok and "ok" or "WRONG")) end
function love.load()
  check("env", os.getenv("LOVEMINI_TEST") == "42")
  check("files", love.filesystem.read("data.txt") == "the profile's\n")
  check("edits", EDITED == true)
  check("lua", EXTRA == "from the profile")
  local t = love.thread.newThread("worker.lua")
  t:start()
  check("thread", love.thread.getChannel("out"):demand(5) == "hello")
  local fd = love.filesystem.newFileData("abc", "name.txt")
  check("newFileData", fd:getFilename() == "name.txt" and fd:getSize() == 3)
end
function love.draw() end
