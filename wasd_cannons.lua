-- WASD Cannons: aim and fire Create Big Cannons by hand from a Linked Typewriter.
--
-- One computer. On its wired network (or touching it): the Linked Typewriter
-- plus, for each cannon, an Auto Yaw Controller, an Auto Pitch Controller and
-- a Fire Controller. Controllers are paired by name order (lowest yaw goes
-- with lowest pitch and lowest fire). If that pairs them wrong, press TAB
-- to pick one cannon and see which one moves, or set CANNONS below.
--
-- The typewriter only sends keys that are bound to a frequency, so bind
-- W A S D, SPACE, LEFT SHIFT, TAB and Q on it. The computer's own keyboard works too.
--   W/S   pitch up/down        A/D   yaw left/right
--   SPACE fire (hold)          SHIFT slow aim
--   TAB   all / cannon 1 / cannon 2 / ...
--   Q     cannons in TOGGLE_CANNONS join SPACE or sit out
--   On the computer keyboard: H back to center, Z set here as center, X safety
--
-- Put a wired modem on each Cannon Mount too: then moving or firing while the
-- cannons are disassembled assembles them, and where they point on assembly
-- becomes the center.
--
-- Turn speed is MAX_YAW_SPEED / MAX_PITCH_SPEED, or the controllers' own top
-- speed (RPM / 24 degrees a tick) if that is slower.

KEYS = { up = "w", down = "s", left = "a", right = "d", fire = "space",
         slow = "leftShift", select = "tab" }
SLOW = 0.25               -- speed multiplier while SHIFT is held
INVERT_YAW = false        -- true if A turns right
INVERT_PITCH = false      -- true if W points down
YAW_MIN = nil             -- limits in degrees from center (nil = no limit)
YAW_MAX = nil
PITCH_MIN = -30
PITCH_MAX = 60
MAX_YAW_SPEED = 20        -- degrees per second
MAX_PITCH_SPEED = 15
CANNONS = nil             -- nil = auto. Or {{yaw="...", pitch="...", fire="..."}, {...}}
TOGGLE_CANNONS = { 3 }    -- these only fire with SPACE after Q turns them on
TOGGLE_KEY = "q"
ARMED_AT_START = true     -- false = start with the safety on
AUTO_UPDATE = true

if fs and fs.exists("/config.lua") then
  local f, err = loadfile("/config.lua", nil, _ENV)
  if not f then error("/config.lua: " .. err, 0) end
  f()
end

-- ============================================================ setup

VERSION = "1.4.0"
local SAVE_FILE = "/wasd_cannons.dat"
local TICK = 0.05
local FIRE_EVERY = 0.25     -- Fire Controller stops 10 ticks after the last command
local LEAD = 0.4            -- seconds the target runs ahead at full controller speed
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
local extras = 0            -- controllers with no partner
local all = { yaw = {}, pitch = {}, fire = {} }
local typewriter = nil
local mounts = {}           -- cannon mount names (cc-cbc / compact mount)
local mountInfo = {}        -- [name] = getInfo() table or false

-- names sort as text, so "_10" would come before "_2" without this
local function byNumber(a, b)
  local pa, na = a:match("^(.-)(%d*)$")
  local pb, nb = b:match("^(.-)(%d*)$")
  if pa ~= pb then return a < b end
  return (tonumber(na) or -1) < (tonumber(nb) or -1)
end

local function findAll()
  typewriter = nil
  mounts = {}
  local yaws, pitches, fires = {}, {}, {}
  for _, n in ipairs(names()) do
    if isType(n, "auto_yaw_controller") or isType(n, "yaw_controller") then yaws[#yaws + 1] = n
    elseif isType(n, "auto_pitch_controller") or isType(n, "pitch_controller") then pitches[#pitches + 1] = n
    elseif isType(n, "fire_controller") then fires[#fires + 1] = n
    elseif hasType(n, "cannon_mount") or hasType(n, "compact_cannon_mount") then mounts[#mounts + 1] = n
    elseif not typewriter and hasType(n, "linked_typewriter") then typewriter = n end
  end
  extras = 0
  all = { yaw = yaws, pitch = pitches, fire = fires }
  if type(CANNONS) == "table" then
    cannons = CANNONS
    table.sort(mounts, byNumber)
    all = { yaw = {}, pitch = {}, fire = {} }
    for _, c in ipairs(CANNONS) do
      for k in pairs(all) do if c[k] then table.insert(all[k], c[k]) end end
    end
    return
  end
  table.sort(yaws, byNumber); table.sort(pitches, byNumber); table.sort(fires, byNumber)
  table.sort(mounts, byNumber)
  local list = {}
  for i = 1, math.max(#yaws, #pitches, #fires) do
    local c = { yaw = yaws[i], pitch = pitches[i], fire = fires[i] }
    -- a lone controller is not shown as a cannon, but "all" still moves it
    local parts = (c.yaw and 1 or 0) + (c.pitch and 1 or 0) + (c.fire and 1 or 0)
    if parts >= 2 then list[#list + 1] = c else extras = extras + 1 end
  end
  cannons = list
end

-- ============================================================ state

-- assemYaw = mount yaw at the last assembly (assemKnown = 1 once seen)
local aim = { yaw = 0, pitch = 0, yawZero = 0, pitchZero = 0, assemYaw = 0, assemKnown = 0 }
local selected = 0          -- 0 = all cannons
local toggleOn = false      -- TOGGLE_CANNONS fire with SPACE
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

-- controller names for one part ("yaw"/"pitch"/"fire") of what TAB picked
local function targets(part)
  local c = selected > 0 and cannons[selected]
  if not c then return all[part] end
  return { c[part] }
end

local function clamp(v, lo, hi)
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

local function isToggled(i)
  for _, n in ipairs(TOGGLE_CANNONS or {}) do if n == i then return true end end
  return false
end

-- fire controllers SPACE triggers: a picked cannon always fires; with ALL
-- the toggle cannons only join while toggleOn
local function fireTargets()
  if selected > 0 and cannons[selected] then return { cannons[selected].fire } end
  local skip = {}
  if not toggleOn then
    for i, c in ipairs(cannons) do
      if isToggled(i) and c.fire then skip[c.fire] = true end
    end
  end
  local out = {}
  for _, n in ipairs(all.fire) do if not skip[n] then out[#out + 1] = n end end
  return out
end

-- mainThread calls each wait for a server tick, so run them side by side
local function runJobs(jobs, first)
  local fns = { first }
  for _, j in ipairs(jobs) do
    fns[#fns + 1] = function() pcall(peripheral.call, table.unpack(j)) end
  end
  if #fns > 0 then parallel.waitForAll(table.unpack(fns)) end
end

-- Create moves the mount RPM/24 degrees a tick, so 20 ticks = RPM * 5/6 deg/s
local function readRates()
  local fns = {}
  for _, part in ipairs({ "yaw", "pitch" }) do
    for _, n in ipairs(all[part]) do
      fns[#fns + 1] = function()
        local ok, sp = pcall(peripheral.call, n, "getSpeed")
        rpm[n] = ok and type(sp) == "number" and math.abs(sp) or false
      end
    end
  end
  for _, n in ipairs(mounts) do
    fns[#fns + 1] = function()
      local ok, info = pcall(peripheral.call, n, "getInfo")
      mountInfo[n] = ok and type(info) == "table" and info or false
    end
  end
  if #fns > 0 then parallel.waitForAll(table.unpack(fns)) end
  for _, part in ipairs({ "yaw", "pitch" }) do
    local slowest = nil
    for _, n in ipairs(targets(part)) do
      local r = rpm[n]
      if r and r > 0 then slowest = math.min(slowest or math.huge, r * 20 / 24) end
    end
    rate[part] = slowest
  end
end

-- turn speed in deg/s, and whether that is the controllers' own top speed
local function axisRate(part)
  local cap = part == "yaw" and MAX_YAW_SPEED or MAX_PITCH_SPEED
  local top = rate[part]
  if not top then return cap or 30, false end
  if cap and cap < top then return cap, false end
  return top, true
end

-- adds setAngle calls to jobs; lead > 0 keeps the target ahead of the mount
local function aimJobs(jobs, yawLead, pitchLead, force)
  local values = {
    yaw = aim.yawZero + clamp(aim.yaw + (yawLead or 0), YAW_MIN, YAW_MAX),
    pitch = aim.pitchZero + clamp(aim.pitch + (pitchLead or 0), PITCH_MIN, PITCH_MAX),
  }
  for part, v in pairs(values) do
    for _, n in ipairs(targets(part)) do
      if force or not sent[n] or math.abs(sent[n] - v) >= 0.01 then
        jobs[#jobs + 1] = { n, "setAngle", v }
        sent[n] = v
      end
    end
  end
  return jobs
end

local function pushAim(yawLead, pitchLead, force)
  runJobs(aimJobs({}, yawLead, pitchLead, force))
end

local function stopFire()
  local jobs = {}
  for _, n in ipairs(all.fire) do jobs[#jobs + 1] = { n, "fireOff" } end
  runJobs(jobs)
  firing = false
end

local function disassembled()
  local out = {}
  for _, n in ipairs(mounts) do
    local info = mountInfo[n]
    if info and info.assembled == false then out[#out + 1] = n end
  end
  return out
end

-- Assemble every disassembled mount. The controllers would swing a freshly
-- assembled cannon to their old target, so aim them at where the mount
-- faced last time first, then make the real heading the new center.
local function assembleMounts()
  local need = disassembled()
  if #need == 0 then return false end
  say("Assembling...")
  if aim.assemKnown == 1 then
    local jobs = {}
    for _, n in ipairs(all.yaw) do jobs[#jobs + 1] = { n, "setAngle", aim.assemYaw } end
    for _, n in ipairs(all.pitch) do jobs[#jobs + 1] = { n, "setAngle", 0 } end
    runJobs(jobs)
  end
  local jobs = {}
  for _, n in ipairs(need) do jobs[#jobs + 1] = { n, "assemble", true } end
  runJobs(jobs)
  readRates()
  local yaw = nil
  for _, n in ipairs(mounts) do
    local info = mountInfo[n]
    if info and info.assembled and type(info.yaw) == "number" then yaw = info.yaw; break end
  end
  if #disassembled() > 0 then
    say("Assembly failed - check the cannon build")
  else
    say("Assembled - this is the center")
  end
  if yaw then
    aim.yawZero, aim.pitchZero = yaw, 0
    aim.assemYaw, aim.assemKnown = yaw, 1
  end
  aim.yaw, aim.pitch = 0, 0
  pushAim(0, 0, true)
  saveAim()
  return true
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
    return string.format("%.0f%s/s", (axisRate(a)), DEG)
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
    if isToggled(i) then
      put(x + 1, y, "[" .. TOGGLE_KEY:upper() .. "] " .. (toggleOn and "ON " or "OFF"),
        toggleOn and colors.lime or colors.lightGray, bg)
    end
    local info = ""
    if c.yaw and rpm[c.yaw] == 0 then info = "no rotation"
    elseif c.yaw and rpm[c.yaw] then info = string.format("%.0f rpm", rpm[c.yaw]) end
    put(W - #info - 1, y, info, rpm[c.yaw] == 0 and colors.orange or colors.lightGray, bg)
    y = y + 1
  end
  if extras > 0 then put(3, y, "+" .. extras .. " unpaired controller(s), moved with ALL", colors.gray); y = y + 1 end
  if #mounts == 0 then
    put(3, y, "No mount on network: no auto-assemble", colors.gray)
  else
    local off = #disassembled()
    if off > 0 then
      put(3, y, off .. "/" .. #mounts .. " disassembled - move or fire to assemble", colors.orange)
    else
      put(3, y, #mounts .. " mount(s) assembled", colors.lime)
    end
  end
  y = y + 1

  -- live keys
  local ky = H - 4
  local function k(name) return down(KEYS[name]) end
  keyCap(6, ky, "W", k("up"))
  local x = keyCap(2, ky + 1, "A", k("left"))
  x = keyCap(x + 1, ky + 1, "S", k("down"))
  keyCap(x + 1, ky + 1, "D", k("right"))
  x = keyCap(17, ky + 1, "SPACE", k("fire"))
  x = keyCap(x + 1, ky + 1, "SHIFT", k("slow"))
  x = keyCap(x + 1, ky + 1, "TAB", false)
  keyCap(x + 1, ky + 1, TOGGLE_KEY:upper(), toggleOn)
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
  local wasToggleDown = false
  while true do
    local t = now()
    local dt = math.min(t - last, 0.25)
    last = t
    if t - lastScan > 5 then findAll(); lastScan = t end
    if t - lastRate > 1 then readRates(); lastRate = t end

    local wantsAction = axis(KEYS.right, KEYS.left) ~= 0 or axis(KEYS.up, KEYS.down) ~= 0
      or (armed and down(KEYS.fire))
    if wantsAction and #disassembled() > 0 then
      assembleMounts()
      t = now()
      last = t
      lastRate = t
    end

    local toggleDown = down(TOGGLE_KEY)
    local toggled = toggleDown and not wasToggleDown
    wasToggleDown = toggleDown

    local slow = down(KEYS.slow)
    local yawDir = axis(KEYS.right, KEYS.left) * (INVERT_YAW and -1 or 1)
    local pitchDir = axis(KEYS.up, KEYS.down) * (INVERT_PITCH and -1 or 1)
    local yr, yTop = axisRate("yaw")
    local pr, pTop = axisRate("pitch")
    local mult = slow and SLOW or 1
    aim.yaw = clamp(aim.yaw + yawDir * yr * mult * dt, YAW_MIN, YAW_MAX)
    aim.pitch = clamp(aim.pitch + pitchDir * pr * mult * dt, PITCH_MIN, PITCH_MAX)

    local jobs = {}
    local moving = yawDir ~= 0 or pitchDir ~= 0
    if moving then
      -- at the controllers' top speed the target has to run ahead or the
      -- mount stops between updates; slower than that it follows each tick
      local yl = (yTop and not slow) and yawDir * math.min(yr * LEAD, 150) or 0
      local pl = (pTop and not slow) and pitchDir * math.min(pr * LEAD, 150) or 0
      aimJobs(jobs, yl, pl)
      dirty = true
    elseif wasMoving then
      aimJobs(jobs, 0, 0)       -- let go: stop where the mount is now
    end
    wasMoving = moving

    if toggled then
      toggleOn = not toggleOn
      local list = {}
      for _, i in ipairs(TOGGLE_CANNONS or {}) do list[#list + 1] = "#" .. i end
      say("Cannon " .. table.concat(list, ", ") .. (toggleOn and " joins SPACE" or " sits out"))
      if not toggleOn and firing then
        for i, c in ipairs(cannons) do
          if isToggled(i) and c.fire then jobs[#jobs + 1] = { c.fire, "fireOff" } end
        end
      end
    end

    if armed and down(KEYS.fire) then
      if not firing or t - lastFire >= FIRE_EVERY or toggled then
        for _, n in ipairs(fireTargets()) do jobs[#jobs + 1] = { n, "keepFiring" } end
        firing, lastFire = true, t
      end
    elseif firing then
      for _, n in ipairs(all.fire) do jobs[#jobs + 1] = { n, "fireOff" } end
      firing = false
    end

    -- typewriter read, aim and trigger all go out in the same tick
    runJobs(jobs, poll)
    -- the typewriter read may not wait a tick; never spin without yielding
    if #jobs == 0 then sleep(TICK) end

    if dirty and not moving and t - lastSave > 2 then saveAim(); dirty = false; lastSave = t end
    if t - lastDraw >= 0.1 then draw(); lastDraw = t end
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
