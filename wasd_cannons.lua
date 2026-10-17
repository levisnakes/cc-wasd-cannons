-- WASD Cannons: aim and fire Create Big Cannons by hand from a Linked Typewriter.
--
-- One computer. On its wired network (or touching it): the Linked Typewriter
-- plus, for each cannon, an Auto Yaw Controller, an Auto Pitch Controller and
-- a Fire Controller. Controllers are paired by name order (lowest yaw goes
-- with lowest pitch and lowest fire). If that pairs them wrong, press TAB
-- to pick one cannon and see which one moves, or set CANNONS below.
--
-- The typewriter only sends keys that are bound to a frequency, so bind
-- W A S D, SPACE, LEFT SHIFT and TAB on it. The computer's own keyboard works too.
--   W/S   pitch up/down        A/D   yaw left/right
--   SPACE fire (hold)          SHIFT slow aim
--   TAB   both / cannon 1 / cannon 2
--   On the computer keyboard: H back to center, Z set here as center, X safety

KEYS = { up = "w", down = "s", left = "a", right = "d", fire = "space",
         slow = "leftShift", select = "tab" }
YAW_SPEED = 30            -- degrees per second while a key is held
PITCH_SPEED = 20
SLOW = 0.25               -- speed multiplier while SHIFT is held
INVERT_YAW = false        -- true if A turns right
INVERT_PITCH = false      -- true if W points down
YAW_MIN = nil             -- limits in degrees from center (nil = no limit)
YAW_MAX = nil
PITCH_MIN = -30
PITCH_MAX = 60
CANNONS = nil             -- nil = auto. Or {{yaw="...", pitch="...", fire="..."}, {...}}
ARMED_AT_START = true     -- false = start with the safety on
AUTO_UPDATE = true

if fs and fs.exists("/config.lua") then
  local f, err = loadfile("/config.lua", nil, _ENV)
  if not f then error("/config.lua: " .. err, 0) end
  f()
end

-- ============================================================ setup

VERSION = "1.0.0"
local SAVE_FILE = "/wasd_cannons.dat"
local TICK = 0.05
local FIRE_EVERY = 0.25     -- Fire Controller stops 10 ticks after the last command

local function now() return os.epoch("utc") / 1000 end

-- remote peripherals show up twice with two modems, so de-duplicate
local function names()
  local seen, out = {}, {}
  for _, n in ipairs(peripheral.getNames()) do
    if not seen[n] then seen[n] = true; out[#out + 1] = n end
  end
  return out
end

local function hasType(name, t)
  if peripheral.hasType and peripheral.hasType(name, t) then return true end
  for _, x in ipairs({ peripheral.getType(name) }) do
    if x == t then return true end
  end
  return false
end

local function isType(name, short)
  return hasType(name, "create_radar:" .. short) or hasType(name, short)
end

local function call(name, method, ...)
  if not name then return nil, "not connected" end
  local ok, a = pcall(peripheral.call, name, method, ...)
  if not ok then return nil, a end
  return a
end

local cannons = {}
local typewriter = nil

-- names sort as text, so "_10" would come before "_2" without this
local function byNumber(a, b)
  local pa, na = a:match("^(.-)(%d*)$")
  local pb, nb = b:match("^(.-)(%d*)$")
  if pa ~= pb then return a < b end
  return (tonumber(na) or -1) < (tonumber(nb) or -1)
end

local function findAll()
  typewriter = nil
  local yaws, pitches, fires = {}, {}, {}
  for _, n in ipairs(names()) do
    if isType(n, "auto_yaw_controller") or isType(n, "yaw_controller") then yaws[#yaws + 1] = n
    elseif isType(n, "auto_pitch_controller") or isType(n, "pitch_controller") then pitches[#pitches + 1] = n
    elseif isType(n, "fire_controller") then fires[#fires + 1] = n
    elseif not typewriter and hasType(n, "linked_typewriter") then typewriter = n end
  end
  if type(CANNONS) == "table" then
    cannons = CANNONS
    return
  end
  table.sort(yaws, byNumber); table.sort(pitches, byNumber); table.sort(fires, byNumber)
  cannons = {}
  for i = 1, math.max(#yaws, #pitches, #fires) do
    cannons[i] = { yaw = yaws[i], pitch = pitches[i], fire = fires[i] }
  end
end

-- ============================================================ state

local aim = { yaw = 0, pitch = 0, yawZero = 0, pitchZero = 0 }
local selected = 0          -- 0 = all cannons
local armed = ARMED_AT_START ~= false
local firing = false
local held = {}
local kbHeld = {}
local twError = nil
local status = ""
local dirty = false

local function saveAim()
  local f = fs.open(SAVE_FILE, "w")
  if f then f.write(textutils.serialize(aim)); f.close() end
end

local function loadAim()
  if not fs.exists(SAVE_FILE) then return false end
  local f = fs.open(SAVE_FILE, "r")
  local t = textutils.unserialize(f.readAll())
  f.close()
  if type(t) ~= "table" then return false end
  for k in pairs(aim) do if type(t[k]) == "number" then aim[k] = t[k] end end
  return true
end

local function active()
  if selected == 0 then return cannons end
  return { cannons[selected] }
end

local function clamp(v, lo, hi)
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

local function pushAim()
  for _, c in ipairs(active()) do
    call(c.yaw, "setAngle", aim.yawZero + aim.yaw)
    call(c.pitch, "setAngle", aim.pitchZero + aim.pitch)
  end
end

local function stopFire()
  for _, c in ipairs(cannons) do call(c.fire, "fireOff") end
  firing = false
end

-- ============================================================ keys

local function poll()
  local h = {}
  if typewriter then
    local ok, codes = pcall(peripheral.call, typewriter, "getPressedKeyCodes")
    if ok and type(codes) == "table" then
      for _, c in ipairs(codes) do h[c] = true end
      twError = nil
    elseif not ok then
      twError = tostring(codes)
    end
  end
  -- typewriter key events land here too; drop them if no key_up comes
  for c, t in pairs(kbHeld) do
    if now() - t < 0.7 then h[c] = true else kbHeld[c] = nil end
  end
  held = h
end

local function down(name) return keys[name] ~= nil and held[keys[name]] == true end

local function axis(plus, minus)
  local p, m = down(plus), down(minus)
  if p and not m then return 1 elseif m and not p then return -1 end
  return 0
end

local function heldText()
  local out = {}
  for c in pairs(held) do out[#out + 1] = (keys.getName and keys.getName(c)) or tostring(c) end
  table.sort(out)
  return #out == 0 and "none" or table.concat(out, " ")
end

-- ============================================================ screen

local function draw()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  print("WASD Cannons v" .. VERSION)
  term.setTextColor(colors.white)
  print("Typewriter: " .. (typewriter or "MISSING"))
  if twError then term.setTextColor(colors.red); print("  " .. twError); term.setTextColor(colors.white) end
  print("Cannons found: " .. #cannons)
  for i, c in ipairs(cannons) do
    local mark = (selected == 0 or selected == i) and "> " or "  "
    print(mark .. i .. ": yaw " .. (c.yaw and "ok" or "MISSING") .. ", pitch " .. (c.pitch and "ok" or "MISSING")
      .. ", fire " .. (c.fire and "ok" or "MISSING"))
  end
  print("")
  print(string.format("Yaw %7.1f   Pitch %6.1f", aim.yaw, aim.pitch))
  print("Aiming: " .. (selected == 0 and "ALL" or ("cannon " .. selected)))
  if not armed then term.setTextColor(colors.lime); print("SAFE (X to arm)")
  elseif firing then term.setTextColor(colors.red); print("FIRING")
  else term.setTextColor(colors.orange); print("ARMED") end
  term.setTextColor(colors.lightGray)
  print("Keys held: " .. heldText())
  print("WASD aim  SPACE fire  SHIFT slow  TAB pick")
  print("H center  Z set center  X safety")
  if status ~= "" then term.setTextColor(colors.white); print(status) end
  term.setTextColor(colors.white)
end

-- ============================================================ loops

local function controlLoop()
  local last = now()
  local lastFire, lastDraw, lastSave, lastScan = 0, 0, now(), now()
  while true do
    local t = now()
    local dt = math.min(t - last, 0.25)
    last = t
    if t - lastScan > 5 then findAll(); lastScan = t end
    poll()

    local speed = down(KEYS.slow) and SLOW or 1
    local yawDir = axis(KEYS.right, KEYS.left) * (INVERT_YAW and -1 or 1)
    local pitchDir = axis(KEYS.up, KEYS.down) * (INVERT_PITCH and -1 or 1)
    if yawDir ~= 0 or pitchDir ~= 0 then
      aim.yaw = clamp(aim.yaw + yawDir * YAW_SPEED * speed * dt, YAW_MIN, YAW_MAX)
      aim.pitch = clamp(aim.pitch + pitchDir * PITCH_SPEED * speed * dt, PITCH_MIN, PITCH_MAX)
      pushAim()
      dirty = true
    end

    if armed and down(KEYS.fire) then
      if not firing or t - lastFire >= FIRE_EVERY then
        for _, c in ipairs(active()) do call(c.fire, "keepFiring") end
        firing, lastFire = true, t
      end
    elseif firing then
      stopFire()
    end

    if dirty and t - lastSave > 2 then saveAim(); dirty = false; lastSave = t end
    if t - lastDraw >= 0.25 then draw(); lastDraw = t end
    sleep(TICK)
  end
end

local function eventLoop()
  while true do
    local ev, a = os.pullEvent()
    if ev == "key" then
      kbHeld[a] = now()
      if a == keys[KEYS.select] then
        selected = (selected + 1) % (#cannons + 1)
        status = "Aiming: " .. (selected == 0 and "all cannons" or ("cannon " .. selected))
        pushAim()
      elseif a == keys.h then
        aim.yaw, aim.pitch = 0, 0
        pushAim(); saveAim()
        status = "Back to center"
      elseif a == keys.z then
        aim.yawZero = aim.yawZero + aim.yaw
        aim.pitchZero = aim.pitchZero + aim.pitch
        aim.yaw, aim.pitch = 0, 0
        saveAim()
        status = "Center set here"
      elseif a == keys.x then
        armed = not armed
        if not armed then stopFire() end
        status = armed and "ARMED" or "Safety on"
      end
    elseif ev == "key_up" then
      kbHeld[a] = nil
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      findAll()
    end
  end
end

function readyToUpdate() return not firing and next(held) == nil end

findAll()
if not loadAim() and cannons[1] and cannons[1].yaw then
  -- first run: start from wherever cannon 1 is pointed
  aim.yawZero = call(cannons[1].yaw, "getAngle") or 0
  aim.pitchZero = cannons[1].pitch and call(cannons[1].pitch, "getAngle") or 0
end
pushAim()

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-wasd-cannons"
local UPDATE_FILE = "wasd_cannons.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end


bootUpdate()
parallel.waitForAny(controlLoop, eventLoop, updateLoop)
stopFire()
