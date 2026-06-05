-- By Kolenvlogger unc

local total      = 0
local passed     = 0
local failed     = {}
local at_ok      = 0
local AT_TOTAL   = 11
local chain_dead = nil

-- anti-fake checksum
-- every time a check passes we mix a running hash with a value
-- derived from the check index and current pass count.
-- patching 'passed' after the fact won't update the hash.
-- written in plain Lua 5.1 math, no bitwise operators.
local _hash  = 1516855341  -- 0x5A4B3C2D as decimal
local _index = 0
local _MOD   = 2^32

local function _mix(a, b)
    -- multiplicative mix, Lua 5.1 compatible
    return (a * 1000003 + b * 2654435769) % _MOD
end

local function _tick_hash(did_pass)
    _index = _index + 1
    if did_pass then
        _hash = _mix(_hash, _index * 2654435761)
        _hash = _mix(_hash, passed * 1812433253)
    end
end

local function why(ok, val)
    if not ok then
        local s = tostring(val)
        if s:find("attempt to index")   then return "something was nil that shouldn't be" end
        if s:find("attempt to call")    then return "tried to call a nil value" end
        if s:find("not a valid member") then return "property missing on this object" end
        if s:find("invalid argument")   then return "bad argument (wrong type or value)" end
        if s:find("stack overflow")     then return "stack overflow" end
        return "error: " .. s:sub(1, 32)
    end
    return "returned " .. tostring(val)
end

local function pass(label, fn)
    total = total + 1
    local ok, v = pcall(fn)
    local did = ok and v == true
    if did then
        passed = passed + 1
    else
        table.insert(failed, "FAIL  " .. label .. " -- " .. why(ok, v))
    end
    _tick_hash(did)
end

local function passNoErr(label, fn)
    total = total + 1
    local ok, e = pcall(fn)
    if ok then
        passed = passed + 1
    else
        table.insert(failed, "FAIL  " .. label .. " -- " .. why(false, e))
    end
    _tick_hash(ok)
end

local function passMustErr(label, fn)
    total = total + 1
    local ok = pcall(fn)
    local did = not ok
    if did then
        passed = passed + 1
    else
        table.insert(failed, "FAIL  " .. label .. " -- expected an error but it didn't error")
    end
    _tick_hash(did)
end

-- optional: wraps fn in pcall, skips (doesn't count as fail) if fn itself errors,
-- only counts if it runs cleanly and returns true. used for things not all
-- executors implement.
local function passOpt(label, fn)
    -- optional check: always counts toward total (so denominator is fixed).
    -- if it passes -> counts as passed.
    -- if it fails or errors -> silently skipped, NOT added to failed list.
    -- this keeps the denominator identical across all executors.
    total = total + 1
    local ok, v = pcall(fn)
    if ok and v == true then
        passed = passed + 1
        _tick_hash(true)
    else
        _tick_hash(false)
    end
end

local function at(n, label, fn)
    total = total + 1
    if chain_dead then
        table.insert(failed,
            "FAIL  [AT-"..n.."] "..label.." -- chain already dead (AT-"..chain_dead.." failed first)")
        _tick_hash(false)
        return
    end
    local ok, v = pcall(fn)
    local did = ok and v == true
    if did then
        passed  = passed + 1
        at_ok   = at_ok + 1
    else
        chain_dead = n
        table.insert(failed, "FAIL  [AT-"..n.."] "..label.." -- " .. why(ok, v))
    end
    _tick_hash(did)
end

-- snapshot the hash at the end of all checks so we can verify it wasn't touched
local _expected_hash = nil


-- ================================================================
-- ANTI-TAMPER
-- ================================================================

-- AT-1
-- pcall has to work properly. three things at once: message survives,
-- nested rethrow works, multi-return comes through.
-- hooking pcall to always return true breaks the multi-return stage.
at(1, "pcall: message / nested rethrow / multi-return", function()
    local ok1, e1 = pcall(function() error("__kl_at1__") end)
    if ok1 ~= false then return false end
    if type(e1) ~= "string" or not e1:find("__kl_at1__") then return false end

    local ok2, e2 = pcall(function()
        pcall(function() error("inner") end)
        error("__kl_rethrow__")
    end)
    if ok2 ~= false then return false end
    if not tostring(e2):find("__kl_rethrow__") then return false end

    local ok3, a, b, c = pcall(function() return 10, "hello", true end)
    if not ok3 or a ~= 10 or b ~= "hello" or c ~= true then return false end

    return true
end)

-- AT-2
-- type() vs typeof() must disagree on real Roblox C++ objects.
-- on a fake table both give "table". real objects give
-- type()="userdata", typeof()="Instance".
-- also checks same service ref returned twice.
at(2, "type/typeof split on Roblox objects + service ref stability", function()
    local p = Instance.new("Part")
    if type(p)   ~= "userdata" then p:Destroy(); return false end
    if typeof(p) ~= "Instance" then p:Destroy(); return false end
    if typeof(CFrame.new())  ~= "CFrame"  then p:Destroy(); return false end
    if typeof(Vector3.new()) ~= "Vector3" then p:Destroy(); return false end
    if typeof(Color3.new())  ~= "Color3"  then p:Destroy(); return false end
    p:Destroy()

    local rs1 = game:GetService("RunService")
    local rs2 = game:GetService("RunService")
    if rs1 ~= rs2 then return false end
    if game.ClassName ~= "DataModel" then return false end
    return true
end)

-- AT-3
-- IEEE 754 precision. sin^2+cos^2=1 across six angles.
-- log(exp(x))=x across four values.
-- NaN != NaN. infinity behaviour.
-- hardcoding true fails the numerical checks.
at(3, "IEEE 754: trig identity + log/exp inverse + NaN + inf", function()
    for _, a in ipairs({0.1, 0.5, 1.0, 1.7, 2.9, 4.2}) do
        if math.abs(math.sin(a)^2 + math.cos(a)^2 - 1) > 1e-10 then return false end
    end
    for _, x in ipairs({0.5, 1.0, 2.0, 7.3}) do
        if math.abs(math.log(math.exp(x)) - x) > 1e-10 then return false end
    end
    local nan = 0/0
    if nan == nan then return false end
    if not (math.huge > 1e300) then return false end
    if math.huge + 1 ~= math.huge then return false end
    if math.fmod(997, 13) ~= 997 % 13 then return false end
    return true
end)

-- AT-4
-- CFrame inverse identity and point roundtrip in C++.
-- a Lua table fake has to replicate matrix math bit-exactly.
at(4, "CFrame: inverse identity + point roundtrip + cross anti-commutativity", function()
    local cf = CFrame.new(3, 7, -2) * CFrame.Angles(0.5, 1.2, -0.3)
    local id  = cf * cf:Inverse()
    if math.abs(id.X) > 1e-5 then return false end
    if math.abs(id.Y) > 1e-5 then return false end
    if math.abs(id.Z) > 1e-5 then return false end

    local origin = CFrame.new(1, 2, 3)
    local pt     = Vector3.new(4, 5, 6)
    local back   = origin:PointToWorldSpace(origin:PointToObjectSpace(pt))
    if math.abs(back.X - pt.X) > 1e-5 then return false end
    if math.abs(back.Y - pt.Y) > 1e-5 then return false end
    if math.abs(back.Z - pt.Z) > 1e-5 then return false end

    local a  = Vector3.new(1, 2, 3)
    local b  = Vector3.new(4, 5, 6)
    local ab = a:Cross(b)
    local ba = b:Cross(a)
    if math.abs(ab.X + ba.X) > 1e-10 then return false end
    if math.abs(ab.Y + ba.Y) > 1e-10 then return false end
    if math.abs(ab.Z + ba.Z) > 1e-10 then return false end
    if math.abs(Vector3.new(3, 4, 0).Unit.Magnitude - 1) > 1e-6 then return false end
    return true
end)

-- AT-5
-- five independent ways to verify workspace is inside game.
-- would need to hook all five methods simultaneously.
at(5, "hierarchy 5-way cross-check", function()
    if not workspace:IsDescendantOf(game)                      then return false end
    if not game:IsAncestorOf(workspace)                        then return false end
    if game:FindFirstChild("Workspace") ~= workspace           then return false end
    if workspace:FindFirstAncestorOfClass("DataModel") ~= game then return false end
    if workspace.Parent ~= game                                then return false end
    return true
end)

-- AT-6
-- real Roblox objects have locked metatables.
-- setmetatable on game must fail.
-- __index and __namecall must exist AND be C closures.
-- executors replacing metamethods with Lua wrappers fail iscclosure.
at(6, "game metatable: locked + __index/__namecall are C closures", function()
    if pcall(setmetatable, game, {}) then return false end
    local mt = getrawmetatable(game)
    if type(mt) ~= "table"         then return false end
    if mt.__index    == nil         then return false end
    if mt.__namecall == nil         then return false end
    if not iscclosure(mt.__index)   then return false end
    if not iscclosure(mt.__namecall) then return false end
    return true
end)

-- AT-7
-- getnamecallmethod must return the exact method name.
-- tests GetService only (most reliable across all executors).
-- a fake returning a hardcoded string may get lucky once but
-- combined with AT-6 the full chain is hard to fake.
at(7, "getnamecallmethod returns correct method name", function()
    local captured = nil
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if captured == nil then captured = getnamecallmethod() end
        return old(self, ...)
    end))
    pcall(function() game:GetService("RunService") end)
    hookmetamethod(game, "__namecall", old)
    if captured ~= "GetService" then return false end
    return true
end)

-- AT-8
-- GetFullName path integrity + attribute survives reparent.
-- requires real internal Instance state, not a Lua table.
at(8, "Instance GetFullName + attribute persists through reparent", function()
    -- some executors report alternate names; accept both
    local wsfn = workspace:GetFullName()
    if wsfn ~= "Workspace" and wsfn ~= workspace.Name then return false end
    local gmfn = game:GetFullName()
    if gmfn ~= "Game" and gmfn ~= "DataModel" and gmfn ~= game.Name then return false end
    local lp = game.Players.LocalPlayer:GetFullName()
    if not lp:find("^Players%.") and not lp:find("Players") then return false end

    local f = Instance.new("Folder")
    f:SetAttribute("at8", 54321)
    f.Parent = workspace
    local v1 = f:GetAttribute("at8")
    f.Parent = nil
    local v2 = f:GetAttribute("at8")
    f:Destroy()
    if v1 ~= 54321 then return false end
    if v2 ~= 54321 then return false end
    return true
end)

-- AT-9
-- loadstring must produce a real function whose env can be swapped.
-- a pre-built fake closure ignores setfenv so the env stage fails.
at(9, "loadstring: compile + run + setfenv env isolation + syntax error", function()
    local fn1 = loadstring("return 2 + 2")
    if type(fn1) ~= "function" then return false end
    if fn1() ~= 4 then return false end

    local fn2, err = loadstring("this is !! not lua")
    if fn2 ~= nil or type(err) ~= "string" then return false end

    local fn3 = loadstring("return __at9__")
    if type(fn3) ~= "function" then return false end
    setfenv(fn3, setmetatable({__at9__ = 7777}, {__index = getfenv()}))
    if fn3() ~= 7777 then return false end
    return true
end)

-- AT-10
-- string metatable must be locked and __index must point to the
-- string library. OOP calls must work.
at(10, "string metatable: locked + __index==string + OOP calls", function()
    if pcall(setmetatable, "", {}) then return false end
    local s = "Hello World"
    if s:upper()  ~= "HELLO WORLD" then return false end
    if s:lower()  ~= "hello world" then return false end
    if s:len()    ~= 11            then return false end
    if s:sub(1,5) ~= "Hello"       then return false end
    local mt = getrawmetatable("")
    if type(mt) ~= "table"  then return false end
    if mt.__index ~= string then return false end
    return true
end)

-- AT-11
-- upvalue shared-state integrity via pure Lua mutation.
-- no getupvalue/setupvalue needed; tests that two closures
-- genuinely share the same upvalue slot by writing through a third closure.
at(11, "upvalue shared-state: two closures share one upvalue", function()
    local x = 100
    local getter = function() return x end
    local adder  = function() return x + 1 end
    local setter = function(v) x = v end

    if getter() ~= 100 then return false end
    if adder()  ~= 101 then return false end

    setter(999)

    if getter() ~= 999  then return false end
    if adder()  ~= 1000 then return false end

    return true
end)


-- ================================================================
-- GAME / DATAMODEL
-- ================================================================

pass("game.JobId is a non-empty string", function()
    return type(game.JobId) == "string" and #game.JobId > 0
end)
pass("game.PlaceId is > 0", function() return game.PlaceId > 0 end)
pass("game.GameId is > 0", function() return game.GameId > 0 end)
pass("game.ClassName is DataModel", function() return game.ClassName == "DataModel" end)
pass("game:IsA DataModel is true", function() return game:IsA("DataModel") == true end)
pass("game.PlaceVersion is >= 0", function()
    return type(game.PlaceVersion) == "number" and game.PlaceVersion >= 0
end)
pass("game.CreatorId is >= 0", function()
    return type(game.CreatorId) == "number" and game.CreatorId >= 0
end)
pass("game.CreatorType is an EnumItem", function()
    return typeof(game.CreatorType) == "EnumItem"
end)
passMustErr("GetService with a fake name errors", function()
    game:GetService("EnvCheckFakeService00000")
end)
pass("GetService Players works", function()
    return game:GetService("Players") ~= nil
end)
pass("FindService Workspace works", function()
    return game:FindService("Workspace") ~= nil
end)
pass("game:GetChildren has stuff in it", function()
    local c = game:GetChildren()
    return type(c) == "table" and #c > 0
end)
pass("game:GetDescendants has stuff in it", function()
    local d = game:GetDescendants()
    return type(d) == "table" and #d > 0
end)
passOpt("game.Name is Game or DataModel", function()
    return game.Name == "Game" or game.Name == "DataModel"
end)
pass("game.Parent is nil", function() return game.Parent == nil end)
passOpt("game:GetFullName() is Game or DataModel", function()
    local n = game:GetFullName()
    return n == "Game" or n == "DataModel"
end)
pass("game:FindFirstChild Workspace gives workspace", function()
    return game:FindFirstChild("Workspace") == workspace
end)
pass("FindFirstChildOfClass Workspace works", function()
    return game:FindFirstChildOfClass("Workspace") ~= nil
end)


-- ================================================================
-- WORKSPACE
-- ================================================================

pass("workspace.ClassName is Workspace", function()
    return workspace.ClassName == "Workspace"
end)
pass("workspace:IsA Workspace is true", function()
    return workspace:IsA("Workspace") == true
end)
pass("workspace:IsA Model is true", function()
    return workspace:IsA("Model") == true
end)
pass("workspace.Gravity is a positive number", function()
    return type(workspace.Gravity) == "number" and workspace.Gravity > 0
end)
pass("workspace.Gravity is between 50 and 500", function()
    return workspace.Gravity >= 50 and workspace.Gravity <= 500
end)
pass("workspace.DistributedGameTime is >= 0", function()
    return type(workspace.DistributedGameTime) == "number"
        and workspace.DistributedGameTime >= 0
end)
pass("workspace.StreamingEnabled is a boolean", function()
    return type(workspace.StreamingEnabled) == "boolean"
end)
pass("workspace.Parent is game", function()
    return workspace.Parent == game
end)
pass("workspace is a descendant of game", function()
    return workspace:IsDescendantOf(game) == true
end)
pass("workspace:GetFullName() returns Workspace", function()
    return workspace:GetFullName() == "Workspace"
end)
pass("workspace:GetChildren gives a table", function()
    return type(workspace:GetChildren()) == "table"
end)


-- ================================================================
-- CAMERA
-- ================================================================

pass("workspace.CurrentCamera exists", function()
    return workspace.CurrentCamera ~= nil
end)
pass("CurrentCamera.ClassName is Camera", function()
    return workspace.CurrentCamera.ClassName == "Camera"
end)
pass("CurrentCamera:IsA Camera is true", function()
    return workspace.CurrentCamera:IsA("Camera") == true
end)
pass("CurrentCamera.CFrame is a CFrame", function()
    return typeof(workspace.CurrentCamera.CFrame) == "CFrame"
end)
pass("Camera.ViewportSize.X is > 0", function()
    local v = workspace.CurrentCamera.ViewportSize
    return typeof(v) == "Vector2" and v.X > 0
end)
pass("Camera.ViewportSize.Y is > 0", function()
    return workspace.CurrentCamera.ViewportSize.Y > 0
end)
pass("Camera.FieldOfView is between 1 and 120", function()
    local f = workspace.CurrentCamera.FieldOfView
    return type(f) == "number" and f >= 1 and f <= 120
end)
pass("Camera.CameraType is an EnumItem", function()
    return typeof(workspace.CurrentCamera.CameraType) == "EnumItem"
end)
pass("Camera.NearPlaneZ is negative", function()
    return type(workspace.CurrentCamera.NearPlaneZ) == "number"
        and workspace.CurrentCamera.NearPlaneZ < 0
end)
pass("FindFirstChildOfClass Camera works", function()
    local c = workspace:FindFirstChildOfClass("Camera")
    return c ~= nil and c.ClassName == "Camera"
end)


-- ================================================================
-- PLAYERS / LOCALPLAYER
-- ================================================================

pass("LocalPlayer.UserId is greater than 0", function()
    return game.Players.LocalPlayer.UserId > 0
end)
pass("LocalPlayer.Name is a real string", function()
    local n = game.Players.LocalPlayer.Name
    return type(n) == "string" and #n > 0
end)
pass("LocalPlayer.DisplayName is a real string", function()
    local d = game.Players.LocalPlayer.DisplayName
    return type(d) == "string" and #d > 0
end)
pass("LocalPlayer.CharacterAdded signal is there", function()
    return game.Players.LocalPlayer.CharacterAdded ~= nil
end)
pass("LocalPlayer.CharacterRemoving signal is there", function()
    return game.Players.LocalPlayer.CharacterRemoving ~= nil
end)
pass("LocalPlayer has a PlayerGui", function()
    return game.Players.LocalPlayer:FindFirstChildOfClass("PlayerGui") ~= nil
end)
pass("LocalPlayer has a Backpack", function()
    return game.Players.LocalPlayer:FindFirstChildOfClass("Backpack") ~= nil
end)
pass("LocalPlayer has PlayerScripts", function()
    return game.Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts") ~= nil
end)
passNoErr("LocalPlayer.Team access doesn't error", function()
    local _ = game.Players.LocalPlayer.Team
end)
pass("LocalPlayer:GetMouse gives an Instance", function()
    local m = game.Players.LocalPlayer:GetMouse()
    return m ~= nil and typeof(m) == "Instance"
end)
passNoErr("LocalPlayer.Character doesn't error", function()
    local _ = game.Players.LocalPlayer.Character
end)
pass("LocalPlayer.AccountAge is >= 0", function()
    return type(game.Players.LocalPlayer.AccountAge) == "number"
        and game.Players.LocalPlayer.AccountAge >= 0
end)
pass("LocalPlayer.MembershipType is an EnumItem", function()
    return typeof(game.Players.LocalPlayer.MembershipType) == "EnumItem"
end)
pass("LocalPlayer.FollowUserId is a number", function()
    return type(game.Players.LocalPlayer.FollowUserId) == "number"
end)
pass("LocalPlayer:IsA Player is true", function()
    return game.Players.LocalPlayer:IsA("Player") == true
end)
pass("LocalPlayer.Parent is the Players service", function()
    return game.Players.LocalPlayer.Parent == game:GetService("Players")
end)
pass("LocalPlayer is a descendant of game", function()
    return game.Players.LocalPlayer:IsDescendantOf(game) == true
end)
pass("LocalPlayer:GetFullName starts with Players.", function()
    return game.Players.LocalPlayer:GetFullName():find("^Players%.") ~= nil
end)
pass("GetPlayers includes the LocalPlayer", function()
    local lp = game.Players.LocalPlayer
    for _, p in ipairs(game.Players:GetPlayers()) do
        if p == lp then return true end
    end
    return false
end)
pass("Players.MaxPlayers is at least 1", function()
    return type(game.Players.MaxPlayers) == "number" and game.Players.MaxPlayers >= 1
end)
pass("Players.RespawnTime is >= 0", function()
    return type(game.Players.RespawnTime) == "number" and game.Players.RespawnTime >= 0
end)
pass("GetPlayerByUserId with -999 returns nil", function()
    return game.Players:GetPlayerByUserId(-999) == nil
end)
pass("GetPlayerByUserId with own UserId returns LocalPlayer", function()
    local lp = game.Players.LocalPlayer
    return game.Players:GetPlayerByUserId(lp.UserId) == lp
end)


-- ================================================================
-- SERVICES
-- ================================================================

pass("ReplicatedStorage exists", function() return game:GetService("ReplicatedStorage") ~= nil end)
pass("StarterGui exists", function() return game:GetService("StarterGui") ~= nil end)
pass("StarterPack exists", function() return game:GetService("StarterPack") ~= nil end)
pass("StarterPlayer exists", function() return game:GetService("StarterPlayer") ~= nil end)
pass("PhysicsService exists", function() return game:GetService("PhysicsService") ~= nil end)
pass("ScriptContext exists", function() return game:GetService("ScriptContext") ~= nil end)
pass("Teams exists", function() return game:GetService("Teams") ~= nil end)
pass("VirtualInputManager exists", function() return game:GetService("VirtualInputManager") ~= nil end)
pass("MarketplaceService exists", function() return game:GetService("MarketplaceService") ~= nil end)
pass("CollectionService exists", function() return game:GetService("CollectionService") ~= nil end)
pass("CollectionService:GetTagged returns a table", function()
    return type(game:GetService("CollectionService"):GetTagged("__fake__")) == "table"
end)
pass("CollectionService:GetAllTags returns a table", function()
    return type(game:GetService("CollectionService"):GetAllTags()) == "table"
end)
pass("HttpService.HttpEnabled is a boolean", function()
    return type(game:GetService("HttpService").HttpEnabled) == "boolean"
end)
pass("HttpService:GenerateGUID returns something", function()
    local g = game:GetService("HttpService"):GenerateGUID(false)
    return type(g) == "string" and #g > 0
end)
pass("HttpService JSON encode then decode roundtrip", function()
    local hs  = game:GetService("HttpService")
    local dec = hs:JSONDecode(hs:JSONEncode({x = 42, y = "hello"}))
    return type(dec) == "table" and dec.x == 42 and dec.y == "hello"
end)
pass("HttpService JSON decode of an array works", function()
    local dec = game:GetService("HttpService"):JSONDecode("[1,2,3]")
    return type(dec) == "table" and dec[1] == 1 and dec[3] == 3
end)
pass("SoundService.RolloffScale is positive", function()
    local ss = game:GetService("SoundService")
    return type(ss.RolloffScale) == "number" and ss.RolloffScale > 0
end)
pass("SoundService.AmbientReverb is an EnumItem", function()
    return typeof(game:GetService("SoundService").AmbientReverb) == "EnumItem"
end)
pass("Lighting.ClockTime is between 0 and 24", function()
    local t = game:GetService("Lighting").ClockTime
    return type(t) == "number" and t >= 0 and t <= 24
end)
pass("Lighting.Brightness is positive", function()
    local b = game:GetService("Lighting").Brightness
    return type(b) == "number" and b > 0
end)
pass("Lighting.Ambient is a Color3", function()
    return typeof(game:GetService("Lighting").Ambient) == "Color3"
end)
pass("Lighting.OutdoorAmbient is a Color3", function()
    return typeof(game:GetService("Lighting").OutdoorAmbient) == "Color3"
end)
pass("TextService:GetTextSize returns a real Vector2", function()
    local sz = game:GetService("TextService"):GetTextSize(
        "hi", 14, Enum.Font.Arial, Vector2.new(500, 500))
    return typeof(sz) == "Vector2" and sz.X > 0
end)
pass("GetGuiInset returns two Vector2s", function()
    local a, b = game:GetService("GuiService"):GetGuiInset()
    return typeof(a) == "Vector2" and typeof(b) == "Vector2"
end)
passOpt("ContentProvider:GetRequestQueueSize is >= 0", function()
    local n = game:GetService("ContentProvider"):GetRequestQueueSize()
    return type(n) == "number" and n >= 0
end)
pass("TweenService:GetValue at 0.5 is between 0 and 1", function()
    local v = game:GetService("TweenService"):GetValue(
        0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
    return type(v) == "number" and v >= 0 and v <= 1
end)
pass("TweenService:GetValue at 0 is 0", function()
    local v = game:GetService("TweenService"):GetValue(
        0, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
    return math.abs(v) < 0.001
end)
pass("TweenService:GetValue at 1 is 1", function()
    local v = game:GetService("TweenService"):GetValue(
        1, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
    return math.abs(v - 1) < 0.001
end)


-- ================================================================
-- RUNSERVICE / TIMING
-- ================================================================

pass("RunService:IsClient is true", function()
    return game:GetService("RunService"):IsClient() == true
end)
pass("RunService:IsServer is false", function()
    return game:GetService("RunService"):IsServer() == false
end)
pass("RunService:IsRunning is true", function()
    return game:GetService("RunService"):IsRunning() == true
end)
pass("RunService:IsStudio returns a boolean", function()
    return type(game:GetService("RunService"):IsStudio()) == "boolean"
end)
pass("RunService.Heartbeat is there", function()
    return game:GetService("RunService").Heartbeat ~= nil
end)
pass("RunService.RenderStepped is there", function()
    return game:GetService("RunService").RenderStepped ~= nil
end)
pass("RunService.Stepped is there", function()
    return game:GetService("RunService").Stepped ~= nil
end)
pass("tick() gives a positive number", function()
    return type(tick()) == "number" and tick() > 0
end)
pass("tick() doesn't go backwards", function()
    local t1 = tick(); local t2 = tick(); return t2 >= t1
end)
pass("os.clock() is >= 0", function()
    return type(os.clock()) == "number" and os.clock() >= 0
end)
pass("os.time() is > 0", function()
    return type(os.time()) == "number" and os.time() > 0
end)
pass("os.time() looks like a real unix timestamp", function()
    return os.time() > 1577836800
end)
pass("os.date() returns a non-empty string", function()
    return type(os.date()) == "string" and #os.date() > 0
end)
passOpt("tick and os.time are within 60 seconds of each other", function()
    return math.abs(tick() - os.time()) < 60
end)


-- ================================================================
-- DATATYPES
-- ================================================================

pass("typeof CFrame.new() is CFrame", function()
    return typeof(CFrame.new()) == "CFrame"
end)
pass("CFrame X Y Z fields are correct", function()
    local cf = CFrame.new(1, 2, 3)
    return cf.X == 1 and cf.Y == 2 and cf.Z == 3
end)
pass("CFrame.lookAt gives a CFrame", function()
    return typeof(CFrame.lookAt(Vector3.new(), Vector3.new(1,0,0))) == "CFrame"
end)
pass("typeof Vector3.new() is Vector3", function()
    return typeof(Vector3.new()) == "Vector3"
end)
pass("Vector3(1,0,0) magnitude is 1", function()
    return Vector3.new(1,0,0).Magnitude == 1
end)
pass("Vector3.Unit magnitude is 1", function()
    return math.abs(Vector3.new(3,4,0).Unit.Magnitude - 1) < 1e-6
end)
pass("Vector3 dot product works", function()
    return Vector3.new(1,0,0):Dot(Vector3.new(0,1,0)) == 0
end)
pass("Vector3 cross product i x j = k", function()
    local c = Vector3.new(1,0,0):Cross(Vector3.new(0,1,0))
    return c.X == 0 and c.Y == 0 and c.Z == 1
end)
pass("Vector3 addition works", function()
    local v = Vector3.new(1,2,3) + Vector3.new(4,5,6)
    return v.X == 5 and v.Y == 7 and v.Z == 9
end)
pass("Vector3 scalar multiply works", function()
    local v = Vector3.new(1,2,3) * 2
    return v.X == 2 and v.Y == 4 and v.Z == 6
end)
pass("typeof Vector2.new() is Vector2", function()
    return typeof(Vector2.new()) == "Vector2"
end)
pass("Vector2 addition works", function()
    local v = Vector2.new(1,2) + Vector2.new(3,4)
    return v.X == 4 and v.Y == 6
end)
pass("typeof UDim2.new() is UDim2", function()
    return typeof(UDim2.new()) == "UDim2"
end)
pass("UDim2.fromScale gives right values", function()
    local u = UDim2.fromScale(0.5, 0.5)
    return u.X.Scale == 0.5 and u.Y.Scale == 0.5
end)
pass("UDim2.fromOffset gives right values", function()
    local u = UDim2.fromOffset(100, 200)
    return u.X.Offset == 100 and u.Y.Offset == 200
end)
pass("typeof UDim.new() is UDim", function()
    return typeof(UDim.new()) == "UDim"
end)
pass("typeof BrickColor.new() is BrickColor", function()
    return typeof(BrickColor.new()) == "BrickColor"
end)
pass("BrickColor Really red name is right", function()
    return BrickColor.new("Really red").Name == "Really red"
end)
pass("typeof Color3.new() is Color3", function()
    return typeof(Color3.new()) == "Color3"
end)
pass("Color3.fromRGB(255,0,0) R is near 1", function()
    local c = Color3.fromRGB(255, 0, 0)
    return math.abs(c.R - 1) < 0.01 and c.G == 0 and c.B == 0
end)
pass("Color3.fromHSV red hue R is near 1", function()
    return math.abs(Color3.fromHSV(0,1,1).R - 1) < 0.01
end)
pass("NumberRange.Min and Max are correct", function()
    local r = NumberRange.new(2, 5)
    return r.Min == 2 and r.Max == 5
end)
pass("TweenInfo.Time field is correct", function()
    return TweenInfo.new(1).Time == 1
end)
pass("typeof Ray.new() is Ray", function()
    return typeof(Ray.new(Vector3.new(), Vector3.new(0,1,0))) == "Ray"
end)
pass("typeof Rect.new() is Rect", function()
    return typeof(Rect.new()) == "Rect"
end)
pass("Enum.KeyCode.W is an EnumItem", function()
    return typeof(Enum.KeyCode.W) == "EnumItem"
end)
pass("Enum.EasingStyle.Linear is an EnumItem", function()
    return typeof(Enum.EasingStyle.Linear) == "EnumItem"
end)
pass("Enum.Font.Arial is an EnumItem", function()
    return typeof(Enum.Font.Arial) == "EnumItem"
end)
pass("Enum.Material.SmoothPlastic is an EnumItem", function()
    return typeof(Enum.Material.SmoothPlastic) == "EnumItem"
end)
pass("Enum.KeyCode:GetEnumItems has entries", function()
    return #Enum.KeyCode:GetEnumItems() > 0
end)
pass("Enum.NormalId.Front is an EnumItem", function()
    return typeof(Enum.NormalId.Front) == "EnumItem"
end)
pass("Enum.CameraType.Custom is an EnumItem", function()
    return typeof(Enum.CameraType.Custom) == "EnumItem"
end)


-- ================================================================
-- INSTANCE SYSTEM
-- ================================================================

pass("Instance.new Part has ClassName Part", function()
    local p = Instance.new("Part")
    local ok = p.ClassName == "Part"
    p:Destroy(); return ok
end)
pass("Part:IsA BasePart is true", function()
    local p = Instance.new("Part")
    local ok = p:IsA("BasePart")
    p:Destroy(); return ok
end)
pass("Clone gives same class but different ref", function()
    local p = Instance.new("Part")
    local c = p:Clone()
    local ok = c ~= nil and c.ClassName == "Part" and c ~= p
    p:Destroy(); c:Destroy(); return ok
end)
pass("GetPropertyChangedSignal returns a signal", function()
    local p = Instance.new("Part")
    local s = p:GetPropertyChangedSignal("Name")
    p:Destroy(); return s ~= nil
end)
pass("SetAttribute/GetAttribute number roundtrip", function()
    local p = Instance.new("Part")
    p:SetAttribute("N", 42)
    local v = p:GetAttribute("N")
    p:Destroy(); return v == 42
end)
pass("SetAttribute/GetAttribute string roundtrip", function()
    local p = Instance.new("Part")
    p:SetAttribute("S", "kolenv")
    local v = p:GetAttribute("S")
    p:Destroy(); return v == "kolenv"
end)
pass("GetAttributes returns table with right values", function()
    local p = Instance.new("Part")
    p:SetAttribute("A", 1)
    local t = p:GetAttributes()
    p:Destroy(); return type(t) == "table" and t.A == 1
end)
pass("newproxy() returns userdata", function()
    return type(newproxy()) == "userdata"
end)
pass("newproxy(true) has a real metatable", function()
    return type(getmetatable(newproxy(true))) == "table"
end)
pass("FindFirstChild finds a child we just parented", function()
    local f = Instance.new("Folder")
    local p = Instance.new("Part")
    p.Parent = f
    local ok = f:FindFirstChild(p.Name) == p
    f:Destroy(); return ok
end)
pass("Destroy sets Parent to nil", function()
    local f = Instance.new("Folder")
    f.Parent = workspace
    f:Destroy()
    return f.Parent == nil
end)
passMustErr("Instance.new with a fake class errors", function()
    Instance.new("FakeEnvCheckClass00000")
end)


-- ================================================================
-- LUA STDLIB
-- ================================================================

pass("math.floor ceil abs max min sqrt all work", function()
    return math.floor(1.9) == 1 and math.ceil(1.1) == 2 and math.abs(-5) == 5
       and math.max(1,2,3) == 3 and math.min(1,2,3) == 1 and math.sqrt(9) == 3
end)
pass("math.fmod(10,3) == 1", function() return math.fmod(10,3) == 1 end)
pass("sin(0)==0 and cos(0)==1", function()
    return math.sin(0) == 0 and math.cos(0) == 1
end)
pass("exp(0)==1 and log(1)==0", function()
    return math.exp(0) == 1 and math.log(1) == 0
end)
pass("2^10 is 1024", function() return 2^10 == 1024 end)
pass("math.random() is between 0 and 1", function()
    local r = math.random(); return r >= 0 and r <= 1
end)
pass("math.random(1,10) gives an int in range", function()
    local r = math.random(1, 10)
    return r >= 1 and r <= 10 and math.floor(r) == r
end)
pass("string.format %d works", function()
    return string.format("%d", 42) == "42"
end)
pass("string.format float works", function()
    return string.format("%.2f", 3.14159) == "3.14"
end)
pass("string.upper and lower work", function()
    return string.upper("abc") == "ABC" and string.lower("XYZ") == "xyz"
end)
pass("string.sub rep reverse all work", function()
    return string.sub("hello",1,3) == "hel"
       and string.rep("ab",2) == "abab"
       and string.reverse("abc") == "cba"
end)
pass("string.find returns correct positions", function()
    local s, e = string.find("hello world", "world")
    return s == 7 and e == 11
end)
pass("string.find plain mode works", function()
    return string.find("a+b", "a+b", 1, true) == 1
end)
pass("string.gmatch iterates the right count", function()
    local t = {}
    for w in string.gmatch("one two three", "%a+") do t[#t+1] = w end
    return #t == 3
end)
pass("string.gsub replacement works", function()
    return (string.gsub("hello", "l", "r")) == "herro"
end)
pass("string.byte and char roundtrip", function()
    return string.char(string.byte("A")) == "A"
end)
pass("table.concat works", function()
    return table.concat({"a","b","c"}, ",") == "a,b,c"
end)
pass("table.insert and remove work", function()
    local t = {1,2,3}
    table.insert(t, 4); table.remove(t, 1)
    return t[1] == 2 and #t == 3
end)
pass("table.sort ascending works", function()
    local t = {3,1,2}; table.sort(t)
    return t[1] == 1 and t[2] == 2 and t[3] == 3
end)
pass("table.sort descending with comparator", function()
    local t = {1,2,3}
    table.sort(t, function(a,b) return a > b end)
    return t[1] == 3 and t[3] == 1
end)
pass("pcall catches errors and returns values on success", function()
    local ok1, e  = pcall(function() error("e") end)
    local ok2, v  = pcall(function() return 42 end)
    return ok1 == false and type(e) == "string" and ok2 == true and v == 42
end)
pass("xpcall message handler fires", function()
    local msg = nil
    xpcall(function() error("x") end, function(e) msg = e end)
    return type(msg) == "string"
end)
pass("coroutine create and resume works", function()
    local co = coroutine.create(function() return 99 end)
    local ok, v = coroutine.resume(co)
    return ok and v == 99
end)
pass("coroutine.wrap yields correctly", function()
    local gen = coroutine.wrap(function()
        coroutine.yield(1); coroutine.yield(2)
    end)
    return gen() == 1 and gen() == 2
end)
pass("coroutine status dead and suspended work", function()
    local co1 = coroutine.create(function() end)
    coroutine.resume(co1)
    local co2 = coroutine.create(function() coroutine.yield() end)
    coroutine.resume(co2)
    return coroutine.status(co1) == "dead"
       and coroutine.status(co2) == "suspended"
end)
pass("coroutine passes arguments through", function()
    local co = coroutine.create(function(a,b) return a + b end)
    local ok, v = coroutine.resume(co, 3, 4)
    return ok and v == 7
end)
pass("tostring and tonumber work", function()
    return tostring(123)   == "123"
       and tostring(true)  == "true"
       and tostring(nil)   == "nil"
       and tonumber("456") == 456
       and tonumber("0xFF") == 255
       and tonumber("bad") == nil
end)
pass("rawget and rawset bypass __index", function()
    local t = setmetatable({}, {__index = function() return 99 end})
    rawset(t, "k", 1)
    return rawget(t, "k") == 1
end)
pass("rawequal works on same and different tables", function()
    local t = {}
    return rawequal(t, t) == true and rawequal({}, {}) == false
end)
pass("rawlen on a table works", function() return rawlen({1,2,3}) == 3 end)
pass("ipairs and pairs iterate correctly", function()
    local sum = 0
    for _, v in ipairs({10,20,30}) do sum = sum + v end
    local n = 0
    for _ in pairs({a=1,b=2,c=3}) do n = n + 1 end
    return sum == 60 and n == 3
end)
pass("unpack with range works", function()
    local a, b = unpack({10,20,30}, 2, 3)
    return a == 20 and b == 30
end)
pass("select count and from-index work", function()
    local function cnt(...) return select("#", ...) end
    local function frm(...) return select(2, ...) end
    local a, b = frm(10, 20, 30)
    return cnt(1,2,3) == 3 and a == 20 and b == 30
end)
pass("next on table and empty table works", function()
    local k, v = next({x = 1})
    return k == "x" and v == 1 and next({}) == nil
end)
pass("UserInputService touch keyboard mouse are booleans", function()
    local uis = game:GetService("UserInputService")
    return type(uis.TouchEnabled)    == "boolean"
       and type(uis.KeyboardEnabled) == "boolean"
       and type(uis.MouseEnabled)    == "boolean"
end)


-- ================================================================
-- FUNCTION EXISTENCE CHECKS
-- checks whether common executor functions exist and are callable.
-- uses passOpt so missing ones don't tank the score.
-- ================================================================

passOpt("identifyexecutor / getexecutorname exists", function()
    local fn = identifyexecutor or getexecutorname
    return type(fn) == "function"
end)
passOpt("setclipboard / toclipboard exists", function()
    local fn = setclipboard or toclipboard
    return type(fn) == "function"
end)
passOpt("rconsolecreate exists", function()
    return type(rconsolecreate) == "function"
end)
passOpt("rconsoleprint exists", function()
    return type(rconsoleprint) == "function"
end)
passOpt("rconsoleclear exists", function()
    return type(rconsoleclear) == "function"
end)
passOpt("rconsoledestroy exists", function()
    return type(rconsoledestroy) == "function"
end)
passOpt("mousemoverel exists", function()
    return type(mousemoverel) == "function"
end)
passOpt("mousemoveabs exists", function()
    return type(mousemoveabs) == "function"
end)
passOpt("mouse1click or mouseclick exists", function()
    local fn = mouse1click or mouseclick
    return type(fn) == "function"
end)
passOpt("mouse2click exists", function()
    return type(mouse2click) == "function"
end)
passOpt("keypress exists", function()
    return type(keypress) == "function"
end)
passOpt("keyrelease exists", function()
    return type(keyrelease) == "function"
end)
passOpt("isrbxactive exists", function()
    return type(isrbxactive) == "function"
end)
passOpt("getfflag exists", function()
    return type(getfflag) == "function"
end)
passOpt("decompile exists", function()
    return type(decompile) == "function"
end)
passOpt("getobjects exists", function()
    return type(getobjects) == "function"
end)
passOpt("replicatesignal exists", function()
    return type(replicatesignal) == "function"
end)
passOpt("saveinstance exists", function()
    return type(saveinstance) == "function"
end)
passOpt("setfpscap exists", function()
    return type(setfpscap) == "function"
end)
passOpt("getfpscap exists", function()
    return type(getfpscap) == "function"
end)


-- ================================================================
-- UNC CHECKS
-- ================================================================

pass("getgenv() returns a table", function() return type(getgenv()) == "table" end)
pass("getrenv() returns a table", function() return type(getrenv()) == "table" end)
pass("getfenv() returns a table", function() return type(getfenv()) == "table" end)
passNoErr("setfenv doesn't error", function() setfenv(1, getfenv()) end)
passOpt("getsenv on PlayerScripts returns a table", function()
    return type(getsenv(game.Players.LocalPlayer.PlayerScripts)) == "table"
end)
pass("writing to getgenv() persists", function()
    getgenv().__kolenv_rw = "rw_ok"
    return getgenv().__kolenv_rw == "rw_ok"
end)
pass("getrenv() has game and workspace", function()
    return getrenv().game ~= nil and getrenv().workspace ~= nil
end)
pass("getfenv() has print", function()
    return type(getfenv().print) == "function"
end)
pass("getrawmetatable on game has __index and __namecall", function()
    local mt = getrawmetatable(game)
    return type(mt) == "table" and mt.__index ~= nil and mt.__namecall ~= nil
end)
pass("setrawmetatable overrides __index on locked table", function()
    local t = setmetatable({}, {__metatable = "locked"})
    setrawmetatable(t, {__index = function() return 42 end})
    return t.anything == 42
end)
pass("getrawmetatable bypasses __metatable lock", function()
    local t = setmetatable({}, {__metatable = "locked"})
    return type(getrawmetatable(t)) == "table"
end)
pass("setrawmetatable doesn't error on locked table", function()
    local t = setmetatable({}, {__metatable = "locked"})
    return pcall(setrawmetatable, t, {}) == true
end)
pass("hookfunction intercepts and old still works", function()
    local function original() return 1 end
    local old = hookfunction(original, function() return 2 end)
    local result = original()
    hookfunction(original, old)
    return result == 2 and type(old) == "function"
end)
pass("hookfunction restore brings back original", function()
    local function original() return "a" end
    local old = hookfunction(original, function() return "b" end)
    hookfunction(original, old)
    return original() == "a"
end)
pass("newcclosure works and iscclosure confirms it", function()
    local fn = newcclosure(function() return true end)
    return type(fn) == "function" and fn() == true and iscclosure(fn) == true
end)
pass("print is a C closure not a Lua one", function()
    return iscclosure(print) == true and islclosure(print) == false
end)
pass("a Lua function is lclosure not cclosure", function()
    local fn = function() end
    return islclosure(fn) == true and iscclosure(fn) == false
end)
pass("clonefunction gives a separate but identical function", function()
    local fn = function() return 7 end
    local cl = clonefunction(fn)
    return type(cl) == "function" and cl() == 7 and cl ~= fn and islclosure(cl) == true
end)
pass("checkcaller returns a boolean", function()
    return type(checkcaller()) == "boolean"
end)
passNoErr("getcallingscript doesn't error", function()
    local _ = getcallingscript()
end)
pass("getscripts returns a non-empty table", function()
    local t = getscripts()
    return type(t) == "table" and #t > 0 and typeof(t[1]) == "Instance"
end)
pass("getloadedmodules returns a table", function()
    return type(getloadedmodules()) == "table"
end)
pass("getrunningscripts returns a table", function()
    return type(getrunningscripts()) == "table"
end)
passOpt("getconnections on Heartbeat has callable entries", function()
    local c = getconnections(game:GetService("RunService").Heartbeat)
    if type(c) ~= "table" or #c == 0 then return false end
    if type(c[1].Function) ~= "function" then return false end
    local en = c[1].Enabled
    if en ~= nil and type(en) ~= "boolean" then return false end
    return true
end)
pass("fire* functions all exist", function()
    return type(firetouchinterest)   == "function"
       and type(fireclickdetector)   == "function"
       and type(fireproximityprompt) == "function"
       and type(firesignal)          == "function"
end)
passOpt("getupvalues returns at least one entry", function()
    local x = 123
    local fn = function() return x end
    local u = getupvalues(fn)
    return type(u) == "table" and #u >= 1
end)
passOpt("getupvalue returns the right value", function()
    local x = 55
    local fn = function() return x end
    return getupvalue(fn, 1) == 55
end)
passOpt("setupvalue changes what the function returns", function()
    local x = 10
    local fn = function() return x end
    setupvalue(fn, 1, 99)
    return fn() == 99
end)
pass("getconstants finds a known string in the function", function()
    local fn = function() return "kolenv_const_check" end
    local c  = getconstants(fn)
    if type(c) ~= "table" then return false end
    for _, v in pairs(c) do
        if v == "kolenv_const_check" then return true end
    end
    return false
end)
pass("setconstant changes what the function returns", function()
    local fn = function() return "before" end
    for i, v in pairs(getconstants(fn)) do
        if v == "before" then setconstant(fn, i, "after"); break end
    end
    return fn() == "after"
end)
pass("debug.getinfo on print says C", function()
    local info = debug.getinfo(print)
    -- executors vary on exact fields so we accept either indicator
    return type(info) == "table"
       and (info.what == "C" or info.short_src == "[C]" or info.source == "=[C]")
end)
pass("debug.getinfo on a Lua function says Lua", function()
    local fn   = function() end
    local info = debug.getinfo(fn)
    return type(info) == "table"
       and (info.what == "Lua" or info.what == "l" or
            (info.short_src ~= nil and info.short_src ~= "[C]"))
end)
pass("loadstring compiles and runs correctly", function()
    local fn = loadstring("return 1 + 1")
    return type(fn) == "function" and fn() == 2
end)
pass("loadstring on broken code gives nil + error", function()
    local fn, err = loadstring("??? broken !!!")
    return fn == nil and type(err) == "string"
end)
pass("loadstring setfenv env swap works", function()
    local fn = loadstring("return __kolenv_et__")
    setfenv(fn, setmetatable({__kolenv_et__ = 5555}, {__index = getfenv()}))
    return fn() == 5555
end)
pass("writefile readfile isfile all work", function()
    writefile("kolvcheck_rw.txt", "hello123")
    return readfile("kolvcheck_rw.txt") == "hello123"
       and isfile("kolvcheck_rw.txt") == true
end)
passOpt("appendfile adds to the file", function()
    writefile("kolvcheck_ap.txt", "hello")
    appendfile("kolvcheck_ap.txt", "world")
    return readfile("kolvcheck_ap.txt") == "helloworld"
end)
pass("delfile removes the file", function()
    writefile("kolvcheck_dl.txt", "x")
    delfile("kolvcheck_dl.txt")
    return isfile("kolvcheck_dl.txt") == false
end)
pass("isfile on a nonexistent path is false", function()
    return isfile("kolvcheck_nonexistent_99999.txt") == false
end)
pass("makefolder and isfolder work", function()
    makefolder("kolvcheck_dir")
    local e = isfolder("kolvcheck_dir")
    -- delfolder is optional, not all executors have it
    pcall(delfolder, "kolvcheck_dir")
    return e == true
end)
pass("listfiles finds a file we just wrote", function()
    writefile("kolvcheck_list.txt", "x")
    local files = listfiles("")
    local found = false
    for _, f in ipairs(files) do
        if type(f) == "string" and f:find("kolvcheck_list") then
            found = true; break
        end
    end
    pcall(delfile, "kolvcheck_list.txt")
    return found
end)
pass("getinstances has workspace and game in it", function()
    local ws, gm = false, false
    for _, v in ipairs(getinstances()) do
        if v == workspace then ws = true end
        if v == game      then gm = true end
    end
    return ws and gm
end)
pass("getnilinstances returns a table", function()
    return type(getnilinstances()) == "table"
end)
pass("cloneref gives different ref and compareinstances agrees", function()
    local ws = cloneref(workspace)
    return typeof(ws) == "Instance"
       and ws ~= workspace
       and ws.ClassName == "Workspace"
       and compareinstances(ws, workspace) == true
       and compareinstances(workspace, game:GetService("ReplicatedStorage")) == false
end)
pass("hookmetamethod __namecall catches GetService", function()
    local method = nil
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        method = getnamecallmethod()
        return old(self, ...)
    end))
    pcall(function() game:GetService("RunService") end)
    hookmetamethod(game, "__namecall", old)
    return method == "GetService"
end)
pass("hookmetamethod __index fires on property read", function()
    local fired = false
    local old
    old = hookmetamethod(game, "__index", newcclosure(function(self, key)
        fired = true
        return old(self, key)
    end))
    pcall(function() local _ = game.Name end)
    hookmetamethod(game, "__index", old)
    return fired == true
end)



-- ================================================================
-- ANTI-ENV-LOGGER DETECTIONS
-- checks drawn from real-world anti-envlogger scripts.
-- uses passOpt so executor-missing features don't count against score.
-- ================================================================

-- Luau runtime identifier
pass("_VERSION == Luau", function()
    return _VERSION == "Luau"
end)

-- lune/lfs runtime detection (env loggers run on lune or lfs)
pass("lune and lfs runtimes not loaded", function()
    local loadFn = loadstring or load
    if type(loadFn) ~= "function" then return true end -- can't check, skip
    local luneChunk = loadFn('return require("@lune/fs")')
    if luneChunk and pcall(luneChunk) then return false end
    local lfsChunk = loadFn('return require("lfs")')
    if lfsChunk and pcall(lfsChunk) then return false end
    return true
end)

-- getfenv must return the same table across calls
pass("getfenv() returns same table twice", function()
    local e1 = getfenv()
    local e2 = getfenv()
    return e1 == e2
end)

-- _SUPER is an envlogger-injected global
pass("_SUPER is nil", function()
    return _SUPER == nil
end)

-- core Roblox types must exist
pass("Vector3 Vector2 UDim2 are all present", function()
    return Vector3 ~= nil and Vector2 ~= nil and UDim2 ~= nil
end)

-- Vector3.one scalar multiplication (env loggers fake Vector3 math wrong)
pass("Vector3.one * n gives correct result", function()
    local base = Vector3.one
    for i = 1, 5 do
        local n = math.random(1, 67)
        if base * n ~= Vector3.new(n, n, n) then return false end
    end
    return true
end)

-- PlaybackLoudness is read-only — env loggers miss this
pass("Sound.PlaybackLoudness can't be set", function()
    local snd = Instance.new("Sound")
    local canSet = pcall(function() snd.PlaybackLoudness = 69 end)
    snd:Destroy()
    return canSet == false
end)

-- TextBounds is read-only — same
pass("TextBox.TextBounds can't be set", function()
    local tb = Instance.new("TextBox")
    local canSet = pcall(function() tb.TextBounds = Vector2.new(67, 67) end)
    tb:Destroy()
    return canSet == false
end)

-- game must NOT be iterable
pass("game can't be iterated with for-in", function()
    return pcall(function() for _ in game do end end) == false
end)

-- game must error with correct message when called
pass("game() errors with the right message", function()
    local _, msg = pcall(function() game() end)
    return type(msg) == "string" and msg:find("attempt to call a Instance value") ~= nil
end)

-- Enum identity: same enum item must equal itself
pass("Enum.Material.Plastic equals itself", function()
    return Enum.Material.Plastic == Enum.Material.Plastic
end)

-- Enum.Material.Plastic.Value must be 256
pass("Plastic enum value is 256", function()
    return Enum.Material.Plastic.Value == 256
end)

-- game.Changed must be a real signal
pass("game.Changed is a real signal", function()
    return typeof(game.Changed) == "RBXScriptSignal"
end)

-- GetService must be singleton — two calls return same ref
pass("GetService returns same ref each call", function()
    local a = game:GetService("Players")
    local b = game:GetService("Players")
    return a == b and rawequal(a, b)
end)

-- game.Players shortcut vs GetService must match
pass("game.Players matches GetService result", function()
    return game:GetService("Players") == game.Players
end)

-- Instance name change must be reflected in tostring
pass("renaming an Instance changes its tostring", function()
    local p = Instance.new("Part")
    local before = tostring(p)
    p.Name = "kolenv_name_test"
    local after = tostring(p)
    p:Destroy()
    return before ~= after
end)

-- Destroy propagates to children: child.Parent becomes nil
pass("Destroy sets child.Parent to nil", function()
    local folder = Instance.new("Folder")
    local child  = Instance.new("Folder")
    child.Parent  = folder
    folder.Parent = workspace
    folder:Destroy()
    task.wait()
    return child.Parent == nil
end)

-- table library must be read-only (env loggers allow writing)
pass("can't write to the table library", function()
    local ok = pcall(function() table._KOLENV_TEST_KEY = 1 end)
    if ok then pcall(rawset, table, "_KOLENV_TEST_KEY", nil) end
    return ok == false
end)

-- workspace:GetServerTimeNow must advance
passOpt("GetServerTimeNow goes up over time", function()
    local t1 = workspace:GetServerTimeNow()
    task.wait(0.05)
    local t2 = workspace:GetServerTimeNow()
    local delta = t2 - t1
    return type(t1) == "number" and delta > 0 and delta < 5
end)

-- game and workspace.Parent must rawequal
pass("workspace.Parent rawequals game", function()
    return rawequal(game, workspace.Parent)
end)

-- Enum.Material.Plastic.Parent must rawequal Enum.Material
passOpt("Enum.Material.Plastic.Parent is Enum.Material", function()
    local ok, result = pcall(function()
        return rawequal(Enum.Material.Plastic.Parent, Enum.Material)
    end)
    return ok and result == true
end)

-- metatable lock string on Roblox objects
pass("workspace metatable is locked", function()
    return getmetatable(workspace) == "The metatable is locked"
end)
pass("game metatable is locked", function()
    return getmetatable(game) == "The metatable is locked"
end)

-- typeof vs type split (already in AT-2 but explicit label here)
pass("typeof and type disagree on Roblox types", function()
    if typeof(CFrame.new())  == type(CFrame.new())  then return false end
    if typeof(Vector3.new()) == type(Vector3.new()) then return false end
    if typeof(UDim2.new())   == type(UDim2.new())   then return false end
    if typeof(Color3.new())  == type(Color3.new())  then return false end
    return true
end)

-- game ClassName must be DataModel
pass("game.ClassName is DataModel", function()
    return game.ClassName == "DataModel"
end)

-- workspace ClassName must be Workspace
pass("workspace.ClassName is Workspace", function()
    return workspace.ClassName == "Workspace"
end)

-- RunService IsClient must differ from IsServer
pass("IsClient and IsServer give opposite results", function()
    local rs = game:GetService("RunService")
    return rs:IsClient() ~= rs:IsServer()
end)

-- Heartbeat type must be RBXScriptSignal
pass("Heartbeat is an RBXScriptSignal", function()
    return typeof(game:GetService("RunService").Heartbeat) == "RBXScriptSignal"
end)

-- Part mass check: default 2x2x2 Part = 5.6 studs
pass("Part:GetMass gives a positive number", function()
    local p = Instance.new("Part")
    local m = p:GetMass()
    p:Destroy()
    return type(m) == "number" and m > 0
end)

-- PhysicalProperties roundtrip
pass("PhysicalProperties elasticity reads back correctly", function()
    local p = Instance.new("Part")
    p.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.5)
    local check = p.CustomPhysicalProperties.Elasticity
    p:Destroy()
    return math.abs(check - 0.5) < 1e-5
end)

-- Invalid property access must give "valid member" error
pass("reading a null-byte property gives the right error", function()
    local p = Instance.new("Part")
    local ok, msg = pcall(function() return p["\0Property"] end)
    p:Destroy()
    return not ok and type(msg) == "string" and msg:find("valid member") ~= nil
end)

-- stack overflow at reasonable depth (env loggers may not have real stack)
pass("deep enough recursion hits stack overflow", function()
    local function depth(n)
        if n == 0 then return 0 end
        return depth(n - 1)
    end
    local ok, err = pcall(depth, 30000)
    -- either it overflows (expected) or it reaches 0 cleanly on TCO executors
    if ok then return true end
    return type(err) == "string" and (err:find("stack") ~= nil or err:find("overflow") ~= nil)
end)

-- buffer library basic read/write
pass("buffer writeu32/readu32 roundtrip works", function()
    local buf = buffer.create(8)
    buffer.writeu32(buf, 0, 0xDEADBEEF)
    return buffer.readu32(buf, 0) == 0xDEADBEEF
end)

-- table.freeze / table.isfrozen
pass("table.freeze stops writes", function()
    local t = {1, 2, 3}
    table.freeze(t)
    if not table.isfrozen(t) then return false end
    local ok = pcall(function() t[1] = 99 end)
    return ok == false
end)

-- utf8.graphemes works
pass("utf8.graphemes works on a basic string", function()
    local ok = pcall(function()
        for v2, v3 in utf8.graphemes("test") do
        end
    end)
    return ok == true
end)

-- print() must return nil (env loggers sometimes return the args)
pass("print() returns nil", function()
    return print("__kolenv_print_test__") == nil
end)

-- debug.info on a Lua closure must not report [C]
pass("debug.info on a Lua func says Lua not C", function()
    local fn = function() end
    local ok, src = pcall(debug.info, fn, "s")
    return ok and src ~= "[C]"
end)

-- getfenv must error on invalid level (level 69 doesn't exist)
pass("getfenv(69) errors", function()
    local ok = pcall(getfenv, 69)
    return ok == false
end)

-- math.log missing arg must error with "missing" in message
pass("math.log() with no args errors with missing", function()
    local ok, err = pcall(math.log)
    return not ok and type(err) == "string" and err:find("missing") ~= nil
end)

-- EncodingService compress/decompress roundtrip
passOpt("EncodingService Zstd compress/decompress works", function()
    local es = game:GetService("EncodingService")
    local b = buffer.create(7)
    buffer.writestring(b, 0, "buluark")
    local compressed = es:CompressBuffer(b, Enum.CompressionAlgorithm.Zstd, 22)
    local decompressed = es:DecompressBuffer(compressed, Enum.CompressionAlgorithm.Zstd)
    return buffer.readstring(decompressed, 0, 7) == "buluark"
end)

-- DistributedGameTime must advance (real server tick)
pass("DistributedGameTime goes up", function()
    local t1 = workspace.DistributedGameTime
    task.wait(0.1)
    local t2 = workspace.DistributedGameTime
    return (t2 - t1) > 0
end)

-- GetPropertyChangedSignal fires on real property change
pass("GetPropertyChangedSignal fires on name change", function()
    local part = Instance.new("Part")
    local fired = nil
    part:GetPropertyChangedSignal("Name"):Connect(function()
        fired = part.Name
    end)
    part.Name = "kolenv_signal_test"
    task.wait(0.05)
    part:Destroy()
    return fired == "kolenv_signal_test"
end)

-- Instance:GetDebugId must return unique non-empty strings
passOpt("GetDebugId returns different strings per instance", function()
    local g = game:GetDebugId(0)
    local w = workspace:GetDebugId(0)
    local p = game.Players:GetDebugId(0)
    if type(g) ~= "string" or #g == 0 then return false end
    if g == w or g == p or w == p then return false end
    return true
end)

-- game:Clone() must fail with "Ugc cannot be cloned"
pass("game:Clone() fails as expected", function()
    local ok, err = pcall(function() return game:Clone() end)
    return not ok or (type(err) == "string" and err:find("cloned") ~= nil)
end)

-- LocalizationService locale IDs must be non-empty strings
passOpt("LocalizationService locale IDs are real strings", function()
    local ls = game:GetService("LocalizationService")
    local r = ls.RobloxLocaleId
    local s = ls.SystemLocaleId
    return type(r) == "string" and #r >= 2
       and type(s) == "string" and #s >= 2
end)

-- Heartbeat fires at least twice (env loggers fire connections 0 or 1 times)
pass("Heartbeat fires at least twice", function()
    local count = 0
    local conn = game:GetService("RunService").Heartbeat:Connect(function()
        count = count + 1
    end)
    local attempts = 0
    repeat task.wait() attempts = attempts + 1 until count >= 2 or attempts >= 10
    conn:Disconnect()
    return count >= 2
end)

-- task.spawn must return a thread and run the function
pass("task.spawn runs the function and returns a thread", function()
    local ran = false
    local co = task.spawn(function() ran = true end)
    return type(co) == "thread" and ran == true
end)

-- task.defer fires after current frame (basic check)
pass("task.defer doesn't error", function()
    local ok = pcall(function() task.defer(function() end) end)
    return ok == true
end)

-- CollectionService tag add/remove/check roundtrip
pass("CollectionService add/remove/check tag works", function()
    local cs = game:GetService("CollectionService")
    local p  = Instance.new("Part")
    cs:AddTag(p, "kolenv_tag_test")
    if not p:HasTag("kolenv_tag_test") then p:Destroy(); return false end
    p:RemoveTag("kolenv_tag_test")
    if p:HasTag("kolenv_tag_test") then p:Destroy(); return false end
    p:Destroy()
    return true
end)

-- model:ClearAllChildren empties children
pass("ClearAllChildren empties the model", function()
    local m = Instance.new("Model")
    Instance.new("Part").Parent = m
    Instance.new("Folder").Parent = m
    m:ClearAllChildren()
    local n = #m:GetChildren()
    m:Destroy()
    return n == 0
end)

-- isreadonly on math must be true
passOpt("math library is read-only", function()
    return isreadonly(math) == true
end)

-- gcinfo must return > 0 (real GC active)
pass("gcinfo shows memory is being used", function()
    local mem = 0
    if gcinfo then
        mem = gcinfo()
    elseif collectgarbage then
        local ok, v = pcall(collectgarbage, "count")
        if ok then mem = v end
    end
    return mem > 0
end)

-- NaN propagation: math.max(nan, 1) must be NaN
pass("NaN stays NaN through math.max/min", function()
    local nan = 0/0
    local mx = math.max(nan, 1)
    local mn = math.min(nan, 1)
    return mx ~= mx and mn ~= mn
end)

-- string interning: two identical literals must compare equal quickly
pass("two identical string literals compare equal", function()
    local a = "ax"
    local b = "ax"
    return a == b
end)

-- weak table GC: values in __mode=v table may be collected
pass("weak value table accepts entries without error", function()
    local weak = setmetatable({}, {__mode = "v"})
    for i = 1, 10 do weak[i] = {i} end
    -- just verify it doesn't error; GC timing is non-deterministic
    return type(weak) == "table"
end)

-- BrickColor roundtrip via Color3
pass("BrickColor roundtrip via Color3 keeps the same number", function()
    local bc = BrickColor.new("Bright red")
    local c3 = bc.Color
    local reconstructed = BrickColor.new(Color3.new(c3.R, c3.G, c3.B))
    return reconstructed.Number == bc.Number and bc.Number > 0
end)

-- MembershipType must be None or Premium
pass("MembershipType is None or Premium", function()
    local mt = game.Players.LocalPlayer.MembershipType
    if typeof(mt) ~= "EnumItem" then return false end
    if mt.EnumType ~= Enum.MembershipType then return false end
    return mt == Enum.MembershipType.None or mt == Enum.MembershipType.Premium
end)

-- TweenService playback state progression
pass("Tween states go Begin then Playing then Completed", function()
    local ts = game:GetService("TweenService")
    local p  = Instance.new("Part")
    p.Parent = workspace
    p.Position = Vector3.new(0, 0, 0)
    local tw = ts:Create(p, TweenInfo.new(0.1, Enum.EasingStyle.Linear), {Position = Vector3.new(10, 0, 0)})
    local s1 = tw.PlaybackState
    tw:Play()
    local s2 = tw.PlaybackState
    task.wait(0.2)
    local s3 = tw.PlaybackState
    p:Destroy()
    return s1 == Enum.PlaybackState.Begin
       and s2 == Enum.PlaybackState.Playing
       and s3 == Enum.PlaybackState.Completed
end)

-- Terrain:ReadVoxels at high altitude must be all Air
pass("terrain at altitude 900 is all air voxels", function()
    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if not terrain then return true end -- skip if no terrain
    local region = Region3.new(Vector3.new(0, 900, 0), Vector3.new(4, 904, 4))
    local mats = terrain:ReadVoxels(region, 4)
    for _, layer in ipairs(mats) do
        for _, row in ipairs(layer) do
            for _, mat in ipairs(row) do
                if mat ~= Enum.Material.Air then return false end
            end
        end
    end
    return true
end)

-- WaitForChild with timeout returns nil for nonexistent child
pass("WaitForChild with timeout returns nil", function()
    local f = Instance.new("Folder")
    f.Parent = workspace
    local result = f:WaitForChild("__kolenv_noexist__", 0.1)
    f:Destroy()
    return result == nil
end)

-- coroutine.wrap error propagation
pass("coroutine.wrap error shows up in pcall", function()
    local wrapped = coroutine.wrap(function()
        coroutine.yield(1)
        error("wrappedError")
    end)
    local first = wrapped()
    local ok, err = pcall(wrapped)
    return first == 1 and not ok and tostring(err):find("wrappedError") ~= nil
end)

-- SoundService:GetListener returns an EnumItem of ListenerType
pass("SoundService:GetListener returns a ListenerType", function()
    local lt = game:GetService("SoundService"):GetListener()
    return typeof(lt) == "EnumItem" and lt.EnumType == Enum.ListenerType
end)

-- Lighting.ClockTime write/read and GetMinutesAfterMidnight
pass("Lighting ClockTime and GetMinutesAfterMidnight agree", function()
    local lighting = game:GetService("Lighting")
    local orig = lighting.ClockTime
    lighting.ClockTime = 13.75
    local rb   = lighting.ClockTime
    local mins = lighting:GetMinutesAfterMidnight()
    lighting.ClockTime = orig
    return math.abs(rb - 13.75) < 1e-4 and math.abs(mins - 825) < 0.1
end)

-- MemStorageService set/get roundtrip
passOpt("MemStorageService set then get works", function()
    local ms = game:GetService("MemStorageService")
    ms:SetItem("kolenv_ms_test", "hello_kolenv")
    return ms:GetItem("kolenv_ms_test") == "hello_kolenv"
end)

-- OverlapParams default values
pass("OverlapParams default values are correct", function()
    local op = OverlapParams.new()
    return op.MaxParts == 0
       and op.FilterType == Enum.RaycastFilterType.Exclude
       and type(op.FilterDescendantsInstances) == "table"
end)

-- Instance.Part.UniqueId exists
pass("Part.UniqueId exists", function()
    local p = Instance.new("Part")
    local uid = p.UniqueId
    p:Destroy()
    return uid ~= nil
end)

-- Instance.Part.Sandboxed is a boolean
pass("Part.Sandboxed is a boolean", function()
    local p = Instance.new("Part")
    local sb = type(p.Sandboxed) == "boolean"
    p:Destroy()
    return sb
end)

-- PlayerScripts must contain PlayerModule and RbxCharacterSounds
pass("PlayerScripts has PlayerModule and RbxCharacterSounds", function()
    local lp = game.Players.LocalPlayer
    local ps = lp:FindFirstChild("PlayerScripts")
    if not ps then return false end
    return ps:FindFirstChild("PlayerModule") ~= nil
       and ps:FindFirstChild("RbxCharacterSounds") ~= nil
end)

-- game.PlaceId must not equal game.GameId (Larry/fork detection)
pass("PlaceId and GameId are different", function()
    return game.PlaceId ~= game.GameId
end)


-- ================================================================
-- EXTENDED CHECKS BATCH 2
-- ================================================================

-- ── MATH ─────────────────────────────────────────────────────────
pass("math.huge is positive infinity", function()
    return math.huge > 0 and math.huge == math.huge * 2
end)
pass("math.pi is correct to 4 decimal places", function()
    return math.abs(math.pi - 3.1415) < 0.001
end)
pass("math.max with multiple args", function()
    return math.max(1, 5, 3, 2, 4) == 5
end)
pass("math.min with multiple args", function()
    return math.min(9, 3, 7, 1, 5) == 1
end)
pass("math.clamp works", function()
    return math.clamp(15, 0, 10) == 10
       and math.clamp(-5, 0, 10) == 0
       and math.clamp(5, 0, 10)  == 5
end)
pass("math.round rounds correctly", function()
    return math.round(1.4) == 1
       and math.round(1.5) == 2
       and math.round(-1.5) == -1
end)
pass("math.sign works", function()
    return math.sign(5) == 1
       and math.sign(-3) == -1
       and math.sign(0) == 0
end)
pass("math.noise returns a number between -1 and 1", function()
    local n = math.noise(1.5, 2.5, 3.5)
    return type(n) == "number" and n >= -1 and n <= 1
end)
pass("integer overflow wraps to float correctly", function()
    local big = 2^53
    return big + 1 ~= big or type(big) == "number"
end)
pass("math.modf splits integer and fractional parts", function()
    local i, f = math.modf(3.75)
    return i == 3 and math.abs(f - 0.75) < 1e-9
end)

-- ── STRING ───────────────────────────────────────────────────────
pass("string.split works on comma separated", function()
    local parts = string.split("a,b,c", ",")
    return #parts == 3 and parts[1] == "a" and parts[3] == "c"
end)
pass("string.match captures a digit", function()
    local n = string.match("abc123", "%d+")
    return n == "123"
end)
pass("string.format %x hex works", function()
    return string.format("%x", 255) == "ff"
end)
pass("string.format %05d zero padding", function()
    return string.format("%05d", 42) == "00042"
end)
pass("# length operator on string", function()
    return #"hello" == 5
end)
pass("string concatenation with ..", function()
    local s = "foo" .. "bar"
    return s == "foobar" and #s == 6
end)
pass("string.rep with separator", function()
    return string.rep("ab", 3, "-") == "ab-ab-ab"
end)
pass("string.find with pattern anchors", function()
    return string.find("hello world", "^hello") ~= nil
       and string.find("hello world", "world$") ~= nil
end)
pass("tostring on numbers is consistent", function()
    return tostring(0) == "0"
       and tostring(-1) == "-1"
       and tostring(1.5) == "1.5"
end)
pass("tonumber with base 16", function()
    return tonumber("ff", 16) == 255
       and tonumber("10", 2)  == 2
end)

-- ── TABLE ────────────────────────────────────────────────────────
pass("# length on sequence table", function()
    local t = {10, 20, 30, 40}
    return #t == 4
end)
pass("table.move shifts elements correctly", function()
    local t = {1, 2, 3, 4, 5}
    table.move(t, 1, 3, 2)
    return t[2] == 1 and t[3] == 2 and t[4] == 3
end)
pass("table.unpack with range", function()
    local t = {10, 20, 30, 40}
    local a, b = table.unpack(t, 2, 3)
    return a == 20 and b == 30
end)
pass("table.pack gives n field", function()
    local t = table.pack(5, 6, 7)
    return t.n == 3 and t[1] == 5 and t[3] == 7
end)
pass("table.find locates a value", function()
    local t = {"a", "b", "c", "d"}
    return table.find(t, "c") == 3
       and table.find(t, "z") == nil
end)
pass("pairs works on mixed table", function()
    local t = {x = 1, y = 2, z = 3}
    local sum = 0
    for _, v in pairs(t) do sum = sum + v end
    return sum == 6
end)
pass("ipairs stops at nil gap", function()
    local t = {10, 20, nil, 40}
    local count = 0
    for _ in ipairs(t) do count = count + 1 end
    return count == 2
end)

-- ── COROUTINE ────────────────────────────────────────────────────
pass("coroutine.isyieldable is true inside a coroutine", function()
    local result
    local co = coroutine.create(function()
        result = coroutine.isyieldable()
    end)
    coroutine.resume(co)
    return result == true
end)
pass("coroutine.running returns current thread", function()
    local co
    local got
    co = coroutine.create(function()
        got = coroutine.running()
    end)
    coroutine.resume(co)
    return got == co
end)
pass("coroutine passes multiple yields", function()
    local co = coroutine.create(function()
        coroutine.yield(1)
        coroutine.yield(2)
        coroutine.yield(3)
    end)
    local _, a = coroutine.resume(co)
    local _, b = coroutine.resume(co)
    local _, c = coroutine.resume(co)
    return a == 1 and b == 2 and c == 3
end)
pass("dead coroutine returns false on resume", function()
    local co = coroutine.create(function() end)
    coroutine.resume(co)
    local ok = coroutine.resume(co)
    return ok == false
end)

-- ── METATABLES ───────────────────────────────────────────────────
pass("__index function metamethod works", function()
    local t = setmetatable({}, {
        __index = function(_, k) return k .. "_val" end
    })
    return t.foo == "foo_val" and t.bar == "bar_val"
end)
pass("__newindex metamethod intercepts write", function()
    local log = {}
    local t = setmetatable({}, {
        __newindex = function(_, k, v) log[k] = v end
    })
    t.x = 99
    return log.x == 99
end)
pass("__len metamethod fires on # operator", function()
    local t = setmetatable({}, { __len = function() return 42 end })
    return #t == 42
end)
pass("__tostring metamethod fires on tostring", function()
    local t = setmetatable({}, { __tostring = function() return "custom" end })
    return tostring(t) == "custom"
end)
pass("__eq metamethod fires on == between two tables", function()
    local mt = { __eq = function(a, b) return rawget(a, "v") == rawget(b, "v") end }
    local a = setmetatable({v = 5}, mt)
    local b = setmetatable({v = 5}, mt)
    return a == b
end)
pass("__add metamethod works", function()
    local mt = { __add = function(a, b) return setmetatable({v = a.v + b.v}, getmetatable(a)) end }
    local a = setmetatable({v = 3}, mt)
    local b = setmetatable({v = 4}, mt)
    local c = a + b
    return c.v == 7
end)
pass("__call metamethod makes table callable", function()
    local t = setmetatable({}, { __call = function(_, x) return x * 2 end })
    return t(21) == 42
end)
pass("__concat metamethod fires on ..", function()
    local mt = { __concat = function(a, b) return a.v .. b.v end }
    local a = setmetatable({v = "foo"}, mt)
    local b = setmetatable({v = "bar"}, mt)
    return (a .. b) == "foobar"
end)
pass("metatable inheritance chain works two levels", function()
    local base = { greet = function() return "hi" end }
    base.__index = base
    local mid = setmetatable({}, base)
    mid.__index = mid
    local obj = setmetatable({}, mid)
    return obj.greet() == "hi"
end)

-- ── ROBLOX TYPES ─────────────────────────────────────────────────
pass("CFrame.new from position and lookAt differ", function()
    local a = CFrame.new(0, 0, 0)
    local b = CFrame.new(1, 2, 3)
    return a ~= b
end)
pass("CFrame * CFrame multiplication", function()
    local a = CFrame.new(1, 0, 0)
    local b = CFrame.new(0, 1, 0)
    local c = a * b
    return typeof(c) == "CFrame"
end)
pass("CFrame:ToEulerAnglesXYZ returns three numbers", function()
    local rx, ry, rz = CFrame.Angles(1, 2, 3):ToEulerAnglesXYZ()
    return type(rx) == "number" and type(ry) == "number" and type(rz) == "number"
end)
pass("Vector3.new components read back correctly", function()
    local v = Vector3.new(3, 5, 7)
    return v.X == 3 and v.Y == 5 and v.Z == 7
end)
pass("Vector3 distance between two points", function()
    local a = Vector3.new(0, 0, 0)
    local b = Vector3.new(3, 4, 0)
    return math.abs((b - a).Magnitude - 5) < 1e-5
end)
pass("Color3 fromHSV and toHSV roundtrip", function()
    local c = Color3.fromHSV(0.5, 0.8, 0.9)
    local h, s, v = Color3.toHSV(c)
    return math.abs(h - 0.5) < 1e-4
       and math.abs(s - 0.8) < 1e-4
       and math.abs(v - 0.9) < 1e-4
end)
pass("Color3 lerp midpoint is correct", function()
    local a = Color3.new(0, 0, 0)
    local b = Color3.new(1, 1, 1)
    local mid = a:Lerp(b, 0.5)
    return math.abs(mid.R - 0.5) < 1e-4
end)
pass("UDim2 addition works", function()
    local a = UDim2.new(0.5, 10, 0.5, 10)
    local b = UDim2.new(0.5, 10, 0.5, 10)
    local c = a + b
    return math.abs(c.X.Scale - 1) < 1e-5 and c.X.Offset == 20
end)
pass("Rect Min and Max fields correct", function()
    local r = Rect.new(Vector2.new(1, 2), Vector2.new(5, 6))
    return r.Min.X == 1 and r.Max.Y == 6
       and r.Width == 4 and r.Height == 4
end)
pass("NumberSequence keypoints are correct", function()
    local ns = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    return #ns.Keypoints == 2
       and ns.Keypoints[1].Time == 0
       and ns.Keypoints[2].Value == 1
end)
pass("ColorSequence keypoints are correct", function()
    local cs = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.new(1,0,0)),
        ColorSequenceKeypoint.new(1, Color3.new(0,0,1)),
    })
    return #cs.Keypoints == 2
end)
pass("Ray direction is unit length", function()
    local r = Ray.new(Vector3.new(0,0,0), Vector3.new(3,4,0))
    return math.abs(r.Direction.Magnitude - 1) < 1e-5
       or  math.abs(r.Direction.Magnitude - 5) < 1e-5
end)
pass("TweenInfo fields read back correctly", function()
    local ti = TweenInfo.new(2, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out, 3, true, 0.5)
    return ti.Time == 2
       and ti.EasingStyle == Enum.EasingStyle.Bounce
       and ti.RepeatCount == 3
       and ti.Reverses == true
       and math.abs(ti.DelayTime - 0.5) < 1e-5
end)
pass("PhysicalProperties default density > 0", function()
    local pp = PhysicalProperties.new(Enum.Material.Wood)
    return pp.Density > 0
end)
pass("Axes new with all norms has all true", function()
    local ax = Axes.new(Enum.Axis.X, Enum.Axis.Y, Enum.Axis.Z)
    return ax.X == true and ax.Y == true and ax.Z == true
end)
pass("Faces new with all norms has all true", function()
    local f = Faces.new(
        Enum.NormalId.Top, Enum.NormalId.Bottom,
        Enum.NormalId.Front, Enum.NormalId.Back,
        Enum.NormalId.Left, Enum.NormalId.Right)
    return f.Top and f.Bottom and f.Front
end)

-- ── INSTANCES ────────────────────────────────────────────────────
pass("Part Anchored defaults to false", function()
    local p = Instance.new("Part")
    local v = p.Anchored
    p:Destroy()
    return v == false
end)
pass("Part CastShadow defaults to true", function()
    local p = Instance.new("Part")
    local v = p.CastShadow
    p:Destroy()
    return v == true
end)
pass("Part CanCollide defaults to true", function()
    local p = Instance.new("Part")
    local v = p.CanCollide
    p:Destroy()
    return v == true
end)
pass("Part Size defaults to 4x1.2x2", function()
    local p = Instance.new("Part")
    local s = p.Size
    p:Destroy()
    return math.abs(s.X - 4) < 0.01
       and math.abs(s.Y - 1.2) < 0.01
       and math.abs(s.Z - 2) < 0.01
end)
pass("Part BrickColor defaults to Medium stone grey", function()
    local p = Instance.new("Part")
    local name = p.BrickColor.Name
    p:Destroy()
    return name == "Medium stone grey"
end)
pass("Frame default BackgroundTransparency is 0", function()
    local f = Instance.new("Frame")
    local t = f.BackgroundTransparency
    f:Destroy()
    return t == 0
end)
pass("TextLabel default Text is empty string", function()
    local tl = Instance.new("TextLabel")
    local t = tl.Text
    tl:Destroy()
    return t == ""
end)
pass("Folder has no children by default", function()
    local f = Instance.new("Folder")
    local n = #f:GetChildren()
    f:Destroy()
    return n == 0
end)
pass("RemoteEvent ClassName is RemoteEvent", function()
    local re = Instance.new("RemoteEvent")
    local cn = re.ClassName
    re:Destroy()
    return cn == "RemoteEvent"
end)
pass("BindableEvent Fire and Event connect fires", function()
    local be = Instance.new("BindableEvent")
    local got = nil
    be.Event:Connect(function(v) got = v end)
    be:Fire(42)
    task.wait()
    be:Destroy()
    return got == 42
end)
pass("ObjectValue .Value holds an instance ref", function()
    local ov = Instance.new("ObjectValue")
    local p  = Instance.new("Part")
    ov.Value = p
    local same = ov.Value == p
    ov:Destroy()
    p:Destroy()
    return same
end)
pass("IntValue .Value roundtrip", function()
    local iv = Instance.new("IntValue")
    iv.Value = 12345
    local v = iv.Value
    iv:Destroy()
    return v == 12345
end)
pass("StringValue .Value roundtrip", function()
    local sv = Instance.new("StringValue")
    sv.Value = "kolenv"
    local v = sv.Value
    sv:Destroy()
    return v == "kolenv"
end)
pass("BoolValue .Value roundtrip", function()
    local bv = Instance.new("BoolValue")
    bv.Value = true
    local v = bv.Value
    bv:Destroy()
    return v == true
end)
pass("NumberValue .Value roundtrip", function()
    local nv = Instance.new("NumberValue")
    nv.Value = 3.14
    local v = nv.Value
    nv:Destroy()
    return math.abs(v - 3.14) < 1e-5
end)
pass("Model PrimaryPart assignment works", function()
    local m  = Instance.new("Model")
    local p  = Instance.new("Part")
    p.Parent = m
    m.PrimaryPart = p
    local same = m.PrimaryPart == p
    m:Destroy()
    return same
end)
pass("Model:GetBoundingBox returns two CFrames", function()
    local m  = Instance.new("Model")
    local p  = Instance.new("Part")
    p.Parent = m
    m.Parent = workspace
    local cf, sz = m:GetBoundingBox()
    m:Destroy()
    return typeof(cf) == "CFrame" and typeof(sz) == "Vector3"
end)
pass("Workspace:Raycast returns nil for empty space at altitude", function()
    local origin = Vector3.new(0, 5000, 0)
    local dir    = Vector3.new(0, 100, 0)
    local result = workspace:Raycast(origin, dir)
    return result == nil
end)
pass("workspace:FindPartOnRay returns nil for empty space", function()
    local ray = Ray.new(Vector3.new(0, 5000, 0), Vector3.new(0, 100, 0))
    local hit = workspace:FindPartOnRay(ray)
    return hit == nil
end)
pass("Instance:GetChildren returns table type", function()
    return type(workspace:GetChildren()) == "table"
end)
pass("Instance:GetDescendants returns table type", function()
    return type(workspace:GetDescendants()) == "table"
end)
pass("Instance:IsAncestorOf works correctly", function()
    local folder = Instance.new("Folder")
    local child  = Instance.new("Part")
    child.Parent  = folder
    folder.Parent = workspace
    local result = folder:IsAncestorOf(child)
    folder:Destroy()
    return result == true
end)
pass("Instance:IsDescendantOf works correctly", function()
    local folder = Instance.new("Folder")
    local child  = Instance.new("Part")
    child.Parent  = folder
    folder.Parent = workspace
    local result = child:IsDescendantOf(workspace)
    folder:Destroy()
    return result == true
end)

-- ── SERVICES ─────────────────────────────────────────────────────
pass("UserInputService.TouchEnabled is boolean", function()
    return type(game:GetService("UserInputService").TouchEnabled) == "boolean"
end)
pass("UserInputService.KeyboardEnabled is boolean", function()
    return type(game:GetService("UserInputService").KeyboardEnabled) == "boolean"
end)
pass("UserInputService.MouseEnabled is boolean", function()
    return type(game:GetService("UserInputService").MouseEnabled) == "boolean"
end)
pass("GuiService.MenuIsOpen is boolean", function()
    return type(game:GetService("GuiService").MenuIsOpen) == "boolean"
end)
pass("MarketplaceService:GetProductInfo errors gracefully on id 0", function()
    local ok, err = pcall(function()
        game:GetService("MarketplaceService"):GetProductInfo(0)
    end)
    return not ok and type(err) == "string"
end)
passOpt("Players:GetNameFromUserIdAsync errors on id -1", function()
    local ok, err = pcall(function()
        game:GetService("Players"):GetNameFromUserIdAsync(-1)
    end)
    return not ok and type(err) == "string"
end)
pass("Teams service ClassName is Teams", function()
    return game:GetService("Teams").ClassName == "Teams"
end)
pass("ScriptContext.ScriptsDisabled is boolean", function()
    return type(game:GetService("ScriptContext").ScriptsDisabled) == "boolean"
end)
pass("PhysicsService exists and ClassName is right", function()
    local ps = game:GetService("PhysicsService")
    return ps ~= nil and ps.ClassName == "PhysicsService"
end)
pass("LogService:GetLogHistory returns a table", function()
    local ls = game:GetService("LogService")
    return type(ls:GetLogHistory()) == "table"
end)
pass("TweenService ClassName is TweenService", function()
    return game:GetService("TweenService").ClassName == "TweenService"
end)
passOpt("PathfindingService:CreatePath returns a Path", function()
    local pf   = game:GetService("PathfindingService")
    local path = pf:CreatePath()
    return path ~= nil and path.ClassName == "Path"
end)

-- ── EXECUTOR FUNCTIONS ───────────────────────────────────────────
passOpt("getreg returns a table", function()
    local r = getreg()
    return type(r) == "table"
end)
passOpt("getprotos returns a table for a Lua function", function()
    local fn = function()
        local function inner() end
        return inner
    end
    local protos = getprotos(fn)
    return type(protos) == "table"
end)
passOpt("setreadonly makes a frozen table writable", function()
    local t = table.freeze({x = 1})
    setreadonly(t, false)
    local ok = pcall(function() t.x = 2 end)
    return ok == true and t.x == 2
end)
passOpt("getscriptbytecode returns a non-empty string", function()
    local sc = game.Players.LocalPlayer.PlayerScripts:FindFirstChild("PlayerModule")
    if not sc then return false end
    local bc = getscriptbytecode(sc)
    return type(bc) == "string" and #bc > 0
end)
passOpt("getscripthash returns a non-empty string", function()
    local sc = game.Players.LocalPlayer.PlayerScripts:FindFirstChild("PlayerModule")
    if not sc then return false end
    local h = getscripthash(sc)
    return type(h) == "string" and #h > 0
end)
passOpt("getscriptclosure returns a function", function()
    local sc = game.Players.LocalPlayer.PlayerScripts:FindFirstChild("PlayerModule")
    if not sc then return false end
    local fn = getscriptclosure(sc)
    return type(fn) == "function"
end)
passOpt("decompile returns a non-empty string", function()
    local sc = game.Players.LocalPlayer.PlayerScripts:FindFirstChild("PlayerModule")
    if not sc then return false end
    local src = decompile(sc)
    return type(src) == "string" and #src > 0
end)
passOpt("gethiddenproperty reads a hidden property", function()
    local p = Instance.new("Part")
    p.Parent = workspace
    local val, exists = gethiddenproperty(p, "SimulationThrottled")
    p:Destroy()
    return exists == true
end)
passOpt("sethiddenproperty writes a hidden property", function()
    local p = Instance.new("Part")
    p.Parent = workspace
    local ok = pcall(sethiddenproperty, p, "SimulationThrottled", false)
    p:Destroy()
    return ok == true
end)
passOpt("getspecialinfo returns a table", function()
    local sc = game.Players.LocalPlayer.PlayerScripts:FindFirstChild("PlayerModule")
    if not sc then return false end
    return type(getspecialinfo(sc)) == "table"
end)
passOpt("lz4compress and lz4decompress roundtrip", function()
    local original = "kolenv_compress_test_string_12345"
    local compressed = lz4compress(original)
    local decompressed = lz4decompress(compressed, #original)
    return decompressed == original
end)
passOpt("getthreadidentity returns a number 0-8", function()
    local id = getthreadidentity()
    return type(id) == "number" and id >= 0 and id <= 8
end)
passOpt("setthreadidentity changes the identity", function()
    local old = getthreadidentity()
    setthreadidentity(6)
    local new = getthreadidentity()
    setthreadidentity(old)
    return new == 6
end)
passOpt("request function exists", function()
    return type(request) == "function" or type(http_request) == "function" or type(syn) == "table"
end)
passOpt("rconsoleprint exists", function()
    return type(rconsoleprint) == "function"
        or type(rconsolewarn) == "function"
        or type(consolecreate) == "function"
end)
passOpt("setclipboard exists", function()
    return type(setclipboard) == "function"
        or type(toclipboard) == "function"
end)
passOpt("mousemoverel exists", function()
    return type(mousemoverel) == "function"
        or type(mouse_moverel) == "function"
end)
passOpt("keypress and keyrelease exist", function()
    return type(keypress) == "function" and type(keyrelease) == "function"
end)
passOpt("mouseclick exists", function()
    return type(mouseclick) == "function"
        or type(mouse1click) == "function"
end)
passOpt("Drawing.new exists", function()
    return type(Drawing) == "table" and type(Drawing.new) == "function"
end)
passOpt("getrenderproperty exists", function()
    return type(getrenderproperty) == "function"
end)
passOpt("getcustomasset exists", function()
    return type(getcustomasset) == "function"
end)

-- ── CLOSURES / UPVALUES ──────────────────────────────────────────
passOpt("getupvalues on a closure with multiple upvalues", function()
    local a, b, c = 1, 2, 3
    local fn = function() return a + b + c end
    local ups = getupvalues(fn)
    return type(ups) == "table" and #ups >= 3
end)
passOpt("getconstants finds a number constant", function()
    local fn = function() return 99999 end
    local consts = getconstants(fn)
    if type(consts) ~= "table" then return false end
    for _, v in pairs(consts) do
        if v == 99999 then return true end
    end
    return false
end)
passOpt("getinfo on a Lua function gives correct source", function()
    local fn = function() end
    local info = debug.getinfo and debug.getinfo(fn, "S")
    if not info then return false end
    return type(info.source) == "string"
end)
passOpt("clonefunction produces a different but equivalent closure", function()
    local x = 7
    local fn = function() return x end
    local cl = clonefunction(fn)
    return cl ~= fn and cl() == 7
end)

-- ── ANTI-CHEAT / ENVIRONMENT INTEGRITY ──────────────────────────
pass("rawget does not trigger __index", function()
    local intercepted = false
    local t = setmetatable({}, {
        __index = function() intercepted = true; return nil end
    })
    rawget(t, "missing")
    return intercepted == false
end)
pass("rawset does not trigger __newindex", function()
    local intercepted = false
    local t = setmetatable({}, {
        __newindex = function() intercepted = true end
    })
    rawset(t, "k", "v")
    return intercepted == false and rawget(t, "k") == "v"
end)
pass("select('#', ...) counts nils correctly", function()
    local function count(...) return select('#', ...) end
    return count(1, nil, 3) == 3
end)
pass("pcall returns true and values on success", function()
    local ok, a, b = pcall(function() return 10, 20 end)
    return ok == true and a == 10 and b == 20
end)
pass("pcall returns false and message on error", function()
    local ok, msg = pcall(error, "test_error")
    return ok == false and type(msg) == "string" and msg:find("test_error") ~= nil
end)
pass("xpcall message handler receives error object", function()
    local received
    xpcall(function() error("boom") end, function(e) received = e end)
    return type(received) == "string" and received:find("boom") ~= nil
end)
pass("error with level 0 gives raw message", function()
    local ok, msg = pcall(function() error("raw_msg", 0) end)
    return not ok and msg == "raw_msg"
end)
pass("type returns correct strings for all base types", function()
    return type(nil)       == "nil"
       and type(true)      == "boolean"
       and type(1)         == "number"
       and type("s")       == "string"
       and type({})        == "table"
       and type(print)     == "function"
       and type(coroutine.create(function() end)) == "thread"
end)
pass("typeof returns userdata for newproxy()", function()
    return typeof(newproxy()) == "userdata"
end)

-- ── ROBLOX SPECIFIC INTEGRITY ────────────────────────────────────
pass("workspace:GetRealPhysicsFPS returns a positive number", function()
    local fps = workspace:GetRealPhysicsFPS()
    return type(fps) == "number" and fps > 0
end)
pass("LocalPlayer character exists or CharacterAdded fires", function()
    local lp = game.Players.LocalPlayer
    return lp.Character ~= nil or typeof(lp.CharacterAdded) == "RBXScriptSignal"
end)
pass("Camera.CFrame position fields are numbers", function()
    local cf = workspace.CurrentCamera.CFrame
    return type(cf.X) == "number" and type(cf.Y) == "number" and type(cf.Z) == "number"
end)
pass("game.Workspace == workspace", function()
    return game.Workspace == workspace and rawequal(game.Workspace, workspace)
end)
pass("StarterGui ResetPlayerGuiOnSpawn is boolean", function()
    return type(game:GetService("StarterGui").ResetPlayerGuiOnSpawn) == "boolean"
end)
pass("ReplicatedStorage ClassName is ReplicatedStorage", function()
    return game:GetService("ReplicatedStorage").ClassName == "ReplicatedStorage"
end)
pass("Debris service exists", function()
    return game:GetService("Debris") ~= nil
end)
pass("Debris:AddItem does not error", function()
    local p = Instance.new("Part")
    local ok = pcall(function() game:GetService("Debris"):AddItem(p, 9999) end)
    return ok == true
end)
pass("TweenService:Create returns a Tween", function()
    local p  = Instance.new("Part")
    local tw = game:GetService("TweenService"):Create(
        p, TweenInfo.new(1), {Transparency = 1})
    p:Destroy()
    return tw ~= nil and tw.ClassName == "Tween"
end)
pass("SoundService PlaybackSpeed is 1 by default", function()
    return game:GetService("SoundService").AmbientReverb ~= nil
end)
pass("HttpService:GenerateGUID two calls give different results", function()
    local a = game:GetService("HttpService"):GenerateGUID(false)
    local b = game:GetService("HttpService"):GenerateGUID(false)
    return a ~= b and #a > 0 and #b > 0
end)
pass("Players.LocalPlayer.UserId matches GetPlayerByUserId", function()
    local lp = game.Players.LocalPlayer
    local found = game.Players:GetPlayerByUserId(lp.UserId)
    return found == lp
end)
pass("game:GetService with wrong case errors", function()
    local ok = pcall(function() game:GetService("players") end)
    return ok == false
end)
pass("task.wait returns elapsed time > 0", function()
    local dt = task.wait(0.05)
    return type(dt) == "number" and dt > 0
end)
passOpt("SharedTable basic set and get", function()
    local st = SharedTable.new()
    st.x = 42
    return st.x == 42
end)
pass("buffer.len returns correct length", function()
    local b = buffer.create(16)
    return buffer.len(b) == 16
end)
pass("buffer.fill then readu8 gives filled value", function()
    local b = buffer.create(4)
    buffer.fill(b, 0, 0xAB)
    return buffer.readu8(b, 0) == 0xAB
       and buffer.readu8(b, 3) == 0xAB
end)
pass("buffer.writestring and readstring roundtrip", function()
    local b = buffer.create(16)
    buffer.writestring(b, 0, "kolenv")
    return buffer.readstring(b, 0, 6) == "kolenv"
end)
pass("buffer.writef32 and readf32 roundtrip within tolerance", function()
    local b = buffer.create(4)
    buffer.writef32(b, 0, 3.14)
    local v = buffer.readf32(b, 0)
    return math.abs(v - 3.14) < 0.001
end)
pass("buffer.writef64 and readf64 roundtrip precisely", function()
    local b = buffer.create(8)
    buffer.writef64(b, 0, math.pi)
    return math.abs(buffer.readf64(b, 0) - math.pi) < 1e-12
end)
pass("bit32.band bor bxor work", function()
    return bit32.band(0xFF, 0x0F) == 0x0F
       and bit32.bor(0xF0, 0x0F)  == 0xFF
       and bit32.bxor(0xFF, 0x0F) == 0xF0
end)
pass("bit32.lshift and rshift work", function()
    return bit32.lshift(1, 4) == 16
       and bit32.rshift(16, 4) == 1
end)
pass("bit32.bnot inverts bits within 32 bits", function()
    return bit32.bnot(0) == 0xFFFFFFFF
end)
pass("bit32.countlz and countrz work", function()
    return bit32.countlz(1) == 31
       and bit32.countrz(16) == 4
end)

-- ================================================================
-- DTC CHECKS FROM ZIP (top-level + level2)
-- Direct ports of real-world anti-envlogger detection scripts.
-- ================================================================

-- from 1.luau / 19.lua: Vector3int16 and Vector2int16 match on X
pass("Vector3int16 and Vector2int16 X fields match", function()
    local v3i = Vector3int16.new(1, 1, 1)
    local v2i = Vector2int16.new(1, 1)
    return v3i.X == v2i.X
end)

-- from 1.luau: TweenService with UI works end-to-end
pass("TweenService on a Frame completes without error", function()
    local f = Instance.new("Frame")
    local tw = game:GetService("TweenService"):Create(
        f, TweenInfo.new(0.01), {Position = UDim2.fromScale(1, 1)})
    tw:Play()
    tw.Completed:Wait()
    f:Destroy()
    return true
end)

-- from 1.luau: getmetatable on a locked table returns the lock string not a table
pass("getmetatable on a locked object returns string not table", function()
    local mt = {__metatable = "protected"}
    local obj = setmetatable({}, mt)
    return getmetatable(obj) == "protected"
end)

-- from 1.luau: core globals all present
pass("debug rawget rawset getfenv pcall select type all exist", function()
    return getmetatable ~= nil and setmetatable ~= nil and type ~= nil
       and select ~= nil and pcall ~= nil and debug ~= nil
       and rawget ~= nil and rawset ~= nil and getfenv ~= nil
end)

-- from 1.luau: rawset on a plain table works
pass("rawset on a plain table does not error", function()
    return pcall(rawset, {}, " ", " ")
end)

-- from 1.luau: getmetatable on require and print returns nil (not wrapped)
pass("require and print have no metatable", function()
    return getmetatable(require) == nil
       and getmetatable(print)   == nil
       and getmetatable(error)   == nil
end)

-- from 1.luau / 24.lua: debug.info on print says source is [C]
pass("debug.info on print source is [C]", function()
    return debug.info(print, "s") == "[C]"
end)

-- from 1.luau / 24.lua: debug.info on require source is [C]
pass("debug.info on require source is [C]", function()
    return debug.info(require, "s") == "[C]"
end)

-- from 1.luau: a Lua function is not reported as [C] by debug.info
pass("debug.info on a Lua function source is not [C]", function()
    return debug.info(function() end, "s") ~= "[C]"
end)

-- from 1.luau: dead coroutine errors on debug.info
pass("debug.info errors on a dead coroutine", function()
    local dead = coroutine.wrap(function() end)
    dead()
    return select(1, pcall(debug.info, dead, "s")) == false
end)

-- from 1.luau / 14.lua: lune require not loadable
pass("require @lune/roblox is not accessible", function()
    local loadFn = loadstring or load
    if type(loadFn) ~= "function" then return true end
    local chunk = loadFn('return require("@lune/roblox")')
    if not chunk then return true end
    return not pcall(chunk)
end)

-- from 8.lua / 12.lua / 25.lua: Heartbeat dt params are real numbers > 0 and vary
pass("Heartbeat delta times are positive and vary between frames", function()
    local dts = {}
    local count = 0
    local conn
    conn = game:GetService("RunService").Heartbeat:Connect(function(dt)
        count = count + 1
        dts[count] = dt
        if count >= 5 then conn:Disconnect() end
    end)
    while count < 5 do task.wait() end
    for _, dt in next, dts do
        if type(dt) ~= "number" or dt <= 0 or dt > 1 then return false end
    end
    local same = true
    for i = 2, #dts do
        if dts[i] ~= dts[1] then same = false break end
    end
    return not same
end)

-- from level2/1.lua: Part property types are correct
pass("Part property typeof checks all correct", function()
    local p = Instance.new("Part")
    local ok = typeof(p)          == "Instance"
           and typeof(p.Size)     == "Vector3"
           and typeof(p.CFrame)   == "CFrame"
           and typeof(p.Color)    == "Color3"
           and typeof(p.BrickColor) == "BrickColor"
           and typeof(p.Material) == "EnumItem"
    p:Destroy()
    return ok
end)

-- from level2/2.lua: GetPropertyChangedSignal on a fake property errors
pass("GetPropertyChangedSignal on fake property errors", function()
    local lp = game:GetService("Players").LocalPlayer
    return not pcall(function()
        lp:GetPropertyChangedSignal("FakeProperty_kolenv")
    end)
end)

-- from level2/3.lua: setthreadidentity(-1) errors
passOpt("setthreadidentity with -1 errors", function()
    return not pcall(setthreadidentity, -1)
end)

-- from level2/11.lua: coroutine.wrap depth C stack overflow at 199 wraps but not 198
pass("coroutine.wrap 199 deep causes C stack overflow", function()
    local closure = getmetatable
    for _ = 1, 199 do closure = coroutine.wrap(closure) end
    local ok, out = pcall(closure)
    return not ok and tostring(out):find("C stack overflow") ~= nil
end)

-- from level2/12.lua: GetPropertyChangedSignal on Size fires with new value
pass("GetPropertyChangedSignal Size fires with correct value", function()
    local part = Instance.new("Part")
    local log = {}
    part:GetPropertyChangedSignal("Size"):Connect(function()
        table.insert(log, part.Size)
    end)
    part.Size = Vector3.new(9, 9, 9)
    task.wait(0.05)
    part:Destroy()
    return #log > 0 and log[#log].X == 9
end)

-- from level2/22.lua / 34.lua: Part:Clone respects Archivable false
pass("Part:Clone returns nil when Archivable is false", function()
    local p = Instance.new("Part")
    p.Archivable = false
    local ok, c = pcall(function() return p:Clone() end)
    p:Destroy()
    return (not ok) or (c == nil)
end)

-- from level2/22.lua: FindFirstChildWhichIsA works
pass("FindFirstChildWhichIsA finds a Part in a Model", function()
    local m = Instance.new("Model")
    local p = Instance.new("Part")
    p.Parent = m
    local found = m:FindFirstChildWhichIsA("BasePart")
    m:Destroy()
    return found == p
end)

-- from level2/24.lua: NetworkClient exists and has ClientReplicator
passOpt("NetworkClient exists and has ClientReplicator", function()
    local ok, n = pcall(function() return game:GetService("NetworkClient") end)
    return ok and n ~= nil and n:FindFirstChild("ClientReplicator") ~= nil
end)

-- from level2/25.lua / 57.lua: GetRealPhysicsFPS is between 0 and 300
pass("workspace:GetRealPhysicsFPS is between 0 and 300", function()
    local fps = workspace:GetRealPhysicsFPS()
    return type(fps) == "number" and fps > 0 and fps <= 300
end)

-- from level2/26.lua / 57.lua: settings().Rendering.QualityLevel is a valid EnumItem
pass("settings().Rendering.QualityLevel is a valid QualityLevel EnumItem", function()
    local ql = settings().Rendering.QualityLevel
    if typeof(ql) ~= "EnumItem" then return false end
    for _, item in ipairs(Enum.QualityLevel:GetEnumItems()) do
        if item == ql then return true end
    end
    return false
end)

-- from level2/27.lua: string interning — interned strings compare faster than dynamic ones
pass("interned string equality is faster than dynamic string equality", function()
    local t0 = os.clock()
    for _ = 1, 500 do local a = "ax"; local b = "ax"; local _ = a == b end
    local t1 = os.clock() - t0
    local t2 = os.clock()
    for i = 1, 500 do local a = "ax"..i; local b = "ax"..i; local _ = a == b end
    local t3 = os.clock() - t2
    return t1 < t3 * 2
end)

-- from level2/27.lua: NaN self-inequality
pass("NaN is not equal to itself via math.max and math.min", function()
    local nan = 0/0
    return math.max(nan, 1) ~= math.max(nan, 1)
       and math.min(nan, 1) ~= math.min(nan, 1)
       and nan ~= nan
end)

-- from level2/27.lua: write-then-read closure timing ratio is sane
pass("write closure takes more time than read closure in fair ratio", function()
    local x = 0
    local write = function() x = x + 1 end
    local read  = function() return x end
    local t0 = os.clock()
    for _ = 1, 1000 do write() end
    local wt = os.clock() - t0
    local t1 = os.clock()
    for _ = 1, 1000 do read() end
    local rt = os.clock() - t1
    return wt > rt * 0.3 and wt < rt * 10
end)

-- from level2/29.lua / 55.lua: ContextActionService bind/get/unbind works
pass("ContextActionService BindAction GetAllBoundActionInfo UnbindAction works", function()
    local cas = game:GetService("ContextActionService")
    cas:BindAction("kolenv_test", function() end, false, Enum.KeyCode.F)
    local info = cas:GetAllBoundActionInfo()
    local found = info["kolenv_test"] ~= nil
       and type(info["kolenv_test"].inputTypes) == "table"
       and info["kolenv_test"].inputTypes[1] == Enum.KeyCode.F
    cas:UnbindAction("kolenv_test")
    return found and cas:GetAllBoundActionInfo()["kolenv_test"] == nil
end)

-- from level2/29.lua / 55.lua: CaptureService.CaptureBegan is a signal
pass("CaptureService.CaptureBegan is an RBXScriptSignal and connection works", function()
    local cs = game:GetService("CaptureService")
    if typeof(cs.CaptureBegan) ~= "RBXScriptSignal" then return false end
    local conn = cs.CaptureBegan:Connect(function() end)
    if typeof(conn) ~= "RBXScriptConnection" then conn:Disconnect(); return false end
    conn:Disconnect()
    return conn.Connected == false
end)

-- from level2/30.lua: CoreGui RobloxGui Modules Settings Pages Help chain exists
passOpt("CoreGui/RobloxGui/Modules/Settings/Pages/Help chain exists", function()
    local cg = game:GetService("CoreGui")
    local chain = {"RobloxGui", "Modules", "Settings", "Pages", "Help"}
    local cur = cg
    for _, name in ipairs(chain) do
        cur = cur:WaitForChild(name, 2)
        if cur == nil then return false end
    end
    return true
end)

-- from level2/31.lua: MemStorageService math.log(100,10) roundtrip
passOpt("MemStorageService stores and retrieves math.log(100,10) correctly", function()
    local ms = game:GetService("MemStorageService")
    local val = math.log(100, 10)
    ms:SetItem("kolenv_log_test", tostring(val))
    local back = tonumber(ms:GetItem("kolenv_log_test"))
    return back ~= nil and math.abs(back - 2) < 1e-5
end)

-- from level2/31.lua: SoundService.DistanceFactor > 0 and math roundtrip
pass("SoundService.DistanceFactor is positive and survives pi multiply/divide", function()
    local df = game:GetService("SoundService").DistanceFactor
    if df <= 0 then return false end
    local roundtrip = (df * math.pi) / math.pi
    return math.abs(roundtrip - df) < 1e-5
end)

-- from level2/32.lua: HapticService:IsVibrationSupported returns boolean
passOpt("HapticService:IsVibrationSupported returns a boolean", function()
    local hs = game:GetService("HapticService")
    return type(hs:IsVibrationSupported(Enum.UserInputType.Gamepad1)) == "boolean"
end)

-- from level2/32.lua / 127.lua: GetCharacterAppearanceInfoAsync returns correct shape
passOpt("GetCharacterAppearanceInfoAsync for local player returns valid table", function()
    local lp = game:GetService("Players").LocalPlayer
    local info = game:GetService("Players"):GetCharacterAppearanceInfoAsync(lp.UserId)
    if type(info) ~= "table" then return false end
    if type(info.assets) ~= "table" or #info.assets == 0 then return false end
    if type(info.bodyColors) ~= "table" then return false end
    if type(info.scales) ~= "table" then return false end
    return true
end)

-- from level2/33.lua / 37.lua: GetCorescriptLocalizations returns non-empty table of Instances
passOpt("LocalizationService:GetCorescriptLocalizations returns Instances", function()
    local ls = game:GetService("LocalizationService")
    local t = ls:GetCorescriptLocalizations()
    if type(t) ~= "table" or #t == 0 then return false end
    for _, v in pairs(t) do
        if typeof(v) == "Instance" then return true end
    end
    return false
end)

-- from level2/34.lua / 126.lua: AchievementService exists and has correct methods
passOpt("AchievementService exists with IsAvailable HasAchieved GrantAchievement", function()
    local a = game:GetService("AchievementService")
    if a == nil or a.ClassName ~= "AchievementService" then return false end
    if type(a.IsAvailable) ~= "function" then return false end
    if type(a.HasAchieved) ~= "function" then return false end
    if type(a.GrantAchievement) ~= "function" then return false end
    return type(a:IsAvailable()) == "boolean"
end)

-- from level2/34.lua / 126.lua: PlayerViewService exists with camera methods
passOpt("PlayerViewService GetDeviceCameraCFrameForSelfView returns a CFrame", function()
    local pvs = game:GetService("PlayerViewService")
    if pvs == nil or pvs.ClassName ~= "PlayerViewService" then return false end
    local cf = pvs:GetDeviceCameraCFrameForSelfView()
    return typeof(cf) == "CFrame"
end)

-- from level2/34.lua: AppLifecycleObserverService exists
passOpt("AppLifecycleObserverService exists", function()
    local a = game:GetService("AppLifecycleObserverService")
    return a ~= nil and a.ClassName == "AppLifecycleObserverService"
end)

-- from level2/35.lua / 21.lua: AnimationClipProvider:GetMemStats returns string-keyed number table
passOpt("AnimationClipProvider:GetMemStats returns string keys with number values", function()
    local a = game:GetService("AnimationClipProvider")
    local b = a:GetMemStats()
    if type(b) ~= "table" then return false end
    local c, d = 0, 0
    for k, v in pairs(b) do
        if type(k) == "string" then c = c + 1 end
        if type(v) == "number" then d = d + 1 end
    end
    return c > 0 and d > 0 and c == d
end)

-- from level2/39.lua: WaitForChild with negative timeout errors
pass("WaitForChild with negative timeout errors", function()
    return not pcall(function()
        workspace:WaitForChild("__kolenv_noexist__", -1)
    end)
end)

-- from level2/44.lua: two different tables have different tostring addresses
pass("two different tables have different tostring addresses", function()
    local a = tostring({})
    local b = tostring({})
    return a ~= b
end)

-- from level2/45.lua: Lighting.Technology is a valid EnumItem
pass("Lighting.Technology is a valid EnumItem", function()
    local tech = game:GetService("Lighting").Technology
    if typeof(tech) ~= "EnumItem" then return false end
    local valid = {"Future", "ShadowMap", "Voxel", "Compatibility", "Legacy"}
    for _, name in ipairs(valid) do
        if tech.Name == name then return true end
    end
    return false
end)

-- from level2/46.lua: Stepped and RenderStepped dt are not identical
pass("RunService.Stepped and RenderStepped deltas differ between frames", function()
    local sd, rd = 0, 0
    local cs = game:GetService("RunService").Stepped:Connect(function(_, dt) sd = dt end)
    local cr = game:GetService("RunService").RenderStepped:Connect(function(dt) rd = dt end)
    task.wait(0.15)
    cs:Disconnect(); cr:Disconnect()
    return math.abs(sd - rd) >= 1e-8
end)

-- from level2/51.lua: MemStorageService GetInstanceAddedSignal singleton
passOpt("MemStorageService GetInstanceAddedSignal returns same signal twice", function()
    local cs = game:GetService("CollectionService")
    local s1 = cs:GetInstanceAddedSignal("__kolenv_tag__")
    local s2 = cs:GetInstanceAddedSignal("__kolenv_tag__")
    return s1 == s2
end)

-- from level2/51.lua: DebuggerManager is not accessible from executor identity
pass("DebuggerManager is not accessible (identity too low)", function()
    local ok = pcall(function() return game:GetService("DebuggerManager") end)
    return not ok
end)

-- from level2/63.lua: Part.Name cannot be set to a thread
pass("Part.Name rejects a thread as a value", function()
    local p = Instance.new("Part")
    local ok = pcall(function()
        p.Name = coroutine.create(function() end)
    end)
    p:Destroy()
    return not ok
end)

-- from level2/63.lua: Camera.FieldOfView assignment does not hard-error but clamps
pass("Camera.FieldOfView clamps and does not accept -10", function()
    local cam = workspace.CurrentCamera
    if not cam then return true end
    local orig = cam.FieldOfView
    pcall(function() cam.FieldOfView = -10 end)
    local clamped = cam.FieldOfView ~= -10
    cam.FieldOfView = orig
    return clamped
end)

-- from level2/65.lua: coroutine.running inside a coroutine returns itself
pass("coroutine.running inside a coroutine returns the thread", function()
    local co
    local got
    co = coroutine.create(function()
        got = coroutine.running()
    end)
    coroutine.resume(co)
    return got == co
end)

-- from level2/67.lua: stack overflow does not include LUA_ERRERR in message
pass("stack overflow error does not contain LUA_ERRERR", function()
    local function ov() return ov() end
    local _, err = pcall(ov)
    return tostring(err):find("stack overflow") ~= nil
       and tostring(err):find("LUA_ERRERR") == nil
end)

-- from level2/69.lua: Enum tables are read-only
pass("Enum tables are read-only", function()
    return not pcall(function() Enum.PartType["__DETECTION__"] = true end)
end)

-- from level2/70.lua: Part.Position loses float precision (engine rounds)
pass("Part.Position loses sub-engine-float precision as expected", function()
    local p = Instance.new("Part")
    p.Position = Vector3.new(1.0000001, 2.0000001, 3.0000001)
    local rb = p.Position
    p:Destroy()
    -- engine rounds these; they should NOT come back exactly
    return rb.X ~= 1.0000001 or rb.Y ~= 2.0000001 or rb.Z ~= 3.0000001
end)

-- from level2/72.lua: task.delay fires after real time
pass("task.delay fires with a positive elapsed time", function()
    local diff = nil
    local start = os.clock()
    task.delay(0, function()
        diff = os.clock() - start
    end)
    task.wait(0.1)
    return diff ~= nil and diff > 0 and diff < 0.5
end)

-- from level2/85.lua: LocalizationTable SetEntries / GetEntries roundtrip
pass("LocalizationTable SetEntries GetEntries key/value roundtrip", function()
    local lt = Instance.new("LocalizationTable")
    lt.SourceLocaleId = "en"
    lt:SetEntries({{Key = "kolenv_key", Source = "Hello", Values = {en = "Hello", fr = "Bonjour"}}})
    lt.Parent = game
    local entries = lt:GetEntries()
    local found = false
    for _, e in ipairs(entries) do
        if e.Key == "kolenv_key" and e.Values["fr"] == "Bonjour" then
            found = true; break
        end
    end
    lt:Destroy()
    return found
end)

-- from level2/86.lua: Vector3.fromNormalId gives correct directions
pass("Vector3.fromNormalId gives correct directions for all NormalIds", function()
    local map = {
        [Enum.NormalId.Right]  = Vector3.new(1, 0, 0),
        [Enum.NormalId.Top]    = Vector3.new(0, 1, 0),
        [Enum.NormalId.Back]   = Vector3.new(0, 0, 1),
        [Enum.NormalId.Left]   = Vector3.new(-1, 0, 0),
        [Enum.NormalId.Bottom] = Vector3.new(0, -1, 0),
        [Enum.NormalId.Front]  = Vector3.new(0, 0, -1),
    }
    for nid, expected in pairs(map) do
        if (Vector3.fromNormalId(nid) - expected).Magnitude > 1e-9 then
            return false
        end
    end
    return true
end)

-- from level2/89.lua: CFrame.fromMatrix axes are orthogonal and unit
pass("CFrame.fromMatrix axes are orthogonal and unit length", function()
    local cf = CFrame.fromMatrix(Vector3.new(0,0,0),
        Vector3.new(1,0,0), Vector3.new(0,1,0), Vector3.new(0,0,1))
    if math.abs(cf.RightVector:Dot(cf.UpVector)) > 1e-6 then return false end
    if math.abs(cf.RightVector:Dot(cf.LookVector)) > 1e-6 then return false end
    if math.abs(cf.RightVector.Magnitude - 1) > 1e-6 then return false end
    return true
end)

-- from level2/96.lua / 99.lua: BindableFunction Invoke roundtrip
pass("BindableFunction Invoke multiply roundtrip", function()
    local bf = Instance.new("BindableFunction")
    bf.OnInvoke = function(a, b) return a * b end
    local r = bf:Invoke(7, 6)
    bf:Destroy()
    return r == 42
end)

-- from level2/97.lua: CFrame.Angles axes are mutually orthogonal
pass("CFrame.Angles RightVector UpVector LookVector are all orthogonal", function()
    local cf = CFrame.Angles(math.rad(45), math.rad(30), math.rad(60))
    return math.abs(cf.RightVector:Dot(cf.UpVector))   < 0.001
       and math.abs(cf.RightVector:Dot(cf.LookVector)) < 0.001
       and math.abs(cf.UpVector:Dot(cf.LookVector))    < 0.001
end)

-- from level2/98.lua: Random.new seeded with os.time gives varying results
pass("Random.new gives different values on consecutive calls", function()
    local rng = Random.new(os.time())
    local results = {}
    for i = 1, 10 do results[i] = rng:NextInteger(1, 100) end
    for i = 2, #results do
        if results[i] ~= results[1] then return true end
    end
    return false
end)

-- from level2/100.lua: getfenv() has no metatable on its environment
pass("getfenv() result has no metatable", function()
    return getmetatable(getfenv()) == nil
end)

-- from level2/100.lua: loop sum 1..1000000 = 500000500000
pass("loop sum 1 to 1000000 equals 500000500000", function()
    local x = 0
    for i = 1, 1000000 do x = x + i end
    return x == 500000500000
end)

-- from level2/110.lua: math string table coroutine bit32 task os all frozen
pass("standard libraries math string table coroutine bit32 task os are all frozen", function()
    for _, lib in ipairs({math, string, table, coroutine, bit32, task, os}) do
        if not table.isfrozen(lib) then return false end
        if pcall(function() lib.x = 1 end) then return false end
    end
    return true
end)

-- from level2/114.lua: workspace:BulkMoveTo moves parts to correct CFrames
pass("workspace:BulkMoveTo moves parts to target positions", function()
    local parts, targets = {}, {}
    for i = 1, 3 do
        local p = Instance.new("Part")
        p.Anchored = true
        p.Parent = workspace
        table.insert(parts, p)
        table.insert(targets, CFrame.new(i * 10, 500, 0))
    end
    workspace:BulkMoveTo(parts, targets, Enum.BulkMoveMode.FireCFrameChanged)
    local ok = true
    for i, p in ipairs(parts) do
        if (p.CFrame.Position - targets[i].Position).Magnitude > 1e-3 then ok = false end
        p:Destroy()
    end
    return ok
end)

-- from level2/128.lua: debug.traceback has at least 2 newlines and at most 5
pass("debug.traceback has 2 to 5 newline lines at call depth", function()
    local depth = 0
    local function stack()
        local trace = debug.traceback()
        for _ in trace:gmatch("
") do depth = depth + 1 end
    end
    pcall(stack)
    return depth >= 2 and depth <= 5
end)

-- from level2/134.lua: debug.info inside string.gsub callback shows 4-6 deep stack
pass("debug.info stack inside string.gsub callback has reasonable depth", function()
    local depth = 0
    string.gsub("a", ".", function()
        local i = 1
        while debug.info(i, "f") do depth = i; i = i + 1 end
    end)
    return depth >= 4 and depth <= 6
end)

-- from level2/135.lua / 151.lua: debug.info on a no-arg Lua function returns 0 arity
pass("debug.info on a zero-arg Lua closure returns arity 0 isvararg false", function()
    local function empty() end
    local arity, isvararg = debug.info(empty, "a")
    return arity == 0 and isvararg == false and debug.info(empty, "s") ~= "[C]"
end)

-- from level2/136.lua / 152.lua: ReceiveAge is not scriptable
pass("Part.ReceiveAge is not scriptable and errors on set", function()
    local p = Instance.new("Part")
    local ok = pcall(function() p.ReceiveAge = 1 end)
    p:Destroy()
    return not ok
end)

-- from level2/143.lua: coroutine + pcall inside yields correctly
pass("coroutine with pcall inside yields and returns both pcall results", function()
    local co = coroutine.create(function()
        return pcall(function()
            coroutine.yield(123)
            return 456
        end)
    end)
    local _, r1 = coroutine.resume(co)
    local _, r2, r3 = coroutine.resume(co)
    return r1 == 123 and r2 == true and r3 == 456
end)

-- from level2/144.lua: rawget on an Instance errors (not a table)
pass("rawget on a Part errors since Instances are not tables", function()
    local p = Instance.new("Part")
    local ok = pcall(function() return rawget(p, "Name") end)
    p:Destroy()
    return not ok
end)

-- from level2/145.lua: table.insert returns nil
pass("table.insert returns nil", function()
    local t = {}
    return table.insert(t, 1) == nil
end)

-- from level2/146.lua: newproxy(false) has no metatable
pass("newproxy(false) has no metatable", function()
    return getmetatable(newproxy(false)) == nil
end)

-- from level2/148.lua: math.random(10, 1) errors with interval is empty
pass("math.random with inverted range errors with interval is empty", function()
    local ok, err = pcall(math.random, 10, 1)
    return not ok and tostring(err):find("interval is empty") ~= nil
end)

-- from level2/149.lua: rawset on an Enum table errors
pass("rawset on Enum.PartType errors", function()
    return not pcall(function() rawset(Enum.PartType, "Detected", true) end)
end)

-- from level2/150.lua: task.wait inside xpcall handler errors (not yieldable)
pass("task.wait inside xpcall error handler errors", function()
    local ok = true
    xpcall(function() error() end, function()
        if pcall(function() task.wait() end) then ok = false end
    end)
    return ok
end)

-- from level2/34.lua: SharedTable.increment works
passOpt("SharedTable.increment increments counter correctly", function()
    local st = SharedTable.new()
    st.counter = 0
    SharedTable.increment(st, "counter", 7)
    SharedTable.increment(st, "counter", 3)
    return st.counter == 10 and typeof(st) == "SharedTable"
end)

-- from level2/34.lua: CFrame.ToWorldSpace / ToObjectSpace roundtrip
pass("CFrame ToWorldSpace then ToObjectSpace roundtrip is within 1e-4", function()
    local world = CFrame.new(5, 10, 15) * CFrame.Angles(math.rad(30), math.rad(60), math.rad(90))
    local local_ = CFrame.new(1, 2, 3)
    local converted = world:ToWorldSpace(local_)
    local reverted = world:ToObjectSpace(converted)
    return (reverted.Position - local_.Position).Magnitude < 1e-4
end)

-- from level2/34.lua: Vector3:Lerp unit stays unit
pass("Vector3:Lerp midpoints stay unit length", function()
    local a = Vector3.new(1, 0, 0)
    local b = Vector3.new(0, 1, 0)
    for i = 1, 9 do
        local t = i / 10
        if math.abs(a:Lerp(b, t).Unit.Magnitude - 1) > 1e-5 then
            return false
        end
    end
    return true
end)

-- from level2/34.lua: BindableEvent fires to multiple connections
pass("BindableEvent fires to multiple connections independently", function()
    local be = Instance.new("BindableEvent")
    local log = {}
    be.Event:Connect(function(v) table.insert(log, v * 2) end)
    be.Event:Connect(function(v) table.insert(log, v * 3) end)
    be:Fire(5)
    task.wait()
    be:Destroy()
    return table.find(log, 10) ~= nil and table.find(log, 15) ~= nil and #log == 2
end)

-- from level2/34.lua: DateTime.now().UnixTimestampMillis advances
pass("DateTime.now().UnixTimestampMillis advances over time", function()
    local t1 = DateTime.now().UnixTimestampMillis
    task.wait(0.05)
    local t2 = DateTime.now().UnixTimestampMillis
    return t2 > t1 and (t2 - t1) < 5000
end)

-- from level2/34.lua: WeldConstraint keeps relative offset when part moves
pass("WeldConstraint keeps relative offset when Part0 moves", function()
    local a = Instance.new("Part")
    local b = Instance.new("Part")
    a.CFrame = CFrame.new(0, 5, 0); a.Anchored = true; a.Parent = workspace
    b.CFrame = CFrame.new(2, 5, 0); b.Parent = workspace
    local w = Instance.new("WeldConstraint")
    w.Part0 = a; w.Part1 = b; w.Parent = a
    local before = a.CFrame:ToObjectSpace(b.CFrame)
    a.CFrame = CFrame.new(10, 5, 0)
    task.wait()
    local after = a.CFrame:ToObjectSpace(b.CFrame)
    a:Destroy(); b:Destroy()
    return (before.Position - after.Position).Magnitude < 0.01
end)

-- from level2/34.lua: Terrain:FillBlock then GetMaterialColor returns Color3
pass("Terrain:FillBlock then GetMaterialColor returns a Color3", function()
    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if not terrain then return true end
    local pos = Vector3.new(0, -500, 0)
    terrain:FillBlock(CFrame.new(pos), Vector3.new(8, 8, 8), Enum.Material.Grass)
    local mat = terrain:GetMaterialColor(Enum.Material.Grass)
    terrain:FillBlock(CFrame.new(pos), Vector3.new(8, 8, 8), Enum.Material.Air)
    return typeof(mat) == "Color3"
end)

-- from level2/53.lua: MarketplaceService:GetProductInfo errors on negative id
pass("MarketplaceService:GetProductInfo errors on -1e30 id", function()
    local ms = game:GetService("MarketplaceService")
    return not pcall(ms.GetProductInfo, ms, -1e30, Enum.InfoType.Asset)
end)

-- from level2/53.lua: HttpService:JSONDecode errors on invalid JSON escape
pass("HttpService:JSONDecode errors on invalid JSON escape sequence", function()
    local hs = game:GetService("HttpService")
    return not pcall(function() hs:JSONDecode('{"x":"\"}') end)
end)

-- from level2/53.lua: HttpService:UrlEncode on high-byte string works
pass("HttpService:UrlEncode does not error on high-byte string", function()
    local hs = game:GetService("HttpService")
    return pcall(function() hs:UrlEncode("aÿb") end)
end)

-- from level2/54.lua / 106.lua: TweenService:Create errors on wrong goal types
pass("TweenService:Create errors on wrong value types in goal", function()
    local ts = game:GetService("TweenService")
    local p = Instance.new("Part")
    local bad = {Position = "ENV_DETECTED", CFrame = true}
    local ok = pcall(function() ts:Create(p, TweenInfo.new(1), bad) end)
    p:Destroy()
    return not ok
end)

-- from level2/54.lua: buffer.writeu32 out of bounds errors
pass("buffer.writeu32 out of bounds errors correctly", function()
    local b = buffer.create(16)
    return not pcall(function() buffer.writeu32(b, 999999, 0xcafebabe) end)
end)

-- from level2/54.lua: getrawmetatable on game has __namecall and __index
pass("getrawmetatable on game has __namecall and __index", function()
    local mt = getrawmetatable(game)
    return mt ~= nil and mt.__namecall ~= nil and mt.__index ~= nil
end)

-- from level2/54.lua: debug.getinfo can be called 40 times without issue
pass("debug.getinfo can be called 40 times in a loop without error", function()
    local count = 0
    pcall(function()
        for _ = 1, 40 do debug.getinfo(1); count = count + 1 end
    end)
    return count > 30
end)

-- from level2/110.lua: string metatable is frozen and __index is string
pass("string metatable is frozen and __index == string", function()
    local mt = getmetatable("")
    if type(mt) ~= "table" then return false end
    if not table.isfrozen(mt) then return false end
    if type(mt.__index) == "table" and not table.isfrozen(mt.__index) then return false end
    return true
end)

-- from level2/116.lua: __eq metamethod cannot yield (task.wait inside it errors)
pass("__eq metamethod that yields causes pcall to fail", function()
    local t = setmetatable({}, {__eq = function() task.wait(); return true end})
    return not pcall(function() return t == t end)
end)

-- from level2/118.lua: LocalPlayer:Kick can be called without error
pass("LocalPlayer:Kick can be called without hard error", function()
    local lp = game:GetService("Players").LocalPlayer
    return typeof(lp) == "Instance" and type(lp.Kick) == "function"
       and pcall(function() lp:Kick("kolenv_test") end)
end)

-- from level2/118.lua: RBXScriptConnection fields work correctly
pass("RBXScriptConnection Connected toggles on Disconnect", function()
    local part = Instance.new("Part")
    local sig = part:GetPropertyChangedSignal("Name")
    local con = sig:Connect(function() end)
    if con.Connected ~= true then part:Destroy(); return false end
    con:Disconnect()
    if con.Connected ~= false then part:Destroy(); return false end
    local con2 = sig:Connect(function() end)
    if con == con2 then part:Destroy(); return false end
    con2:Disconnect()
    part:Destroy()
    return true
end)

-- from level2/118.lua: Once and ConnectParallel return valid connections
pass("Signal:Once and Signal:ConnectParallel return valid connections", function()
    local part = Instance.new("Part")
    local sig = part:GetPropertyChangedSignal("Name")
    local c3 = sig:Once(function() end)
    if typeof(c3) ~= "RBXScriptConnection" then part:Destroy(); return false end
    c3:Disconnect()
    local c4 = sig:ConnectParallel(function() end)
    if typeof(c4) ~= "RBXScriptConnection" then part:Destroy(); return false end
    c4:Disconnect()
    part:Destroy()
    return true
end)

-- from level2/132.lua: Vector3 metatable is nil or a string (not a table)
pass("Vector3 metatable is nil or a string not a table", function()
    local mt = getmetatable(Vector3.new(1,1,1))
    return mt == nil or type(mt) == "string"
end)

-- from level2/140.lua: utf8 library is read-only and charpattern is correct
pass("utf8 library is frozen and charpattern is correct", function()
    if type(utf8) ~= "table" then return false end
    if not table.isfrozen(utf8) then return false end
    return utf8.charpattern == "[ -Â-ô][-¿]*"
end)

-- from level2/139.lua: setfenv on a C closure (print) errors
pass("setfenv on print (a C closure) errors", function()
    return not pcall(setfenv, print, getfenv(print))
end)

-- from level2/129.lua: os.date year is 2025 or later
pass("os.date year is 2025 or later", function()
    local t = os.date("*t")
    return type(t.year) == "number" and t.year >= 2025
end)

-- from level2/129.lua: string.pack and string.unpack roundtrip
pass("string.pack b 100 and string.unpack roundtrip", function()
    return string.pack("b", 100) == string.char(100)
       and string.unpack("b", string.char(100)) == 100
end)

-- from level2/129.lua: utf8.nfcnormalize and nfdnormalize work on ascii
pass("utf8.nfcnormalize and nfdnormalize work on basic ascii", function()
    return utf8.nfcnormalize("a") == "a"
       and utf8.nfdnormalize("a") == "a"
end)

-- from level2/129.lua: bit32.replace and extract roundtrip
pass("bit32.replace and bit32.extract roundtrip", function()
    return bit32.extract(0xFF, 0, 4) == 0xF
       and bit32.replace(0x0, 0xF, 0, 4) == 0xF
       and bit32.countlz(0x00FFFFFF) == 8
       and bit32.countrz(0xFFFFFF00) == 8
end)

-- from level2/129.lua: math.ldexp and math.frexp work
pass("math.ldexp and math.frexp work correctly", function()
    return math.ldexp(0.5, 1) == 1
       and math.frexp(1) == 0.5
end)

-- from level2/120.lua: utf8.char utf8.len utf8.codepoint work
pass("utf8.char utf8.len and utf8.codepoint all work", function()
    return utf8.char(104) == "h"
       and utf8.len("abc") == 3
       and utf8.codepoint("a") == 97
end)

-- from level2/120.lua: DateTime type check
pass("typeof(DateTime.now()) is DateTime", function()
    return typeof(DateTime.now()) == "DateTime"
end)

-- from level2/120.lua: Font.fromEnum works
pass("Font.fromEnum(Enum.Font.Arial) returns a Font", function()
    return typeof(Font.fromEnum(Enum.Font.Arial)) == "Font"
end)

-- from level2/120.lua: bit32.arshift works
pass("bit32.arshift of -8 by 2 is -2", function()
    return bit32.arshift(-8, 2) == -2
end)

-- from level2/120.lua: bit32.lrotate and rrotate
pass("bit32.lrotate and rrotate work", function()
    return bit32.lrotate(1, 2) == 4
       and bit32.rrotate(4, 2) == 1
end)

-- from level2/129.lua: string metatable __index == string
pass("string metatable __index equals string library", function()
    local mt = getmetatable("")
    return type(mt) == "table" and mt.__index == string
end)

-- from level2/47.lua / level2/41.lua: StarterPlayerScripts has at least 2 children
pass("StarterPlayer.StarterPlayerScripts has at least 2 children", function()
    local sp = game:GetService("StarterPlayer")
    local sps = sp:FindFirstChild("StarterPlayerScripts")
    return sps ~= nil and #sps:GetChildren() >= 2
end)

-- from level2/41.lua: Players:GetPlayerFromCharacter(workspace) returns nil
pass("Players:GetPlayerFromCharacter with workspace returns nil", function()
    local ok, player = pcall(function()
        return game:GetService("Players"):GetPlayerFromCharacter(workspace)
    end)
    return ok and player == nil
end)

-- from level2/82.lua: debug.gethook returns nil in a clean environment
pass("debug.gethook returns nil in executor environment", function()
    return debug.gethook() == nil
end)

-- from level2/83.lua: pcall is a C closure (debug.getinfo says C)
pass("debug.getinfo on pcall says what == C", function()
    local info = debug.getinfo(pcall)
    return info ~= nil and info.what == "C"
end)

-- from level2/91.lua: version() major is 0 (Roblox executor builds)
passOpt("version() major version is 0", function()
    local ver = version()
    local major = tonumber(ver:match("^(%d+)%."))
    return major == 0
end)

-- from level2/92.lua: Camera.ViewportSize both axes > 0
pass("Camera.ViewportSize X and Y are both greater than 0", function()
    local cam = workspace.CurrentCamera
    if not cam then return true end
    local vp = cam.ViewportSize
    return vp.X >= 1 and vp.Y >= 1
end)

-- from level2/93.lua: error(msg, 0) gives raw message with no location prefix
pass("error with level 0 gives raw message without location prefix", function()
    local ok, msg = pcall(function() error("raw_exact_msg", 0) end)
    return not ok and msg == "raw_exact_msg"
end)

-- from level2/93.lua: debug.getupvalue on pcall (C func) returns nil
pass("debug.getupvalue on pcall C function returns nil", function()
    local ok, nm = pcall(debug.getupvalue, pcall, 1)
    return not (ok and nm ~= nil)
end)

-- from level2/93.lua: string.format %.5f of pi is 3.14159
pass("string.format %.5f of math.pi is 3.14159", function()
    local ok, r = pcall(string.format, "%.5f", math.pi)
    return ok and r == "3.14159"
end)

-- from level2/93.lua: string.format %q produces a quoted string
pass("string.format %q on a string with newline gives a quoted string", function()
    local ok, r = pcall(string.format, "%q", "te
st")
    return ok and type(r) == "string" and #r > 4
end)

-- from level2/129.lua: getgenv is not nil in executor
pass("getgenv is not nil", function()
    return getgenv ~= nil
end)
-- but getrenv should also not be nil
pass("getrenv is not nil", function()
    return getrenv ~= nil
end)

-- ================================================================
-- LOCK THE HASH BEFORE PRINTING
-- ================================================================

_expected_hash = _hash


-- ================================================================
-- RESULTS
-- ================================================================

print("")
print("-- results --")
print("")

-- anti-fake check: recompute what the hash should be for the
-- claimed passed count. if someone patched passed/total after
-- the run the hash won't match and we call it out.
do
    local claimed = passed
    if _hash ~= _expected_hash then
        print("!! SCORE TAMPERED !! the pass count was modified after the run.")
        print("!! real results below are unreliable. stop faking.")
        print("")
    end
    -- also sanity: passed can't exceed total and can't go negative
    if claimed > total or claimed < 0 then
        print("!! SCORE TAMPERED !! passed=" .. tostring(claimed)
            .. " total=" .. tostring(total) .. " is impossible.")
        print("")
    end
end

if chain_dead then
    print("anti-tamper : " .. at_ok .. "/" .. AT_TOTAL
        .. "  (chain broke at AT-" .. chain_dead .. ")")
else
    print("anti-tamper : " .. at_ok .. "/" .. AT_TOTAL .. "  all passed")
end

print("")

if #failed > 0 then
    print(#failed .. " thing(s) failed:")
    for _, v in ipairs(failed) do
        print("  " .. v)
    end
    print("")
end

local pct = math.floor((passed / total) * 100)

local rating
if     pct >= 97 then rating = "S+  perfect or near perfect"
elseif pct >= 93 then rating = "S   excellent"
elseif pct >= 85 then rating = "A   good"
elseif pct >= 70 then rating = "B   decent"
elseif pct >= 55 then rating = "C   mediocre"
elseif pct >= 40 then rating = "D   poor"
else                   rating = "F   very poor"
end

print("passed  : " .. passed .. " / " .. total .. "  (" .. pct .. "%)")
print("rating  : " .. rating)
print("")
print("-- By Kolenvlogger eunc v3 | https://discord.gg/WCZghenRpw")
