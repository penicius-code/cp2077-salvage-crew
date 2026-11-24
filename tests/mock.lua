-- Mock run of CyberslopSalvage 1.1.1 init.lua: stubs the CET / game API and the redscript system.
-- Run: luajit mock.lua <path to init.lua>     (writes nothing: the mod's log is kept in memory)
local INIT = arg[1]
local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1 else fail = fail + 1 print("FAIL: " .. name) end
end

-- ---------------------------------------------------------------- world
local notices, logLines = {}, {}
local world = { ents = {}, gameTime = 0.0, bag = { [0] = 0, [1] = 0, [2] = 0 }, money = 0 }
local nextHash = 100

local function V4(x, y, z) return { x = x, y = y, z = z, w = 1 } end

local function newEnt(kind, x, y, z, opts)
  nextHash = nextHash + 1
  opts = opts or {}
  local e = { kind = kind, pos = V4(x, y, z), hash = nextHash, items = opts.items or {},
              dead = opts.dead or false, civ = opts.civ or false, defined = true, yaw = 0,
              own = opts.own, van = opts.van, bike = opts.bike }
  function e:GetWorldPosition() return V4(self.pos.x, self.pos.y, self.pos.z) end
  function e:GetWorldForward() return { x = 0, y = 1, z = 0 } end
  function e:GetWorldYaw() return self.yaw end
  function e:GetEntityID() return { hash = self.hash } end
  function e:IsPlayer() return self.kind == "player" end
  function e:IsNPC() return self.kind == "npc" or self.kind == "unit" end
  function e:IsDead() return self.dead end
  function e:IsCrowd() return false end
  function e:IsCharacterCivilian() return self.civ end
  function e:IsInCombat() return world.combat == true end
  function e:IsA(c) return c == "gameItemDropObject" and self.kind == "drop" end
  function e:GetHighLevelStateFromBlackboard() return self.dead and "Dead" or "Relaxed" end
  function e:GetAttitudeAgent()
    return { SetAttitudeGroup = function() end, SetAttitudeTowards = function() end }
  end
  function e:GetSensesComponent() return { Toggle = function(_, on) self.senses = on end } end
  function e:GetAIControllerComponent()
    return {
      SendCommand = function(_, cmd)
        if cmd.kind == "move" then self.moveTarget = cmd.target end
        if cmd.kind == "hold" then self.holding = true end
      end,
      CancelOrInterruptCommand = function(_, name)
        if name == "AIHoldPositionCommand" then self.holding = false end
        if name == "AIMoveToCommand" then self.moveTarget = nil end
        return true
      end,
    }
  end
  world.ents[#world.ents + 1] = e
  return e
end

local player = newEnt("player", 0, 0, 0)
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

-- ---------------------------------------------------------------- fake redscript system
local R = { rows = {}, nextId = 1, version = 1, jobs = {}, lastCash = 0, lastLeft = 0, paid = {},
            wear = { 0, 0, 0, 0, 0, 0 }, served = { 0, 0, 0, 0, 0, 0 }, field = { 0, 0, 0, 0, 0, 0 },
            fieldAt = { 0, 0, 0, 0, 0, 0 }, serviceText = "", carHow = "none" }
local KG = { gun = 4.0, jacket = 1.5, junk = 0.5, ammo = 0.0, comp = 0.0 }
local CATOF = { gun = 0, jacket = 1, junk = 8, ammo = 6, comp = 7 }
local RATE = { [0] = 0.6, [1] = 0.3, [2] = 0.1 }
local PRICE = { [0] = 25, [1] = 50, [2] = 120 }
local QNAME = { [0] = "Common", [1] = "Uncommon", [2] = "Rare" }
function R:UnitName(unit)
  if unit == 2 then return "Salvage drone" end
  if unit == 1 then return "Salvage android 1" end
  return "Salvage android " .. (unit - 1)
end
function R:LootFrom(unit, src, cap)
  self.lastCash, self.lastLeft = 0, 0
  if self.jobs[unit] then return 0 end
  self.wear[unit] = math.min(100, self.wear[unit] + 0.5)
  local load = self:CargoKg(unit)
  local taken = 0
  local keep = {}
  for _, it in ipairs(src.items) do
    if it == "cash" then
      self.lastCash = self.lastCash + 50
    elseif load + KG[it] > cap then
      self.lastLeft = self.lastLeft + 1
      keep[#keep + 1] = it
    else
      load = load + KG[it]
      self.rows[#self.rows + 1] = { id = self.nextId, unit = unit, rec = it, qty = 1, kg = KG[it], cat = CATOF[it], sell = 100 }
      self.nextId = self.nextId + 1
      taken = taken + 1
    end
  end
  src.items = keep
  if taken > 0 or self.lastCash > 0 then self.version = self.version + 1 end
  if taken == 0 and self.lastLeft > 0 then return -1 end
  return taken
end
function R:LastCash() return self.lastCash end
function R:LastLeft() return self.lastLeft end
function R:Version() return self.version end
function R:view(unit)
  local v = {}
  for _, r in ipairs(self.rows) do if r.unit == unit then v[#v + 1] = r end end
  return v
end
function R:Count(unit) return #self:view(unit) end
local function rowAt(unit, i) return R:view(unit)[i + 1] end
function R:EntryId(u, i) return rowAt(u, i).id end
function R:Name(u, i) return rowAt(u, i).rec end
function R:Qty(u, i) return rowAt(u, i).qty end
function R:Tier(u, i) return 4 end
function R:Cat(u, i) return rowAt(u, i).cat end
function R:Kg(u, i) return rowAt(u, i).kg end
function R:Sell(u, i) return rowAt(u, i).sell end
function R:CargoKg(unit)
  local kg = 0
  for _, r in ipairs(self.rows) do if r.unit == unit then kg = kg + r.kg * r.qty end end
  return kg
end
function R:EstSell(unit) local s = 0 for _, r in ipairs(self:view(unit)) do s = s + r.sell end return s end
function R:EstComponents(unit) return #self:view(unit) * 2 end
function R:IsAway(unit) return self.jobs[unit] ~= nil end
function R:AwayMinutesLeft(unit)
  local j = self.jobs[unit]
  if not j then return 0.0 end
  return math.max(0.01, (j.due - world.gameTime) / 60)
end
function R:Take(id)
  for i, r in ipairs(self.rows) do
    if r.id == id then
      if self.jobs[r.unit] then return false end
      table.remove(self.rows, i)
      self.paid[#self.paid + 1] = r.rec
      self.version = self.version + 1
      return true
    end
  end
  return false
end
function R:TakeCategory(unit, cat)
  local n = 0
  for i = #self.rows, 1, -1 do
    local r = self.rows[i]
    if r.unit == unit and (cat < 0 or r.cat == cat) then table.remove(self.rows, i) n = n + 1 end
  end
  if n > 0 then self.version = self.version + 1 end
  return n
end
function R:Dispatch(unit, mode, minutes, fence)
  if self.jobs[unit] then return false end
  local any, credits = false, 0
  for i = #self.rows, 1, -1 do
    local r = self.rows[i]
    if r.unit == unit then any = true credits = credits + r.sell * fence table.remove(self.rows, i) end
  end
  if not any then return false end
  self.jobs[unit] = { due = world.gameTime + minutes * 60, credits = math.floor(credits), mode = mode }
  self:accrue()
  self.field[unit] = 0
  self.version = self.version + 1
  return true
end
function R:accrue()
  for u = 1, 6 do
    if self.field[u] ~= 0 then
      local h = (world.gameTime - self.fieldAt[u]) / 3600
      if h > 0 and h <= 30 then self.wear[u] = math.min(100, self.wear[u] + h * (self.field[u] == 2 and 0.5 or 2.0)) end
      self.fieldAt[u] = world.gameTime
    end
  end
end
function R:Update()
  self:accrue()
  local text = ""
  for unit, j in pairs(self.jobs) do
    if world.gameTime >= j.due then
      text = text .. self:UnitName(unit) .. " back: " .. j.credits .. " eddies"
      self.jobs[unit] = nil
      self.version = self.version + 1
    end
  end
  return text
end
function R:SetField(u, f) self:accrue() self.field[u] = f self.fieldAt[u] = world.gameTime end
function R:Field(u) return self.field[u] end
function R:Wear(u) return self.wear[u] end
function R:plan(u)
  local take, buy, cost = {}, {}, 0
  for q = 0, 2 do
    local s = self.served[u]
    local need = math.floor((s + self.wear[u]) * RATE[q] + 0.0001) - math.floor(s * RATE[q] + 0.0001)
    local have = math.min(need, world.bag[q])
    take[q], buy[q] = have, need - have
    cost = cost + (need - have) * PRICE[q]
  end
  return take, buy, cost
end
local function kitText(c)
  local t = ""
  for q = 0, 2 do
    if c[q] > 0 then t = t .. (t ~= "" and ", " or "") .. c[q] .. " " .. QNAME[q] end
  end
  return t
end
function R:ServiceQuote(u)
  if self.wear[u] < 1 then return "" end
  local take, buy, cost = self:plan(u)
  return "Service: " .. kitText(take) .. " | buy " .. kitText(buy) .. " for " .. cost
end
function R:Service(u)
  self.serviceText = ""
  self:accrue()
  if self.field[u] ~= 0 or self.jobs[u] then return -2 end
  local wear = self.wear[u]
  if wear < 1 then return 0 end
  local take, buy, cost = self:plan(u)
  if cost > world.money then
    self.serviceText = self:UnitName(u) .. " not serviced: " .. kitText(buy) .. " components missing, " .. cost .. " eddies needed to buy them."
    return -1
  end
  for q = 0, 2 do world.bag[q] = world.bag[q] - take[q] end
  world.money = world.money - cost
  self.served[u] = (self.served[u] + wear) % 10
  self.wear[u] = 0
  self.serviceText = self:UnitName(u) .. " serviced (" .. math.floor(wear + 0.5) .. " % wear)."
  self.version = self.version + 1
  return 1
end
function R:ServiceText() return self.serviceText end
function R:FindCar(vanOnly, range)
  self.carHow = "none"
  local best, bestD
  for _, e in ipairs(world.ents) do
    if e.kind == "car" and e.defined and e.own and not e.bike and (not vanOnly or e.van) then
      local d = d2(e.pos, player.pos)
      if d <= range and (not bestD or d < bestD) then best, bestD = e, d end
    end
  end
  if best then self.carHow = "targeting" end
  return best
end
function R:CarHow() return self.carHow end

-- ---------------------------------------------------------------- CET globals
local spawnedByRec = {}
local tweak = {}
TweakDBID = { new = function(s) return s end }
TweakDB = {
  GetRecord = function(_, id) if id:match("^Character%.") or tweak[id] then return {} end return nil end,
  CreateRecord = function(_, id) tweak[id] = {} end,
  GetFlat = function(_, path)
    if path:match("^Character%..-%.entityTemplatePath$") then return "base\\x.ent" end
    if path:match("^Character%..-%.statModifiers$") then return { "Mod.A" } end
    if path:match("^Character%.") then return "v" end
    local id, f = path:match("^(.*)%.([%w_]+)$")
    return tweak[id] and tweak[id][f]
  end,
  SetFlat = function(_, path, v) local id, f = path:match("^(.*)%.([%w_]+)$") tweak[id] = tweak[id] or {} tweak[id][f] = v end,
  Update = function() end,
}
TweakDB.SetFlatNoUpdate = TweakDB.SetFlat

function IsDefined(x) return x ~= nil and (type(x) ~= "table" or x.defined ~= false) end
CName = { new = function(s) return s end }
EAIAttitude = { AIA_Friendly = 1 }
gameGodModeType = { Immortal = 1 }
moveMovementType = { Walk = 1 }
gamedataNPCHighLevelState = { Unconscious = "Unconscious", Dead = "Dead" }
ScriptedPuppet = { IsDefeated = function(e) return e.dead end, IsPlayerCompanion = function(e) return e.kind == "unit" end }
AIFollowerRole = { new = function() return { kind = "follow", SetFollowTarget = function() end } end }
AINoRole = { new = function() return { kind = "none" } end }
AIHumanComponent = { SetCurrentRole = function(e, r) e.role = r.kind end }
Vector3 = { new = function() return { x = 0, y = 0, z = 0 } end }
Vector4 = { new = function(x, y, z) return V4(x, y, z) end }
EulerAngles = { new = function(r, p, y) return { yaw = y } end }
WorldPosition = { SetVector4 = function(wp, v) wp.v = v end }
AIPositionSpec = { SetWorldPosition = function(spec, wp) spec.wp = wp end }
function NewObject(name)
  if name == "handle:AIMoveToCommand" then
    local cmd = { kind = "move" }
    return setmetatable(cmd, { __newindex = function(t, k, v)
      rawset(t, k, v)
      if k == "movementTarget" then rawset(t, "target", v.wp.v) end
    end })
  end
  if name == "handle:AIHoldPositionCommand" then return { kind = "hold" } end
  return {}
end
SimpleScreenMessage = { new = function() return {} end }
function ToVariant(m) return m end
json = {
  encode = function(t) return "{}" end,
  decode = function(s) return {} end,
}
local hotkeys, events = {}, {}
function registerHotkey(id, _, fn) hotkeys[id] = fn end
function registerForEvent(ev, fn) events[ev] = fn end

-- the mod's log goes to memory, its config is neither read nor written
local realOpen = io.open
io.open = function(path, mode)
  if path == "CyberslopSalvage.log" then
    return { write = function(_, ...) logLines[#logLines + 1] = table.concat({ ... }) end, close = function() end }
  end
  if path == "config.json" then
    if mode == "r" then return nil end
    return { write = function() end, close = function() end }
  end
  return realOpen(path, mode)
end
local function hasLog(pat)
  for _, l in ipairs(logLines) do if l:find(pat, 1, true) then return true end end
  return false
end

local godmode = 0
Game = {
  GetPlayer = function()
    if world.noPlayer then return nil end   -- (the 1.0.0 mock's "noPlayer and nil or player" always gave the player)
    return player
  end,
  GetScriptableSystemsContainer = function() return { Get = function(_, n) return n == "CyberslopSalvage.CyberslopSalvageSystem" and R or nil end } end,
  GetCompanionSystem = function()
    return {
      SpawnSubcharacterOnPosition = function(_, rec, pos)
        if world.failSpawn then return end
        local e = newEnt("unit", pos.x, pos.y, pos.z)
        spawnedByRec[rec] = e
      end,
      DespawnSubcharacter = function(_, rec)
        local e = spawnedByRec[rec]
        if e then e.defined = false end
        spawnedByRec[rec] = nil
      end,
      GetSpawnedEntities = function(_, rec)
        local e = spawnedByRec[rec]
        if e and e.defined then return { e } end
        return {}
      end,
    }
  end,
  CreateEntityReference = function() return {} end,
  ["TSQ_ALL;"] = function() return {} end,
  GetTargetingSystem = function()
    return { GetTargetParts = function(_, p, q)
      world.queries = (world.queries or 0) + 1
      local parts = {}
      for _, e in ipairs(world.ents) do
        if e.defined and e.kind ~= "player" then
          if d2(e.pos, p.pos) <= q.maxDistance then
            local part = {}
            function part:GetComponent() return { GetEntity = function() return e end } end
            parts[#parts + 1] = part
          end
        end
      end
      return true, parts
    end }
  end,
  GetTransactionSystem = function() return { GetItemList = function(_, e) return true, e.items end } end,
  GetSpatialQueriesSystem = function()
    return { SyncRaycastByCollisionGroup = function(_, from)
      if world.wall then return true, { position = from } end
      return false
    end }
  end,
  GetTeleportationFacility = function() return { Teleport = function(_, e, p) e.pos = V4(p.x, p.y, p.z) end } end,
  GetGodModeSystem = function() return { AddGodMode = function() godmode = godmode + 1 end } end,
  GetAllBlackboardDefs = function() return { UI_Notifications = { WarningMessage = 1 } } end,
  GetBlackboardSystem = function()
    return { Get = function() return { SetVariant = function(_, _, m) notices[#notices + 1] = m.message end } end }
  end,
}

local imguiClicks, imguiSeen = {}, {}
ImGui = {
  Begin = function() return true end, End = function() end, Text = function() end, Separator = function() end,
  SameLine = function() end, ProgressBar = function() end,
  Button = function(label)
    imguiSeen[label] = true
    if imguiClicks[label] then imguiClicks[label] = nil return true end
    return false
  end,
  CollapsingHeader = function() return true end,
  Checkbox = function(_, v) return v, false end,
  SliderInt = function(_, v) return v, false end,
}

-- ---------------------------------------------------------------- run
dofile(INIT)
events.onInit()

local function step(sec)
  local t = 0
  while t < sec do
    -- simulate walking: units with a move target arrive after one second of steps
    for _, e in ipairs(world.ents) do
      if e.moveTarget then
        e.walk = (e.walk or 0) + 0.05
        if e.walk >= 1.0 then e.pos = V4(e.moveTarget.x, e.moveTarget.y, e.moveTarget.z) e.moveTarget, e.walk = nil, 0 end
      end
    end
    events.onUpdate(0.05)
    t = t + 0.05
  end
end
local function hasNotice(pat)
  for _, n in ipairs(notices) do if n:find(pat, 1, true) then return true end end
  return false
end
local function countNotice(pat)
  local c = 0
  for _, n in ipairs(notices) do if n:find(pat, 1, true) then c = c + 1 end end
  return c
end
local function click(label)
  imguiClicks[label] = true
  events.onDraw()
  local used = imguiClicks[label] == nil
  imguiClicks[label] = nil
  return used
end
local function drawn(label)
  imguiSeen = {}
  events.onDraw()
  return imguiSeen[label] == true
end
local function ent(recName) return spawnedByRec["CyberslopSalvage." .. recName] end
local function clearBodies()
  for _, e in ipairs(world.ents) do
    if e.kind == "npc" or e.kind == "drop" then e.defined = false end
  end
end

for _, n in ipairs({ "Android", "Android2", "Android3", "Android4", "Android5", "Octant", "Carry" }) do
  check("record " .. n, tweak["CyberslopSalvage." .. n] ~= nil)
end
check("android unarmed", tweak["CyberslopSalvage.Android"].primaryEquipment == "CyberslopSalvage.NoWeapons")
check("health x5 appended", tweak["CyberslopSalvage.Android5"].statModifiers[2] == "CyberslopSalvage.HealthX5")
check("player side", tweak["CyberslopSalvage.Android3"].baseAttitudeGroup == "player")

events.onOverlayOpen()   -- the window refreshes the cached wear every second, as in play with the overlay up

-- ---------------------------------------------------------------- trunk rule
hotkeys.cs_android()
step(1.2)
check("no car: android 1 stays stowed", ent("Android") == nil and hasNotice("in your trunk"))
local bike = newEnt("car", 2, -3, 0, { own = true, bike = true })
hotkeys.cs_android()
step(1.2)
check("a bike is no trunk", ent("Android") == nil)
local stranger = newEnt("car", -3, -3, 0, { own = false })
hotkeys.cs_android()
step(1.2)
check("a stranger's car is no trunk", ent("Android") == nil)
local farCar = newEnt("car", 0, -30, 0, { own = true })
hotkeys.cs_android()
step(1.2)
check("own car 30 m away is too far", ent("Android") == nil)
farCar.defined = false
local car = newEnt("car", 0, -5, 0, { own = true })

-- deploy android 1 at the car with two bodies and a civilian nearby
local b1 = newEnt("npc", 10, 10, 0, { dead = true, items = { "gun", "jacket", "cash" } })
local b2 = newEnt("npc", -12, 8, 0, { dead = true, items = { "junk", "gun" } })
local civ = newEnt("npc", 3, 3, 0, { dead = true, civ = true, items = { "junk" } })
local alive = newEnt("npc", 5, 5, 0, { items = { "gun" } })
local drop = newEnt("drop", 11, 11, 0, { items = { "gun" } })
local farDrop = newEnt("drop", 20, -20, 0, { items = { "gun" } })
world.combat = true
hotkeys.cs_android()
step(1.2)
local andr = ent("Android")
check("android 1 spawned at an own car", andr ~= nil)
check("comes out behind the car's rear", andr and math.abs(andr.pos.x) < 0.01 and math.abs(andr.pos.y + 8.6) < 0.01)
check("car found by the redscript search", hasLog("car check for android: found via targeting"))
check("follower role + senses off + immortal", andr and andr.role == "follow" and andr.senses == false and godmode == 1)
check("field state active", R:Field(1) == 1)

step(3)
check("deploy notice", hasNotice("Salvage android 1 deployed"))
check("a repeated refusal is not queued up (4 presses in 4 s, shown twice at most)", countNotice("in your trunk") <= 2)
check("no looting in combat", #b1.items == 3 and andr.role == "follow")
world.combat = false
step(24)
check("body 1 looted", #b1.items == 0)
check("body 2 looted", #b2.items == 0)
check("drop near body looted", #drop.items == 0)
check("far drop untouched", #farDrop.items == 1)
check("civilian untouched", #civ.items == 1)
check("alive untouched", #alive.items == 1)
check("cash notice", hasNotice("wired you"))
check("back to follow after run", andr.role == "follow")
check("cargo 14.0 kg", math.abs(R:CargoKg(1) - 14.0) < 0.01)
check("bodies searched wear the unit (3 x 0.5 %)", math.abs(R:Wear(1) - 1.5) < 0.01)

-- window: take one row via button
-- 1.1.1: Take needs the unit within 6 m of the player. In the game a following unit walks up to the player;
-- the stub world does not move it, so it is placed next to the player here.
andr.pos = V4(1.0, 0.0, 0.0)
events.onUpdate(1.0)
events.onDraw()
local firstId = R:view(1)[1].id
click("Take##" .. firstId)
check("take one row", R:Count(1) == 4 and R.paid[1] ~= nil)
click("Take all##android0")
check("take all weapons", R:Count(1) == 1)

-- full: a body heavier than what is left
local heavy = { }
for i = 1, 30 do heavy[i] = "gun" end
local b3 = newEnt("npc", 6, -6, 0, { dead = true, items = heavy })
step(10)
check("full notice", hasNotice("full ("))
local kgFull = R:CargoKg(1)
check("capacity respected", kgFull <= 90.0)
step(4)
local nBefore = #notices
step(10)
check("no repeat while full", #notices == nBefore)
R.version = R.version + 1
step(8)
check("full unit ignores other units' cargo changes", countNotice("full (") == 1 and math.abs(R:CargoKg(1) - kgFull) < 0.01)

-- make room: the half-looted body gets a second visit
local leftOnB3 = #b3.items
events.onUpdate(1.0)
click("Take all##android0")
step(10)
check("half-looted body revisited after making room", leftOnB3 > 0 and #b3.items < leftOnB3)

-- ---------------------------------------------------------------- standby / resume
clearBodies()
step(8)
local s1 = newEnt("npc", 4, 12, 0, { dead = true, items = { "junk" } })
local posBefore = V4(andr.pos.x, andr.pos.y, andr.pos.z)
hotkeys.cs_standby()
step(12)
check("standby: holds position, no role", andr.role == "none" and andr.holding == true)
check("standby: body not looted, unit did not move", #s1.items == 1 and d2(andr.pos, posBefore) < 0.01)
check("standby: field state 2, notice", R:Field(1) == 2 and hasNotice("1 unit on standby"))
check("standby: window offers Resume, not Standby", drawn("Resume##android") and not drawn("Standby##android"))
hotkeys.cs_standby()
step(1)
check("resume near: follows again, hold released", andr.role ~= nil and andr.holding == false and R:Field(1) == 1)
step(12)
check("resume: the body gets looted", #s1.items == 0)

-- standby, then V walks 400 m away: the unit keeps waiting, a resume brings it after its travel time
click("Standby##android")
check("standby from the window", andr.holding == true and R:Field(1) == 2)
player.pos = V4(0, 400, 0)
step(6)
check("standby out of contact: entity removed, still out", ent("Android") == nil and R:Field(1) == 2)
check("no 'returning home' for a cargo unit", not hasNotice("Salvage android 1 lost contact and is returning home"))
local rowsKept = R:Count(1)
hotkeys.cs_standby()
step(4)
check("resume far: on its way, not there yet", ent("Android") == nil and hasNotice("1 unit resuming") and R:Field(1) == 1)
step(60)
andr = ent("Android")
check("resume far: arrives next to V without a car", andr ~= nil and d2(andr.pos, player.pos) < 8 and andr.role == "follow")
check("cargo kept through standby", R:Count(1) == rowsKept and rowsKept > 0)

-- contact loss while active: waits where it was, does not go home
player.pos = V4(0, 0, 0)
step(1.2)
check("contact loss: unit waits", ent("Android") == nil and hasNotice("lost contact. It waits where you left it") and R:Field(1) == 2)
click("Resume##android")
step(62)
andr = ent("Android")
check("called back after contact loss", andr ~= nil and R:Field(1) == 1)

-- load a save while the unit is out: it is still out, waiting; send home works without an entity
world.noPlayer = true
step(1.1)
world.noPlayer = false
spawnedByRec["CyberslopSalvage.Android"] = nil     -- the load dropped the entity
step(1.1)
check("after a load: still out, not home", R:Field(1) == 1 and hasLog("android is out in this save") and drawn("Resume##android"))
step(11)
check("after a load: entity not restored within 10 s = waiting on standby", R:Field(1) == 2)
step(3)
check("after a load: notice", hasNotice("still out, waiting where you left it"))
check("after a load: Resume offered", drawn("Resume##android"))
world.bag[0], world.bag[1], world.bag[2] = 50, 50, 50
local wearBefore = R:Wear(1)
hotkeys.cs_android()
step(4)
check("send home without an entity: stowed and serviced", R:Field(1) == 0 and R:Wear(1) == 0 and wearBefore >= 1 and hasNotice("Salvage android 1 serviced"))
check("service took components, no eddies", world.bag[0] < 50 and world.money == 0)

-- an entity the game restores for a waiting unit is adopted and held
hotkeys.cs_android()
step(1.2)
andr = ent("Android")
click("Standby##android")
world.noPlayer = true
step(1.1)
world.noPlayer = false
step(6)
check("restored entity adopted on standby", ent("Android") == andr and andr.holding == true and drawn("Resume##android"))
click("Resume##android")
step(1)
check("adopted unit resumes", andr.role == "follow" and andr.holding == false and R:Field(1) == 1)

-- a load while the unit is working, and the game restores its entity: it carries on
world.noPlayer = true
step(1.1)
world.noPlayer = false
step(6.5)
check("active unit restored by a load carries on", ent("Android") == andr and R:Field(1) == 1 and andr.role == "follow"
  and not andr.holding and hasLog("android entity is back, carrying on") and drawn("Standby##android"))
s1.dead, s1.items = false, { "junk" }   -- a second load brings this enemy back alive under the same entity id
world.noPlayer = true
step(1.1)
world.noPlayer = false
step(6.5)
check("alive again after the load: left alone", #s1.items == 1)
s1.dead = true
step(12)
check("a body looted before the load is looted again after it", #s1.items == 0)

-- ---------------------------------------------------------------- sell all: unit walks to the car, away, deploy blocked
local sb = newEnt("npc", 3, 6, 0, { dead = true, items = { "gun" } })
step(12)
click("Sell all##android")
check("dispatched", R:IsAway(1))
check("on a trip = not in the field", R:Field(1) == 0)
check("leave notice", hasNotice("heading to a fence"))
step(1.5)
check("walks to the trunk of the car", math.abs(andr.pos.y + 8.6) < 0.01 and math.abs(andr.pos.x) < 0.01)
step(15)
check("android despawned after walking off", ent("Android") == nil and R:Field(1) == 0)
hotkeys.cs_android()
step(1.2)
check("deploy blocked while away", ent("Android") == nil and hasNotice("still away"))
world.gameTime = world.gameTime + 121 * 60
step(5.5)
check("payout notice names the unit", hasNotice("Salvage android 1 back"))
check("not away after payout", not R:IsAway(1))

-- ---------------------------------------------------------------- van crew
clearBodies()
notices = {}
hotkeys.cs_van()
step(4)
check("no van: crew stays stowed", ent("Android2") == nil and hasNotice("Bring your Columbus"))
click("Deploy##android3")
step(1.2)
check("own car is not the van", ent("Android3") == nil and hasLog("notice: Salvage android 3 is in the van"))
car.defined = false
local van = newEnt("car", 0, -6, 0, { own = true, van = true })
hotkeys.cs_van()
step(6)
local crew = { ent("Android2"), ent("Android3"), ent("Android4"), ent("Android5") }
check("van: all four out at once", crew[1] and crew[2] and crew[3] and crew[4] and hasNotice("4 androids climbing out of the van"))
local xs = {}
for i = 1, 4 do xs[i] = crew[i] and crew[i].pos.x or 99 end
check("van: side by side at the rear doors", math.abs(xs[1] + 1.35) < 0.01 and math.abs(xs[2] + 0.45) < 0.01
  and math.abs(xs[3] - 0.45) < 0.01 and math.abs(xs[4] - 1.35) < 0.01 and crew[1] and math.abs(crew[1].pos.y + 9.6) < 0.01)
check("van: field state of all four active", R:Field(3) == 1 and R:Field(4) == 1 and R:Field(5) == 1 and R:Field(6) == 1)
hotkeys.cs_android()
step(1.2)
check("the van is a car too: android 1 comes out of it", ent("Android") ~= nil)

-- five androids, three bodies: every body is claimed by one unit only
world.queries = 0
local c1 = newEnt("npc", 5, 5, 0, { dead = true, items = { "gun" } })
local c2 = newEnt("npc", -5, 5, 0, { dead = true, items = { "gun" } })
local c3 = newEnt("npc", 0, 9, 0, { dead = true, items = { "gun" } })
step(1.05)
local heading = 0
for _, n in ipairs({ "Android", "Android2", "Android3", "Android4", "Android5" }) do
  if ent(n).role == "none" then heading = heading + 1 end
end
check("three bodies, three units heading out, two stay", heading == 3)
check("one body search per tick for all units", world.queries <= 2)
step(12)
check("all three bodies looted once", #c1.items + #c2.items + #c3.items == 0)
local guns = 0
for unit = 1, 6 do guns = guns + R:Count(unit) end
check("three guns aboard in total", guns == 3)

-- separate cargo and trips per android
local owner
for unit = 3, 6 do if R:Count(unit) > 0 then owner = unit break end end
if not owner then
  local e = newEnt("npc", 2, 4, 0, { dead = true, items = { "junk" } })
  R.rows[#R.rows + 1] = { id = R.nextId, unit = 3, rec = "junk", qty = 1, kg = 0.5, cat = 8, sell = 100 }
  R.nextId = R.nextId + 1
  R.version = R.version + 1
  owner = 3
  e.defined = false
end
events.onUpdate(1.0)
click("Sell all##android" .. (owner - 1))
check("one van android on a trip, the others stay", R:IsAway(owner) and not R:IsAway(owner == 3 and 4 or 3) and not R:IsAway(1))
step(16)

-- standby / resume / send home for the whole crew
hotkeys.cs_standby()
step(1)
local holding = 0
for _, n in ipairs({ "Android", "Android2", "Android3", "Android4", "Android5" }) do
  local e = ent(n)
  if e and e.holding then holding = holding + 1 end
end
check("standby all: every unit out holds", holding == 4 and hasNotice("4 units on standby"))
check("standby all: window shows Resume all", drawn("Resume all"))
click("Resume all")
step(4)
check("resume all", hasNotice("4 units resuming") and R:Field(1) == 1)
world.bag[0], world.bag[1], world.bag[2] = 0, 0, 0
world.money = 100000
world.gameTime = world.gameTime + 3600      -- one game hour in the field: 2 % each
step(1.2)
click("Send all home")
step(17)
local left = 0
for _, n in ipairs({ "Android", "Android2", "Android3", "Android4", "Android5" }) do if ent(n) then left = left + 1 end end
check("send all home: everyone stowed", left == 0 and R:Field(1) == 0 and R:Field(3) + R:Field(4) + R:Field(5) + R:Field(6) == 0)
check("no components in the bag: service paid in eddies", world.money < 100000 and R:Wear(1) == 0)
step(14)
check("every service notice shown, none overwritten", countNotice("serviced (") >= 4)

-- ---------------------------------------------------------------- wear
world.gameTime = world.gameTime + 121 * 60
step(6)
hotkeys.cs_android()
step(1.2)
andr = ent("Android")
world.gameTime = world.gameTime + 2 * 3600
step(1.2)
check("2 game hours active = 4 % wear", math.abs(R:Wear(1) - 4.0) < 0.05)
click("Standby##android")
world.gameTime = world.gameTime + 4 * 3600
step(5.2)
check("4 game hours standby = 2 % more", math.abs(R:Wear(1) - 6.0) < 0.05)
click("Resume##android")
step(1)

-- worn unit works slower: 4 s search at 0 %, 7.9 s at 99 %
R.wear[1] = 99
step(1.2)
local w1 = newEnt("npc", 0, -4, 0, { dead = true, items = { "junk" } })
step(8)
check("99 % wear: still searching after 8 s", #w1.items == 1)
step(5)
check("99 % wear: body done later", #w1.items == 0)
R.wear[1] = 0
step(1.2)
local w2 = newEnt("npc", 1, -4, 0, { dead = true, items = { "junk" } })
step(8)
check("0 % wear: body done within 8 s", #w2.items == 0)

-- worn out: heads back by itself, stays stowed until V can pay for the service
world.bag[0], world.bag[1], world.bag[2] = 0, 0, 0
world.money = 0
R.wear[1] = 100
step(12)
check("worn out: heads back", hasNotice("worn out and heads back"))
step(16)
check("worn out: stowed, not serviced without parts or eddies", ent("Android") == nil and R:Wear(1) == 100 and hasNotice("not serviced"))
hotkeys.cs_android()
step(1.2)
check("worn out: deploy refused", ent("Android") == nil)
events.onUpdate(1.0)
check("window offers Service while stowed and worn", drawn("Service##android"))
world.bag[0], world.bag[1], world.bag[2] = 100, 100, 100
click("Service##android")
check("service button: components used", R:Wear(1) == 0 and world.bag[0] == 40 and world.bag[1] == 70 and world.bag[2] == 90)
hotkeys.cs_android()
step(1.2)
check("serviced unit deploys again", ent("Android") ~= nil)
hotkeys.cs_android()
step(17)

-- a wall behind the car: the unit comes out next to V
world.wall = true
hotkeys.cs_android()
step(1.2)
andr = ent("Android")
check("wall behind the car: spawns next to V", andr ~= nil and d2(andr.pos, player.pos) < 3)
world.wall = false
hotkeys.cs_android()
step(17)

-- two units out of contact in the same second: one notice for both
hotkeys.cs_android()
click("Deploy##android2")
step(4)
check("two units out", ent("Android") ~= nil and ent("Android2") ~= nil)
notices = {}
player.pos = V4(0, 400, 0)
step(4.2)
check("two units lose contact: one notice", hasNotice("2 units lost contact") and countNotice("lost contact") == 1
  and R:Field(1) == 2 and R:Field(3) == 2)
hotkeys.cs_standby()
step(0.5)
hotkeys.cs_standby()
step(8)
check("standby key while they travel: told they are on their way", hasNotice("Salvage units are on their way"))
step(56)
check("both arrive, arrival is announced", ent("Android") ~= nil and ent("Android2") ~= nil and hasNotice("is back with you"))
player.pos = V4(0, 0, 0)
step(1.2)
click("Send all home")
step(4)
check("waiting units sent home at once", R:Field(1) == 0 and R:Field(3) == 0)

-- ---------------------------------------------------------------- octant: flies to the body, glides, loots
clearBodies()
local b4 = newEnt("npc", 0, 30, 0, { dead = true, items = { "gun", "jacket" } })
van.defined = false
hotkeys.cs_octant()
step(1.2)
local oct = ent("Octant")
check("octant needs no car", oct ~= nil)
step(15)
check("octant looted the body", #b4.items == 0)
check("octant hovered over body", math.abs(oct.pos.y - 30) < 0.5 and math.abs(oct.pos.z - 2.5) < 0.5)

-- contact loss: the drone waits too, cargo kept
local octRows = R:Count(2)
oct.pos = V4(0, 400, 0)
step(1.1)
check("drone contact loss: waits", ent("Octant") == nil and R:Field(2) == 2)
check("cargo kept after contact loss", R:Count(2) == octRows and octRows > 0)
hotkeys.cs_octant()
step(4)
check("drone sent home while waiting", R:Field(2) == 0)

-- entity vanishes: the unit waits, a resume brings it back
hotkeys.cs_octant()
step(1.2)
spawnedByRec["CyberslopSalvage.Octant"] = nil
step(3.5)
check("missing entity: waiting", R:Field(2) == 2)
hotkeys.cs_standby()
step(25)
check("missing entity: resume respawns it", ent("Octant") ~= nil and R:Field(2) == 1)
hotkeys.cs_octant()
step(12)

-- ---------------------------------------------------------------- carry drone: call, then send to stash
hotkeys.cs_carry()
step(1.2)
local carry = ent("Carry")
check("carry drone spawned", carry ~= nil and hasNotice("Carry drone inbound"))
local z0 = carry.pos.z
hotkeys.cs_carry()
step(2)
check("carry climbs", carry.pos.z > z0 + 3)
step(8)
check("stash notice", hasNotice("stash"))
check("carry despawned", ent("Carry") == nil)

-- carry drone out of contact goes home as before
hotkeys.cs_carry()
step(1.2)
ent("Carry").pos = V4(0, 400, 0)
step(1.1)
check("carry contact loss: home", ent("Carry") == nil)
step(4)
check("carry contact loss notice", hasNotice("Carry drone lost contact and is returning home"))

-- spawn failure path
world.failSpawn = true
hotkeys.cs_carry()
step(8)
check("spawn failure notice", hasNotice("could not reach you"))
world.failSpawn = false

-- main menu: no player resets states
hotkeys.cs_carry()
step(1.2)
world.noPlayer = true
step(1.1)
world.noPlayer = false
hotkeys.cs_carry()
step(1.2)
check("menu reset lets carry redeploy", ent("Carry") ~= nil)

-- shutdown removes the entities, the saved field state is left alone
van.defined = true
hotkeys.cs_android()
step(1.2)
check("android out before shutdown", ent("Android") ~= nil and R:Field(1) == 1)
events.onShutdown()
check("shutdown despawns", ent("Carry") == nil and ent("Android") == nil)
check("shutdown keeps the field state", R:Field(1) == 1)

for _, l in ipairs(logLines) do
  if l:find("error", 1, true) then fail = fail + 1 print("LOG ERROR LINE: " .. l) end
end
print(string.format("mock: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
