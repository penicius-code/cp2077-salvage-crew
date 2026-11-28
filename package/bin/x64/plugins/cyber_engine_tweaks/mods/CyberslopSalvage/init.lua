-- Optional: if a file cyberslop_palette.lua is present, this mod's windows use its teal palette (colours only).
do
  local ok, palette = pcall(require, "cyberslop_palette")
  if ok and type(palette) == "table" and type(registerForEvent) == "function" then
    local reg = registerForEvent
    registerForEvent = function(ev, fn)
      if ev == "onDraw" and type(fn) == "function" then fn = palette.wrap("teal", fn) end
      return reg(ev, fn)
    end
  end
end
-- Cyberslop Salvage 1.2.4 (my mod, 2026-11-26)
-- 1.2.4: every android look names its appearance. The records copied no appearanceName, and the android
--   templates hold several factions (corpo__ep1_android_ma: 6, gang__ep1_android_ma: 22 incl. Maelstrom and
--   Wraiths), so each spawn took a random skin. The name goes into the record and, if the spawned entity
--   still shows another one, is applied once more with ScheduleAppearanceChange.
-- 1.2.3: CET input cs_android_key (Numpad 2) for android 1: hold 0.5 s = deploy from the trunk / send home,
--   tap = go / wait (standby / resume).
-- 1.2.2: version number only. The fix is in the .reds (item drops report through a queued request,
--   CTD exe+0x270242 while a save loads).
-- 1.2.1: a body or drop holding nothing the unit takes is not visited (LootableCount; before, any item in
--   the list counted, also hidden ones); the loot line in the log names each item with its weight.
-- 1.2.0: the units pick up guns lying on the ground, next to a body or not. The targeting query used for the
--   search does not return dropped weapons, so the redscript side keeps a list of the item drops in the world
--   (FindWeaponDrops). Loose guns: not iconic, not quest, not one V dropped (setting). A pickup takes half the
--   search time of a body and wears the unit 0.1 % (body 0.5 %).
-- 1.1.1: Take / Take all only with the unit next to V (6 m), as the README says; a unit on standby stays out up
--   to 150 m away and could be emptied from there.
-- Carry drone (cosmetic RP mule), five salvage androids and a salvage drone (loot downed enemies into
-- their own cargo, recycle or sell it on a 120 game-minute trip). Replaces DroneCompanion.
-- 1.1.0: android 1 comes out of the trunk of any of V's own cars, androids 2-5 out of the van
-- (Villefort Columbus) only; standby / resume; wear and service in crafting components.
-- Lightweight: no Observe/Override hooks. onUpdate only adds dt; a 1 Hz tick runs the units, a
-- 20 Hz step runs only while a drone flies a leg. Cargo, wear and field state live in redscript
-- (r6\scripts\CyberslopSalvage, persistent ScriptableSystem = kept in the save).
-- Build 2 (review): full gate per unit, looted list cleared on a load, routine notices not queued.
-- Revert: delete this folder and r6\scripts\CyberslopSalvage.

local VERSION = "1.2.4"
local TAKE_RANGE = 6.0   -- 1.1.1: metres between V and the unit for Take / Take all
local TDB = "CyberslopSalvage."
local SYS = "CyberslopSalvage.CyberslopSalvageSystem"

local CAR_RANGE = 12.0      -- m: an own car / the van this close lets a stowed android out
local STOW_RANGE = 40.0     -- m: a unit sent home walks to an own car this close
local CONTACT = 150.0       -- m: farther from V = out of contact, the unit waits
local RESUME_WALK = 60.0    -- m: a resumed unit this close walks over, a farther one arrives later
local TRAVEL_SPEED = 5.0    -- m/s, travel time of a unit called from far away
local HOLD_SECONDS = 86400.0

-- looseWeapons: guns on the ground away from any body are picked up too; ownDrops: also the ones V dropped
local cfg = { log = true, autoLoot = true, looseWeapons = true, ownDrops = false, tripMinutes = 120, fencePct = 80,
              look = { carry = 1, android = 1, android2 = 1, android3 = 1, android4 = 1, android5 = 1, octant = 1 } }

local overlay = false
local timers = {}
local acc, tickN = 0.0, 0
local recordsOk = false
local needSync = true       -- read the saved field state once a save is loaded
local noteQ, noteWait, noteShown = {}, 0.0, nil
local scanTick, scanList = -1, nil
local emptySeen, emptyN = {}, 0

-- ---------------------------------------------------------------- units

-- [3] = appearance in the record's entity template (ep1\characters\entities\corpo|gang\*__ep1_android_ma.ent)
local ANDROID_LOOKS = {
  { "Militech", "Character.militech_android_android2_crusher_ma", "corpo__android_ma_militech_droid__lvl2_01" },
  { "Arasaka", "Character.arasaka_android_android2_shingen_ma", "corpo__android_ma_arasaka_droid__lvl2_01" },
  { "Kang Tao", "Character.kangtao_android_android2_dian_ma", "corpo__android_ma_kang_tao_droid__lvl2_01" },
  { "Scavengers", "Character.scavenger_android_android2_pulsar_ma", "gang__android_ma_scavenger_droid__lvl2_01" },
  { "Sixth Street", "Character.sixthstreet_android_android2_saratoga_ma", "gang__android_ma_6th_street_droid_lvl1_01" },
  { "NCPD", "Character.prevention_android_rifle_ma", "corpo__android_ma_ncpd_droid__lvl1_01" },
}

-- n = 1..5; unit = cargo unit id in redscript; stow = "car" (trunk of any own car) or "van"
local function android(key, n, unit, stow)
  return { key = key, name = "Salvage android " .. n, rec = TDB .. (n == 1 and "Android" or ("Android" .. n)),
           fly = false, cargo = true, unit = unit, capacity = 90.0, radius = 25.0, work = 4.0,
           stow = stow, looks = ANDROID_LOOKS }
end

local UNITS = {
  carry = { key = "carry", name = "Carry drone", rec = TDB .. "Carry", fly = true, cargo = false,
    looks = {
      { "Delamain", "Character.sq025_delamain_drone_bombus" },
      { "Militech", "Character.militech_base_drone_bombus" },
      { "NCPD", "Character.ncpd_base_drone_bombus" },
      { "Aldecaldos", "Character.aldecaldos_base_drone_bombus" },
    } },
  android = android("android", 1, 1, "car"),
  android2 = android("android2", 2, 3, "van"),
  android3 = android("android3", 3, 4, "van"),
  android4 = android("android4", 4, 5, "van"),
  android5 = android("android5", 5, 6, "van"),
  octant = { key = "octant", name = "Salvage drone", rec = TDB .. "Octant", fly = true, cargo = true,
    unit = 2, capacity = 40.0, radius = 35.0, work = 3.0,
    looks = {
      { "Militech", "Character.militech_base_drone_octant" },
      { "Arasaka", "Character.arasaka_base_drone_octant" },
      { "Kang Tao", "Character.kangtao_base_drone_octant" },
      { "Trauma Team", "Character.trauma_team_base_drone_octant" },
    } },
}
local ORDER = { "carry", "android", "android2", "android3", "android4", "android5", "octant" }
local CARGO = { "android", "android2", "android3", "android4", "android5", "octant" }
local VAN = { "android2", "android3", "android4", "android5" }
local SCAN_RADIUS = 35.0
for _, k in ipairs(ORDER) do
  local u = UNITS[k]
  u.state = "home"   -- home | spawning | deployed | standby | coming | leaving
  u.gen = 0          -- bumps on every spawn / dismiss, stale callbacks check it
  u.ent = nil        -- standby with no entity = waiting out of contact
  u.missing = 0
  u.run = nil        -- loot run: { ent, key, phase = "move" | "work", t }
  u.full = false
  u.fullKg = 0.0
  u.glide = nil
  u.looted, u.lootedN = {}, 0
  u.lastPos = nil
  u.wear = 0.0
  u.warned = false
  -- window labels, built once (nothing is formatted per frame)
  u.L = { deploy = "Deploy##" .. k, standby = "Standby##" .. k, resume = "Resume##" .. k,
          home = "Send home##" .. k, service = "Service##" .. k, recycle = "Recycle all##" .. k,
          sell = "Sell all##" .. k }
end

local CATS = { [0] = "Weapons", "Clothing & armor", "Cyberware", "Mods & attachments", "Quickhacks",
  "Consumables & meds", "Ammo & grenades", "Components (kept)", "Junk & valuables", "Iconic & other (kept)" }

local TITLE = "Cyberslop Salvage " .. VERSION
local CARRY_TEXT = { home = "Carry drone (cosmetic): Home", deployed = "Carry drone (cosmetic): Following",
  standby = "Carry drone (cosmetic): On standby", other = "Carry drone (cosmetic): ..." }

local STASH_LINES = {
  "Carry drone en route to your stash with your gear.",
  "Carry drone climbing out. Your gear goes to the stash.",
  "Carry drone headed home. It will drop your gear in the stash.",
}

-- ---------------------------------------------------------------- helpers

local function log(msg)
  if not cfg.log then return end
  local f = io.open("CyberslopSalvage.log", "a")
  if f then
    f:write(os.date("%H:%M:%S "), tostring(msg), "\n")
    f:close()
  end
end

local function show(msg)
  pcall(function()
    local m = SimpleScreenMessage.new()
    m.isShown = true
    m.duration = 4.0
    m.message = tostring(msg)
    m.isInstant = true
    local defs = Game.GetAllBlackboardDefs()
    Game.GetBlackboardSystem():Get(defs.UI_Notifications):SetVariant(defs.UI_Notifications.WarningMessage, ToVariant(m), true)
  end)
end

-- notices never overwrite each other: a second one within 3 s waits its turn (onUpdate shows it)
-- soft = routine chatter (loot lines, arrivals): shown only when nothing else is on screen, never queued
local function notify(msg, soft)
  log("notice: " .. msg)
  if soft and noteWait > 0.0 then return end
  if noteWait <= 0.0 then
    show(msg)
    noteShown = msg
    noteWait = 3.0
  else
    -- the same text on screen or waiting already (a key pressed twice): once is enough
    if msg == noteShown then return end
    for _, q in ipairs(noteQ) do
      if q == msg then return end
    end
    if #noteQ >= 6 then table.remove(noteQ, 1) end
    noteQ[#noteQ + 1] = msg
  end
end

local function after(sec, fn)
  timers[#timers + 1] = { t = sec, fn = fn }
end

local function tdbid(s) return TweakDBID.new(s) end

local function getPlayer()
  local ok, p = pcall(Game.GetPlayer)
  if ok and p and IsDefined(p) then return p end
  return nil
end

local function sys()
  local ok, s = pcall(function() return Game.GetScriptableSystemsContainer():Get(SYS) end)
  if ok and s then return s end
  return nil
end

local function entKey(ent)
  local key
  pcall(function()
    local id = ent:GetEntityID()
    key = id.hash and tostring(id.hash) or tostring(id)
  end)
  return key or tostring(ent)
end

local function dist(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function isDown(ent)
  if not ent or not IsDefined(ent) then return true end
  local down = false
  pcall(function() down = ent:IsDead() end)
  if down then return true end
  pcall(function() down = ScriptedPuppet.IsDefeated(ent) == true end)
  if down then return true end
  pcall(function()
    local hls = ent:GetHighLevelStateFromBlackboard()
    down = hls == gamedataNPCHighLevelState.Unconscious or hls == gamedataNPCHighLevelState.Dead
  end)
  return down
end

local function saveCfg()
  local f = io.open("config.json", "w")
  if f then
    f:write(json.encode(cfg))
    f:close()
  end
end

local function loadCfg()
  local f = io.open("config.json", "r")
  if not f then return end
  local ok, t = pcall(json.decode, f:read("*a"))
  f:close()
  if not ok or type(t) ~= "table" then return end
  for k, v in pairs(t) do
    if k == "look" and type(v) == "table" then
      for lk, lv in pairs(v) do
        if UNITS[lk] and type(lv) == "number" and UNITS[lk].looks[lv] then cfg.look[lk] = lv end
      end
    elseif cfg[k] ~= nil and type(v) == type(cfg[k]) then
      cfg[k] = v
    end
  end
  cfg.tripMinutes = math.max(30, math.min(240, math.floor(cfg.tripMinutes)))
  cfg.fencePct = math.max(50, math.min(100, math.floor(cfg.fencePct)))
end

-- ---------------------------------------------------------------- records

local COPY = {
  "abilities", "actionMap", "affiliation", "appearanceName", "archetypeData",
  "archetypeName", "attachmentSlots", "audioResourceName", "audioMeleeMaterial",
  "baseAttitudeGroup", "characterType", "communitySquad", "contentAssignment",
  "crowdMemberSettings", "defaultCrosshair", "defaultEquipment", "displayName",
  "driving", "dropsAmmoOnDeath", "dropsMoneyOnDeath", "dropsWeaponOnDeath",
  "effectors", "enableSensesOnStart", "entityTemplatePath", "fullDisplayName",
  "genders", "idleActions", "isBumpable", "itemGroups", "items", "lootDrop",
  "objectActions", "onSpawnGLPs", "persistentName", "primaryEquipment",
  "priority", "quest", "rarity", "reactionPreset", "referenceName", "savable",
  "scannerModulePreset", "secondaryEquipment", "sensePreset", "squadParamsID",
  "startingEquippedItems", "stateMachineName", "statModifierGroups",
  "statModifiers", "statPools", "tags", "threatTrackingPreset", "uiNameplate",
  "vendorID", "visualTags", "voiceTag", "weakspots",
}
local COPY_CNAME = {
  "alertedSensesPreset", "combatSensesPreset", "keepColliderOnDeath",
  "relaxedSensesPreset", "statusEffectParamsPackageName", "weaponSlot",
}
local COPY_FLOAT = {
  "airDeathRagdollDelay", "combatDefaultZOffset", "mass",
  "massNormalizedCoefficient", "pseudoAcceleration", "sizeBack", "sizeFront",
  "sizeLeft", "sizeRight", "speedIdleThreshold", "startingRecoveryBalance",
  "tiltAngleOnSpeed", "turnInertiaDamping", "walkTiltCoefficient",
}

local function ensureRecord(id, rtype)
  if TweakDB:GetRecord(id) == nil then TweakDB:CreateRecord(id, rtype) end
end

local function buildShared()
  ensureRecord(TDB .. "NoWeapons", "gamedataNPCEquipmentGroup_Record")
  ensureRecord(TDB .. "HealthX5", "gamedataConstantStatModifier_Record")
  TweakDB:SetFlatNoUpdate(TDB .. "HealthX5.modifierType", "Multiplier")
  TweakDB:SetFlatNoUpdate(TDB .. "HealthX5.statType", "BaseStats.Health")
  TweakDB:SetFlat(TDB .. "HealthX5.value", 5.0, "Float")
  TweakDB:Update(TDB .. "HealthX5")
end

-- copies a vanilla character into our subcharacter record: unarmed, player side, x5 health
local function buildUnit(u)
  local look = u.looks[cfg.look[u.key]]
  local base = look[2]
  if TweakDB:GetRecord(base) == nil then
    log("ERROR base record missing: " .. base)
    return false
  end
  local id = u.rec
  ensureRecord(id, "gamedataSubCharacter_Record")
  for _, f in ipairs(COPY) do
    local v = TweakDB:GetFlat(base .. "." .. f)
    if v ~= nil then TweakDB:SetFlatNoUpdate(id .. "." .. f, v) end
  end
  for _, f in ipairs(COPY_CNAME) do
    local v = TweakDB:GetFlat(base .. "." .. f)
    if v ~= nil then TweakDB:SetFlat(id .. "." .. f, v) end
  end
  for _, f in ipairs(COPY_FLOAT) do
    local v = TweakDB:GetFlat(base .. "." .. f)
    if v ~= nil then TweakDB:SetFlat(id .. "." .. f, v, "Float") end
  end
  TweakDB:SetFlatNoUpdate(id .. ".baseAttitudeGroup", "player")
  TweakDB:SetFlatNoUpdate(id .. ".disableDefeatedState", true)
  TweakDB:SetFlatNoUpdate(id .. ".dropsWeaponOnDeath", false)
  TweakDB:SetFlatNoUpdate(id .. ".dropsAmmoOnDeath", false)
  TweakDB:SetFlatNoUpdate(id .. ".dropsMoneyOnDeath", false)
  TweakDB:SetFlatNoUpdate(id .. ".lootBagEntity", "None")
  TweakDB:SetFlatNoUpdate(id .. ".primaryEquipment", TDB .. "NoWeapons")
  TweakDB:SetFlatNoUpdate(id .. ".secondaryEquipment", TDB .. "NoWeapons")
  if look[3] then TweakDB:SetFlatNoUpdate(id .. ".appearanceName", look[3]) end
  local mods = TweakDB:GetFlat(base .. ".statModifiers") or {}
  local list = {}
  for _, m in ipairs(mods) do list[#list + 1] = m end
  list[#list + 1] = TweakDBID.new(TDB .. "HealthX5")
  TweakDB:SetFlatNoUpdate(id .. ".statModifiers", list)
  TweakDB:Update(id)
  local tpl = TweakDB:GetFlat(id .. ".entityTemplatePath")
  if tpl == nil or tostring(tpl) == "" then log("WARNING " .. id .. " has no entityTemplatePath") end
  log("record " .. id .. " <- " .. base .. (look[3] and (" / " .. look[3]) or ""))
  return true
end

local function buildRecords()
  local ok, err = pcall(function()
    buildShared()
    for _, k in ipairs(ORDER) do buildUnit(UNITS[k]) end
  end)
  recordsOk = ok
  if not ok then log("ERROR building records: " .. tostring(err)) end
end

-- ---------------------------------------------------------------- AI

local function spawned(u)
  local list
  pcall(function() list = Game.GetCompanionSystem():GetSpawnedEntities(tdbid(u.rec)) end)
  if list and #list > 0 and IsDefined(list[1]) then return list[1] end
  return nil
end

local function setFollow(ent)
  local player = getPlayer()
  if not player or not ent or not IsDefined(ent) then return end
  pcall(function()
    local role = AIFollowerRole.new()
    role.followerRef = Game.CreateEntityReference("#player", {})
    role.attitudeGroupName = CName.new("player")
    role:SetFollowTarget(player)
    AIHumanComponent.SetCurrentRole(ent, role)
  end)
end

local function setNoRole(ent)
  pcall(function() AIHumanComponent.SetCurrentRole(ent, AINoRole.new()) end)
end

-- standby: no role, running walk order dropped, vanilla hold-position order on top
local function hold(ent)
  setNoRole(ent)
  pcall(function()
    ent:GetAIControllerComponent():CancelOrInterruptCommand(CName.new("AIMoveToCommand"), false, false)
  end)
  pcall(function()
    local cmd = NewObject("handle:AIHoldPositionCommand")
    cmd.duration = HOLD_SECONDS
    ent:GetAIControllerComponent():SendCommand(cmd)
  end)
end

local function releaseHold(ent)
  pcall(function()
    ent:GetAIControllerComponent():CancelOrInterruptCommand(CName.new("AIHoldPositionCommand"), false, true)
  end)
end

local function applyCompanion(u, ent)
  local player = getPlayer()
  if not player then return end
  local ok, err = pcall(function()
    ent:GetAttitudeAgent():SetAttitudeGroup(CName.new("player"))
    ent:GetAttitudeAgent():SetAttitudeTowards(player:GetAttitudeAgent(), EAIAttitude.AIA_Friendly)
    ent.isPlayerCompanionCached = true
    ent.isPlayerCompanionCachedTimeStamp = 0
  end)
  if not ok then log("attitude failed: " .. tostring(err)) end
  setFollow(ent)
  pcall(function() Game.GetGodModeSystem():AddGodMode(ent:GetEntityID(), gameGodModeType.Immortal, CName.new("CyberslopSalvage")) end)
  pcall(function()
    local senses = ent:GetSensesComponent()
    if senses then senses:Toggle(false) end
  end)
end

local function teleport(ent, x, y, z, yaw)
  pcall(function()
    Game.GetTeleportationFacility():Teleport(ent, Vector4.new(x, y, z, 1.0), EulerAngles.new(0, 0, yaw or ent:GetWorldYaw()))
  end)
end

local function moveTo(ent, x, y, z)
  return pcall(function()
    local wp = NewObject("WorldPosition")
    WorldPosition.SetVector4(wp, Vector4.new(x, y, z, 1.0))
    local spec = NewObject("AIPositionSpec")
    AIPositionSpec.SetWorldPosition(spec, wp)
    local cmd = NewObject("handle:AIMoveToCommand")
    cmd.movementTarget = spec
    cmd.movementType = moveMovementType.Walk
    cmd.desiredDistanceFromTarget = 1.0
    cmd.finishWhenDestinationReached = true
    ent:GetAIControllerComponent():SendCommand(cmd)
  end)
end

-- drone flies from where it is to (x, y, z) in about dist / speed seconds, 20 Hz teleport steps
local function glide(u, x, y, z, speed, onDone)
  local ent = u.ent
  if not ent or not IsDefined(ent) then return end
  local p = ent:GetWorldPosition()
  local d = dist(p, { x = x, y = y, z = z })
  local yaw = math.deg(-math.atan2(x - p.x, y - p.y))
  u.glide = { fx = p.x, fy = p.y, fz = p.z, tx = x, ty = y, tz = z, yaw = yaw,
              t = 0.0, dur = math.max(1.0, d / speed), step = 0.0, onDone = onDone }
end

local function stepGlide(u, dt)
  local g = u.glide
  if not u.ent or not IsDefined(u.ent) then u.glide = nil return end
  g.t = g.t + dt
  g.step = g.step + dt
  local done = g.t >= g.dur
  if g.step < 0.05 and not done then return end
  g.step = 0.0
  local a = done and 1.0 or g.t / g.dur
  a = a * a * (3.0 - 2.0 * a)
  teleport(u.ent, g.fx + (g.tx - g.fx) * a, g.fy + (g.ty - g.fy) * a, g.fz + (g.tz - g.fz) * a, g.yaw)
  if done then
    u.glide = nil
    if g.onDone then g.onDone() end
  end
end

local function spawnPoint(player, u)
  local pos = player:GetWorldPosition()
  local fwd = player:GetWorldForward()
  local back = u.fly and 5.0 or 6.0
  local zUp = u.fly and 3.0 or 0.1
  pcall(function()
    local from = Vector4.new(pos.x, pos.y, pos.z + 1.5, 1.0)
    local to = Vector4.new(pos.x - fwd.x * back, pos.y - fwd.y * back, pos.z + 1.5, 1.0)
    local hit, trace = Game.GetSpatialQueriesSystem():SyncRaycastByCollisionGroup(from, to, "Static", true, false)
    if hit and trace then
      local d = dist(from, trace.position) - 1.0
      if d < back then back = math.max(1.5, d) end
    end
  end)
  local v = Vector3.new()
  v.x = pos.x - fwd.x * back
  v.y = pos.y - fwd.y * back
  v.z = pos.z + zUp
  return v
end

-- ---------------------------------------------------------------- trunk / van

-- one of V's own cars within range (vanOnly: a Villefort Columbus); the redscript side does the search
local function findCar(vanOnly, range)
  local s = sys()
  if not s then return nil, "no system" end
  local car, how
  pcall(function()
    car = s:FindCar(vanOnly, range)
    how = s:CarHow()
  end)
  if car and IsDefined(car) then return car, how end
  return nil, how
end

-- spot behind the rear of a car (trunk / van doors); slot shifts it sideways for a crew.
-- A wall right behind the car: the unit comes out next to V instead.
local function trunkSpot(car, slot, player, u)
  local p, f, pp
  local ok = pcall(function()
    p, f, pp = car:GetWorldPosition(), car:GetWorldForward(), player:GetWorldPosition()
  end)
  if not ok or not p or not f then return spawnPoint(player, u) end
  local back, side = 3.6, (slot or 0) * 0.9
  local x = p.x - f.x * back + f.y * side
  local y = p.y - f.y * back - f.x * side
  local blocked = false
  pcall(function()
    local from = Vector4.new(p.x, p.y, p.z + 1.2, 1.0)
    local to = Vector4.new(x, y, p.z + 1.2, 1.0)
    local hit = Game.GetSpatialQueriesSystem():SyncRaycastByCollisionGroup(from, to, "Static", true, false)
    blocked = hit == true
  end)
  if blocked then return spawnPoint(player, u) end
  local v = Vector3.new()
  v.x, v.y = x, y
  v.z = ((math.abs(p.z - pp.z) < 2.0) and pp.z or p.z) + 0.1
  return v
end

-- ---------------------------------------------------------------- cargo, wear, service

local function cargoKg(u)
  local s = sys()
  if not s then return 0.0 end
  local ok, kg = pcall(function() return s:CargoKg(u.unit) end)
  return ok and kg or 0.0
end

local function isAway(u)
  if not u.cargo then return false end
  local s = sys()
  if not s then return false end
  local ok, away = pcall(function() return s:IsAway(u.unit) end)
  return ok and away == true
end

-- field state in the save: 0 home, 1 active, 2 standby (wear runs on it)
local function setField(u, f)
  if not u.cargo then return end
  local s = sys()
  if s then pcall(function() s:SetField(u.unit, f) end) end
end

local function wearOf(u)
  if not u.cargo then return 0.0 end
  local s = sys()
  if s then pcall(function() u.wear = s:Wear(u.unit) end) end
  return u.wear or 0.0
end

-- service of a stowed unit: components from V's bag, eddies for the missing ones.
-- Returns the result code (1 done, 0 nothing due, -1 can't pay, -2 not stowed) and the notice text.
local function serviceUnit(u)
  if not u.cargo then return 0, "" end
  local s = sys()
  if not s then return 0, "" end
  local res, text = 0, ""
  pcall(function()
    res = s:Service(u.unit)
    text = s:ServiceText()
  end)
  if res == 1 then u.warned = false end
  if res ~= 0 and res ~= -2 then log(string.format("service %s: %d %s", u.key, res, tostring(text))) end
  wearOf(u)
  return res, text or ""
end

-- a cargo unit is back in the trunk / van: service it, say what it took
local function stowed(u)
  local _, text = serviceUnit(u)
  if text ~= "" then notify(text) return true end
  return false
end

-- ---------------------------------------------------------------- deploy, leave, standby

local function goHome(u)
  u.gen = u.gen + 1
  u.state, u.ent, u.run, u.glide, u.lastPos, u.wasActive = "home", nil, nil, nil, nil, nil
  setField(u, 0)
end

local function despawnNow(u)
  pcall(function() Game.GetCompanionSystem():DespawnSubcharacter(tdbid(u.rec)) end)
  goHome(u)
end

-- opts: quiet (no notice), note (text in front of the deploy notice), arrive (unit called back by
-- Resume), back = "standby" (a failed spawn leaves the unit waiting instead of home)
local function startSpawn(u, pos, opts)
  opts = opts or {}
  buildUnit(u)
  u.gen = u.gen + 1
  local gen = u.gen
  u.state = "spawning"
  u.run, u.ent, u.missing, u.full, u.glide = nil, nil, 0, false, nil
  if u.lootedN > 400 then u.looted, u.lootedN = {}, 0 end
  setField(u, 1)
  local cs = Game.GetCompanionSystem()
  cs:DespawnSubcharacter(tdbid(u.rec))
  cs:SpawnSubcharacterOnPosition(tdbid(u.rec), pos)
  log(string.format("spawn %s at %.1f %.1f %.1f", u.rec, pos.x, pos.y, pos.z))
  local function found(ent)
    u.ent = ent
    u.state = "deployed"
    applyCompanion(u, ent)
    local app = u.looks[cfg.look[u.key]][3]
    if app then
      pcall(function()
        local cur = NameToString(ent:GetCurrentAppearanceName())
        if cur ~= app then
          ent:ScheduleAppearanceChange(CName.new(app))
          log(string.format("appearance %s -> %s", tostring(cur), app))
        end
      end)
    end
    if u.cargo then
      -- 1.2.0: how many item drops the redscript list holds (0 after minutes of play = its wrap is not running)
      pcall(function() log("item drops known: " .. tostring(sys():DropsKnown())) end)
    end
    if opts.quiet then return end
    if u.key == "carry" then
      notify("Carry drone inbound.")
    elseif opts.arrive then
      notify(u.name .. " is back with you.", true)
    else
      notify(string.format("%s%s deployed (%.1f / %.0f kg aboard).", opts.note or "", u.name, cargoKg(u), u.capacity))
    end
  end
  local function failed()
    log("spawn FAILED: " .. u.rec)
    if opts.back == "standby" then
      u.state, u.ent = "standby", nil
      setField(u, 2)
      notify(u.name .. " could not reach you and keeps waiting.")
    else
      u.state = "home"
      setField(u, 0)
      notify(u.name .. " could not reach you.")
    end
  end
  after(1.0, function()
    if u.gen ~= gen then return end
    local ent = spawned(u)
    if ent then found(ent) return end
    after(3.0, function()
      if u.gen ~= gen then return end
      local e2 = spawned(u)
      if e2 then found(e2) return end
      local p = getPlayer()
      if not p then u.state = "home" return end
      local pp = p:GetWorldPosition()
      local v = Vector3.new()
      v.x, v.y, v.z = pp.x, pp.y, pp.z + (u.fly and 2.5 or 0.0)
      log("spawn slow, retry next to V: " .. u.rec)
      Game.GetCompanionSystem():SpawnSubcharacterOnPosition(tdbid(u.rec), v)
      after(3.0, function()
        if u.gen ~= gen then return end
        local e3 = spawned(u)
        if e3 then found(e3) return end
        failed()
      end)
    end)
  end)
end

-- slot: sideways place at the van doors; quiet: no deploy notice (crew call)
local function deploy(u, slot, quiet)
  if u.state ~= "home" then return false end
  if not recordsOk then notify("Cyberslop Salvage: records failed to build, see the log") return false end
  local player = getPlayer()
  if not player then return false end
  if isAway(u) then notify(u.name .. " is still away.") return false end
  local pos
  if u.stow then
    local car, how = findCar(u.stow == "van", CAR_RANGE)
    log(string.format("car check for %s: %s via %s", u.key, car and "found" or "none", tostring(how)))
    if not car then
      if u.stow == "van" then
        notify(string.format("%s is in the van. Bring your Columbus within %d m.", u.name, CAR_RANGE))
      else
        notify(string.format("%s is in your trunk. None of your cars is within %d m.", u.name, CAR_RANGE))
      end
      return false
    end
    pos = trunkSpot(car, slot, player, u)
  else
    pos = spawnPoint(player, u)
  end
  local note
  if u.cargo then
    local res, text = serviceUnit(u)   -- parts go in before it leaves the trunk
    if res == 1 then
      if quiet then notify(text) else note = text .. " " end
    end
    if wearOf(u) >= 100.0 then
      notify(text ~= "" and text or (u.name .. " is worn out and stays stowed until it is serviced."))
      return false
    end
    if res == -1 then notify(text) end
  end
  startSpawn(u, pos, { quiet = quiet, note = note })
  return true
end

local function anyVan(state)
  for _, k in ipairs(VAN) do
    if UNITS[k].state == state then return true end
  end
  return false
end

-- all stowed van androids climb out, 0.7 s apart, side by side at the rear doors
local function deployCrew()
  if not getPlayer() then return end
  local car = findCar(true, CAR_RANGE)
  if not car then
    notify(string.format("The androids are in the van. Bring your Columbus within %d m.", CAR_RANGE))
    return
  end
  local n = 0
  for i, k in ipairs(VAN) do
    local u = UNITS[k]
    if u.state == "home" and not isAway(u) then
      local slot = i - 2.5
      after(n * 0.7, function() deploy(u, slot, true) end)
      n = n + 1
    end
  end
  if n > 0 then
    notify(n == 1 and "1 android climbing out of the van." or (n .. " androids climbing out of the van."))
  else
    notify("No android is stowed in the van.")
  end
end

-- walks to the nearest own car (android) or climbs out (drones), then despawns and gets serviced
local function leave(u, msg)
  if u.state == "home" or u.state == "leaving" then return end
  local ent, player = u.ent, getPlayer()
  if u.state ~= "deployed" and u.state ~= "standby" or not ent or not IsDefined(ent) or not player then
    -- still spawning, on its way, or waiting out of contact: nothing to walk off
    despawnNow(u)
    if not (u.cargo and stowed(u)) and msg then notify(msg) end
    return
  end
  u.gen = u.gen + 1
  local gen = u.gen
  u.state, u.run, u.glide = "leaving", nil, nil
  if msg then notify(msg) end
  releaseHold(ent)
  setNoRole(ent)
  local p, pp = ent:GetWorldPosition(), player:GetWorldPosition()
  local function done()
    if u.gen ~= gen then return end
    despawnNow(u)
    if u.cargo then stowed(u) end
  end
  if u.fly then
    local dx, dy = p.x - pp.x, p.y - pp.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.5 then dx, dy, d = 0.0, 1.0, 1.0 end
    glide(u, p.x + dx / d * 40.0, p.y + dy / d * 40.0, p.z + 35.0, 9.0, done)
    return
  end
  local tx, ty, tz
  local wait = 7.0
  if u.stow then
    -- android 1 goes to any own car, a van android only to the van (else it walks off to it by itself)
    local car = findCar(u.stow == "van", STOW_RANGE)
    if car then
      local spot = trunkSpot(car, 0, player, u)
      tx, ty, tz = spot.x, spot.y, spot.z
      wait = math.max(4.0, math.min(15.0, dist(p, spot) / 1.5 + 1.0))
    end
  end
  if not tx then
    local dx, dy = p.x - pp.x, p.y - pp.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.5 then dx, dy, d = 0.0, 1.0, 1.0 end
    tx, ty, tz = p.x + dx / d * 25.0, p.y + dy / d * 25.0, p.z
  end
  moveTo(ent, tx, ty, tz)
  after(wait, done)
end

-- the unit stops where it is and waits: no looting, no following
local function standby(u, quiet)
  if u.state ~= "deployed" then return false end
  u.state, u.run, u.glide = "standby", nil, nil
  local ent = u.ent
  if ent and IsDefined(ent) then
    hold(ent)
    local p = ent:GetWorldPosition()
    u.lastPos = { x = p.x, y = p.y, z = p.z }
  end
  setField(u, 2)
  log(u.key .. " standby")
  if not quiet then notify(u.name .. " on standby.") end
  return true
end

-- a unit that is out but not with V any more: no entity, it waits until V calls it or sends it home
local function toWaiting(u, why)
  if not u.cargo then
    despawnNow(u)
    notify(u.name .. " lost contact and is returning home.")
    return
  end
  local ent = u.ent
  if ent and IsDefined(ent) then
    pcall(function()
      local p = ent:GetWorldPosition()
      u.lastPos = { x = p.x, y = p.y, z = p.z }
    end)
  end
  u.gen = u.gen + 1
  pcall(function() Game.GetCompanionSystem():DespawnSubcharacter(tdbid(u.rec)) end)
  u.state, u.ent, u.run, u.glide, u.missing = "standby", nil, nil, nil, 0
  setField(u, 2)
  log(u.key .. " waiting (" .. why .. ")")
  return true   -- the tick tells V, once for all units that dropped out in the same second
end

-- a waiting unit comes back: close by it walks over, from farther away it arrives after its travel time
local function resume(u, quiet)
  if u.state ~= "standby" then return false end
  local player = getPlayer()
  if not player then return false end
  u.wasActive = nil
  local pp = player:GetWorldPosition()
  local ent = u.ent
  local here = ent ~= nil and IsDefined(ent)
  local d
  if here then
    d = dist(ent:GetWorldPosition(), pp)
  elseif u.lastPos then
    d = dist(u.lastPos, pp)
  end
  if here and d <= RESUME_WALK then
    releaseHold(ent)
    setFollow(ent)
    u.state = "deployed"
    setField(u, 1)
    log(u.key .. " resume (walks over)")
    if not quiet then notify(u.name .. " resuming.") end
    return true
  end
  local eta = math.max(5.0, math.min(60.0, (d or 100.0) / TRAVEL_SPEED))
  pcall(function() Game.GetCompanionSystem():DespawnSubcharacter(tdbid(u.rec)) end)
  u.gen = u.gen + 1
  local gen = u.gen
  u.state, u.ent, u.run, u.glide = "coming", nil, nil, nil
  setField(u, 1)
  log(string.format("%s resume (travels %.0f s)", u.key, eta))
  if not quiet then notify(string.format("%s on its way, about %d s.", u.name, eta)) end
  after(eta, function()
    if u.gen ~= gen or u.state ~= "coming" then return end
    local p = getPlayer()
    if not p then return end
    startSpawn(u, spawnPoint(p, u), { back = "standby", arrive = true })
  end)
  return true
end

-- one key for the mission case: everything out waits; pressed again, everything waiting comes
local function toggleStandbyAll()
  local n = 0
  for _, k in ipairs(ORDER) do
    if standby(UNITS[k], true) then n = n + 1 end
  end
  if n > 0 then
    notify(n == 1 and "1 unit on standby." or (n .. " units on standby."))
    return
  end
  for _, k in ipairs(ORDER) do
    if resume(UNITS[k], true) then n = n + 1 end
  end
  if n > 0 then
    notify(n == 1 and "1 unit resuming." or (n .. " units resuming."))
  else
    for _, k in ipairs(ORDER) do
      local st = UNITS[k].state
      if st == "coming" or st == "spawning" then
        notify("Salvage units are on their way.")
        return
      end
    end
    notify("No salvage unit is out.")
  end
end

local function sendAllHome()
  local n = 0
  for _, k in ipairs(CARGO) do
    local u = UNITS[k]
    if u.state ~= "home" and u.state ~= "leaving" then
      leave(u, nil)
      n = n + 1
    end
  end
  if n > 0 then notify(n == 1 and "1 unit heading back. Cargo stays aboard." or (n .. " units heading back. Cargo stays aboard.")) end
end

local function dispatch(u, mode)
  local s = sys()
  if not s then notify("Cyberslop Salvage: redscript part missing") return end
  local ok, res = pcall(function() return s:Dispatch(u.unit, mode, cfg.tripMinutes * 1.0, cfg.fencePct / 100.0) end)
  if not ok or not res then
    log("dispatch refused: " .. tostring(res))
    notify(u.name .. ": nothing to " .. (mode == 1 and "recycle." or "sell."))
    return
  end
  local what = mode == 1 and "the recycler" or "a fence"
  local msg = string.format("%s heading to %s. Back in about %d game minutes.", u.name, what, cfg.tripMinutes)
  if u.state == "home" then notify(msg) else leave(u, msg) end
  log(string.format("dispatch %s mode %d, %d min, fence %d %%", u.key, mode, cfg.tripMinutes, cfg.fencePct))
end

-- ---------------------------------------------------------------- looting

-- one search per tick for all idle units: downed non-civilians around V, the drops next to them,
-- and (1.2.0) guns lying on the ground
local gunsFailed = false
local function scan(player)
  if scanTick == tickN and scanList then return scanList end
  local list = {}
  local pp = player:GetWorldPosition()
  local bodies, drops = {}, {}
  local ok, err = pcall(function()
    local q = Game["TSQ_ALL;"]()
    q.maxDistance = SCAN_RADIUS
    q.includeSecondaryTargets = false
    q.ignoreInstigator = true
    local found, parts = Game.GetTargetingSystem():GetTargetParts(player, q)
    if not found or not parts then return end
    local seen = {}
    for _, part in ipairs(parts) do
      pcall(function()
        local ent = part:GetComponent(part):GetEntity()
        if not ent or not IsDefined(ent) or ent:IsPlayer() then return end
        local key = entKey(ent)
        if seen[key] then return end
        seen[key] = true
        if ent:IsNPC() then
          if not isDown(ent) then return end
          if ent:IsCrowd() or ent:IsCharacterCivilian() then return end
          if ScriptedPuppet.IsPlayerCompanion(ent) then return end
          local p = ent:GetWorldPosition()
          bodies[#bodies + 1] = { ent = ent, key = key, pos = p, dP = dist(p, pp) }
        elseif ent:IsA("gameItemDropObject") then
          local p = ent:GetWorldPosition()
          drops[#drops + 1] = { ent = ent, key = key, pos = p, dP = dist(p, pp), drop = true }
        end
      end)
    end
  end)
  if not ok then log("search failed: " .. tostring(err)) end
  local listed = {}
  for _, b in ipairs(bodies) do list[#list + 1] = b end
  -- 1.2.0: guns on the ground, from the redscript drop list (the query above does not return them).
  -- Next to a body: any gun. Away from one: setting on, and not an iconic (V picks those up).
  local s = sys()
  if s and not gunsFailed then
    local okG, errG = pcall(function()
      local guns = s:FindWeaponDrops(SCAN_RADIUS, cfg.ownDrops)
      if not guns then return end
      for i, ent in ipairs(guns) do
        if ent and IsDefined(ent) then
          local key = entKey(ent)
          if not listed[key] then
            local p = ent:GetWorldPosition()
            local near = false
            for _, b in ipairs(bodies) do
              if dist(p, b.pos) <= 4.0 then near = true break end
            end
            if near or (cfg.looseWeapons and s:FoundPlain(i - 1)) then
              listed[key] = true
              -- count is known: redscript saw a gun there (it may be linked to the drop, not in its item list)
              list[#list + 1] = { ent = ent, key = key, pos = p, dP = dist(p, pp), drop = true, gun = true,
                                  loose = not near, count = 1 }
            end
          end
        end
      end
    end)
    if not okG then
      gunsFailed = true   -- redscript part older than 1.2.0: say it once, keep looting bodies
      log("gun search failed, off until the next reload: " .. tostring(errG))
    end
  end
  for _, dr in ipairs(drops) do
    if not listed[dr.key] then
      for _, b in ipairs(bodies) do
        if dist(dr.pos, b.pos) <= 4.0 then
          list[#list + 1] = dr
          listed[dr.key] = true
          break
        end
      end
    end
  end
  scanTick, scanList = tickN, list
  return list
end

local function claimedByOther(u, key)
  for _, k in ipairs(CARGO) do
    local o = UNITS[k]
    if o ~= u and o.run and o.run.key == key then return true end
  end
  return false
end

local function findTarget(u, player)
  local list = scan(player)
  local up = u.ent:GetWorldPosition()
  local best, bestD
  for _, c in ipairs(list) do
    if c.dP <= u.radius and not u.looted[c.key] and not emptySeen[c.key] and not claimedByOther(u, c.key) then
      if c.count == nil then
        c.count = 0
        -- 1.2.1: what the unit would really take (redscript rules); item list size with an older .reds
        local s = sys()
        local okC = s ~= nil and pcall(function()
          c.count = s:LootableCount(c.ent, (not c.drop) or cfg.ownDrops) or 0
        end)
        if not okC then
          pcall(function()
            local _, items = Game.GetTransactionSystem():GetItemList(c.ent)
            c.count = items and #items or 0
          end)
        end
        if c.count == 0 then
          if emptyN > 800 then emptySeen, emptyN = {}, 0 end
          emptySeen[c.key] = true
          emptyN = emptyN + 1
        end
      end
      if c.count > 0 then
        local d = dist(up, c.pos)
        if not bestD or d < bestD then best, bestD = c, d end
      end
    end
  end
  return best
end

local function finishRun(u)
  u.run = nil
  if u.ent and IsDefined(u.ent) then setFollow(u.ent) end
end

local function markLooted(u, key)
  if not u.looted[key] then
    u.looted[key] = true
    u.lootedN = u.lootedN + 1
  end
end

local function lootTarget(u, target)
  local s = sys()
  markLooted(u, target.key)
  if not s then return end
  local ok, n = pcall(function()
    -- 1.2.0: a drop goes through LootDrop (the unit itself carries a gun that is only linked to its drop)
    if target.drop then return s:LootDrop(u.unit, target.ent, u.ent, u.capacity, cfg.ownDrops) end
    return s:LootFrom(u.unit, target.ent, u.capacity)
  end)
  if not ok then log("LootFrom error: " .. tostring(n)) return end
  local cash, left, how = 0, 0, ""
  pcall(function() cash = s:LastCash() left = s:LastLeft() end)
  if target.drop then pcall(function() how = " (drop, " .. tostring(s:LastHow()) .. ")" end) end
  local kg = cargoKg(u)
  local what = ""
  pcall(function()
    local w = s:LastWhat()
    if w and w ~= "" then what = " [" .. tostring(w) .. "]" end
  end)
  log(string.format("%s looted %s%s: %s items, cash %d, left %d, cargo %.1f kg%s", u.key, target.key, how, tostring(n), cash, left, kg, what))
  if cash > 0 then
    notify(string.format(target.drop and "%s wired you E$ %d it picked up." or "%s wired you E$ %d found on the body.", u.name, cash), true)
  end
  if n == -1 or left > 0 then
    -- items stayed on the body: visit it again once there is room (the full gate waits for this unit's cargo to shrink)
    if u.looted[target.key] then
      u.looted[target.key] = nil
      u.lootedN = u.lootedN - 1
    end
    u.full = true
    u.fullKg = kg
    notify(string.format("%s full (%.1f / %.0f kg). Recycle or sell to make room.", u.name, kg, u.capacity))
  elseif n and n > 0 then
    notify(string.format("%s: %d items aboard (%.1f / %.0f kg).", u.name, n, kg, u.capacity), true)
  end
end

-- search time per body: as rated up to 50 % wear, twice as long at 100 %
local function workTime(u)
  local w = u.wear or 0.0
  if w <= 50.0 then return u.work end
  return u.work * (1.0 + (math.min(100.0, w) - 50.0) / 50.0)
end

local function lootTick(u, player, inCombat)
  local ent = u.ent
  if not ent or not IsDefined(ent) then return end
  if inCombat then
    if u.run then finishRun(u) end
    return
  end
  if u.full then
    -- stays full until its own cargo shrinks (take, recycle, sell); other units' loot does not reopen it
    if cargoKg(u) >= u.fullKg - 0.01 then return end
    u.full = false
  end
  local r = u.run
  if not r then
    if not cfg.autoLoot then return end
    local target = findTarget(u, player)
    if not target then return end
    local tp = target.pos
    u.run = { ent = target.ent, key = target.key, pos = tp, phase = "move", t = 0.0, drop = target.drop }
    setNoRole(ent)
    log(string.format("%s heading to %s (%s%.0f m)", u.key, target.key,
      target.gun and (target.loose and "loose gun, " or "gun by a body, ") or (target.drop and "drop, " or ""),
      dist(ent:GetWorldPosition(), tp)))
    if u.fly then
      local gen = u.gen
      glide(u, tp.x, tp.y, tp.z + 2.5, 6.0, function()
        if u.gen == gen and u.run then u.run.phase, u.run.t = "work", 0.0 end
      end)
    else
      moveTo(ent, tp.x, tp.y, tp.z)
    end
    return
  end
  if not IsDefined(r.ent) then markLooted(u, r.key) finishRun(u) return end
  r.t = r.t + 1.0
  if r.phase == "move" then
    if not u.fly and dist(ent:GetWorldPosition(), r.pos) <= 2.5 then
      r.phase, r.t = "work", 0.0
    elseif r.t > 25.0 then
      log(u.key .. " could not reach " .. r.key .. ", skipped")
      markLooted(u, r.key)
      finishRun(u)
    end
  elseif r.phase == "work" and r.t >= workTime(u) * (r.drop and 0.5 or 1.0) then
    -- 1.2.0: picking something up off the ground takes half the time of searching a body
    lootTarget(u, { ent = r.ent, key = r.key, drop = r.drop })
    finishRun(u)
  end
end

-- ---------------------------------------------------------------- tick

local view   -- window cache, defined with the window code below

local function resetAll()
  if view then view.version = -1 end
  if not needSync then
    -- first tick without a player after play: a load brings enemies back under the same entity ids
    emptySeen, emptyN = {}, 0
    for _, k in ipairs(ORDER) do
      local u = UNITS[k]
      u.looted, u.lootedN, u.full = {}, 0, false
    end
  end
  needSync = true
  for _, k in ipairs(ORDER) do
    local u = UNITS[k]
    if u.state ~= "home" then
      -- no player (menu, loading): forget the entities. The field state stays in the save,
      -- syncField() puts units that are out back on standby once a save is loaded.
      u.gen = u.gen + 1
      u.state, u.ent, u.run, u.glide, u.lastPos, u.wasActive = "home", nil, nil, nil, nil, nil
    end
  end
end

-- after a load (or a CET reload): units the save has in the field are out, waiting on standby
local function syncField(s)
  local n = 0
  for _, k in ipairs(CARGO) do
    local u = UNITS[k]
    if u.state == "home" then
      local f = 0
      pcall(function() f = s:Field(u.unit) end)
      if f ~= 0 then
        u.gen = u.gen + 1
        u.state, u.ent, u.run, u.glide, u.lastPos, u.missing = "standby", nil, nil, nil, nil, 0
        if f == 2 then
          n = n + 1
          log(u.key .. " is out in this save: waiting on standby")
        else
          -- it was working when the save was made: if the game brings its entity back within
          -- two checks (10 s) it carries on, else it waits (tick, standby branch)
          u.wasActive = 2
          log(u.key .. " is out in this save: was active, looking for its entity")
        end
      end
    end
    wearOf(u)
  end
  if n > 0 then
    notify(n == 1 and "1 salvage unit is still out, waiting where you left it."
      or (n .. " salvage units are still out, waiting where you left them."))
  end
end

local function tick()
  tickN = tickN + 1
  local player = getPlayer()
  if not player then resetAll() return end
  if needSync then
    local s0 = sys()
    if s0 then
      needSync = false
      syncField(s0)
    end
  end
  local pp = player:GetWorldPosition()
  local busy = false
  local inCombat
  local lostN, lostName = 0, nil
  for _, k in ipairs(ORDER) do
    local u = UNITS[k]
    if u.state == "deployed" then
      busy = true
      local ent = spawned(u)
      if not ent then
        u.missing = u.missing + 1
        if u.missing >= 3 and toWaiting(u, "entity gone") then lostN, lostName = lostN + 1, u.name end
      else
        u.missing = 0
        u.ent = ent
        if dist(ent:GetWorldPosition(), pp) > CONTACT then
          if toWaiting(u, "out of contact") then lostN, lostName = lostN + 1, u.name end
        elseif u.cargo then
          if tickN % 10 == 0 then
            local w = wearOf(u)
            if w >= 100.0 then
              leave(u, u.name .. " is worn out and heads back to be serviced.")
            elseif w >= 50.0 and not u.warned then
              u.warned = true
              notify(u.name .. " is past 50 % wear and works slower. Stow it to service it.")
            end
          end
          if u.state == "deployed" and not u.glide then
            if inCombat == nil then
              inCombat = false
              pcall(function() inCombat = player:IsInCombat() == true end)
            end
            lootTick(u, player, inCombat)
          end
        end
      end
    elseif u.state == "standby" then
      -- every 5 s: adopt an entity the game brought back, drop one that got out of contact
      if tickN % 5 == 0 then
        local ent = spawned(u)
        if ent and u.ent == nil and u.wasActive then
          -- restored by the game after a load while it was working: carry on
          u.wasActive = nil
          u.ent, u.state, u.missing = ent, "deployed", 0
          applyCompanion(u, ent)
          log(u.key .. " entity is back, carrying on")
        elseif ent then
          if u.ent == nil then
            log(u.key .. " entity is back, holding position")
            applyCompanion(u, ent)
            hold(ent)
          end
          u.ent = ent
          local p = ent:GetWorldPosition()
          if dist(p, pp) > CONTACT then
            u.lastPos = { x = p.x, y = p.y, z = p.z }
            pcall(function() Game.GetCompanionSystem():DespawnSubcharacter(tdbid(u.rec)) end)
            u.ent = nil
            log(u.key .. " standby out of contact, entity removed")
          end
        else
          u.ent = nil
          if u.wasActive then
            u.wasActive = u.wasActive - 1
            if u.wasActive <= 0 then
              u.wasActive = nil
              setField(u, 2)
              log(u.key .. " entity did not come back: waiting on standby")
              notify(u.name .. " is still out, waiting where you left it.")
            end
          end
        end
      end
    elseif u.state ~= "home" then
      busy = true
    elseif tickN % 10 == 0 and spawned(u) then
      -- a unit the game restored by itself (save / load) while it is stowed
      log(u.key .. " orphan entity removed")
      pcall(function() Game.GetCompanionSystem():DespawnSubcharacter(tdbid(u.rec)) end)
    end
  end
  if lostN == 1 then
    notify(lostName .. " lost contact. It waits where you left it.")
  elseif lostN > 1 then
    notify(lostN .. " units lost contact. They wait where you left them.")
  end
  if busy or tickN % 5 == 0 then
    local s = sys()
    if s then
      local ok, text = pcall(function() return s:Update() end)
      if ok and text and text ~= "" then notify(text) end
    end
  end
end

-- ---------------------------------------------------------------- window

view = { version = -1, t = 0.0, units = {} }

local function tierText(t)
  if t >= 10 then return "T5++" end
  return "T" .. (math.floor(t / 2) + 1) .. ((t % 2 == 1) and "+" or "")
end

local function rebuildRows(s)
  for _, k in ipairs(CARGO) do
    local u = UNITS[k]
    local cats = {}
    local n = 0
    pcall(function() n = s:Count(u.unit) end)
    for i = 0, n - 1 do
      local id, name, qty, tier, cat, kg, sell = 0, "?", 0, 0, 9, 0.0, 0
      pcall(function()
        id = s:EntryId(u.unit, i)
        name = s:Name(u.unit, i)
        qty = s:Qty(u.unit, i)
        tier = s:Tier(u.unit, i)
        cat = s:Cat(u.unit, i)
        kg = s:Kg(u.unit, i)
        sell = s:Sell(u.unit, i)
      end)
      local c = cats[cat]
      if not c then c = { rows = {}, kg = 0.0, n = 0 } cats[cat] = c end
      local tierPart = (cat <= 2 or (cat == 9 and tier > 0)) and (" " .. tierText(tier)) or ""
      c.rows[#c.rows + 1] = {
        id = id,
        label = string.format("%s%s  x%d  %.1f kg  E$ %d", name, tierPart, qty, kg, sell),
        btn = "Take##" .. id,
      }
      c.kg = c.kg + kg
      c.n = c.n + qty
    end
    local list = {}
    for cat = 0, 9 do
      local c = cats[cat]
      if c then
        c.cat = cat
        c.header = string.format("%s: %d items, %.1f kg##%s%d", CATS[cat], c.n, c.kg, k, cat)
        c.takeAll = "Take all##" .. k .. cat
        list[#list + 1] = c
      end
    end
    local vu = view.units[k] or {}
    vu.cats = list
    view.units[k] = vu
  end
end

local function statusText(u, left)
  if left > 0 then
    local m = math.ceil(left)
    return string.format("away, back in %d h %02d min", math.floor(m / 60), m % 60)
  elseif u.state == "deployed" then
    return u.run and "looting" or (u.full and "out, full" or "out")
  elseif u.state == "standby" then
    return u.ent and "on standby" or "waiting where you left it"
  elseif u.state == "coming" then
    return "on its way"
  elseif u.state == "spawning" then
    return "coming out"
  elseif u.state == "leaving" then
    return "heading back"
  elseif u.stow == "van" then
    return "in the van"
  elseif u.stow == "car" then
    return "in the trunk"
  end
  return "home"
end

local function refreshStatus(s)
  for _, k in ipairs(CARGO) do
    local u = UNITS[k]
    local vu = view.units[k] or { cats = {} }
    view.units[k] = vu
    local kg, est, comps, left, wear, quote = 0.0, 0, 0, 0.0, 0.0, ""
    pcall(function()
      kg = s:CargoKg(u.unit)
      est = s:EstSell(u.unit)
      comps = s:EstComponents(u.unit)
      left = s:AwayMinutesLeft(u.unit)
      wear = s:Wear(u.unit)
      if wear >= 1.0 then quote = s:ServiceQuote(u.unit) end
    end)
    u.wear = wear
    vu.kg, vu.away, vu.wear = kg, left > 0, wear
    vu.bar = string.format("%.1f / %.0f kg", kg, u.capacity)
    vu.frac = math.min(1.0, kg / u.capacity)
    vu.est = string.format("Sell: about E$ %d after the fence cut | Recycle: about %d components",
      math.floor(est * cfg.fencePct / 100), comps)
    vu.status = statusText(u, left)
    local cond = math.max(0, math.floor(100.0 - wear + 0.5))
    -- text after ### is the id, so the header keeps its open state while the label changes
    vu.header = string.format("%s: %s | %.0f / %.0f kg | condition %d %%###cs_%s", u.name, vu.status, kg, u.capacity, cond, k)
    vu.cond = string.format("Condition %d %%%s", cond,
      (wear > 50.0) and string.format(" (worn: %.1f x search time)", 1.0 + (math.min(100.0, wear) - 50.0) / 50.0) or "")
    vu.quote = quote or ""
  end
end

local function lookButton(u)
  if not u.lookLabel then u.lookLabel = "Look: " .. u.looks[cfg.look[u.key]][1] .. "##look" .. u.key end
  if ImGui.Button(u.lookLabel) then
    cfg.look[u.key] = cfg.look[u.key] % #u.looks + 1
    u.lookLabel = nil
    saveCfg()
  end
end

local function drawCargoUnit(u, s)
  local vu = view.units[u.key]
  if not vu or not vu.status then return end
  if not ImGui.CollapsingHeader(vu.header) then return end
  ImGui.ProgressBar(vu.frac, -1, 0, vu.bar)
  ImGui.Text(vu.cond)
  if vu.quote ~= "" then ImGui.Text(vu.quote) end
  ImGui.Text(vu.est)
  local L = u.L
  if u.state == "home" and not vu.away then
    if ImGui.Button(L.deploy) then deploy(u) end
    ImGui.SameLine()
    if vu.wear >= 1.0 then
      if ImGui.Button(L.service) then
        local res, text = serviceUnit(u)
        if text ~= "" then notify(text) elseif res == 0 then notify(u.name .. ": nothing to service.") end
        view.version = -1
      end
      ImGui.SameLine()
    end
  elseif u.state == "deployed" then
    if ImGui.Button(L.standby) then standby(u) end
    ImGui.SameLine()
    if ImGui.Button(L.home) then leave(u, u.name .. " heading back. Cargo stays aboard.") end
    ImGui.SameLine()
  elseif u.state == "standby" then
    if ImGui.Button(L.resume) then resume(u) end
    ImGui.SameLine()
    if ImGui.Button(L.home) then leave(u, u.name .. " heading back. Cargo stays aboard.") end
    ImGui.SameLine()
  end
  if not vu.away and #vu.cats > 0 and (u.state == "home" or u.state == "deployed" or u.state == "standby") then
    if ImGui.Button(L.recycle) then dispatch(u, 1) end
    ImGui.SameLine()
    if ImGui.Button(L.sell) then dispatch(u, 2) end
    ImGui.SameLine()
  end
  lookButton(u)
  -- 1.1.1: next to V, checked twice a second
  local now = os.clock()
  if not vu.nearAt or now >= vu.nearAt then
    vu.nearAt = now + 0.5
    vu.near = false
    pcall(function()
      local player = Game.GetPlayer()
      if u.ent and player then vu.near = dist(u.ent:GetWorldPosition(), player:GetWorldPosition()) <= TAKE_RANGE end
    end)
  end
  local canTake = (u.state == "deployed" or u.state == "standby") and u.ent ~= nil and vu.near == true
  if not canTake and #vu.cats > 0 then ImGui.Text("The unit has to be out, next to you (6 m), to take items off it.") end
  for _, c in ipairs(vu.cats) do
    if ImGui.CollapsingHeader(c.header) then
      if canTake and ImGui.Button(c.takeAll) then
        pcall(function() s:TakeCategory(u.unit, c.cat) end)
      end
      for _, r in ipairs(c.rows) do
        if canTake then
          if ImGui.Button(r.btn) then
            local ok, res = pcall(function() return s:Take(r.id) end)
            if not ok or not res then notify("Could not take that item.") end
          end
          ImGui.SameLine()
        end
        ImGui.Text(r.label)
      end
    end
  end
end

local function anyState(list, state)
  for _, k in ipairs(list) do
    if UNITS[k].state == state then return true end
  end
  return false
end

local function drawBody()
  local s = getPlayer() and sys() or nil
  if not s then
    view.version = -1   -- Version() restarts at 1 after a load: rebuild once a save is back
    ImGui.Text("Load a save first (or the redscript part is missing).")
    return
  end
  local v = -1
  pcall(function() v = s:Version() end)
  if v ~= view.version then
    view.version = v
    rebuildRows(s)
    refreshStatus(s)
  end
  local carry = UNITS.carry
  ImGui.Text(CARRY_TEXT[carry.state] or CARRY_TEXT.other)
  if carry.state == "home" then
    if ImGui.Button("Call carry drone") then deploy(carry) end
  elseif carry.state == "deployed" or carry.state == "standby" then
    if ImGui.Button("Send to stash") then leave(carry, STASH_LINES[math.random(#STASH_LINES)]) end
  end
  ImGui.SameLine()
  lookButton(carry)
  ImGui.Separator()
  local out = anyState(ORDER, "deployed")
  local waiting = anyState(ORDER, "standby")
  if anyVan("home") then
    if ImGui.Button("Deploy van crew") then deployCrew() end
    ImGui.SameLine()
  end
  if out then
    if ImGui.Button("Standby all") then toggleStandbyAll() end
    ImGui.SameLine()
  elseif waiting then
    if ImGui.Button("Resume all") then toggleStandbyAll() end
    ImGui.SameLine()
  end
  if out or waiting then
    if ImGui.Button("Send all home") then sendAllHome() end
    ImGui.SameLine()
  end
  ImGui.Text("Android 1: any own car. Androids 2-5: the van.")
  for _, k in ipairs(CARGO) do
    drawCargoUnit(UNITS[k], s)
  end
  ImGui.Separator()
  if ImGui.CollapsingHeader("Settings##cs") then
    local val, pressed = ImGui.Checkbox("Auto-loot downed enemies (out of combat)", cfg.autoLoot)
    if pressed then cfg.autoLoot = val saveCfg() end
    local lw, pressedW = ImGui.Checkbox("Pick up guns lying away from any body", cfg.looseWeapons)
    if pressedW then cfg.looseWeapons = lw saveCfg() end
    local od, pressedO = ImGui.Checkbox("Also pick up weapons V dropped", cfg.ownDrops)
    if pressedO then cfg.ownDrops = od saveCfg() end
    local m, used = ImGui.SliderInt("Trip (game minutes)", cfg.tripMinutes, 30, 240)
    if used and m ~= cfg.tripMinutes then cfg.tripMinutes = m saveCfg() end
    local f, usedF = ImGui.SliderInt("Fence pays (% of vendor price)", cfg.fencePct, 50, 100)
    if usedF and f ~= cfg.fencePct then cfg.fencePct = f saveCfg() end
    local lg, pressedL = ImGui.Checkbox("Log to CyberslopSalvage.log", cfg.log)
    if pressedL then cfg.log = lg saveCfg() end
  end
end

-- ---------------------------------------------------------------- hotkeys

local function toggle(k)
  local u = UNITS[k]
  if u.state == "home" then
    deploy(u)
  elseif u.state == "deployed" or u.state == "standby" then
    if k == "carry" then leave(u, STASH_LINES[math.random(#STASH_LINES)])
    else leave(u, u.name .. " heading back. Cargo stays aboard.") end
  end
end

local function toggleVan()
  local n = 0
  for _, k in ipairs(VAN) do
    local u = UNITS[k]
    if u.state == "deployed" or u.state == "standby" then
      leave(u, nil)
      n = n + 1
    end
  end
  if n > 0 then
    notify(n == 1 and "1 van android heading back. Cargo stays aboard." or (n .. " van androids heading back. Cargo stays aboard."))
  else
    deployCrew()
  end
end

-- 1.2.3: one key for android 1 (Numpad 2). Hold = deploy from the trunk, or send home when it is out.
-- Tap = go / wait: a working android stops and waits, a waiting one comes back and works.
local KEY_HOLD = 0.5   -- seconds the key must stay down to count as a hold
local akey = { down = false, t = 0.0, fired = false }

local function androidHold()
  local u = UNITS.android
  if u.state == "home" then
    deploy(u)
  elseif u.state == "leaving" then
    notify(u.name .. " is already heading back.")
  else
    leave(u, u.name .. " heading back. Cargo stays aboard.")
  end
end

local function androidTap()
  local u = UNITS.android
  if u.state == "deployed" then
    standby(u)
  elseif u.state == "standby" then
    resume(u)
  elseif u.state == "home" then
    notify(u.name .. " is stowed. Hold the key to deploy it.")
  elseif u.state == "leaving" then
    notify(u.name .. " is heading back.")
  else
    notify(u.name .. " is on its way.")
  end
end

local function androidKeyFrame(dt)
  if not akey.down or akey.fired then return end
  akey.t = akey.t + dt
  if akey.t >= KEY_HOLD then
    akey.fired = true
    androidHold()
  end
end

registerInput("cs_android_key", "Salvage android 1: hold = deploy / send home, tap = go / wait", function(down)
  if down then
    akey.down, akey.t, akey.fired = true, 0.0, false   -- a lost release (menu) never blocks the next press
    return
  end
  local wasTap = akey.down and not akey.fired
  akey.down, akey.fired = false, false
  if wasTap then androidTap() end
end)

registerHotkey("cs_carry", "Carry drone: call / send to stash", function() toggle("carry") end)
registerHotkey("cs_android", "Salvage android 1 (trunk): deploy / send home", function() toggle("android") end)
registerHotkey("cs_octant", "Salvage drone: deploy / send home", function() toggle("octant") end)
registerHotkey("cs_van", "Van androids 2-5: deploy all / send home", function() toggleVan() end)
registerHotkey("cs_standby", "Salvage units: standby / resume (all)", function() toggleStandbyAll() end)

-- ---------------------------------------------------------------- events

registerForEvent("onInit", function()
  loadCfg()
  buildRecords()
  log("Cyberslop Salvage " .. VERSION .. " init, records " .. (recordsOk and "ok" or "FAILED"))
end)

registerForEvent("onOverlayOpen", function() overlay = true view.version = -1 end)
registerForEvent("onOverlayClose", function() overlay = false end)

registerForEvent("onUpdate", function(dt)
  if akey.down then pcall(androidKeyFrame, dt) end
  for _, k in ipairs(ORDER) do
    local u = UNITS[k]
    if u.glide then stepGlide(u, dt) end
  end
  if #timers > 0 then
    local due
    for i = #timers, 1, -1 do
      local t = timers[i]
      t.t = t.t - dt
      if t.t <= 0 then
        table.remove(timers, i)
        due = due or {}
        due[#due + 1] = t.fn
      end
    end
    if due then for i = #due, 1, -1 do due[i]() end end
  end
  if noteWait > 0.0 then
    noteWait = noteWait - dt
    if noteWait <= 0.0 and #noteQ > 0 then
      noteShown = table.remove(noteQ, 1)
      show(noteShown)
      noteWait = 3.0
    end
  end
  acc = acc + dt
  if acc >= 1.0 then
    acc = 0.0
    local ok, err = pcall(tick)
    if not ok then log("tick error: " .. tostring(err)) end
    if overlay then
      view.t = view.t + 1
      local s = sys()
      if s then pcall(refreshStatus, s) end
    end
  end
end)

registerForEvent("onDraw", function()
  if not overlay then return end
  -- End() must run whatever the body does, or ImGui's window stack breaks
  if ImGui.Begin(TITLE) then
    local ok, err = pcall(drawBody)
    if not ok then log("draw error: " .. tostring(err)) end
  end
  ImGui.End()
end)

registerForEvent("onShutdown", function()
  -- entities only: the field state stays as it is, so a CET reload finds the units waiting
  for _, k in ipairs(ORDER) do
    local u = UNITS[k]
    if u.state ~= "home" then
      pcall(function() Game.GetCompanionSystem():DespawnSubcharacter(tdbid(u.rec)) end)
      u.state, u.ent = "home", nil
    end
  end
end)
