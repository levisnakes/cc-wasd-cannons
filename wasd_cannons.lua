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
--
-- Turn speed comes from the controllers' rotation speed (RPM / 24 degrees a
-- tick). For slower aiming give the controllers less RPM.

KEYS = { up = "w", down = "s", left = "a", right = "d", fire = "space",
         slow = "leftShift", select = "tab" }
SLOW = 0.25               -- speed multiplier while SHIFT is held
INVERT_YAW = false        -- true if A turns right
INVERT_PITCH = false      -- true if W points down
YAW_MIN = nil             -- limits in degrees from center (nil = no limit)
YAW_MAX = nil
PITCH_MIN = -30
PITCH_MAX = 60
YAW_SPEED = 30            -- degrees per second, only used if the RPM can't be read
PITCH_SPEED = 30
CANNONS = nil             -- nil = auto. Or {{yaw="...", pitch="...", fire="..."}, {...}}
ARMED_AT_START = true     -- false = start with the safety on
AUTO_UPDATE = true

if fs and fs.exists("/config.lua") then
  local f, err = loadfile("/config.lua", nil, _ENV)
  if not f then error("/config.lua: " .. err, 0) end
  f()
end

-- ============================================================ setup

VERSION = "1.1.0"
local SAVE_FILE = "/wasd_cannons.dat"
local TICK = 0.05
local FIRE_EVERY = 0.25     -- Fire Controller stops 10 ticks after the last command
local LEAD = 0.4            -- seconds the target runs ahead while a key is held
local DEG = "\176"

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
local extras = 0            -- controllers with no partner (ignored)
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
  extras = 0
  if type(CANNONS) == "table" then
    cannons = CANNONS
    return
  end
  table.sort(yaws, byNumber); table.sort(pitches, byNumber); table.sort(fires, byNumber)
  local list = {}
  for i = 1, math.max(#yaws, #pitches, #fires) do
    local c = { yaw = yaws[i], pitch = pitches[i], fire = fires[i] }
    -- a lone controller (e.g. one seen twice) is not a cannon
    local parts = (c.yaw and 1 or 0) + (c.pitch and 1 or 0) + (c.fire and 1 or 0)
    if parts >= 2 then list[#list + 1] = c else extras = extras + 1 end
  end
  cannons = list
end

-- ============================================================ state

local aim = { yaw = 0, pitch = 0, yawZero = 0, pitchZero = 0 }
local selected = 0          -- 0 = all cannons
local armed = ARMED_AT_START ~= false
local firing = false
local held = {}
local kbHeld = {}
local twError = nil
local status, statusAt = "", 0
local dirty = false
local rate = { yaw = nil, pitch = nil }   -- deg/s from RPM, nil = unknown
local rpm = {}                             -- [controller name] = rpm or false
local sent = {}                            -- [controller name] = last target

local function say(text) status, statusAt = text, now() end

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
  if selected == 0 or not cannons[selected] then return cannons end
  return { cannons[selected] }
end

local function clamp(v, lo, hi)
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

-- Create moves the mount RPM/24 degrees a tick, so 20 ticks = RPM * 5/6 deg/s
local function readRates()
  for _, c in ipairs(cannons) do
    for _, n in ipairs({ c.yaw, c.pitch }) do
      local s = call(n, "getSpeed")
      rpm[n] = type(s) == "number" and math.abs(s) or false
    end
  end
  for _, axis in ipairs({ "yaw", "pitch" }) do
    local slowest = nil
    for _, c in ipairs(active()) do
      local r = rpm[c[axis]]
      if r then slowest = math.min(slowest or math.huge, r * 20 / 24) end
    end
    rate[axis] = slowest
  end
end

local function axisRate(axis)
  if rate[axis] then return rate[axis] end
  return axis == "yaw" and YAW_SPEED or PITCH_SPEED
end

local function sendTarget(name, value, force)
  if not name then return end
  if not force and sent[name] and math.abs(sent[name] - value) < 0.01 then return end
  call(name, "setAngle", value)
  sent[name] = value
end

-- lead > 0 keeps the target ahead so the mount turns without stopping
local function pushAim(yawLead, pitchLead, force)
  local y = aim.yawZero + clamp(aim.yaw + (yawLead or 0), YAW_MIN, YAW_MAX)
  local p = aim.pitchZero + clamp(aim.pitch + (pitchLead or 0), PITCH_MIN, PITCH_MAX)
  for _, c in ipairs(active()) do
    sendTarget(c.yaw, y, force)
    sendTarget(c.pitch, p, force)
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

-- ============================================================ screen

local W, H = term.getSize()
local screen = window.create(term.current(), 1, 1, W, H, false)

local function put(x, y, text, fg, bg)
  screen.setCursorPos(x, y)
  screen.setTextColor(fg or colors.white)
  screen.setBackgroundColor(bg or colors.black)
  screen.write(text)
end

local function fill(y, bg)
  put(1, y, string.rep(" ", W), colors.white, bg)
end

local function keyCap(x, y, label, on)
  put(x, y, " " .. label .. " ", on and colors.black or colors.lightGray, on and colors.white or colors.gray)
  return x + #label + 2
end

-- horizontal gauge: label, bar between lo..hi, marker at v
local function gauge(y, label, v, lo, hi, moving)
  put(2, y, label, colors.lightGray)
  local value = string.format("%7.1f%s", v, DEG)
  local x0, x1 = 9, W - #value - 2
  local width = x1 - x0 + 1
  local bar = {}
  for i = 1, width do bar[i] = "\140" end
  local zero = math.floor((0 - lo) / (hi - lo) * (width - 1) + 0.5) + 1
  if zero >= 1 and zero <= width then bar[zero] = "\149" end
  put(x0, y, table.concat(bar), colors.gray)
  local pos = math.floor((clamp(v, lo, hi) - lo) / (hi - lo) * (width - 1) + 0.5) + x0
  put(pos, y, "\143", moving and colors.yellow or colors.orange)
  put(x1 + 2, y, value, moving and colors.yellow or colors.white)
end

local function draw()
  screen.setVisible(false)
  screen.setBackgroundColor(colors.black)
  screen.clear()

  -- title bar
  fill(1, colors.blue)
  put(2, 1, "WASD CANNONS", colors.white, colors.blue)
  put(15, 1, "v" .. VERSION, colors.lightBlue, colors.blue)
  local chip, chipBg = " ARMED ", colors.orange
  if not armed then chip, chipBg = " SAFE ", colors.green
  elseif firing then chip, chipBg = " FIRING ", colors.red end
  put(W - #chip + 1, 1, chip, colors.white, chipBg)

  -- aim gauges
  local yawDir, pitchDir = axis(KEYS.right, KEYS.left), axis(KEYS.up, KEYS.down)
  local ylo, yhi = YAW_MIN or -180, YAW_MAX or 180
  local shownYaw = aim.yaw
  if not YAW_MIN and not YAW_MAX then shownYaw = (aim.yaw + 180) % 360 - 180 end
  gauge(3, "Yaw", shownYaw, ylo, yhi, yawDir ~= 0)
  gauge(4, "Pitch", aim.pitch, PITCH_MIN or -90, PITCH_MAX or 90, pitchDir ~= 0)
  local function speedText(a)
    if rate[a] then return string.format("%.0f%s/s", rate[a], DEG) end
    return "? " .. DEG .. "/s"
  end
  put(2, 5, "Turn speed  yaw " .. speedText("yaw") .. "  pitch " .. speedText("pitch"), colors.gray)

  -- cannons
  put(2, 7, "CANNONS", colors.lightGray)
  local aimText = selected == 0 and "aiming all" or ("aiming #" .. selected)
  put(W - #aimText, 7, aimText, colors.cyan)
  local y = 8
  if #cannons == 0 then
    put(3, y, "No controllers found. Check the modems.", colors.red); y = y + 1
  end
  for i, c in ipairs(cannons) do
    if y > H - 6 then break end
    local on = selected == 0 or selected == i
    local bg = on and colors.gray or colors.black
    put(2, y, string.rep(" ", W - 2), colors.white, bg)
    put(3, y, (on and "\16 " or "  ") .. "#" .. i, on and colors.white or colors.lightGray, bg)
    local x = 10
    for _, part in ipairs({ "yaw", "pitch", "fire" }) do
      local ok = c[part] ~= nil
      local r = rpm[c[part]]
      local col = ok and colors.lime or colors.red
      if ok and part ~= "fire" and r == 0 then col = colors.orange end
      put(x, y, part, col, bg)
      x = x + #part + 1
    end
    local info = ""
    if c.yaw and rpm[c.yaw] == 0 then info = "no rotation"
    elseif c.yaw and rpm[c.yaw] then info = string.format("%.0f rpm", rpm[c.yaw]) end
    put(W - #info - 1, y, info, rpm[c.yaw] == 0 and colors.orange or colors.lightGray, bg)
    y = y + 1
  end
  if extras > 0 then put(3, y, extras .. " lone controller(s) ignored", colors.gray); y = y + 1 end

  -- live keys
  local ky = H - 4
  local function k(name) return down(KEYS[name]) end
  keyCap(6, ky, "W", k("up"))
  local x = keyCap(2, ky + 1, "A", k("left"))
  x = keyCap(x + 1, ky + 1, "S", k("down"))
  keyCap(x + 1, ky + 1, "D", k("right"))
  x = keyCap(17, ky + 1, "SPACE", k("fire"))
  x = keyCap(x + 1, ky + 1, "SHIFT", k("slow"))
  keyCap(x + 1, ky + 1, "TAB", false)
  local tw = typewriter and "typewriter ok" or "NO TYPEWRITER"
  put(W - #tw, ky, tw, typewriter and colors.gray or colors.red)
  if twError then put(17, ky, twError:sub(1, W - 18), colors.red) end

  -- status + footer
  if status ~= "" and now() - statusAt < 4 then put(2, H - 1, status, colors.yellow) end
  fill(H, colors.gray)
  put(2, H, "H center  Z set center  X safety", colors.white, colors.gray)

  screen.setVisible(true)
end

-- ============================================================ loops

local function controlLoop()
  local last = now()
  local lastFire, lastDraw, lastSave, lastScan, lastRate = 0, 0, now(), now(), 0
  local wasMoving = false
  while true do
    local t = now()
    local dt = math.min(t - last, 0.25)
    last = t
    if t - lastScan > 5 then findAll(); lastScan = t end
    if t - lastRate > 1 then readRates(); lastRate = t end
    poll()

    local slow = down(KEYS.slow)
    local yawDir = axis(KEYS.right, KEYS.left) * (INVERT_YAW and -1 or 1)
    local pitchDir = axis(KEYS.up, KEYS.down) * (INVERT_PITCH and -1 or 1)
    local yr, pr = axisRate("yaw"), axisRate("pitch")
    local mult = slow and SLOW or 1
    aim.yaw = clamp(aim.yaw + yawDir * yr * mult * dt, YAW_MIN, YAW_MAX)
    aim.pitch = clamp(aim.pitch + pitchDir * pr * mult * dt, PITCH_MIN, PITCH_MAX)

    local moving = yawDir ~= 0 or pitchDir ~= 0
    if moving then
      -- full speed: run the target ahead; slow: track exactly
      local yl = slow and 0 or yawDir * math.min(yr * LEAD, 150)
      local pl = slow and 0 or pitchDir * math.min(pr * LEAD, 150)
      pushAim(yl, pl)
      dirty = true
    elseif wasMoving then
      pushAim(0, 0)       -- let go: stop where the mount is now
    end
    wasMoving = moving

    if armed and down(KEYS.fire) then
      if not firing or t - lastFire >= FIRE_EVERY then
        for _, c in ipairs(active()) do call(c.fire, "keepFiring") end
        firing, lastFire = true, t
      end
    elseif firing then
      stopFire()
    end

    if dirty and not moving and t - lastSave > 2 then saveAim(); dirty = false; lastSave = t end
    if t - lastDraw >= 0.1 then draw(); lastDraw = t end
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
        say(selected == 0 and "Aiming all cannons" or ("Aiming cannon #" .. selected))
        readRates()
        pushAim(0, 0, true)
      elseif a == keys.h then
        aim.yaw, aim.pitch = 0, 0
        pushAim(0, 0, true); saveAim()
        say("Back to center")
      elseif a == keys.z then
        aim.yawZero = aim.yawZero + aim.yaw
        aim.pitchZero = aim.pitchZero + aim.pitch
        aim.yaw, aim.pitch = 0, 0
        saveAim()
        say("Center set here")
      elseif a == keys.x then
        armed = not armed
        if not armed then stopFire() end
        say(armed and "Armed" or "Safety on")
      end
    elseif ev == "key_up" then
      kbHeld[a] = nil
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      findAll()
      readRates()
    elseif ev == "term_resize" then
      W, H = term.getSize()
      screen.reposition(1, 1, W, H)
    end
  end
end

function readyToUpdate() return not firing and next(held) == nil end

findAll()
if not loadAim() and cannons[1] then
  -- first run: start from wherever cannon 1 is pointed
  aim.yawZero = call(cannons[1].yaw, "getAngle") or 0
  aim.pitchZero = call(cannons[1].pitch, "getAngle") or 0
end
readRates()
pushAim(0, 0, true)

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
