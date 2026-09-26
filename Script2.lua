--[[
    RUNAWAYS // Script2.lua

    Standalone build carrying exactly three features extracted from Script.lua:
        1. God Mode
        2. Building teleport (dropdown ordered by BuildingId, lowest index first) + Teleport to End Gate
        3. NPC Kill Aura (always-on toggle) + Kill Range

    Everything else from Script.lua (auto farms, ESP, weapons, vehicles, shops,
    loot, refuel, entity teleports, rage aggro) is intentionally omitted.

    Self-contained: reads nothing from disk at runtime, so it runs in any
    executor. Uses its own env.RunawaysScript2 guard so it can coexist with
    Script.lua instead of fighting it for the same global.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

if not game:IsLoaded() then
    game.Loaded:Wait()
end

while not Players.LocalPlayer do
    task.wait()
end

local player = Players.LocalPlayer
local env = getgenv and getgenv() or _G

if env.RunawaysScript2 and type(env.RunawaysScript2.Unload) == "function" then
    pcall(function()
        env.RunawaysScript2:Unload()
    end)
end

local function getGlobal(name)
    local value = env[name]

    if value == nil then
        value = _G[name]
    end

    return value
end

local function httpGet(url)
    local requestFn = getGlobal("request")
    local httpRequestFn = getGlobal("http_request")
    local synLib = getGlobal("syn")
    local attempts = {
        function()
            return game:HttpGet(url)
        end,
        function()
            return requestFn({ Url = url, Method = "GET" })
        end,
        function()
            return httpRequestFn(url)
        end,
        function()
            return synLib.request({ Url = url, Method = "GET" })
        end,
    }

    for _, attempt in ipairs(attempts) do
        local ok, value = pcall(attempt)

        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end

    return nil
end

local flowInstance = ReplicatedStorage:FindFirstChild("FlowClient")
    or ReplicatedStorage:WaitForChild("FlowClient", 10)
local flowOk, flowModule = false, nil

if flowInstance then
    flowOk, flowModule = pcall(require, flowInstance)
end

local flow = flowOk and type(flowModule) == "table" and flowModule or {}

print("[Script2] FlowClient: " .. (flowOk and "loaded" or "UNAVAILABLE (kill aura disabled)"))

local repo = "https://raw.githubusercontent.com/Ali-lov3/Obsidian-UiLibs/refs/heads/main/"
local telegram = httpGet("https://raw.githubusercontent.com/Bac0nHck/Something/refs/heads/main/telegram")
    or "discord.gg/runaways"
telegram = tostring(telegram):match("^%s*(.-)%s*$")

local source = httpGet(repo .. "Library.lua")

if type(source) ~= "string" then
    error("[Script2] Could not download Library.lua - this executor exposes no working HTTP method.", 0)
end

print("[Script2] Library.lua downloaded (" .. #source .. " bytes)")

local target = "            table.clear(Buttons)\n            if Info.Multi then"
local replacement = [[            table.clear(Buttons)
            if MenuTable and MenuTable.Menu then
                for _, child in MenuTable.Menu:GetChildren() do
                    if not child:IsA("UIListLayout") then
                        child:Destroy()
                    end
                end
            end
            if Info.Multi then]]
local first, last = source:find(target, 1, true)

if first then
    source = source:sub(1, first - 1) .. replacement .. source:sub(last + 1)
end

local okLibrary, library = pcall(loadstring(source))

if not okLibrary or type(library) ~= "table" then
    error("[Script2] Library.lua failed to execute: " .. tostring(library), 0)
end

print("[Script2] library initialised")

local themeSource = httpGet(repo .. "addons/ThemeManager.lua")
local saveSource = httpGet(repo .. "addons/SaveManager.lua")

if type(themeSource) ~= "string" or type(saveSource) ~= "string" then
    error("[Script2] Could not download the ThemeManager/SaveManager addons.", 0)
end

local okTheme, ThemeManager = pcall(loadstring(themeSource))
local okSave, SaveManager = pcall(loadstring(saveSource))

if not okTheme or type(ThemeManager) ~= "table" or not okSave or type(SaveManager) ~= "table" then
    error("[Script2] ThemeManager/SaveManager failed to execute.", 0)
end

print("[Script2] addons loaded")

source = nil
themeSource = nil
saveSource = nil

local options = library.Options
local toggles = library.Toggles

env.RunawaysScript2 = library

local function notify(text, duration)
    if library.Unloaded then
        return
    end

    pcall(function()
        library:Notify({
            Title = "RUNAWAYS",
            Description = tostring(text),
            Time = duration or 4,
        })
    end)
end

local function formatName(name)
    return (name:gsub("(%l)(%u)", "%1 %2"))
end

local humanoidStates = setmetatable({}, { __mode = "k" })
local originalTakeDamage = flow.PlayerDamage and flow.PlayerDamage.TakeDamage
local originalAbandon = flow.Passout and flow.Passout.Abandon
local blockedRemote = function() end
local playerStepConnection
local killAuraToken

local function getHumanoid()
    local character = player.Character

    return character and character:FindFirstChildOfClass("Humanoid")
end

local function getCurrentVehicle()
    local humanoid = getHumanoid()
    local seat = humanoid and humanoid.SeatPart

    if not seat or not seat:IsA("VehicleSeat") or seat.Occupant ~= humanoid then
        return
    end

    local vehicle = seat:FindFirstAncestorOfClass("Model")

    if not vehicle or not vehicle:FindFirstChild("VehicleProperty") or not vehicle:FindFirstChild("system") then
        return
    end

    return vehicle
end

local function getVehicleChassis(vehicle)
    local system = vehicle and vehicle:FindFirstChild("system")

    return system and system:FindFirstChild("chassis")
end

local function getVehicleSeat(vehicle)
    local system = vehicle and vehicle:FindFirstChild("system")
    local seats = system and system:FindFirstChild("seats")

    return seats and seats:FindFirstChildWhichIsA("VehicleSeat")
end

local function killAllNPCs(radius)
    local folder = workspace:FindFirstChild("NPCs")

    if not folder or not flow.NPCs or type(flow.NPCs.Damage) ~= "function" then
        return 0
    end

    local character = player.Character
    local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
    local killed = 0

    for _, humanoid in folder:QueryDescendants("Humanoid") do
        local npc = humanoid:FindFirstAncestorWhichIsA("Model")
        local npcRoot = npc and npc:FindFirstChild("HumanoidRootPart")
        local inRange = not radius or playerRoot and npcRoot and (npcRoot.Position - playerRoot.Position).Magnitude <= radius

        if humanoid.Health > 0 and inRange then
            local ok = pcall(flow.NPCs.Damage, humanoid, humanoid.Health + 1)

            if ok then
                killed += 1
            end
        end
    end

    return killed
end

local teleports = {
    Maps = {},
    Signatures = {},
    Ids = setmetatable({}, { __mode = "k" }),
    NextId = 0,
    LastPosition = nil,
    OptionIds = {
        Buildings = "RunawaysTeleportBuilding",
    },
}
library.Teleports = teleports

function teleports:GetId(instance)
    local id = self.Ids[instance]

    if not id then
        self.NextId += 1
        id = self.NextId
        self.Ids[instance] = id
    end

    return id
end

function teleports:Refresh(force)
    local entries = {}
    local map = workspace:FindFirstChild("Map")
    local buildings = map and map:FindFirstChild("Buildings")

    if buildings then
        for _, building in buildings:GetChildren() do
            local id = building:GetAttribute("BuildingId")
            local name = building.Name:lower()

            if building:IsA("Model") and not name:find("sign", 1, true) then
                local generatedId = self:GetId(building)

                entries[#entries + 1] = {
                    Instance = building,
                    Label = id ~= nil
                        and formatName(building.Name) .. " #" .. tostring(id)
                        or formatName(building.Name) .. " (Landmark #" .. generatedId .. ")",
                    Order = tonumber(id) or 1000000000 + generatedId,
                }
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.Order == b.Order then
            return a.Label < b.Label
        end

        return a.Order < b.Order
    end)

    local values = { "None" }
    local targets = {}

    for _, entry in entries do
        values[#values + 1] = entry.Label
        targets[entry.Label] = entry.Instance
    end

    self.Maps.Buildings = targets

    local signature = table.concat(values, "\0")
    local option = options[self.OptionIds.Buildings]

    if option then
        local current = option.Value

        if force or self.Signatures.Buildings ~= signature then
            option:SetValues(values)
            option:SetValue(targets[current] and current or "None")
        elseif current ~= "None" and not targets[current] then
            option:SetValue("None")
        end
    end

    self.Signatures.Buildings = signature
end

function teleports:GetSelected(kind)
    local option = options[self.OptionIds[kind]]
    local targets = self.Maps[kind]
    local target = option and targets and targets[option.Value]

    if not target or not target.Parent then
        notify("Select an available target.")
        return
    end

    return target
end

function teleports:GetBuildingSurface(building)
    local best
    local bestScore = -math.huge

    for _, part in building:GetDescendants() do
        if part:IsA("BasePart") and part.CanCollide and part.Transparency < 0.95 then
            local name = part.Name:lower()

            if name == "road" or name == "floor" then
                local score = part.Size.X * part.Size.Z

                if name == "road" then
                    score += 1000000000
                end

                if score > bestScore then
                    best = part
                    bestScore = score
                end
            end
        end
    end

    return best
end

function teleports:Stream(position)
    pcall(function()
        player:RequestStreamAroundAsync(position, 5)
    end)
end

function teleports:GetDestination(kind, target)
    if not target:IsDescendantOf(workspace) then
        return
    end

    if kind == "Buildings" then
        local surface = self:GetBuildingSurface(target)
        local anchor

        if not surface then
            local ok, pivot = pcall(target.GetPivot, target)

            if ok then
                anchor = pivot
                self:Stream(pivot.Position)
            end

            local expires = os.clock() + 4

            repeat
                task.wait(0.15)
                surface = self:GetBuildingSurface(target)
            until surface or not target.Parent or library.Unloaded or os.clock() >= expires
        end

        if not surface then
            if anchor and target.Parent then
                return CFrame.new(anchor.Position + Vector3.yAxis * 8) * anchor.Rotation
            end

            return
        end

        local position = surface.Position + Vector3.yAxis * (surface.Size.Y * 0.5 + 4)
        local look = Vector3.new(surface.CFrame.LookVector.X, 0, surface.CFrame.LookVector.Z)

        if look.Magnitude < 0.1 then
            look = Vector3.new(0, 0, -1)
        end

        return CFrame.lookAt(position, position + look.Unit, Vector3.yAxis)
    end

    return
end

function teleports:GetRoadNear(z)
    local map = workspace:FindFirstChild("Map")

    if not map then
        return
    end

    local best
    local bestDistance = math.huge
    local bestArea = 0

    for _, part in map:GetDescendants() do
        local name = part.Name:lower()
        local parentName = part.Parent and part.Parent.Name:lower()

        if part:IsA("BasePart")
            and (name == "road" or name == "sideroad" or parentName == "road")
            and not name:find("pathfinding", 1, true)
            and part.CanCollide
            and part.Transparency < 0.95
        then
            local distance = math.max(math.abs(part.Position.Z - z) - math.max(part.Size.X, part.Size.Z) * 0.5, 0)
            local area = part.Size.X * part.Size.Z

            if distance < bestDistance or distance == bestDistance and area > bestArea then
                best = part
                bestDistance = distance
                bestArea = area
            end
        end
    end

    if bestDistance <= 2000 then
        return best
    end

    return
end

function teleports:GetEndPrompt()
    local map = workspace:FindFirstChild("Map")
    local buildings = map and map:FindFirstChild("Buildings")
    local customs = buildings and buildings:FindFirstChild("CustomsFinal")

    if not customs then
        return
    end

    local customsBuilding = customs:FindFirstChild("CustomsBuilding")
    local finalDoor = customsBuilding and customsBuilding:FindFirstChild("FinalDoor")
    local command = finalDoor and finalDoor:FindFirstChild("Command")
    local commandButton = command and command:FindFirstChild("CommandButton")
    local holder = commandButton and commandButton:FindFirstChild("Prompt")
    local prompt = holder and (holder:IsA("ProximityPrompt") and holder or holder:FindFirstChildOfClass("ProximityPrompt"))

    if prompt then
        return prompt
    end

    local ok, candidates = pcall(customs.QueryDescendants, customs, "ProximityPrompt")

    if ok then
        for _, candidate in candidates do
            if candidate.ActionText == "Activate" and candidate:FindFirstAncestor("FinalDoor") then
                return candidate
            end
        end
    end

    return
end

function teleports:GetEndAnchor(endZ, direction)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local source = root and root.Position or Vector3.new(500, 2000, endZ)
    local map = workspace:FindFirstChild("Map")
    local buildings = map and map:FindFirstChild("Buildings")
    local best = source
    local bestDistance = math.huge

    if buildings then
        for _, building in buildings:GetChildren() do
            if building:IsA("Model") then
                local ok, pivot = pcall(building.GetPivot, building)

                if ok then
                    if building.Name == "CustomsFinal" then
                        return pivot:PointToWorldSpace(Vector3.new(-44.4001, 4.65, -16.5))
                    end

                    local distance = math.abs(endZ - pivot.Position.Z)
                    local side = (endZ - pivot.Position.Z) * direction

                    if side >= -500 and distance < bestDistance then
                        best = pivot.Position
                        bestDistance = distance
                    end
                end
            end
        end
    end

    return Vector3.new(best.X, best.Y + 30, endZ - direction * 35)
end

function teleports:GetEndPromptDestination(prompt, direction)
    local holder = prompt and prompt.Parent
    local holderCFrame

    if holder and holder:IsA("Attachment") then
        holderCFrame = holder.WorldCFrame
    elseif holder and holder:IsA("BasePart") then
        holderCFrame = holder.CFrame
    end

    if not holderCFrame then
        return
    end

    local outward = holderCFrame.LookVector

    if outward.Z * direction > 0 then
        outward = -outward
    end

    if math.abs(outward.Z) < 0.25 then
        outward = Vector3.new(0, 0, -direction)
    end

    local position = holderCFrame.Position + outward * 4
    local params = RaycastParams.new()

    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = player.Character and { player.Character } or {}

    local result = workspace:Raycast(
        position + Vector3.yAxis * 20,
        Vector3.new(0, -60, 0),
        params
    )

    if result then
        position = Vector3.new(position.X, result.Position.Y + 3.25, position.Z)
    end

    return CFrame.lookAt(
        position,
        Vector3.new(holderCFrame.Position.X, position.Y, holderCFrame.Position.Z),
        Vector3.yAxis
    )
end

function teleports:ParkEndVehicle(vehicle, endZ, direction)
    local chassis = getVehicleChassis(vehicle)

    if not chassis or not vehicle.Parent then
        return
    end

    local road = self:GetRoadNear(endZ)
    local position

    if road then
        position = Vector3.new(
            road.Position.X,
            road.Position.Y + road.Size.Y * 0.5 + 4.5,
            endZ - direction * 28
        )
    else
        local map = workspace:FindFirstChild("Map")
        local buildings = map and map:FindFirstChild("Buildings")
        local customs = buildings and buildings:FindFirstChild("CustomsFinal")
        local ok
        local pivot

        if customs then
            ok, pivot = pcall(customs.GetPivot, customs)
        end

        if ok then
            position = Vector3.new(pivot.Position.X, pivot.Position.Y + 5, endZ - direction * 28)
        end
    end

    if not position then
        return
    end

    local look = Vector3.new(chassis.CFrame.LookVector.X, 0, chassis.CFrame.LookVector.Z)

    if look.Magnitude < 0.1 then
        look = Vector3.new(0, 0, direction)
    end

    self:Move(CFrame.lookAt(position, position + look.Unit, Vector3.yAxis), vehicle, false)
end

function teleports:Move(destination, subject, saveLast)
    if typeof(destination) ~= "CFrame" then
        return false
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not character or not humanoid or not root or humanoid.Health <= 0 then
        notify("Character is unavailable.")
        return false
    end

    subject = subject or character

    local mover = subject == character and root or getVehicleChassis(subject)

    if not mover or not subject.Parent then
        notify("Teleport target is unavailable.")
        return false
    end

    local oldLast = self.LastPosition

    if saveLast ~= false then
        self.LastPosition = root.CFrame
    end

    local camera = workspace.CurrentCamera
    local cameraCFrame = camera and camera.CFrame
    local cameraSubject = camera and camera.CameraSubject
    local cameraType = camera and camera.CameraType

    if camera then
        camera.CameraType = Enum.CameraType.Scriptable
        camera.CFrame = cameraCFrame
    end

    local ok, message = pcall(function()
        if subject == character and humanoid.SeatPart then
            humanoid.Sit = false
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            RunService.Heartbeat:Wait()
        end

        subject:PivotTo(destination * mover.CFrame:Inverse() * subject:GetPivot())
        mover.AssemblyLinearVelocity = Vector3.zero
        mover.AssemblyAngularVelocity = Vector3.zero
        RunService.Heartbeat:Wait()
    end)

    if camera and camera.Parent then
        camera.CameraSubject = cameraSubject
        camera.CameraType = cameraType
        camera.CFrame = cameraCFrame
    end

    if not ok then
        self.LastPosition = oldLast
        notify("Teleport failed: " .. tostring(message))
        return false
    end

    return true
end

function teleports:Go(kind)
    local target = self:GetSelected(kind)

    if not target then
        return
    end

    task.spawn(function()
        local destination = self:GetDestination(kind, target)

        if not destination then
            notify("Target position is unavailable.")
            return
        end

        self:Move(destination)
    end)
end

function teleports:GetEndZ()
    local flowModule = ReplicatedStorage:FindFirstChild("FlowClient")
    local gui = flowModule and flowModule:FindFirstChild("Gui")
    local distanceModule = gui and gui:FindFirstChild("DistanceToBorderClient")

    if distanceModule then
        local ok, module = pcall(require, distanceModule)

        if ok and type(module) == "table" then
            local callback = module.SetEndPos_event or module.SetEndPos

            if type(callback) == "function" and debug and type(debug.getupvalues) == "function" then
                local read, upvalues = pcall(debug.getupvalues, callback)

                if read and type(upvalues) == "table" then
                    if type(upvalues[1]) == "number" then
                        return upvalues[1]
                    end

                    for _, value in upvalues do
                        if type(value) == "number" and math.abs(value) > 1000 then
                            return value
                        end
                    end
                end
            end
        end
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")

    if playerGui then
        for _, label in playerGui:GetDescendants() do
            if label:IsA("TextLabel") and label.Text:find("Mexico", 1, true) then
                local current = label.Parent

                while current and current ~= playerGui do
                    local value = tonumber(current.Name:match("^Border_(-?[%d%.]+)$"))

                    if value then
                        return value
                    end

                    current = current.Parent
                end
            end
        end
    end

    return
end

function teleports:GetStartCFrame()
    local spawn = workspace:FindFirstChildOfClass("SpawnLocation")

    if not spawn or not spawn.Enabled then
        return
    end

    local excludes = { spawn }

    if player.Character then
        excludes[#excludes + 1] = player.Character
    end

    local parameters = RaycastParams.new()

    parameters.FilterType = Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances = excludes
    parameters.RespectCanCollide = true

    local result = workspace:Raycast(spawn.Position + Vector3.yAxis * 6, -Vector3.yAxis * 20, parameters)
    local y = result and result.Position.Y + 3.5 or spawn.Position.Y + 3

    return CFrame.new(spawn.Position.X, y, spawn.Position.Z) * spawn.CFrame.Rotation
end

function teleports:ToEnd()
    task.spawn(function()
        if library.Unloaded then
            return
        end

        local endZ = self:GetEndZ()
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local vehicle = getCurrentVehicle()
        local mover = vehicle and getVehicleChassis(vehicle) or root

        if not endZ then
            notify("End position is unavailable.")
            return
        end

        if not humanoid or not mover or humanoid.Health <= 0 then
            notify("Character is unavailable.")
            return
        end

        local start = self:GetStartCFrame()
        local direction = (not start or endZ >= start.Position.Z) and 1 or -1
        local prompt = self:GetEndPrompt()

        if prompt then
            local destination = self:GetEndPromptDestination(prompt, direction)

            if destination then
                if vehicle then
                    self.LastPosition = root.CFrame
                    self:ParkEndVehicle(vehicle, endZ, direction)
                    self:Move(destination, nil, false)
                else
                    self:Move(destination)
                end

                return
            end
        end

        local position = self:GetEndAnchor(endZ, direction)

        self:Stream(position)
        prompt = self:GetEndPrompt()

        if prompt then
            local destination = self:GetEndPromptDestination(prompt, direction)

            if destination then
                if vehicle then
                    self.LastPosition = root.CFrame
                    self:ParkEndVehicle(vehicle, endZ, direction)
                    self:Move(destination, nil, false)
                else
                    self:Move(destination)
                end

                return
            end
        end

        local road = self:GetRoadNear(endZ)

        if road then
            position = Vector3.new(
                road.Position.X,
                road.Position.Y + road.Size.Y * 0.5 + 8,
                endZ - direction * 35
            )
        end

        local look = vehicle and Vector3.new(mover.CFrame.LookVector.X, 0, mover.CFrame.LookVector.Z)
            or Vector3.new(0, 0, direction)

        if look.Magnitude < 0.1 then
            look = Vector3.new(0, 0, direction)
        end

        if not self:Move(CFrame.lookAt(position, position + look.Unit, Vector3.yAxis), vehicle or character) then
            return
        end

        mover = vehicle and getVehicleChassis(vehicle) or character:FindFirstChild("HumanoidRootPart")

        local anchored = mover and mover.Anchored

        if mover then
            mover.Anchored = true
        end

        local waited, found = pcall(function()
            local expires = os.clock() + 12
            local loaded
            local refined = false

            repeat
                loaded = self:GetEndPrompt()

                if not loaded and not refined then
                    local map = workspace:FindFirstChild("Map")
                    local buildings = map and map:FindFirstChild("Buildings")
                    local customs = buildings and buildings:FindFirstChild("CustomsFinal")
                    local ok
                    local pivot

                    if customs then
                        ok, pivot = pcall(customs.GetPivot, customs)
                    end

                    if ok then
                        refined = true
                        self:Stream(pivot.Position)
                        loaded = self:GetEndPrompt()
                    end
                end

                if not loaded then
                    task.wait(0.2)
                end
            until loaded or not character.Parent or library.Unloaded or os.clock() >= expires

            return loaded
        end)

        if mover and mover.Parent then
            mover.Anchored = anchored
        end

        if waited then
            prompt = found
        end

        if prompt then
            local destination = self:GetEndPromptDestination(prompt, direction)

            if destination then
                if vehicle then
                    self:ParkEndVehicle(vehicle, endZ, direction)
                end

                self:Move(destination, nil, false)
                return
            end
        end

        road = self:GetRoadNear(endZ)

        if road then
            if vehicle then
                self:ParkEndVehicle(vehicle, endZ, direction)
            else
                position = Vector3.new(
                    road.Position.X,
                    road.Position.Y + road.Size.Y * 0.5 + 8,
                    endZ - direction * 20
                )
                self:Move(CFrame.lookAt(position, position + Vector3.new(0, 0, direction), Vector3.yAxis), nil, false)
            end

            return
        end

        if library.Unloaded then
            return
        end

        notify("End gate button is unavailable.")
    end)
end

local function getHumanoidState(humanoid)
    local state = humanoidStates[humanoid]

    if not state then
        state = {}
        humanoidStates[humanoid] = state
    end

    return state
end

local function blockDamage(value)
    if flow.PlayerDamage and type(originalTakeDamage) == "function" then
        if value then
            flow.PlayerDamage.TakeDamage = blockedRemote
        elseif flow.PlayerDamage.TakeDamage == blockedRemote then
            flow.PlayerDamage.TakeDamage = originalTakeDamage
        end
    end

    if flow.Passout and type(originalAbandon) == "function" then
        if value then
            flow.Passout.Abandon = blockedRemote
        elseif flow.Passout.Abandon == blockedRemote then
            flow.Passout.Abandon = originalAbandon
        end
    end
end

local function restoreGodMode()
    blockDamage(false)

    for humanoid, state in humanoidStates do
        local original = state.GodMode

        if original then
            if humanoid.Parent then
                humanoid.BreakJointsOnDeath = original.BreakJointsOnDeath
                humanoid.RequiresNeck = original.RequiresNeck
                humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, original.DeadEnabled)
            end

            state.GodMode = nil
        end
    end
end

local function applyGodMode(humanoid)
    local state = getHumanoidState(humanoid)

    if not state.GodMode then
        state.GodMode = {
            BreakJointsOnDeath = humanoid.BreakJointsOnDeath,
            RequiresNeck = humanoid.RequiresNeck,
            DeadEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Dead),
        }
    end

    blockDamage(true)
    humanoid.BreakJointsOnDeath = false
    humanoid.RequiresNeck = false
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
    humanoid.Health = humanoid.MaxHealth

    if humanoid:GetAttribute("Downed") == true then
        humanoid:SetAttribute("Downed", false)
        humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
    end
end

local function applyPlayerSettings()
    local humanoid = getHumanoid()

    if humanoid and toggles.RunawaysPlayerGodMode and toggles.RunawaysPlayerGodMode.Value then
        applyGodMode(humanoid)
    end
end

local actionBusy = false
local gameData
local gameDataLoaded = false

local function getGameData()
    if gameDataLoaded then
        return gameData
    end

    gameDataLoaded = true

    local instance = ReplicatedStorage:FindFirstChild("Data")

    if not instance then
        return nil
    end

    local ok, result = pcall(require, instance)

    gameData = ok and type(result) == "table" and result or nil

    return gameData
end

local function getLootFolder()
    return workspace:FindFirstChild("Loot")
end

local function hasTag(instance, tag)
    local ok, result = pcall(function()
        return instance:HasTag(tag)
    end)

    return ok and result == true
end

local lootData
local lootDataLoaded = false
local lootValueByName = {}
local lootCategoryByName = {}

local function getLootData()
    if lootDataLoaded then
        return lootData
    end

    lootDataLoaded = true

    local dataModule = ReplicatedStorage:FindFirstChild("Data")
    local lootModule = dataModule and dataModule:FindFirstChild("Loot")
    local listModule = lootModule and lootModule:FindFirstChild("Data")

    if not listModule then
        return nil
    end

    local ok, result = pcall(require, listModule)

    if not ok or type(result) ~= "table" then
        return nil
    end

    lootData = result

    for _, entry in ipairs(lootData) do
        if type(entry) == "table" and entry.Item then
            lootCategoryByName[entry.Item] = entry.Category
            lootValueByName[entry.Item] = tonumber(entry.Value) or 0
        end
    end

    return lootData
end

local function getLootValue(name)
    getLootData()

    return lootValueByName[name]
end

local function getToolCategory(tool)
    if hasTag(tool, "Backpack") then
        return "Backpack"
    end

    getLootData()

    return lootCategoryByName[tool.Name]
end

local function isSellable(name)
    local value = getLootValue(name)

    return value ~= nil and value > 0
end

local currencyCategories = {
    Cash = true,
    Currency = true,
    Money = true,
}

local function isCurrency(name)
    getLootData()

    return currencyCategories[lootCategoryByName[name]] == true
end

local function getCashAmount()
    local leaderstats = player:FindFirstChild("leaderstats")
    local cash = leaderstats and leaderstats:FindFirstChild("Cash \u{1F4B5}")

    if cash and (cash:IsA("NumberValue") or cash:IsA("IntValue")) then
        return cash.Value
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local hud = playerGui and playerGui:FindFirstChild("HudGui")
    local panel = hud and hud:FindFirstChild("BottomPanel")
    local frame = panel and panel:FindFirstChild("CashAmount")
    local label = frame and frame:FindFirstChild("CashAmount")
    local digits = label and label.Text:gsub("[^%d]", "")

    return digits and tonumber(digits)
end

local function isLoot(item, folder)
    if not folder or item.Parent ~= folder or not item:IsA("Model") then
        return false
    end

    local part = item.PrimaryPart

    if not (part and part:IsA("BasePart") and part.Parent == item) then
        return false
    end

    if CollectionService:HasTag(item, "BuyableLoot") then
        return false
    end

    return CollectionService:HasTag(item, "Draggable") and CollectionService:HasTag(item, "Equippable")
end

local function getLoot(folder)
    local items = {}

    if not folder then
        return items
    end

    for _, item in folder:GetChildren() do
        if isLoot(item, folder) and isSellable(item.Name) and not isCurrency(item.Name) then
            items[#items + 1] = item
        end
    end

    table.sort(items, function(a, b)
        return a.Name < b.Name
    end)

    return items
end

local function getBackpackUsage()
    local backpack = player:FindFirstChildOfClass("Backpack")
    local character = player.Character

    if not backpack then
        return
    end

    local used = #backpack:GetChildren()

    if character and character:FindFirstChildOfClass("Tool") then
        used += 1
    end

    local data = getGameData()
    local balance = data and data.Balance

    if not balance then
        return
    end

    local limits = {
        BackpackLarge = balance.MaxToolsLargeBackpack,
        BackpackMedium = balance.MaxToolsMediumBackpack,
        BackpackSmall = balance.MaxToolsSmallBackpack,
    }

    for _, name in { "BackpackLarge", "BackpackMedium", "BackpackSmall" } do
        if backpack:FindFirstChild(name) or character and character:FindFirstChild(name) then
            return used, limits[name]
        end
    end

    return used, balance.MaxTools
end

local function getPickupCFrame(root, part)
    local offset = root.Position - part.Position
    local direction = Vector3.new(offset.X, 0, offset.Z)

    direction = direction.Magnitude > 0.1 and direction.Unit or Vector3.new(0, 0, 1)

    local position = part.Position + direction * 3 + Vector3.new(0, 2.5, 0)
    return CFrame.lookAt(position, Vector3.new(part.Position.X, position.Y, part.Position.Z))
end

local function collect(onDone)
    if type(onDone) ~= "function" then
        onDone = nil
    end

    if actionBusy then
        notify("An inventory action is already running.", 3)

        if onDone then
            onDone({ ok = false, reason = "busy" })
        end

        return
    end

    if not (flow.Loot and type(flow.Loot.LootEquip) == "function") then
        notify("flow.Loot.LootEquip is unavailable - looting is disabled.", 8)

        if onDone then
            onDone({ ok = false, reason = "unavailable" })
        end

        return
    end

    if not getLootData() then
        notify("Loot price data is unavailable - nothing can be confirmed sellable.", 8)

        if onDone then
            onDone({ ok = false, reason = "noData" })
        end

        return
    end

    local folder = getLootFolder()

    if not folder then
        notify("workspace.Loot was not found.", 6)

        if onDone then
            onDone({ ok = false, reason = "noFolder" })
        end

        return
    end

    actionBusy = true

    task.spawn(function()
        local attempted = 0
        local looted = 0
        local failed = 0
        local full = false
        local used
        local limit
        local character
        local root
        local startPivot
        local camera
        local cameraCFrame
        local cameraSubject
        local cameraType

        local ok, message = pcall(function()
            character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            root = character and character:FindFirstChild("HumanoidRootPart")

            if not character or not humanoid or not root or humanoid.Health <= 0 then
                error("Character is not ready.", 0)
            end

            if humanoid.SeatPart then
                error("Exit the vehicle first.", 0)
            end

            used, limit = getBackpackUsage()

            if not used or not limit then
                error("Backpack is not ready.", 0)
            end

            for _, item in getLoot(folder) do
                if library.Unloaded then
                    break
                end

                if not isLoot(item, folder) then
                    continue
                end

                local currentUsed, currentLimit = getBackpackUsage()

                if not currentUsed or not currentLimit then
                    error("Backpack is not ready.", 0)
                end

                used = math.max(used, currentUsed)
                limit = currentLimit

                if used >= limit then
                    full = true
                    break
                end

                attempted += 1

                local part = item.PrimaryPart
                local far = (root.Position - part.Position).Magnitude > 6

                if far then
                    if not startPivot then
                        startPivot = character:GetPivot()
                        camera = workspace.CurrentCamera
                        cameraCFrame = camera and camera.CFrame
                        cameraSubject = camera and camera.CameraSubject
                        cameraType = camera and camera.CameraType

                        if camera then
                            camera.CameraType = Enum.CameraType.Scriptable
                            camera.CFrame = cameraCFrame
                        end
                    end

                    character:PivotTo(getPickupCFrame(root, part))
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                    task.wait(0.18)
                end

                local callOk, result = pcall(flow.Loot.LootEquip, part)

                if far and (not callOk or result ~= "Success") and isLoot(item, folder) then
                    task.wait(0.15)
                    callOk, result = pcall(flow.Loot.LootEquip, part)
                end

                if callOk and result == "Success" then
                    looted += 1
                    used += 1
                else
                    failed += 1
                end

                task.wait(0.08)
            end
        end)

        if startPivot and character and character.Parent and root and root.Parent == character then
            character:PivotTo(startPivot)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end

        if camera and camera.Parent then
            camera.CameraSubject = cameraSubject
            camera.CameraType = cameraType
            camera.CFrame = cameraCFrame
        end

        actionBusy = false

        local result = {
            ok = ok == true,
            reason = ok and "" or tostring(message),
            attempted = attempted,
            looted = looted,
            failed = failed,
            full = full,
            used = used,
            limit = limit,
            nothing = ok and not full and attempted == 0,
        }

        if not library.Unloaded then
            if not ok then
                notify("Loot failed: " .. tostring(message), 6)
            elseif full then
                notify(string.format("Inventory full: %d/%d. Looted: %d.", used, limit, looted), 6)
            elseif attempted == 0 then
                notify("Nothing to loot.")
            elseif failed == 0 then
                notify(string.format("Looted: %d.", looted))
            else
                notify(string.format("Looted: %d, failed: %d.", looted, failed), 6)
            end
        end

        if onDone then
            onDone(result)
        end
    end)
end

local function selectClosestPawnCounter(root)
    local tagged = CollectionService:GetTagged("PawnCounter")
    local origin = root and root.Position

    if not origin then
        return tagged[1]
    end

    local best
    local bestDistance = math.huge

    for _, counter in tagged do
        local volume = counter and counter:FindFirstChild("Volume", true)
        local bell = counter and counter:FindFirstChild("CallBell", true)
        local prompt = bell and bell:FindFirstChildWhichIsA("ProximityPrompt", true)

        if volume and prompt then
            local distance = (volume.Position - origin).Magnitude

            if distance < bestDistance then
                bestDistance = distance
                best = counter
            end
        end
    end

    return best or tagged[1]
end

local function sellAllLoot(onDone)
    if type(onDone) ~= "function" then
        onDone = nil
    end

    if actionBusy then
        notify("An inventory action is already running.", 3)

        if onDone then
            onDone({ ok = false, reason = "busy" })
        end

        return
    end

    if not (flow.Loot and type(flow.Loot.LootUnequip) == "function") then
        notify("flow.Loot.LootUnequip is unavailable - selling is disabled.", 8)

        if onDone then
            onDone({ ok = false, reason = "unavailable" })
        end

        return
    end

    if not getLootData() then
        notify("Loot price data is unavailable - nothing can be confirmed sellable.", 8)

        if onDone then
            onDone({ ok = false, reason = "noData" })
        end

        return
    end

    local firePrompt = getGlobal("fireproximityprompt")

    actionBusy = true

    task.spawn(function()
        local sold = 0
        local failed = 0
        local earned
        local character
        local root
        local startPivot
        local camera
        local cameraCFrame
        local cameraSubject
        local cameraType

        local ok, message = pcall(function()
            local backpack = player:FindFirstChildOfClass("Backpack")
            character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            root = character and character:FindFirstChild("HumanoidRootPart")
            local counter = selectClosestPawnCounter(root)
            local volume = counter and counter:FindFirstChild("Volume", true)
            local bell = counter and counter:FindFirstChild("CallBell", true)
            local prompt = bell and bell:FindFirstChildWhichIsA("ProximityPrompt", true)

            if not backpack or not character or not humanoid or not root or humanoid.Health <= 0 then
                error("Inventory is not ready.", 0)
            end

            if humanoid.SeatPart then
                error("Exit the vehicle first.", 0)
            end

            if not volume or not bell or not prompt then
                error("Pawn shop is not available.", 0)
            end

            if prompt.Enabled then
                error("Pawn counter is occupied.", 0)
            end

            local tools = {}

            for _, container in { backpack, character } do
                for _, tool in container:QueryDescendants("> Tool") do
                    local category = getToolCategory(tool)

                    if isSellable(tool.Name)
                        and not hasTag(tool, "Undroppable")
                        and category ~= "Backpack"
                    then
                        tools[#tools + 1] = tool
                    end
                end
            end

            if #tools == 0 then
                return
            end

            startPivot = character:GetPivot()
            camera = workspace.CurrentCamera
            cameraCFrame = camera and camera.CFrame
            cameraSubject = camera and camera.CameraSubject
            cameraType = camera and camera.CameraType

            if camera then
                camera.CameraType = Enum.CameraType.Scriptable
                camera.CFrame = cameraCFrame
            end

            local direction = bell.Position - volume.Position
            direction = Vector3.new(direction.X, 0, direction.Z)
            direction = direction.Magnitude > 0.1 and direction.Unit or -volume.CFrame.LookVector

            local position = volume.Position + direction * 3.8
            position = Vector3.new(position.X, volume.Position.Y + 0.35, position.Z)

            humanoid:UnequipTools()
            character:PivotTo(CFrame.lookAt(position, Vector3.new(volume.Position.X, position.Y, volume.Position.Z)))
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            task.wait(0.25)

            local cashBefore = getCashAmount()
            local index = 1

            while index <= #tools and not library.Unloaded do
                local deposited = 0
                local batchValue = 0

                for _ = 1, 5 do
                    local tool = tools[index]

                    if not tool then
                        break
                    end

                    index += 1

                    if tool.Parent == backpack or tool.Parent == character then
                        local callOk = pcall(flow.Loot.LootUnequip, tool, hasTag(tool, "RemoteOnly"))

                        if callOk then
                            local deadline = os.clock() + 0.75

                            repeat
                                task.wait()
                            until tool.Parent ~= backpack and tool.Parent ~= character or os.clock() >= deadline

                            if tool.Parent ~= backpack and tool.Parent ~= character then
                                deposited += 1
                                batchValue += getLootValue(tool.Name) or 0
                            else
                                failed += 1
                            end
                        else
                            failed += 1
                        end

                        task.wait(0.04)
                    end
                end

                if deposited > 0 then
                    local deadline = os.clock() + 3

                    repeat
                        task.wait(0.05)
                    until prompt.Enabled or os.clock() >= deadline

                    if not prompt.Enabled then
                        failed += deposited
                        break
                    end

                    local batchCash = getCashAmount()
                    local soldInBatch = 0

                    task.wait(0.15)

                    for _ = 1, deposited do
                        local currentCash = getCashAmount()

                        if batchCash and currentCash and currentCash - batchCash >= batchValue then
                            soldInBatch = deposited
                            break
                        end

                        local batchDeadline = os.clock() + 1.5

                        repeat
                            task.wait(0.03)
                            currentCash = getCashAmount()
                        until prompt.Enabled
                            or batchCash and currentCash and currentCash - batchCash >= batchValue
                            or os.clock() >= batchDeadline

                        if batchCash and currentCash and currentCash - batchCash >= batchValue then
                            soldInBatch = deposited
                            break
                        end

                        if not prompt.Enabled then
                            break
                        end

                        local clickCash = currentCash

                        if firePrompt then
                            firePrompt(prompt)
                        else
                            prompt:InputHoldBegin()
                            task.wait(prompt.HoldDuration + 0.1)
                            prompt:InputHoldEnd()
                        end

                        local confirmed = false

                        local confirmDeadline = os.clock() + 1.5

                        repeat
                            task.wait(0.05)
                            currentCash = getCashAmount()
                            confirmed = not prompt.Enabled or clickCash and currentCash and currentCash > clickCash
                        until confirmed or os.clock() >= confirmDeadline

                        if not confirmed then
                            break
                        end

                        soldInBatch += 1
                        task.wait(0.05)
                    end

                    local currentCash = getCashAmount()

                    if batchCash and currentCash and currentCash - batchCash >= batchValue then
                        soldInBatch = deposited
                    end

                    sold += soldInBatch

                    if soldInBatch < deposited then
                        failed += deposited - soldInBatch
                        break
                    end
                end
            end

            local cashAfter = getCashAmount()

            if cashBefore and cashAfter and cashAfter > cashBefore then
                earned = cashAfter - cashBefore
            end
        end)

        if startPivot and character and character.Parent and root and root.Parent == character then
            character:PivotTo(startPivot)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end

        if camera and camera.Parent then
            camera.CameraSubject = cameraSubject
            camera.CameraType = cameraType
            camera.CFrame = cameraCFrame
        end

        actionBusy = false

        local result = {
            ok = ok == true,
            reason = ok and "" or tostring(message),
            sold = sold,
            failed = failed,
            earned = earned,
            nothing = ok and sold == 0 and failed == 0,
        }

        if not library.Unloaded then
            if not ok then
                notify("Sell failed: " .. tostring(message), 6)
            elseif sold == 0 and failed == 0 then
                notify("Nothing to sell.")
            elseif earned then
                notify(string.format("Sold: %d, earned: $%d.", sold, earned))
            elseif failed == 0 then
                notify(string.format("Sold: %d.", sold))
            else
                notify(string.format("Sold: %d, failed: %d.", sold, failed), 6)
            end
        end

        if onDone then
            onDone(result)
        end
    end)
end

local pawnKeywords = {
    "pawn",
    "pawnbroker",
    "broker",
    "shop",
    "shopkeeper",
    "seller",
    "vendor",
    "merchant",
    "trader",
    "dealer",
}

local drawingLibrary = getGlobal("Drawing")
local drawingAvailable = type(drawingLibrary) == "table" and type(drawingLibrary.new) == "function"

local espFonts = {
    [1] = 0,
    [2] = 1,
    [3] = 2,
    [4] = 3,
}

local espConfig = {
    NPCs = {
        Toggle = "RunawaysESPNPCs",
        Color = "RunawaysESPNPCColor",
        Box = "RunawaysESPNPCBox",
        Tracer = "RunawaysESPNPCTracer",
        HealthBar = "RunawaysESPNPCHealthBar",
        Distance = "RunawaysESPNPCDistance",
        Range = "RunawaysESPNPCMaxDistance",
    },
}

local espTargets = {
    NPCs = {},
}

local espVisuals = {
    NPCs = {},
}

local pawnKeywords = {
    "pawn",
    "pawnbroker",
    "broker",
    "shop",
    "shopkeeper",
    "seller",
    "vendor",
    "merchant",
    "trader",
    "dealer",
}

local espScanToken
local espRenderName = "RunawaysScript2ESP"
local espClosestId
local espClosestAt = 0

local function isPawnNamed(name)
    local lower = string.lower(tostring(name or ""))

    for _, keyword in ipairs(pawnKeywords) do
        if string.find(lower, keyword, 1, true) then
            return true
        end
    end

    return false
end

local function newESPObject(kind)
    if not drawingAvailable then
        return
    end

    local success, object = pcall(drawingLibrary.new, kind)

    if not success or not object then
        drawingAvailable = false
        return
    end

    object.Visible = false
    return object
end

local function removeESPObject(object)
    if not object then
        return
    end

    object.Visible = false

    if not pcall(function()
        object:Remove()
    end) then
        pcall(function()
            object:Destroy()
        end)
    end
end

local function newESPVisual(kind)
    local visual = {
        Text = newESPObject("Text"),
        Box = newESPObject("Square"),
        Tracer = newESPObject("Line"),
    }

    if kind == "NPCs" or kind == "Players" then
        visual.HealthBack = newESPObject("Line")
        visual.Health = newESPObject("Line")
    end

    if visual.Text then
        visual.Text.Center = true
        visual.Text.ZIndex = 3
    end

    if visual.Box then
        visual.Box.Filled = false
        visual.Box.ZIndex = 2
    end

    if visual.Tracer then
        visual.Tracer.ZIndex = 1
    end

    return visual
end

local function hideESPVisual(visual)
    for _, object in visual do
        object.Visible = false
    end
end

local function removeESPVisuals(registry)
    for target, visual in registry do
        for _, object in visual do
            removeESPObject(object)
        end

        registry[target] = nil
    end
end

local function clearESP()
    for _, registry in espVisuals do
        removeESPVisuals(registry)
    end

    for _, targets in espTargets do
        for index = #targets, 1, -1 do
            targets[index] = nil
        end
    end
end

local function hideESP()
    for _, registry in espVisuals do
        for _, visual in registry do
            hideESPVisual(visual)
        end
    end
end

local function syncESPTargets(kind, targets)
    local active = {}
    local registry = espVisuals[kind]

    for _, target in targets do
        active[target] = true
    end

    for target, visual in registry do
        if not active[target] then
            for _, object in visual do
                removeESPObject(object)
            end

            registry[target] = nil
        end
    end

    espTargets[kind] = targets
end

local function getESPOrigin(camera)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")

    return root and root.Position or camera.CFrame.Position
end

local function getESPTarget(kind, target)
    if kind == "NPCs" then
        local humanoid = target.Parent and target:FindFirstChildOfClass("Humanoid")
        local root = target.Parent and target:FindFirstChild("HumanoidRootPart")

        if not humanoid or not root then
            return
        end

        if toggles.RunawaysESPNPCActiveOnly.Value and humanoid.Health <= 0 then
            return
        end

        return target, root, humanoid
    end

    return
end

local function getESPBounds(model, part)
    if model then
        local success, boxCFrame, boxSize = pcall(model.GetBoundingBox, model)

        if success and boxSize.Magnitude > 0 then
            return boxCFrame, boxSize
        end
    end

    if part then
        return part.CFrame, part.Size
    end

    return
end

local function projectESPBounds(camera, boxCFrame, boxSize)
    local minX = math.huge
    local minY = math.huge
    local maxX = -math.huge
    local maxY = -math.huge

    for _, x in { -1, 1 } do
        for _, y in { -1, 1 } do
            for _, z in { -1, 1 } do
                local offset = Vector3.new(boxSize.X * x, boxSize.Y * y, boxSize.Z * z) * 0.5
                local point = camera:WorldToViewportPoint(boxCFrame:PointToWorldSpace(offset))

                if point.Z <= 0 then
                    return
                end

                minX = math.min(minX, point.X)
                minY = math.min(minY, point.Y)
                maxX = math.max(maxX, point.X)
                maxY = math.max(maxY, point.Y)
            end
        end
    end

    local viewport = camera.ViewportSize

    if maxX < 0 or maxY < 0 or minX > viewport.X or minY > viewport.Y then
        return
    end

    local margin = 64

    minX = math.clamp(minX, -margin, viewport.X + margin)
    minY = math.clamp(minY, -margin, viewport.Y + margin)
    maxX = math.clamp(maxX, -margin, viewport.X + margin)
    maxY = math.clamp(maxY, -margin, viewport.Y + margin)

    return Vector2.new(minX, minY), Vector2.new(maxX - minX, maxY - minY)
end

local function getESPText(kind, target, humanoid, extra, distance)
    local parts = {}

    if kind == "NPCs" then
        if toggles.RunawaysESPNPCName.Value then
            parts[#parts + 1] = formatName(target.Name)
        end

        if toggles.RunawaysESPNPCHealth.Value and humanoid.Health >= 0 then
            parts[#parts + 1] = string.format("%d/%d HP", humanoid.Health, humanoid.MaxHealth)
        end
    end

    if toggles[espConfig[kind].Distance].Value then
        parts[#parts + 1] = tostring(math.round(distance)) .. " studs"
    end

    return table.concat(parts, " | ")
end

local function getESPColor(kind, target)
    local colorOption = options[espConfig[kind].Color]

    return colorOption.Value, 1 - colorOption.Transparency
end

local function getTracerOrigin(camera)
    local origin = options.RunawaysESPTracerOrigin.Value

    if origin == "Center" then
        return camera.ViewportSize * 0.5
    end

    if origin == "Mouse" and UserInputService.MouseEnabled then
        return UserInputService:GetMouseLocation()
    end

    if origin == "Mouse" then
        return camera.ViewportSize * 0.5
    end

    return Vector2.new(camera.ViewportSize.X * 0.5, camera.ViewportSize.Y)
end

local function updateESPVisual(kind, target, visual, camera, origin)
    local model, part, humanoid, extra = getESPTarget(kind, target)

    if not part then
        hideESPVisual(visual)
        return
    end

    local distance = (part.Position - origin).Magnitude

    if distance > options[espConfig[kind].Range].Value then
        hideESPVisual(visual)
        return
    end

    local point, onScreen = camera:WorldToViewportPoint(part.Position)

    if point.Z <= 0 or not onScreen then
        hideESPVisual(visual)
        return
    end

    local showBox = toggles[espConfig[kind].Box].Value
    local showHealth = espConfig[kind].HealthBar
        and toggles[espConfig[kind].HealthBar].Value
        and humanoid
        and humanoid.Health >= 0
        and humanoid.MaxHealth > 0
    local position = Vector2.new(point.X, point.Y)
    local size = Vector2.zero

    if showBox or showHealth then
        local boxCFrame, boxSize = getESPBounds(model, part)

        if not boxCFrame then
            hideESPVisual(visual)
            return
        end

        position, size = projectESPBounds(camera, boxCFrame, boxSize)

        if not position then
            hideESPVisual(visual)
            return
        end
    end

    local color, transparency = getESPColor(kind, target)
    local text = getESPText(kind, target, humanoid, extra, distance)
    local thickness = options.RunawaysESPBoxThickness.Value

    if visual.Text and text ~= "" then
        visual.Text.Text = text
        visual.Text.Position = Vector2.new(position.X + size.X * 0.5, math.max(0, position.Y - options.RunawaysESPTextSize.Value - 2))
        visual.Text.Size = options.RunawaysESPTextSize.Value
        visual.Text.Font = espFonts[options.RunawaysESPFont.Value] or 2
        visual.Text.Color = color
        visual.Text.Transparency = transparency
        visual.Text.Outline = toggles.RunawaysESPTextOutline.Value
        visual.Text.OutlineColor = options.RunawaysESPOutlineColor.Value
        visual.Text.Visible = true
    elseif visual.Text then
        visual.Text.Visible = false
    end

    if visual.Box and showBox then
        visual.Box.Position = position
        visual.Box.Size = size
        visual.Box.Color = color
        visual.Box.Transparency = transparency
        visual.Box.Thickness = thickness
        visual.Box.Visible = true
    elseif visual.Box then
        visual.Box.Visible = false
    end

    if visual.Tracer and toggles[espConfig[kind].Tracer].Value then
        visual.Tracer.From = getTracerOrigin(camera)
        visual.Tracer.To = Vector2.new(position.X + size.X * 0.5, position.Y + size.Y)
        visual.Tracer.Color = color
        visual.Tracer.Transparency = transparency
        visual.Tracer.Thickness = thickness
        visual.Tracer.Visible = true
    elseif visual.Tracer then
        visual.Tracer.Visible = false
    end

    if visual.Health and showHealth then
        local ratio = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
        local x = position.X - 4
        local bottom = position.Y + size.Y

        visual.HealthBack.From = Vector2.new(x, bottom)
        visual.HealthBack.To = Vector2.new(x, position.Y)
        visual.HealthBack.Color = Color3.new(0, 0, 0)
        visual.HealthBack.Transparency = transparency
        visual.HealthBack.Thickness = thickness + 2
        visual.HealthBack.Visible = true
        visual.Health.From = Vector2.new(x, bottom)
        visual.Health.To = Vector2.new(x, bottom - size.Y * ratio)
        visual.Health.Color = Color3.fromHSV(ratio * 0.33, 1, 1)
        visual.Health.Transparency = transparency
        visual.Health.Thickness = thickness
        visual.Health.Visible = true
    elseif visual.Health then
        visual.Health.Visible = false
        visual.HealthBack.Visible = false
    end
end

local function updateESP()
    if not toggles.RunawaysESPEnabled or not toggles.RunawaysESPEnabled.Value then
        return
    end

    if not drawingAvailable then
        hideESP()
        return
    end

    local camera = workspace.CurrentCamera

    if not camera then
        hideESP()
        return
    end

    local origin = getESPOrigin(camera)

    for kind, targets in espTargets do
        local config = espConfig[kind]
        local registry = espVisuals[kind]

        if toggles[config.Toggle].Value then
            for _, target in targets do
                local visual = registry[target]

                if not visual then
                    visual = newESPVisual(kind)
                    registry[target] = visual
                end

                updateESPVisual(kind, target, visual, camera, origin)
            end
        else
            for _, visual in registry do
                hideESPVisual(visual)
            end
        end
    end
end

local function scanESP()
    if not drawingAvailable or not toggles.RunawaysESPEnabled.Value then
        clearESP()
        return
    end

    local camera = workspace.CurrentCamera
    local origin = camera and getESPOrigin(camera)
    local npcs = {}
    local folder = workspace:FindFirstChild("NPCs")

    local function inRange(part, limit)
        return part and (not origin or (part.Position - origin).Magnitude <= limit)
    end

    if toggles.RunawaysESPNPCs.Value and folder then
        local limit = options.RunawaysESPNPCMaxDistance.Value
        local seen = {}

        local function consider(npc)
            if seen[npc] or not isPawnNamed(npc.Name) then
                return
            end

            seen[npc] = true
            local root = npc:FindFirstChild("HumanoidRootPart")

            if inRange(root, limit) then
                npcs[#npcs + 1] = npc
            end
        end

        for _, humanoid in folder:QueryDescendants("Humanoid") do
            if humanoid.Parent then
                consider(humanoid.Parent)
            end
        end

        for _, npc in ipairs(CollectionService:GetTagged("NPC")) do
            consider(npc)
        end

        table.sort(npcs, function(a, b)
            local aRoot = a:FindFirstChild("HumanoidRootPart")
            local bRoot = b:FindFirstChild("HumanoidRootPart")

            if not origin or not aRoot or not bRoot then
                return false
            end

            return (aRoot.Position - origin).Magnitude < (bRoot.Position - origin).Magnitude
        end)
    end

    syncESPTargets("NPCs", npcs)

    local closest = npcs[1]

    if closest then
        local root = closest:FindFirstChild("HumanoidRootPart")
        local distance = origin and root and math.round((root.Position - origin).Magnitude) or 0
        local id = closest:GetDebugId()

        if id ~= espClosestId and os.clock() - espClosestAt >= 5 then
            espClosestId = id
            espClosestAt = os.clock()

            notify(string.format("Nearest pawn: %s (%d studs).", formatName(closest.Name), distance), 5)
        end
    end
end

local window = library:CreateWindow({
    Title = "RUNAWAYS",
    Footer = "RUNAWAYS | " .. telegram,
    Size = UDim2.fromOffset(library.IsMobile and 560 or 640, library.IsMobile and 360 or 520),
    NotifySide = "Right",
    ShowCustomCursor = not library.IsMobile,
    ShowMobileButtons = true,
    MobileButtonsSide = "Left",
    EnableCompacting = true,
})

print("[Script2] window created")

-- ============================================================
-- AUTO FARM
-- Ported from Script.lua library.AutoFarm.
-- Four gate states: Travel -> Activate -> Safe Wait -> Cross,
-- then result handling and re-queue for the next run.
-- Webhooks and file IO are intentionally omitted. Run state rides
-- on TeleportService settings, which survive the server hop.
-- ============================================================

-- >>> TELEPORT LOADER <<<
-- Auto re-queue re-downloads the script on the destination server.
-- Paste a public URL for THIS script below to enable it.
-- "--" disables re-queue cleanly and reports
-- "Teleport loader is not configured".
local AUTO_FARM_LOADER = "https://raw.githubusercontent.com/BlackJackQwQ/RunAwayRobloxScript/refs/heads/main/Script2.lua?cb=13"

local farm = {
    Version = 1,
    StatsVersion = 2,
    ConfigVersion = 2,
    LobbyPlaceId = 118418618261207,
    GamePlaceId = 117311404196294,
    StateKey = "RUNAWAYS2_AUTO_FARM_STATE",
    EnabledKey = "RUNAWAYS2_AUTO_FARM_ENABLED",
    SessionKey = "RUNAWAYS2_AUTO_FARM_SESSION",
    TransitionKey = "RUNAWAYS2_AUTO_FARM_TRANSITION",
    TeleportLoader = AUTO_FARM_LOADER,
    Running = false,
    ResumeRequested = false,
    AutoEnabled = false,
    Token = nil,
    QueueJob = nil,
    Revision = 0,
    Teleporting = false,
    RunActive = false,
    ActiveRunToken = nil,
    RunHeartbeat = 0,
    Phase = "Idle",
    Detail = "Ready",
    GateText = "--",
    LastError = "None",
    QueueStatus = "Not armed",
    SessionId = "",
    TransitionToken = "",
    ExpectedPlaceId = 0,
    TransitionAt = 0,
    StartedAt = 0,
    RunStartedAt = 0,
    RunCashStart = 0,
    RunWinsStart = 0,
    LastCredzBalance = nil,
    LastWins = nil,
    PendingCredz = 0,
    PendingWins = 0,
    BalanceWarmupUntil = 0,
    GateStartedAt = 0,
    PendingFinish = false,
    FinishCrossed = false,
    PendingAt = 0,
    ResultBusy = false,
    ResultFinalized = false,
    ReplayRequested = false,
    SafeCFrame = nil,
    SafeCharacter = nil,
    SafeRootAnchored = nil,
    CrossCollisions = nil,
    LastGameJob = "",
    SweepDone = false,
    SweepIndex = 0,
    AssistCaptured = false,
    SavedKillAura = nil,
    SavedKillRange = nil,
    LastSnapshot = nil,
    LastPersistAt = 0,
    StateReady = false,
    TeleportFailureGeneration = 0,
    TeleportRecoveryGeneration = 0,
    TeleportRetryCount = 0,
    TeleportRetryDelay = 0,
    TeleportRetryTarget = 0,
    TeleportRetryOptions = nil,
    TeleportRecovering = false,
    Sweeping = false,
    LastTeleportFailureAt = 0,
    Labels = {},
    LabelCache = {},
    LastUIProgressAt = 0,
    LastEndScreenScanAt = 0,
    Config = {
        LobbyDelay = 8,
        GateTimeout = 165,
        RetryDelay = 6,
        SettleDelay = 1.5,
        ShopRounds = 4,
        SellRounds = 3,
        ShopRadius = 160,
        ShopBudget = 45,
        SweepTimeout = 900,
        SafeGateWait = true,
        AutoReplay = true,
        ForceAssist = false,
    },
    Stats = {
        Attempts = 0,
        Completed = 0,
        Failed = 0,
        Teleports = 0,
        GateActivations = 0,
        NPCAttacks = 0,
        Shops = 0,
        Looted = 0,
        Sold = 0,
        Retries = 0,
        Replays = 0,
        CashEarned = 0,
        TotalRunTime = 0,
        BestRun = 0,
        LastRun = 0,
    },
}

-- >>> PAWN SHOP SWEEP <<<
-- Walks every qualifying pawn shop in ascending building order.
-- Per shop: kill aura off -> face the closest pawn -> kill aura on at max
-- range -> loot all -> sell all until there is nothing left to sell -> loot
-- again. When a shop reports nothing left to loot, move to the next index.
-- When no qualifying shop remains, hand off to the gate run.

function farm:SaveAssistState()
    if self.AssistCaptured then
        return
    end

    self.SavedKillAura = toggles.RunawaysKillAura and toggles.RunawaysKillAura.Value == true
    self.SavedKillRange = options.RunawaysKillRange and tonumber(options.RunawaysKillRange.Value) or nil
    self.AssistCaptured = true
end

function farm:RestoreAssistState()
    if not self.AssistCaptured then
        return
    end

    self.AssistCaptured = false

    if options.RunawaysKillRange and self.SavedKillRange then
        local saved = self.SavedKillRange

        pcall(function()
            options.RunawaysKillRange:SetValue(saved)
        end)
    end

    self.SavedKillRange = nil

    if toggles.RunawaysKillAura then
        local wanted = self.SavedKillAura == true

        if toggles.RunawaysKillAura.Value ~= wanted then
            pcall(function()
                toggles.RunawaysKillAura:SetValue(wanted)
            end)
        end
    end

    self.SavedKillAura = nil
end

function farm:SetKillAura(enabled, useMaxRange)
    if useMaxRange and options.RunawaysKillRange then
        local top = tonumber(options.RunawaysKillRange.Max) or 1000

        pcall(function()
            options.RunawaysKillRange:SetValue(top)
        end)
    end

    if toggles.RunawaysKillAura and toggles.RunawaysKillAura.Value ~= (enabled == true) then
        pcall(function()
            toggles.RunawaysKillAura:SetValue(enabled == true)
        end)
    end
end

function farm:GetPawnShopEntries()
    local entries = {}
    local map = workspace:FindFirstChild("Map")
    local buildings = map and map:FindFirstChild("Buildings")

    if not buildings then
        return entries
    end

    -- The building list the teleport system already builds contains every pawn
    -- shop regardless of distance, alongside whatever ordinary buildings are
    -- currently loaded. Take the pawn shops straight out of that data instead of
    -- walking every building to find out what it is.
    local generated = 0

    for _, building in buildings:GetChildren() do
        generated += 1

        if building:IsA("Model")
            and not building.Name:lower():find("sign", 1, true)
            and isPawnNamed(building.Name)
        then
            local surface = teleports:GetBuildingSurface(building)

            if surface then
                local attributeId = tonumber(building:GetAttribute("BuildingId"))

                entries[#entries + 1] = {
                    Instance = building,
                    Surface = surface,
                    Anchor = surface.Position + Vector3.new(0, 3, 0),
                    Order = attributeId or 1000000000 + generated,
                    Name = building.Name,
                    Named = true,
                }
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.Order == b.Order then
            return a.Name < b.Name
        end

        return a.Order < b.Order
    end)

    return entries
end

function farm:GetPawnCounterNear(origin, maxDistance)
    local limit = maxDistance or math.huge
    local best
    local bestDistance = limit

    for _, counter in ipairs(CollectionService:GetTagged("PawnCounter")) do
        local volume = counter and counter:FindFirstChild("Volume", true)
        local reference = volume or (counter and counter:IsA("BasePart") and counter or nil)

        if reference then
            local distance = (reference.Position - origin).Magnitude

            if distance < bestDistance then
                bestDistance = distance
                best = counter
            end
        end
    end

    return best, bestDistance
end

function farm:WaitForPawnCounter(origin, maxDistance, timeout, label)
    local deadline = os.clock() + (tonumber(timeout) or 8)

    while self.Running and not library.Unloaded and os.clock() < deadline do
        teleports:Stream(origin)

        local counter = self:GetPawnCounterNear(origin, maxDistance)

        if counter then
            return counter
        end

        if label then
            self:SetPhase("Shops", "Checking " .. label)
        end

        task.wait(0.5)
    end

    return nil
end

function farm:GetClosestPawn(origin, maxDistance)
    local limit = maxDistance or math.huge
    local folder = workspace:FindFirstChild("NPCs")
    local best
    local bestDistance = limit

    if not folder or not origin then
        return nil, limit
    end

    local seen = {}

    local function consider(npc)
        if seen[npc] or not isPawnNamed(npc.Name) then
            return
        end

        seen[npc] = true

        local part = npc:FindFirstChild("HumanoidRootPart")

        if part then
            local distance = (part.Position - origin).Magnitude

            if distance < bestDistance then
                bestDistance = distance
                best = npc
            end
        end
    end

    for _, humanoid in folder:QueryDescendants("Humanoid") do
        if humanoid.Parent then
            consider(humanoid.Parent)
        end
    end

    for _, npc in ipairs(CollectionService:GetTagged("NPC")) do
        consider(npc)
    end

    return best, bestDistance
end

function farm:FaceClosestPawn(maxDistance)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not character or not root then
        return nil
    end

    local npc = self:GetClosestPawn(root.Position, maxDistance or 250)
    local target = npc and (npc:FindFirstChild("HumanoidRootPart") or npc)

    if not target or not target.Parent then
        return nil
    end

    local position = root.Position
    local look = Vector3.new(target.Position.X, position.Y, target.Position.Z)

    if (look - position).Magnitude > 0.5 then
        character:PivotTo(CFrame.lookAt(position, look))
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end

    return npc
end

function farm:GetCharacterReady()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    return character and humanoid and root and humanoid.Health > 0 and not humanoid.SeatPart, character, root
end

-- streaming brings NPCs in over time, so poll instead of guessing a fixed delay
function farm:WaitForPawn(origin, maxDistance, timeout, label)
    local deadline = os.clock() + (tonumber(timeout) or 10)

    while self.Running and not library.Unloaded and os.clock() < deadline do
        teleports:Stream(origin)

        local pawn, distance = self:GetClosestPawn(origin, maxDistance)

        if pawn then
            return pawn, distance
        end

        if label then
            self:SetPhase("Shops", "Streaming " .. label)
        end

        task.wait(0.5)
    end

    return nil
end

function farm:WaitShopLoot(token, shop)
    local rounds = 0
    local settle = tonumber(self.Config.SettleDelay) or 3
    local shopRounds = tonumber(self.Config.ShopRounds) or 4
    local sellRounds = tonumber(self.Config.SellRounds) or 3
    local budget = tonumber(self.Config.ShopBudget) or 45
    local zeroYield = 0
    local shopDeadline = os.clock() + math.max(10, budget)

    while self.Running and self.Token == token and not library.Unloaded do
        if self.TeleportRecovering then
            task.wait(0.25)
            continue
        end

        if os.clock() >= shopDeadline then
            self.LastError = "Shop budget spent at " .. shop.Name
            return true
        end

        rounds += 1

        if rounds > shopRounds then
            return true
        end

        -- let kill aura thin the pawns out before looting
        local settleUntil = os.clock() + math.max(0, settle)

        while os.clock() < settleUntil
            and self.Running
            and self.Token == token
            and not library.Unloaded
            and not self.TeleportRecovering
        do
            self:FaceClosestPawn()
            task.wait(0.1)
        end

        if not self.Running or self.Token ~= token or library.Unloaded then
            return true
        end

        self:SetPhase("Looting", shop.Name)

        local lootDone, lootResult = false, nil

        collect(function(result)
            lootResult = result
            lootDone = true
        end)

        local lootDeadline = os.clock() + 180

        while not lootDone
            and self.Running
            and self.Token == token
            and not library.Unloaded
            and os.clock() < lootDeadline
        do
            task.wait(0.1)
        end

        if not self.Running or self.Token ~= token or library.Unloaded then
            return true
        end

        if not lootResult or lootResult.ok ~= true then
            self.Stats.Retries += 1
            self.LastError = "Loot failed: " .. tostring(lootResult and lootResult.reason or "no result")
            self:SetPhase("Retrying", self.LastError)
            task.wait(1)
            continue
        end

        local gained = tonumber(lootResult.looted) or 0

        self.Stats.Looted += gained

        -- nothing left here: move on to the next shop
        if lootResult.nothing then
            return true
        end

        -- gear was visible but none of it could be taken twice running: call it spent
        if gained <= 0 then
            zeroYield += 1

            if zeroYield >= 2 then
                self.LastError = "No loot could be taken at " .. shop.Name
                return true
            end
        else
            zeroYield = 0
        end

        -- sell until the inventory reports nothing left to sell
        local passes = 0

        while self.Running and self.Token == token and not library.Unloaded do
            passes += 1

            if passes > sellRounds then
                self.LastError = "Sell gave up at " .. shop.Name
                break
            end

            self:SetPhase("Selling", shop.Name)

            local sellDone, sellResult = false, nil

            sellAllLoot(function(result)
                sellResult = result
                sellDone = true
            end)

            local sellDeadline = os.clock() + 180

            while not sellDone
                and self.Running
                and self.Token == token
                and not library.Unloaded
                and os.clock() < sellDeadline
            do
                task.wait(0.1)
            end

            if not self.Running or self.Token ~= token or library.Unloaded then
                return true
            end

            if not sellResult or sellResult.ok ~= true then
                self.Stats.Retries += 1
                self.LastError = "Sell failed: " .. tostring(sellResult and sellResult.reason or "no result")
                self:SetPhase("Retrying", self.LastError)
                break
            end

            self.Stats.Sold += tonumber(sellResult.sold) or 0

            if sellResult.nothing then
                break
            end

            task.wait(0.3)
        end
    end

    -- Confirming Loot All. This used to happen only as a side effect of the next
    -- loop iteration, so a small ShopRounds budget exited before the shop ever
    -- reported "nothing to loot" and loot could be left on the ground.
    for confirm = 1, 2 do
        if not self.Running or self.Token ~= token or library.Unloaded then
            return true
        end

        if os.clock() >= shopDeadline then
            self.LastError = "Shop budget spent at " .. shop.Name
            return true
        end

        self:SetPhase("Looting", shop.Name)

        local confirmDone, confirmResult = false, nil

        collect(function(result)
            confirmResult = result
            confirmDone = true
        end)

        local confirmDeadline = os.clock() + 20

        while not confirmDone
            and self.Running
            and self.Token == token
            and not library.Unloaded
            and os.clock() < confirmDeadline
        do
            task.wait(0.1)
        end

        if not confirmResult or confirmResult.ok ~= true then
            return true
        end

        self.Stats.Looted += tonumber(confirmResult.looted) or 0

        -- the shop is genuinely empty, so the sweep can move on
        if confirmResult.nothing or (tonumber(confirmResult.looted) or 0) <= 0 then
            return true
        end

        -- something was still on the ground: sell it off, then confirm once more
        local confirmPasses = 0

        while self.Running and self.Token == token and not library.Unloaded do
            confirmPasses += 1

            if confirmPasses > sellRounds then
                break
            end

            self:SetPhase("Selling", shop.Name)

            local sold, sellResult = false, nil

            sellAllLoot(function(result)
                sellResult = result
                sold = true
            end)

            local confirmSellDeadline = os.clock() + 180

            while not sold
                and self.Running
                and self.Token == token
                and not library.Unloaded
                and os.clock() < confirmSellDeadline
            do
                task.wait(0.1)
            end

            if not sellResult or sellResult.ok ~= true then
                break
            end

            self.Stats.Sold += tonumber(sellResult.sold) or 0

            if sellResult.nothing then
                break
            end

            task.wait(0.3)
        end
    end

    return true
end

function farm:RunPawnSweep(token)
    self.Sweeping = true
    self:SetPhase("Shops", "Scanning pawn shops")
    self:SaveAssistState()

    local queue = self:GetPawnShopEntries()
    local total = #queue

    if total == 0 then
        self.LastError = "No pawn shop was found in the building list"
        self:SetPhase("Shops", "No pawn shop found")
        notify("Auto Farm: no pawn shop was found in the building list.", 8)
    else
        self:SetPhase("Shops", string.format("%d pawn shop(s) found", total))
        notify(string.format("Auto Farm: %d pawn shop(s) found from the building list.", total), 6)
    end

    local position = 0
    local farms = 0
    local skipped = 0
    local processed = {}
    local shopRadius = tonumber(self.Config.ShopRadius) or 160
    local sweepTimeout = tonumber(self.Config.SweepTimeout) or 900
    local overallDeadline = os.clock() + math.max(60, sweepTimeout)
    local lastProgressAt = os.clock()

    while self.Running and self.Token == token and not library.Unloaded do
        if self.TeleportRecovering then
            task.wait(0.25)
            continue
        end

        if os.clock() >= overallDeadline then
            self.LastError = "Pawn sweep timed out"
            break
        end

        -- never let a single shop wedge the whole sweep without a trace
        if os.clock() - lastProgressAt > 150 then
            self.LastError = string.format(
                "Pawn sweep stalled on shop %d/%d - %s",
                position + 1,
                total,
                queue[position + 1] and queue[position + 1].Name or "?"
            )
            self:SetPhase("Shops", self.LastError)
            notify("Auto Farm: " .. self.LastError .. ". Moving on to the finish.", 10)
            break
        end

        position += 1

        local shop = queue[position]

        if not shop then
            break
        end

        if processed[shop.Order] then
            continue
        end

        processed[shop.Order] = true
        lastProgressAt = os.clock()
        self.SweepIndex = position
        self:SetPhase("Shops", string.format("Shop %d/%d - %s", position, total, shop.Name))

        local ready, character = self:GetCharacterReady()

        if not ready then
            self.LastError = "Character is not ready"
            skipped += 1
            continue
        end

        -- Teleport first, then confirm. A PawnCounter only exists client side once
        -- its area has streamed in, so the tag cannot be read before we arrive.
        if not teleports:Move(CFrame.new(shop.Anchor), character) then
            self.LastError = "Could not reach " .. shop.Name
            skipped += 1
            continue
        end

        -- The building data already identified this as a pawn shop, so a missing
        -- counter must never skip it: confirm quickly for the status line only,
        -- then always loot and sell.
        local counter = self:WaitForPawnCounter(shop.Anchor, shopRadius, 4, shop.Name)

        self.Stats.Shops += 1
        farms += 1
        self:SetPhase("Shops", string.format(
            "Shop %d/%d - %s%s",
            position,
            total,
            shop.Name,
            counter and "" or " (no counter tag)"
        ))

        -- the pawn NPC only drives facing and the kill aura, so it is optional
        local pawn = self:WaitForPawn(shop.Anchor, shopRadius, 4, shop.Name)

        if pawn then
            self:SetKillAura(false)
            task.wait(0.2)
            self:FaceClosestPawn(shopRadius)
            self:SetKillAura(true, true)
        end

        self:WaitShopLoot(token, shop)

        if not self.Running or self.Token ~= token or library.Unloaded then
            break
        end
    end

    self.SweepDone = true
    self.Sweeping = false
    self:RestoreAssistState()
    self:SetPhase("Shops", string.format("Farmed %d of %d pawn shop(s)", farms, total))
    notify(string.format("Auto Farm: farmed %d of %d pawn shop(s).", farms, total), 6)

    return true
end

function farm:GetContext()
    if game.PlaceId == self.LobbyPlaceId then
        return "Lobby"
    end

    if game.PlaceId == self.GamePlaceId then
        return "Game"
    end

    if flowOk and type(flowModule) == "table" and flow.LobbyServer and type(flow.LobbyServer.create) == "function" then
        return "Lobby"
    end

    if workspace:FindFirstChild("Map") and flowOk and type(flowModule) == "table" and flow.NPCs then
        return "Game"
    end

    return "Unsupported"
end

function farm:IsAutoReplayEnabled()
    if toggles.RunawaysAutoFarmAutoReplay then
        return toggles.RunawaysAutoFarmAutoReplay.Value == true
    end

    return self.Config.AutoReplay == true
end

function farm:IsForceAssistEnabled()
    if toggles.RunawaysAutoFarmForceAssist then
        return toggles.RunawaysAutoFarmForceAssist.Value == true
    end

    return self.Config.ForceAssist == true
end

function farm:IsSafeGateWaitEnabled()
    if toggles.RunawaysAutoFarmSafeGateWait then
        return toggles.RunawaysAutoFarmSafeGateWait.Value == true
    end

    return self.Config.SafeGateWait == true
end

function farm:GetQueueFunction()
    if type(queue_on_teleport) == "function" then
        return queue_on_teleport
    end

    if type(queueonteleport) == "function" then
        return queueonteleport
    end

    local synEnv = getGlobal("syn")

    if type(synEnv) == "table" and type(synEnv.queue_on_teleport) == "function" then
        return synEnv.queue_on_teleport
    end

    local fluxusEnv = getGlobal("fluxus")

    if type(fluxusEnv) == "table" and type(fluxusEnv.queue_on_teleport) == "function" then
        return fluxusEnv.queue_on_teleport
    end

    return nil
end

function farm:GetTeleportLoader()
    return tostring(self.TeleportLoader or ""):match("^%s*(.-)%s*$") or ""
end

function farm:HasTeleportLoader()
    local loader = self:GetTeleportLoader()

    return loader ~= "" and not loader:match("^%-%-")
end

function farm:GetTeleportQueueError(expectedPlaceId)
    if not tonumber(expectedPlaceId) then
        return "Target place unavailable"
    end

    if not self:GetQueueFunction() then
        return "queue_on_teleport unavailable"
    end

    if not self:HasTeleportLoader() then
        return "Teleport loader is not configured"
    end

    return nil
end

function farm:SendWebhook()
end

function farm:GetDataValue(name)
    if not (flowOk and type(flowModule) == "table") then
        return
    end

    if flow.LocalData and type(flow.LocalData.Get) == "function" then
        local ok, value = pcall(flow.LocalData.Get, name)

        if ok and type(value) == "number" then
            return value
        end
    end

    if flow.LocalData and type(flow.LocalData.GetValue) == "function" then
        local ok, observer = pcall(flow.LocalData.GetValue, name)

        if ok and observer then
            local read, value = pcall(function()
                return observer:get()
            end)

            if read and type(value) == "number" then
                return value
            end
        end
    end

    if flow.PlayerDataClient and type(flow.PlayerDataClient.getObserver) == "function" then
        local ok, observer = pcall(flow.PlayerDataClient.getObserver, name)

        if ok and observer and type(observer.get) == "function" then
            local read, value = pcall(observer.get, observer)

            if read and type(value) == "number" then
                return value
            end
        end
    end

    return nil
end

function farm:GetCash()
    return self:GetDataValue("coins")
end

function farm:GetWins()
    return self:GetDataValue("wins")
end

function farm:GetEffectiveCredz()
    return (tonumber(self.LastCredzBalance) or 0) + math.max(0, tonumber(self.PendingCredz) or 0)
end

function farm:GetEffectiveWins()
    return (tonumber(self.LastWins) or 0) + math.max(0, tonumber(self.PendingWins) or 0)
end

function farm:SyncProgress(reset)
    local credz = self:GetCash()
    local wins = self:GetWins()

    if type(credz) == "number" then
        if reset or type(self.LastCredzBalance) ~= "number" then
            self.LastCredzBalance = credz
            self.PendingCredz = 0
        elseif credz > self.LastCredzBalance then
            local gained = credz - self.LastCredzBalance
            local accounted = math.min(gained, math.max(0, tonumber(self.PendingCredz) or 0))

            self.PendingCredz = math.max(0, self.PendingCredz - accounted)

            if os.clock() >= (tonumber(self.BalanceWarmupUntil) or 0) then
                self.Stats.CashEarned += gained - accounted
            end

            self.LastCredzBalance = credz
        end
    end

    if type(wins) == "number" then
        if reset or type(self.LastWins) ~= "number" then
            self.LastWins = wins
            self.PendingWins = 0
        elseif wins > self.LastWins then
            local gained = wins - self.LastWins
            local accounted = math.min(gained, math.max(0, tonumber(self.PendingWins) or 0))

            self.PendingWins = math.max(0, self.PendingWins - accounted)
            self.LastWins = wins
        end
    end

    return credz, wins
end

function farm:NormalizeStats()
    local active = self.RunStartedAt > 0 and 1 or 0
    local attempts = math.max(active, math.max(0, math.floor(tonumber(self.Stats.Attempts) or 0)))
    local resolved = math.max(0, attempts - active)
    local failed = math.min(math.max(0, math.floor(tonumber(self.Stats.Failed) or 0)), resolved)
    local completed = math.min(
        math.max(0, math.floor(tonumber(self.Stats.Completed) or 0)),
        math.max(0, resolved - failed)
    )

    self.Stats.Attempts = attempts
    self.Stats.Completed = completed
    self.Stats.Failed = failed

    -- backfill counters a snapshot saved by an older build may not carry
    for _, name in ipairs({
        "Teleports",
        "GateActivations",
        "NPCAttacks",
        "Shops",
        "Looted",
        "Sold",
        "Retries",
        "Replays",
        "CashEarned",
        "TotalRunTime",
        "BestRun",
        "LastRun",
    }) do
        if tonumber(self.Stats[name]) == nil then
            self.Stats[name] = 0
        end
    end
end

function farm:FormatDuration(value)
    local seconds = math.max(0, math.floor(tonumber(value) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)

    return string.format("%02d:%02d:%02d", hours, minutes, seconds % 60)
end

function farm:SetPhase(phase, detail)
    self.Phase = phase
    self.Detail = detail or ""
    self:UpdateUI()
end

function farm:SetLabel(name, text)
    local label = self.Labels[name]
    text = tostring(text)

    if self.LabelCache[name] == text then
        return
    end

    if not label then
        return
    end

    local changed = false

    if type(label.SetText) == "function" then
        changed = pcall(label.SetText, label, text)
    end

    if not changed then
        local ok = pcall(function()
            label.Text = text
        end)

        changed = ok
    end

    if changed then
        self.LabelCache[name] = text
    end
end

function farm:UpdateUI()
    local nowClock = os.clock()

    if (self.StateReady or self.Running) and nowClock - self.LastUIProgressAt >= 1 then
        self.LastUIProgressAt = nowClock
        self:SyncProgress()
    end

    self:NormalizeStats()

    local now = os.time()
    local elapsed = self.StartedAt > 0 and now - self.StartedAt or 0
    local runElapsed = self.RunStartedAt > 0 and now - self.RunStartedAt or 0
    local completed = self.Stats.Completed
    local attempts = self.Stats.Attempts
    local successRate = attempts > 0 and completed / attempts * 100 or 0
    local average = completed > 0 and self.Stats.TotalRunTime / completed or 0
    local queueMode = not self:GetQueueFunction() and "Unavailable"
        or self:HasTeleportLoader() and "Loader ready"
        or "Loader placeholder"

    self:SetLabel("Status", "Status: " .. self.Phase .. "\n" .. self.Detail)
    self:SetLabel("Run", "Context: " .. self:GetContext() .. " | Place: " .. tostring(game.PlaceId)
        .. "\nRun: " .. self:FormatDuration(runElapsed) .. " | Gate: " .. self.GateText)
    self:SetLabel("Queue", "Queue: " .. self.QueueStatus .. " | Mode: " .. queueMode)
    self:SetLabel("Session", "Session: " .. self:FormatDuration(elapsed)
        .. " | Credz: +" .. tostring(math.floor(self.Stats.CashEarned)))
    self:SetLabel("Runs", string.format("Runs: %d completed / %d started | %.1f%%", completed, attempts, successRate)
        .. "\nFailed: " .. self.Stats.Failed .. " | Retries: " .. self.Stats.Retries
        .. " | Teleports: " .. self.Stats.Teleports
        .. "\nAverage: " .. self:FormatDuration(average) .. " | Best: " .. self:FormatDuration(self.Stats.BestRun))
    self:SetLabel("Error", "Last error: " .. self.LastError)
end

function farm:ResetStats()
    self:SyncProgress()

    local now = os.time()
    local active = self.Running and self.RunStartedAt > 0
    local runCashStart = self:GetEffectiveCredz()
    local runWinsStart = self:GetEffectiveWins()
    local gateStartedAt = active and self.GateStartedAt or 0

    self.StartedAt = now
    self.RunStartedAt = active and now or 0
    self.RunCashStart = runCashStart
    self.RunWinsStart = runWinsStart
    self.GateStartedAt = gateStartedAt
    self.LastError = "None"
    self.GateText = "--"
    self.Stats = {
        Attempts = active and 1 or 0,
        Completed = 0,
        Failed = 0,
        Teleports = 0,
        GateActivations = 0,
        NPCAttacks = 0,
        Shops = 0,
        Looted = 0,
        Sold = 0,
        Retries = 0,
        Replays = 0,
        CashEarned = 0,
        TotalRunTime = 0,
        BestRun = 0,
        LastRun = 0,
    }
    self.LastCredzBalance = runCashStart
    self.LastWins = runWinsStart
    self.PendingCredz = 0
    self.PendingWins = 0
    self:Persist()
    self:UpdateUI()
end

function farm:GetSnapshot()
    if self.StateReady or self.Running then
        self:SyncProgress()
    end

    self:NormalizeStats()

    return {
        Version = self.Version,
        StatsVersion = self.StatsVersion,
        ConfigVersion = self.ConfigVersion,
        Revision = self.Revision,
        UserId = player.UserId,
        Enabled = self.Running,
        AutoEnabled = self.AutoEnabled,
        SessionId = self.SessionId,
        TransitionToken = self.TransitionToken,
        ExpectedPlaceId = self.ExpectedPlaceId,
        TransitionAt = self.TransitionAt,
        Phase = self.Phase,
        Detail = self.Detail,
        StartedAt = self.StartedAt,
        RunStartedAt = self.RunStartedAt,
        RunCashStart = self.RunCashStart,
        RunWinsStart = self.RunWinsStart,
        LastCredzBalance = self.LastCredzBalance,
        LastWins = self.LastWins,
        PendingCredz = self.PendingCredz,
        PendingWins = self.PendingWins,
        GateStartedAt = self.GateStartedAt,
        PendingFinish = self.PendingFinish,
        FinishCrossed = self.FinishCrossed,
        PendingAt = self.PendingAt,
        LastGameJob = self.LastGameJob,
        LastError = self.LastError,
        UpdatedAt = os.time(),
        Stats = self.Stats,
        Config = {
            LobbyDelay = options.RunawaysAutoFarmLobbyDelay and options.RunawaysAutoFarmLobbyDelay.Value or self.Config.LobbyDelay,
            GateTimeout = options.RunawaysAutoFarmGateTimeout and options.RunawaysAutoFarmGateTimeout.Value or self.Config.GateTimeout,
            RetryDelay = options.RunawaysAutoFarmRetryDelay and options.RunawaysAutoFarmRetryDelay.Value or self.Config.RetryDelay,
            SafeGateWait = self:IsSafeGateWaitEnabled(),
            AutoReplay = self:IsAutoReplayEnabled(),
            ForceAssist = self:IsForceAssistEnabled(),
        },
    }
end

function farm:Persist()
    if not (self.StateReady or self.Running) then
        return false
    end

    self.Revision += 1

    local ok, encoded = pcall(function()
        return game:GetService("HttpService"):JSONEncode(self:GetSnapshot())
    end)

    if not ok then
        return false
    end

    self.LastSnapshot = encoded
    self.LastPersistAt = os.clock()

    local teleportService = game:GetService("TeleportService")

    pcall(teleportService.SetTeleportSetting, teleportService, self.StateKey, encoded)
    pcall(teleportService.SetTeleportSetting, teleportService, self.EnabledKey, self.Running)
    pcall(teleportService.SetTeleportSetting, teleportService, self.SessionKey, self.SessionId)
    pcall(teleportService.SetTeleportSetting, teleportService, self.TransitionKey, self.TransitionToken)

    return true
end

function farm:ApplyPreferences(snapshot)
    if type(snapshot) ~= "table" or snapshot.Version ~= self.Version or snapshot.UserId ~= player.UserId then
        return false
    end

    self.Revision = math.max(self.Revision, tonumber(snapshot.Revision) or 0)

    if type(snapshot.Config) == "table" then
        self.Config.LobbyDelay = tonumber(snapshot.Config.LobbyDelay) or self.Config.LobbyDelay
        self.Config.GateTimeout = tonumber(snapshot.Config.GateTimeout) or self.Config.GateTimeout
        self.Config.RetryDelay = tonumber(snapshot.Config.RetryDelay) or self.Config.RetryDelay

        if type(snapshot.Config.SafeGateWait) == "boolean" then
            self.Config.SafeGateWait = snapshot.Config.SafeGateWait
        end

        if type(snapshot.Config.AutoReplay) == "boolean" then
            self.Config.AutoReplay = snapshot.Config.AutoReplay
        end

        -- one time migration: snapshots written before the requeue default flipped
        -- to a new match would otherwise pin Auto Replay off forever
        if (tonumber(snapshot.ConfigVersion) or 1) < self.ConfigVersion then
            self.Config.AutoReplay = true
        end

        if type(snapshot.Config.ForceAssist) == "boolean" then
            self.Config.ForceAssist = snapshot.Config.ForceAssist
        end
    end

    return true
end

function farm:ApplySnapshot(snapshot)
    if not self:ApplyPreferences(snapshot) then
        return false
    end

    self.SessionId = tostring(snapshot.SessionId or "")
    self.AutoEnabled = snapshot.AutoEnabled == true
    self.TransitionToken = tostring(snapshot.TransitionToken or "")
    self.ExpectedPlaceId = tonumber(snapshot.ExpectedPlaceId) or 0
    self.TransitionAt = tonumber(snapshot.TransitionAt) or 0
    self.Revision = tonumber(snapshot.Revision) or 0
    self.StartedAt = tonumber(snapshot.StartedAt) or 0
    self.RunStartedAt = tonumber(snapshot.RunStartedAt) or 0
    self.RunCashStart = tonumber(snapshot.RunCashStart) or 0
    self.RunWinsStart = tonumber(snapshot.RunWinsStart) or 0
    self.LastCredzBalance = tonumber(snapshot.LastCredzBalance)
    self.LastWins = tonumber(snapshot.LastWins)
    self.PendingCredz = math.max(0, tonumber(snapshot.PendingCredz) or 0)
    self.PendingWins = math.max(0, tonumber(snapshot.PendingWins) or 0)
    self.GateStartedAt = tonumber(snapshot.GateStartedAt) or 0
    self.PendingFinish = snapshot.PendingFinish == true
    self.FinishCrossed = snapshot.FinishCrossed == true
    self.PendingAt = tonumber(snapshot.PendingAt) or 0
    self.LastGameJob = tostring(snapshot.LastGameJob or "")
    self.LastError = tostring(snapshot.LastError or "None")
    self.BalanceWarmupUntil = os.clock() + 10

    local legacyStats = (tonumber(snapshot.StatsVersion) or 1) < self.StatsVersion

    if type(snapshot.Stats) == "table" then
        for name, value in self.Stats do
            self.Stats[name] = tonumber(snapshot.Stats[name]) or value
        end
    end

    if legacyStats then
        local attempts = math.max(0, math.floor(tonumber(self.Stats.Attempts) or 0))
        local active = self.RunStartedAt > 0 and 1 or 0
        local resolved = math.max(0, attempts - active)
        local failed = math.min(math.max(0, math.floor(tonumber(self.Stats.Failed) or 0)), resolved)
        local currentCredz = self:GetCash()
        local currentWins = self:GetWins()

        self.Stats.Attempts = attempts
        self.Stats.Completed = math.max(0, resolved - failed)
        self.Stats.Failed = failed
        self.Stats.CashEarned = 0
        self.PendingCredz = 0
        self.PendingWins = 0

        if type(currentCredz) == "number"
            and (type(self.LastCredzBalance) ~= "number" or currentCredz > self.LastCredzBalance)
        then
            self.LastCredzBalance = currentCredz
        end

        if type(currentWins) == "number" and (type(self.LastWins) ~= "number" or currentWins > self.LastWins) then
            self.LastWins = currentWins
        end

        self.RunCashStart = tonumber(self.LastCredzBalance) or 0
        self.RunWinsStart = tonumber(self.LastWins) or 0
    end

    self:NormalizeStats()

    if type(self.LastCredzBalance) ~= "number" then
        self.LastCredzBalance = self:GetCash()
        self.PendingCredz = 0
    end

    if type(self.LastWins) ~= "number" then
        self.LastWins = self:GetWins()
        self.PendingWins = 0
    end

    if self.RunCashStart <= 0 and type(self.LastCredzBalance) == "number" then
        self.RunCashStart = self:GetEffectiveCredz()
    end

    if self.RunWinsStart <= 0 and type(self.LastWins) == "number" then
        self.RunWinsStart = self:GetEffectiveWins()
    end

    self.ResumeRequested = self.SessionId ~= ""
        and snapshot.Enabled == true
        and os.time() - (tonumber(snapshot.UpdatedAt) or 0) <= 900

    if snapshot.Enabled == true and not self.ResumeRequested then
        self.LastError = "Saved Auto Farm session expired"

        pcall(function()
            game:GetService("TeleportService"):SetTeleportSetting(self.EnabledKey, false)
        end)
    end

    self.LastSnapshot = nil

    return true
end

function farm:LoadState()
    local transitionToken = tostring(env.RunawaysAutoFarmTransitionToken or "")
    local queuedState = env.RunawaysAutoFarmQueuedState
    local resumeBest
    local resumeUpdated = -1
    local resumeRevision = -1
    local preferenceBest
    local preferenceUpdated = -1
    local preferenceRevision = -1

    env.RunawaysAutoFarmTransitionToken = nil
    env.RunawaysAutoFarmQueuedState = nil

    local function consider(value)
        if type(value) == "string" then
            local ok, decoded = pcall(game:GetService("HttpService").JSONDecode, game:GetService("HttpService"), value)

            if not ok then
                return
            end

            value = decoded
        end

        if type(value) ~= "table"
            or value.Version ~= farm.Version
            or value.UserId ~= player.UserId
        then
            return
        end

        local updated = tonumber(value.UpdatedAt) or 0
        local revision = tonumber(value.Revision) or 0

        if updated > preferenceUpdated or updated == preferenceUpdated and revision >= preferenceRevision then
            preferenceBest = value
            preferenceUpdated = updated
            preferenceRevision = revision
        end

        local transitionAt = tonumber(value.TransitionAt) or 0

        if transitionToken ~= ""
            and tostring(value.TransitionToken or "") == transitionToken
            and (game.PlaceId == farm.LobbyPlaceId or game.PlaceId == farm.GamePlaceId)
            and transitionAt > 0
            and math.abs(os.time() - transitionAt) <= 900
            and tostring(value.SessionId or "") ~= ""
            and value.Enabled == true
            and os.time() - updated <= 900
            and (updated > resumeUpdated or updated == resumeUpdated and revision >= resumeRevision)
        then
            resumeBest = value
            resumeUpdated = updated
            resumeRevision = revision
        end
    end

    consider(queuedState)

    pcall(function()
        consider(game:GetService("TeleportService"):GetTeleportSetting(farm.StateKey))
    end)

    if resumeBest and self:ApplySnapshot(resumeBest) and self.ResumeRequested then
        self.ExpectedPlaceId = game.PlaceId
        return
    end

    local autoIntent = false

    if preferenceBest then
        self:ApplyPreferences(preferenceBest)

        -- Standing intent, independent of the live session: if the user left Auto
        -- Farm switched on, start again on this server even when the transition
        -- token chain did not survive the requeue.
        autoIntent = preferenceBest.AutoEnabled == true
            and (game.PlaceId == farm.LobbyPlaceId or game.PlaceId == farm.GamePlaceId)
            and os.time() - (tonumber(preferenceBest.UpdatedAt) or 0) <= 900
    end

    self.ResumeRequested = false
    self.SessionId = ""
    self.TransitionToken = ""
    self.ExpectedPlaceId = 0
    self.TransitionAt = 0
    self.StartedAt = 0
    self.RunStartedAt = 0
    self.RunCashStart = 0
    self.RunWinsStart = 0
    self.LastCredzBalance = self:GetCash()
    self.LastWins = self:GetWins()
    self.PendingCredz = 0
    self.PendingWins = 0
    self.GateStartedAt = 0
    self.PendingFinish = false
    self.FinishCrossed = false
    self.PendingAt = 0
    self.LastGameJob = ""
    self.LastError = "None"
    self.GateText = "--"

    for name in self.Stats do
        self.Stats[name] = 0
    end

    if autoIntent then
        self.AutoEnabled = true
        self.ResumeRequested = true
        self.QueueStatus = "Auto-started from saved config"
    end
end

function farm:ApplyStoredOptions()
    if options.RunawaysAutoFarmLobbyDelay then
        options.RunawaysAutoFarmLobbyDelay:SetValue(self.Config.LobbyDelay)
    end

    if options.RunawaysAutoFarmGateTimeout then
        options.RunawaysAutoFarmGateTimeout:SetValue(self.Config.GateTimeout)
    end

    if options.RunawaysAutoFarmRetryDelay then
        options.RunawaysAutoFarmRetryDelay:SetValue(self.Config.RetryDelay)
    end

    if toggles.RunawaysAutoFarmSafeGateWait then
        toggles.RunawaysAutoFarmSafeGateWait:SetValue(self.Config.SafeGateWait)
    end

    if toggles.RunawaysAutoFarmAutoReplay then
        toggles.RunawaysAutoFarmAutoReplay:SetValue(self.Config.AutoReplay)
    end

    if toggles.RunawaysAutoFarmForceAssist then
        toggles.RunawaysAutoFarmForceAssist:SetValue(self.Config.ForceAssist)
    end
end

function farm:QueueTeleport(reason, expectedPlaceId)
    expectedPlaceId = tonumber(expectedPlaceId)
    local queueError = self:GetTeleportQueueError(expectedPlaceId)

    if queueError then
        self.QueueStatus = queueError
        self:UpdateUI()
        return false, self.QueueStatus
    end

    local queueFunction = self:GetQueueFunction()
    local loader = self:GetTeleportLoader()

    if self.QueueJob == game.JobId and self.TransitionToken ~= "" then
        self.ExpectedPlaceId = expectedPlaceId
        self.TransitionAt = os.time()

        if not self:Persist() then
            return false, "Transition state is unavailable"
        end

        self.QueueStatus = "Armed: " .. tostring(reason)
        self:UpdateUI()
        return true
    end

    local transitionToken = table.concat({
        tostring(self.SessionId),
        game.JobId,
        tostring(expectedPlaceId),
        tostring(os.time()),
        tostring(math.random(100000, 999999)),
    }, ":")

    self.TransitionToken = transitionToken
    self.ExpectedPlaceId = expectedPlaceId
    self.TransitionAt = os.time()

    if not self:Persist() or type(self.LastSnapshot) ~= "string" then
        return false, "Transition state is unavailable"
    end

    local snapshot = self.LastSnapshot

    local payload = string.format(
        "if not game:IsLoaded() then game.Loaded:Wait() end\n"
            .. "if game.PlaceId == %d or game.PlaceId == %d then\n"
            .. "local p = game:GetService(%q)\n"
            .. "while not p.LocalPlayer do task.wait() end\n"
            .. "local t = game:GetService(%q)\n"
            .. "local v = nil\n"
            .. "pcall(function() v = t:GetTeleportSetting(%q) end)\n"
            .. "if t:GetTeleportSetting(%q) ~= false and tostring(v or '') == %q then\n"
            .. "local e = getgenv and getgenv() or _G\n"
            .. "if e.RunawaysAutoFarmQueueExecution ~= %q then\n"
            .. "e.RunawaysAutoFarmQueueExecution = %q\n"
            .. "e.RunawaysAutoFarmQueueLoading = %q\n"
            .. "local s = false\n"
            .. "for i = 1, 3 do\n"
            .. "e.RunawaysAutoFarmTransitionToken = %q\n"
            .. "e.RunawaysAutoFarmQueuedState = %q\n"
            .. "local o = pcall(function()\n"
            .. "%s\n"
            .. "end)\n"
            .. "if o then s = true break end\n"
            .. "task.wait(i)\n"
            .. "end\n"
            .. "if e.RunawaysAutoFarmQueueLoading == %q then e.RunawaysAutoFarmQueueLoading = nil end\n"
            .. "if not s and e.RunawaysAutoFarmQueueExecution == %q then\n"
            .. "e.RunawaysAutoFarmQueueExecution = nil\n"
            .. "if e.RunawaysScriptLoading == coroutine.running() then\n"
            .. "e.RunawaysScriptLoading = nil\n"
            .. "e.RunawaysScriptLoadingAt = nil\n"
            .. "e.RunawaysScriptLoadingToken = nil\n"
            .. "end\n"
            .. "end\n"
            .. "end\n"
            .. "end\n"
            .. "end",
        self.LobbyPlaceId,
        self.GamePlaceId,
        "Players",
        "TeleportService",
        self.TransitionKey,
        self.EnabledKey,
        transitionToken,
        transitionToken,
        transitionToken,
        transitionToken,
        transitionToken,
        snapshot,
        loader,
        transitionToken,
        transitionToken
    )
    local ok, message = pcall(queueFunction, payload)

    if not ok then
        self.TransitionToken = ""
        self.ExpectedPlaceId = 0
        self.TransitionAt = 0
        self.QueueStatus = "Queue failed"
        self:Persist()
        self:UpdateUI()
        return false, tostring(message)
    end

    self.QueueJob = game.JobId
    self.QueueStatus = "Armed: " .. tostring(reason)
    self:UpdateUI()

    return true
end

function farm:GetOwnedCar()
    if not (flowOk and type(flowModule) == "table") then
        return
    end

    if not flow.PlayerDataClient or type(flow.PlayerDataClient.getObserver) ~= "function" then
        return
    end

    local ok, observer = pcall(flow.PlayerDataClient.getObserver, "cars")

    if not ok or not observer or type(observer.get) ~= "function" then
        return
    end

    local read, cars = pcall(observer.get, observer)

    if not read or type(cars) ~= "table" then
        return
    end

    local names = {}

    for name in cars do
        names[#names + 1] = tostring(name)
    end

    table.sort(names)

    return names[1]
end

function farm:WaitForTeleport(token, duration, failureGeneration)
    local expires = os.clock() + duration
    failureGeneration = tonumber(failureGeneration) or self.TeleportFailureGeneration

    if self.TeleportFailureGeneration ~= failureGeneration then
        return false, "Teleport failed"
    end

    repeat
        if self.TeleportFailureGeneration ~= failureGeneration then
            return false, "Teleport failed"
        end

        if self.Teleporting then
            return true, "Teleport started"
        end

        task.wait(0.25)
    until not self.Running
        or self.Token ~= token
        or library.Unloaded
        or self.TeleportFailureGeneration ~= failureGeneration
        or os.clock() >= expires

    if self.Teleporting and self.TeleportFailureGeneration == failureGeneration then
        return true, "Teleport started"
    end

    return false, "Teleport timed out"
end

function farm:DismissTeleportError()
    local guiService = game:GetService("GuiService")

    pcall(guiService.ClearError, guiService)

    local promptGui = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
    local overlay = promptGui and promptGui:FindFirstChild("promptOverlay")
    local errorPrompt = overlay and (overlay:FindFirstChild("ErrorPrompt") or overlay:FindFirstChild("errorPrompt"))

    if not errorPrompt then
        return
    end

    local ok, buttons = pcall(errorPrompt.QueryDescendants, errorPrompt, "TextButton")

    if not ok then
        return
    end

    for _, button in buttons do
        local text = tostring(button.Text or ""):lower()

        if text == "ok" or text:find("reconnect", 1, true) then
            if type(firesignal) == "function" then
                pcall(firesignal, button.MouseButton1Click)
            else
                pcall(button.Activate, button)
            end

            break
        end
    end
end

function farm:StartTeleportRecovery(token)
    if not self.Running or self.Token ~= token or library.Unloaded then
        return
    end

    -- recovery used to re-arm itself forever, which left TeleportRecovering true
    -- and silently wedged every loop in the farm
    if self.TeleportRetryCount >= 6 then
        self.TeleportRecovering = false
        self.Teleporting = false
        self.LastError = "Teleport recovery gave up after 6 attempts"
        self:SetPhase("Stopped", self.LastError)
        self:Stop()
        return
    end

    self.TeleportRecovering = true
    self.TeleportRecoveryGeneration += 1

    local generation = self.TeleportRecoveryGeneration
    local attempt = math.max(1, tonumber(self.TeleportRetryCount) or 1)
    local delays = { 2, 5, 10, 20, 30 }
    local delay = self.TeleportRetryDelay > 0 and self.TeleportRetryDelay or delays[math.min(attempt, #delays)]

    self.TeleportRetryDelay = 0
    self:SetPhase("Teleport Recovery", "Rejoining in " .. tostring(delay) .. " seconds | Attempt " .. tostring(attempt))
    self:Persist()

    task.spawn(function()
        local expires = os.clock() + delay

        repeat
            task.wait(0.25)
        until not self.Running
            or self.Token ~= token
            or library.Unloaded
            or self.TeleportRecoveryGeneration ~= generation
            or os.clock() >= expires

        if not self.Running
            or self.Token ~= token
            or library.Unloaded
            or self.TeleportRecoveryGeneration ~= generation
        then
            return
        end

        self:DismissTeleportError()

        local target = tonumber(self.TeleportRetryTarget)
        local retryOptions = self.TeleportRetryOptions
        local targetValid = target == self.LobbyPlaceId or target == self.GamePlaceId

        if not targetValid then
            target = self:IsAutoReplayEnabled() and self.GamePlaceId or self.LobbyPlaceId
        end

        local exactRetry = attempt <= 3
            and targetValid
            and typeof(retryOptions) == "Instance"
            and retryOptions:IsA("TeleportOptions")

        if not exactRetry then
            retryOptions = nil
        end

        self.QueueJob = nil
        self.Teleporting = false

        local queued, queueError = self:QueueTeleport("teleport recovery", target)

        if not queued then
            self.Stats.Retries += 1
            self.TeleportRetryCount += 1
            self.LastError = tostring(queueError)
            self:StartTeleportRecovery(token)
            return
        end

        self:SetPhase(
            exactRetry and "Retrying Teleport" or target == self.GamePlaceId and "Rejoining Game" or "Rejoining Lobby",
            "Recovery attempt " .. tostring(attempt)
        )
        self:Persist()

        local sourceJob = game.JobId
        local failureGeneration = self.TeleportFailureGeneration
        local called, teleportError = pcall(function()
            local teleportService = game:GetService("TeleportService")

            if exactRetry then
                teleportService:TeleportAsync(target, { player }, retryOptions)
            else
                teleportService:Teleport(target, player)
            end
        end)

        if not called then
            self.Teleporting = false
            self.Stats.Retries += 1
            self.TeleportRetryCount += 1
            self.LastError = tostring(teleportError)
            self:StartTeleportRecovery(token)
            return
        end

        local timeout = os.clock() + 30

        repeat
            task.wait(0.25)
        until not self.Running
            or self.Token ~= token
            or library.Unloaded
            or self.TeleportRecoveryGeneration ~= generation
            or self.TeleportFailureGeneration ~= failureGeneration
            or game.JobId ~= sourceJob
            or os.clock() >= timeout

        if self.Running
            and self.Token == token
            and not library.Unloaded
            and self.TeleportRecoveryGeneration == generation
            and self.TeleportFailureGeneration == failureGeneration
            and game.JobId == sourceJob
        then
            self.Teleporting = false
            self.Stats.Retries += 1
            self.TeleportRetryCount += 1
            self.LastError = "Teleport timed out"
            self:StartTeleportRecovery(token)
        end
    end)
end

function farm:HandleTeleportFailure(result, message, targetPlaceId, teleportOptions)
    if not self.Running or library.Unloaded then
        return
    end

    task.defer(self.DismissTeleportError, self)

    if os.clock() - self.LastTeleportFailureAt < 0.75 then
        return
    end

    self.LastTeleportFailureAt = os.clock()

    local target = tonumber(targetPlaceId)

    if target ~= self.LobbyPlaceId and target ~= self.GamePlaceId then
        target = tonumber(self.ExpectedPlaceId)
    end

    if target ~= self.LobbyPlaceId and target ~= self.GamePlaceId then
        target = self:GetContext() == "Game" and self:IsAutoReplayEnabled() and self.GamePlaceId
            or self.LobbyPlaceId
    end

    self.TeleportFailureGeneration += 1
    self.Teleporting = false
    self.QueueJob = nil
    self.ReplayRequested = false
    self.TeleportRetryCount += 1
    self.TeleportRetryTarget = target
    self.TeleportRetryOptions = typeof(teleportOptions) == "Instance" and teleportOptions or nil
    self.TeleportRetryDelay = result == Enum.TeleportResult.Flooded and 15 or 0
    self.Stats.Retries += 1
    self.LastError = tostring(message or result or "Teleport failed")
    self:SetCrossNoclip(false)
    self:SetPhase("Teleport Failed", self.LastError)
    self:Persist()
    self:StartTeleportRecovery(self.Token)
end

function farm:IsVisible(instance)
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local current = instance

    while current and current ~= playerGui do
        if current:IsA("GuiObject") and not current.Visible then
            return false
        end

        if current:IsA("LayerCollector") and not current.Enabled then
            return false
        end

        current = current.Parent
    end

    return current == playerGui
end

function farm:GetEndScreen()
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local endFrame = playerGui and playerGui:FindFirstChild("EndFrame", true)

    if not playerGui then
        return
    end

    local function visible(instance)
        local current = instance

        while current and current ~= playerGui do
            if current:IsA("GuiObject") and not current.Visible then
                return false
            end

            if current:IsA("LayerCollector") and not current.Enabled then
                return false
            end

            current = current.Parent
        end

        return current == playerGui
    end

    local function layer(instance)
        local current = instance

        while current and current ~= playerGui do
            if current:IsA("LayerCollector") then
                return current
            end

            current = current.Parent
        end

        return nil
    end

    if endFrame then
        if not visible(endFrame) then
            return
        end

        local escaped = endFrame:FindFirstChild("Escaped", true)
        local captured = endFrame:FindFirstChild("Captured", true)
        local option = endFrame:FindFirstChild("Replay", true) or endFrame:FindFirstChild("Lobby", true)

        if escaped and visible(escaped) then
            return endFrame, "Escaped"
        end

        if captured and visible(captured) then
            return endFrame, "Captured"
        end

        if option and visible(option) then
            return endFrame, "Ended"
        end

        for _, instance in endFrame:GetDescendants() do
            if instance:IsA("GuiObject") and visible(instance) then
                local name = instance.Name:lower()
                local text = (instance:IsA("TextLabel") or instance:IsA("TextButton")) and instance.Text:lower() or ""
                local isCaptured = name == "captured" or text == "captured"
                local isEscaped = name == "escaped" or text == "escaped"

                if isCaptured or isEscaped then
                    return endFrame, isCaptured and "Captured" or "Escaped"
                end
            end
        end

        return
    end

    if os.clock() - self.LastEndScreenScanAt < 1 then
        return
    end

    self.LastEndScreenScanAt = os.clock()

    -- Exact matches only. A substring match across every visible GuiObject used to
    -- fire on any unrelated label that merely mentioned the word, which made the
    -- state machine treat a live round as finished and stall before the gate.
    for _, instance in playerGui:GetDescendants() do
        if instance:IsA("GuiObject") and visible(instance) then
            local name = instance.Name:lower()
            local text = (instance:IsA("TextLabel") or instance:IsA("TextButton")) and instance.Text:lower() or ""
            local isCaptured = name == "captured" or text == "captured"
            local isEscaped = name == "escaped" or text == "escaped"

            if isCaptured or isEscaped then
                return layer(instance) or endFrame, isCaptured and "Captured" or "Escaped"
            end
        end
    end

    return nil
end

function farm:RequestReplay()
    local lastError = "Replay is unavailable"

    if flowOk and type(flowModule) == "table"
        and flow.GameManager and type(flow.GameManager.Replay) == "function"
    then
        local called, result = pcall(flow.GameManager.Replay)

        if called and result ~= false then
            return true
        end

        lastError = tostring(result or "Replay was rejected")
    end

    return false, lastError
end

function farm:GetResultCredz(endFrame)
    local total = endFrame and endFrame:FindFirstChild("Total", true)

    if not total then
        return
    end

    for _, name in { "RobloxPlus", "Credz" } do
        local label = total:FindFirstChild(name, true)

        if label and (label:IsA("TextLabel") or label:IsA("TextButton")) and self:IsVisible(label) then
            local digits = tostring(label.Text or ""):gsub("[^%d]", "")
            local value = tonumber(digits)

            if value then
                return value
            end
        end
    end

    for _, label in total:GetDescendants() do
        if (label:IsA("TextLabel") or label:IsA("TextButton")) and self:IsVisible(label) then
            local text = tostring(label.Text or "")

            if text:lower():find("total:", 1, true) then
                local digits = text:gsub("[^%d]", "")
                local value = tonumber(digits)

                if value then
                    return value
                end
            end
        end
    end

    return nil
end

function farm:FinalizeRun(outcome, detail, reward)
    if self.ResultFinalized then
        return
    end

    local duration = self.RunStartedAt > 0 and math.max(0, os.time() - self.RunStartedAt) or 0
    local active = self.RunStartedAt > 0

    self:SyncProgress()

    local effectiveCredz = self:GetEffectiveCredz()
    local effectiveWins = self:GetEffectiveWins()
    local earned = math.max(0, effectiveCredz - (tonumber(self.RunCashStart) or effectiveCredz))
    local reported = tonumber(reward)

    if active and reported and reported > earned then
        local missing = reported - earned

        self.Stats.CashEarned += missing
        self.PendingCredz += missing
        effectiveCredz += missing
        earned = reported
    end

    self:ReleaseSafeZone()
    self.ResultFinalized = true

    if active then
        self.Stats.Attempts = math.max(
            self.Stats.Attempts,
            self.Stats.Completed + self.Stats.Failed + 1
        )
    end

    if active and outcome == "Escaped" then
        self.Stats.Completed += 1

        if effectiveWins <= (tonumber(self.RunWinsStart) or effectiveWins) then
            self.PendingWins += 1
            effectiveWins += 1
        end

        self.Stats.LastRun = duration
        self.Stats.TotalRunTime += duration

        if self.Stats.BestRun == 0 or duration < self.Stats.BestRun then
            self.Stats.BestRun = duration
        end
    elseif active then
        self.Stats.Failed += 1
        self.Stats.LastRun = duration
    end

    self.PendingFinish = false
    self.FinishCrossed = false
    self.PendingAt = 0
    self.RunStartedAt = 0
    self.RunCashStart = effectiveCredz
    self.RunWinsStart = effectiveWins
    self.GateStartedAt = 0
    self.GatePassage = nil
    self.GateText = "--"

    if outcome == "Escaped" then
        self.LastError = "None"
        self:SetPhase("Run Completed", (detail or "Finish confirmed") .. " | +" .. tostring(math.floor(earned)) .. " Credz")
    else
        self.LastError = "Run captured"
        self:SetPhase("Run Captured", detail or "Preparing the next run")
    end

    self:Persist()
end

function farm:CompletePending(detail)
    if not self.PendingFinish then
        return
    end

    local valid = self.LastGameJob ~= ""
        and self.LastGameJob ~= game.JobId
        and self.PendingAt > 0
        and self.FinishCrossed
        and os.time() - self.PendingAt <= 600

    if not valid then
        self.PendingFinish = false
        self.FinishCrossed = false
        self.PendingAt = 0
        self.LastError = "Pending completion expired"
        return
    end

    self:FinalizeRun("Escaped", detail or "Transition confirmed")
end

function farm:HandleEndScreen(token)
    if self.ResultBusy then
        return false, "Result is already being handled"
    end

    local endFrame, outcome = self:GetEndScreen()

    if not endFrame then
        return false, "Result screen is unavailable"
    end

    self.ResultBusy = true
    self:ReleaseSafeZone()
    self:SetCrossNoclip(false)
    local resultMap = workspace:FindFirstChild("Map")
    local resultCharacter = player.Character
    local resultRoot = resultCharacter and resultCharacter:FindFirstChild("HumanoidRootPart")
    local resultPosition = resultRoot and resultRoot.Position
    local resultPrompt = teleports:GetEndPrompt()
    local resultPromptEnabled = resultPrompt and resultPrompt.Enabled

    if outcome == "Ended" then
        local outcomeExpires = os.clock() + 2

        repeat
            task.wait(0.1)
            endFrame, outcome = self:GetEndScreen()
        until outcome ~= "Ended"
            or not endFrame
            or not self.Running
            or self.Token ~= token
            or os.clock() >= outcomeExpires
    end

    if outcome == "Escaped" or outcome == "Ended" and self.FinishCrossed then
        outcome = "Escaped"
    else
        outcome = "Captured"
    end

    local reward
    local rewardExpires = os.clock() + 3

    repeat
        reward = self:GetResultCredz(endFrame)

        if reward then
            break
        end

        task.wait(0.1)
    until not self.Running
        or self.Token ~= token
        or library.Unloaded
        or os.clock() >= rewardExpires

    if not self.Running or self.Token ~= token or library.Unloaded then
        self.ResultBusy = false
        return true, "Stopped"
    end

    self:FinalizeRun(
        outcome,
        outcome == "Escaped" and "Finish confirmed" or "The run ended before the finish",
        reward
    )

    if not self.Running or self.Token ~= token then
        self.ResultBusy = false
        return true, "Stopped"
    end

    if self:IsAutoReplayEnabled() then
        self.ReplayRequested = true
        self:SetPhase("Auto Replay", "Requesting a replay")

        local replayExpires = os.clock() + 20
        local nextRequestAt = os.clock()
        local queued = false
        local requests = 0
        local restarted = false

        repeat
            self.RunHeartbeat = os.clock()

            if self.Teleporting then
                self.ResultBusy = false
                return true, "Teleporting"
            end

            local currentFrame = self:GetEndScreen()

            if not currentFrame then
                local currentMap = workspace:FindFirstChild("Map")
                local currentCharacter = player.Character
                local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
                local currentRoot = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart")
                local currentPrompt = teleports:GetEndPrompt()
                local reset = currentMap and resultMap and currentMap ~= resultMap
                    or currentCharacter and resultCharacter and currentCharacter ~= resultCharacter
                    or currentPrompt and resultPrompt and currentPrompt ~= resultPrompt
                    or resultPrompt
                        and currentPrompt == resultPrompt
                        and not resultPromptEnabled
                        and currentPrompt.Enabled
                    or resultPosition
                        and currentRoot
                        and (currentRoot.Position - resultPosition).Magnitude >= 250

                if reset and currentHumanoid and currentHumanoid.Health > 0 then
                    self.LastGameJob = ""
                    self.ReplayRequested = false
                    self.ResultBusy = false
                    self.QueueStatus = "Replay started"
                    self:Persist()
                    return true, "Replay"
                end
            else
                if os.clock() >= nextRequestAt then
                    if not queued then
                        local queueError
                        queued, queueError = self:QueueTeleport("replay", self.GamePlaceId)

                        if not queued then
                            self.LastError = tostring(queueError)
                            self:SetPhase("Auto Replay", "Waiting for the teleport loader")
                            nextRequestAt = os.clock() + 3
                        end
                    end

                    if queued and requests < 5 then
                        local firstRequest = requests == 0

                        if firstRequest then
                            self.Stats.Replays += 1
                            self:Persist()
                        end

                        local requested = self:RequestReplay()

                        if requested then
                            requests += 1
                            self:SetPhase("Auto Replay", "Replay requested")
                        else
                            if firstRequest then
                                self.Stats.Replays = math.max(0, self.Stats.Replays - 1)
                                self:Persist()
                            end
                        end

                        nextRequestAt = os.clock() + 2
                    elseif queued then
                        nextRequestAt = os.clock() + 3
                    else
                        nextRequestAt = os.clock() + 0.5
                    end
                end
            end

            task.wait(0.25)
        until not self.Running
            or self.Token ~= token
            or library.Unloaded
            or restarted
            or os.clock() >= replayExpires

        self.ReplayRequested = false

        if not self.Running or self.Token ~= token or library.Unloaded then
            self.ResultBusy = false
            return true, "Stopped"
        end

        local queuedReplay, queueError = self:QueueTeleport("replay recovery", self.GamePlaceId)

        if not queuedReplay then
            self.ResultBusy = false
            return false, tostring(queueError)
        end

        restarted = true
        self:SetPhase("Restarting Game", "Replay did not start")

        local failureGeneration = self.TeleportFailureGeneration
        local teleportService = game:GetService("TeleportService")
        local called, replayError = pcall(teleportService.Teleport, teleportService, self.GamePlaceId, player)

        if not called then
            self.ResultBusy = false
            return false, tostring(replayError)
        end

        if self:WaitForTeleport(token, 30, failureGeneration) then
            return true, "Teleporting"
        end

        if self.TeleportRecovering then
            return false, "Teleport recovery active"
        end

        self.ResultBusy = false

        return false, "Game restart did not start"
    end

    self.ReplayRequested = false

    if not self.Running or self.Token ~= token then
        self.ResultBusy = false
        return true, "Stopped"
    end

    local hasBackToLobby = flowOk and type(flowModule) == "table"
        and flow.GameManager and type(flow.GameManager.BackToLobby) == "function"

    local queued, queueError = self:QueueTeleport("lobby", self.LobbyPlaceId)

    if not queued then
        self.LastError = tostring(queueError)
    end

    if not hasBackToLobby then
        local failureGeneration = self.TeleportFailureGeneration
        local teleportService = game:GetService("TeleportService")
        local called, lobbyError = pcall(teleportService.Teleport, teleportService, self.LobbyPlaceId, player)

        if not called then
            self.ResultBusy = false
            return false, tostring(lobbyError)
        end

        self:SetPhase("Returning to Lobby", hasBackToLobby and "Replay was unavailable" or "Lobby API is unavailable")

        if self:WaitForTeleport(token, 30, failureGeneration) then
            return true, "Teleporting"
        end

        self.ResultBusy = false

        return false, "Lobby teleport did not start"
    end

    local failureGeneration = self.TeleportFailureGeneration
    local called, lobbyError = pcall(flow.GameManager.BackToLobby)

    if not called then
        self.ResultBusy = false
        return false, tostring(lobbyError)
    end

    self:SetPhase("Returning to Lobby", "Replay was unavailable")

    if self:WaitForTeleport(token, 30, failureGeneration) then
        return true, "Teleporting"
    end

    self.ResultBusy = false

    return false, "Lobby teleport did not start"
end

function farm:RunLobby(token)
    if not (flowOk and type(flowModule) == "table")
        or not flow.LobbyServer
        or type(flow.LobbyServer.play) ~= "function"
        or type(flow.LobbyServer.create) ~= "function"
        or type(flow.LobbyServer.exit) ~= "function"
    then
        return false, "Lobby API is unavailable"
    end

    if self.PendingFinish then
        self:SetPhase("Confirming Run", "Waiting for the lobby reward")

        local rewardExpires = os.clock() + 8

        repeat
            self:SyncProgress()

            if self:GetEffectiveWins() > (tonumber(self.RunWinsStart) or self:GetEffectiveWins()) then
                break
            end

            task.wait(0.5)
        until not self.Running or self.Token ~= token or os.clock() >= rewardExpires

        if not self.Running or self.Token ~= token then
            return true
        end

        self:CompletePending("Returned to lobby")
    end

    self:SetPhase("Lobby", "Waiting before the next game")

    local delay = options.RunawaysAutoFarmLobbyDelay and options.RunawaysAutoFarmLobbyDelay.Value or self.Config.LobbyDelay
    local expires = os.clock() + delay

    repeat
        task.wait(0.1)
    until not self.Running or self.Token ~= token or os.clock() >= expires

    if not self.Running or self.Token ~= token then
        return true
    end

    local car = self:GetOwnedCar()

    if not car then
        return false, "No owned vehicle is available"
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local createGui = playerGui and (playerGui:FindFirstChild("CreateLobbyGui") or playerGui:WaitForChild("CreateLobbyGui", 10))

    if not createGui then
        return false, "Create lobby UI is unavailable"
    end

    local queued, queueError = self:QueueTeleport("game", self.GamePlaceId)

    if not queued then
        return false, queueError
    end

    local createFrame = createGui and createGui:FindFirstChild("Frame")
    local exitFrame = createGui and createGui:FindFirstChild("Exit")

    for attempt = 1, 2 do
        if not self.Running or self.Token ~= token then
            return true
        end

        createFrame = createGui:FindFirstChild("Frame")
        exitFrame = createGui:FindFirstChild("Exit")

        if exitFrame and exitFrame.Visible then
            self:SetPhase("Lobby", "Leaving an existing queue")
            pcall(flow.LobbyServer.exit)

            local leaveExpires = os.clock() + 5

            repeat
                task.wait(0.1)
            until not exitFrame.Visible or not self.Running or self.Token ~= token or os.clock() >= leaveExpires

            if exitFrame.Visible then
                self.Stats.Retries += 1
                task.wait(attempt)
                continue
            end
        end

        if not createFrame or not createFrame.Visible then
            self:SetPhase("Lobby", "Requesting the next game")

            local played, playError = pcall(flow.LobbyServer.play)

            if not played then
                return false, tostring(playError)
            end

            local selectionExpires = os.clock() + 10

            repeat
                if self.Teleporting then
                    return true
                end

                task.wait(0.2)
            until not self.Running
                or self.Token ~= token
                or createFrame and createFrame.Visible
                or exitFrame and exitFrame.Visible
                or os.clock() >= selectionExpires
        end

        if exitFrame and exitFrame.Visible then
            self:SetPhase("Lobby", "Leaving an existing queue")
            self.Stats.Retries += 1
            pcall(flow.LobbyServer.exit)
            task.wait(attempt * 1.5)
            continue
        end

        if not createFrame or not createFrame.Visible then
            self.Stats.Retries += 1
            task.wait(attempt)
            continue
        end

        self:SetPhase("Creating Game", "Vehicle: " .. car .. " | Solo | Friends")

        createFrame.Visible = false

        local failureGeneration = self.TeleportFailureGeneration
        local created, createError = pcall(flow.LobbyServer.create, {
            maxPlayers = 1,
            permissions = "Friends",
            car = car,
        })

        if not created then
            return false, tostring(createError)
        end

        local joinExpires = os.clock() + 5

        repeat
            task.wait(0.2)
        until self.Teleporting
            or exitFrame and exitFrame.Visible
            or not self.Running
            or self.Token ~= token
            or os.clock() >= joinExpires

        local teleportStarted = self.Teleporting

        if not teleportStarted then
            teleportStarted = self:WaitForTeleport(token, 20, failureGeneration)
        end

        if teleportStarted then
            return true
        end

        if self.TeleportRecovering then
            return false, "Teleport recovery active"
        end

        self.Stats.Retries += 1
        pcall(flow.LobbyServer.exit)

        if flow.LobbyClient and type(flow.LobbyClient.forceLeave_event) == "function" then
            pcall(flow.LobbyClient.forceLeave_event)
        end

        task.wait(attempt * 2)
    end

    self:SetPhase("Refreshing Lobby", "Game creation timed out")

    local requeued, requeueError = self:QueueTeleport("lobby retry", self.LobbyPlaceId)

    if not requeued then
        return false, requeueError
    end

    local failureGeneration = self.TeleportFailureGeneration
    local teleportService = game:GetService("TeleportService")
    local teleported, teleportError = pcall(teleportService.Teleport, teleportService, self.LobbyPlaceId, player)

    if not teleported then
        return false, tostring(teleportError)
    end

    if self:WaitForTeleport(token, 30, failureGeneration) then
        return true, "Teleporting"
    end

    return false, "Lobby refresh did not start"
end

-- STATE 1: teleport to the end gate.
function farm:ReachGate(token)
    self:SetPhase("Traveling", "Teleporting to the end gate")
    local endZ
    local expires = os.clock() + 20

    repeat
        endZ = teleports:GetEndZ()

        if not endZ then
            task.wait(0.25)
        end
    until endZ or not self.Running or self.Token ~= token or library.Unloaded or os.clock() >= expires

    if not endZ then
        return nil, nil, nil, "End position is unavailable"
    end

    local start = teleports:GetStartCFrame()
    local direction = (not start or endZ >= start.Position.Z) and 1 or -1
    local anchor = teleports:GetEndAnchor(endZ, direction)

    teleports:Stream(anchor)

    local prompt = teleports:GetEndPrompt()

    if not prompt then
        local road = teleports:GetRoadNear(endZ)
        local position

        if road then
            position = Vector3.new(
                road.Position.X,
                road.Position.Y + road.Size.Y * 0.5 + 5,
                endZ - direction * 30
            )
        else
            position = Vector3.new(anchor.X, anchor.Y + 4, endZ - direction * 30)
        end

        teleports:Move(
            CFrame.lookAt(position, position + Vector3.new(0, 0, direction), Vector3.yAxis),
            nil,
            false
        )
        teleports:Stream(anchor)
    end

    expires = os.clock() + 20

    repeat
        prompt = teleports:GetEndPrompt()

        if prompt then
            local destination = teleports:GetEndPromptDestination(prompt, direction)

            if destination then
                teleports:Move(destination, nil, false)
                task.wait(0.4)

                local character = player.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                local root = character and character:FindFirstChild("HumanoidRootPart")

                if humanoid
                    and root
                    and humanoid.Health > 0
                    and (root.Position - destination.Position).Magnitude <= math.max(prompt.MaxActivationDistance + 5, 14)
                then
                    self.GatePassage = self.GatePassage or self:GetGatePassage(prompt, direction, endZ)
                    return prompt, direction, endZ
                end
            end
        end

        task.wait(0.25)
    until not self.Running or self.Token ~= token or library.Unloaded or os.clock() >= expires

    if self.Running and self.Token == token and self.GateStartedAt > 0 and self.LastGameJob == game.JobId then
        self.GatePassage = self.GatePassage or self:GetGatePassage(nil, direction, endZ)

        if self.GatePassage then
            local position = self.GatePassage.Position - Vector3.new(0, 0, direction * 8)

            teleports:Move(
                CFrame.lookAt(position, position + Vector3.new(0, 0, direction), Vector3.yAxis),
                nil,
                false
            )

            return nil, direction, endZ, nil, true
        end
    end

    return nil, nil, nil, "End gate prompt was not reached"
end

function farm:GetFinalDoor(prompt)
    local finalDoor = prompt and prompt:FindFirstAncestor("FinalDoor")

    if finalDoor then
        return finalDoor
    end

    local map = workspace:FindFirstChild("Map")
    local buildings = map and map:FindFirstChild("Buildings")
    local customs = buildings and buildings:FindFirstChild("CustomsFinal")

    return customs and customs:FindFirstChild("FinalDoor", true)
end

function farm:GetGateTimer(prompt)
    local finalDoor = self:GetFinalDoor(prompt)

    if not finalDoor then
        return
    end

    local ok, labels = pcall(finalDoor.QueryDescendants, finalDoor, "TextLabel")

    if not ok then
        labels = {}

        for _, instance in finalDoor:GetDescendants() do
            if instance:IsA("TextLabel") then
                labels[#labels + 1] = instance
            end
        end
    end

    for _, label in labels do
        local text = label.Text
        local minutes, seconds = text:match("(%d+)%s*m%s*(%d+)%s*s")

        if not minutes then
            minutes, seconds = text:match("(%d+)%s*:%s*(%d+)")
        end

        if minutes and seconds then
            return (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0), text
        end
    end

    return nil
end

function farm:GetGatePassage(prompt, direction, endZ)
    local finalDoor = self:GetFinalDoor(prompt)
    local command = finalDoor and finalDoor:FindFirstChild("Command", true)
    local leftHolder = finalDoor and finalDoor:FindFirstChild("DoorL")
    local rightHolder = finalDoor and finalDoor:FindFirstChild("DoorR")
    local leftDoor = leftHolder and leftHolder:FindFirstChild("Door", true)
    local rightDoor = rightHolder and rightHolder:FindFirstChild("Door", true)
    local best
    local bestScore = -math.huge

    if finalDoor then
        local ok, parts = pcall(finalDoor.QueryDescendants, finalDoor, "BasePart")

        if not ok then
            parts = {}

            for _, instance in finalDoor:GetDescendants() do
                if instance:IsA("BasePart") then
                    parts[#parts + 1] = instance
                end
            end
        end

        for _, part in parts do
            if part.CanCollide
                and part.Transparency < 0.95
                and part.Size.Y >= 4
                and (not command or not part:IsDescendantOf(command))
            then
                local name = part.Name:lower()
                local score = part.Size.X * part.Size.Y / math.max(part.Size.Z, 0.5)

                if name:find("door", 1, true) or name:find("gate", 1, true) then
                    score += 1000000
                elseif name:find("wall", 1, true) or name:find("frame", 1, true) then
                    score -= 1000000
                end

                if score > bestScore then
                    best = part
                    bestScore = score
                end
            end
        end
    end

    local road = teleports:GetRoadNear(endZ)
    local position = leftDoor
        and leftDoor:IsA("BasePart")
        and rightDoor
        and rightDoor:IsA("BasePart")
        and (leftDoor.Position + rightDoor.Position) * 0.5
        or best and best.Position
        or road and Vector3.new(road.Position.X, road.Position.Y + road.Size.Y * 0.5 + 3.5, endZ)

    if not position then
        local holder = prompt and prompt.Parent

        if holder and holder:IsA("Attachment") then
            position = holder.WorldPosition
        elseif holder and holder:IsA("BasePart") then
            position = holder.Position
        end
    end

    if not position then
        return
    end

    local parameters = RaycastParams.new()
    local excludes = {}

    parameters.FilterType = Enum.RaycastFilterType.Exclude

    if player.Character then
        excludes[#excludes + 1] = player.Character
    end

    if finalDoor then
        excludes[#excludes + 1] = finalDoor
    end

    parameters.FilterDescendantsInstances = excludes
    parameters.RespectCanCollide = true

    local result = workspace:Raycast(position + Vector3.yAxis * 30, -Vector3.yAxis * 80, parameters)

    if result then
        position = Vector3.new(position.X, result.Position.Y + 3.5, position.Z)
    elseif road then
        position = Vector3.new(position.X, road.Position.Y + road.Size.Y * 0.5 + 3.5, position.Z)
    end

    return {
        Position = position,
        Direction = direction,
        FinalDoor = finalDoor,
        DoorL = leftDoor,
        DoorR = rightDoor,
    }
end

function farm:IsGatePassageOpen(passage)
    if not passage or typeof(passage.Position) ~= "Vector3" then
        return false
    end

    local finalDoor = passage.FinalDoor

    if not finalDoor or not finalDoor.Parent then
        finalDoor = self:GetFinalDoor()
        passage.FinalDoor = finalDoor
    end

    if finalDoor then
        local leftHolder = finalDoor:FindFirstChild("DoorL")
        local rightHolder = finalDoor:FindFirstChild("DoorR")
        local currentLeft = leftHolder and leftHolder:FindFirstChild("Door", true)
        local currentRight = rightHolder and rightHolder:FindFirstChild("Door", true)

        if currentLeft and currentLeft:IsA("BasePart") then
            passage.DoorL = currentLeft
        end

        if currentRight and currentRight:IsA("BasePart") then
            passage.DoorR = currentRight
        end
    end

    local leftDoor = passage.DoorL
    local rightDoor = passage.DoorR

    if leftDoor
        and leftDoor.Parent
        and leftDoor:IsA("BasePart")
        and rightDoor
        and rightDoor.Parent
        and rightDoor:IsA("BasePart")
    then
        local difference = leftDoor.Position - rightDoor.Position

        if difference.Magnitude > 0.1 then
            local axis = difference.Unit
            local leftHalf = math.abs(leftDoor.CFrame.RightVector:Dot(axis)) * leftDoor.Size.X * 0.5
                + math.abs(leftDoor.CFrame.UpVector:Dot(axis)) * leftDoor.Size.Y * 0.5
                + math.abs(leftDoor.CFrame.LookVector:Dot(axis)) * leftDoor.Size.Z * 0.5
            local rightHalf = math.abs(rightDoor.CFrame.RightVector:Dot(axis)) * rightDoor.Size.X * 0.5
                + math.abs(rightDoor.CFrame.UpVector:Dot(axis)) * rightDoor.Size.Y * 0.5
                + math.abs(rightDoor.CFrame.LookVector:Dot(axis)) * rightDoor.Size.Z * 0.5
            local midpoint = (leftDoor.Position + rightDoor.Position) * 0.5

            passage.Position = Vector3.new(midpoint.X, passage.Position.Y, midpoint.Z)

            return difference.Magnitude - leftHalf - rightHalf >= 12
        end
    end

    local parameters = RaycastParams.new()

    parameters.FilterType = Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances = player.Character and { player.Character } or {}
    parameters.RespectCanCollide = true

    local direction = Vector3.new(0, 0, passage.Direction)
    local result = workspace:Raycast(passage.Position - direction * 10, direction * 20, parameters)

    return result == nil
end

function farm:IsGateWindowOpen()
    if flowOk and type(flowModule) == "table"
        and flow.CrimesGui
        and type(flow.CrimesGui.StartEndTimer_event) == "function"
        and debug
        and type(debug.getupvalues) == "function"
    then
        local ok, values = pcall(debug.getupvalues, flow.CrimesGui.StartEndTimer_event)

        if ok and type(values) == "table" then
            local opensAt = tonumber(values[2])
            local closesAt = tonumber(values[3])
            local now = workspace:GetServerTimeNow()

            if opensAt and closesAt and now >= opensAt and now < closesAt then
                return true
            end
        end
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local hud = playerGui and playerGui:FindFirstChild("HudGui")
    local events = hud and hud:FindFirstChild("Events")
    local closing = events and events:FindFirstChild("Closing")

    if not closing or not closing.Visible then
        return false
    end

    local timer = closing:FindFirstChild("Timer")
    local text = timer and timer.Text or ""
    local minutes, seconds = text:match("(%d+)%s*:%s*(%d+)")

    if not minutes then
        return true
    end

    local total = (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0)

    return total > 0
end

-- STATE 2: activate the gate button.
function farm:ActivateGate(prompt, direction, token)
    if not self.Running or self.Token ~= token then
        return false, "Auto Farm stopped"
    end

    if self.GateStartedAt > 0 and self.LastGameJob == game.JobId then
        local seconds = self:GetGateTimer(prompt)

        if not prompt.Enabled or seconds and seconds < 120 then
            return true
        end

        self.GateStartedAt = 0
    end

    self:SetPhase("Activating Gate", "Starting the two minute countdown")

    for attempt = 1, 3 do
        if not self.Running or self.Token ~= token then
            return false, "Auto Farm stopped"
        end

        local destination = teleports:GetEndPromptDestination(prompt, direction)

        if destination then
            teleports:Move(destination, nil, false)
            task.wait(0.4)
        end

        if not self.Running or self.Token ~= token then
            return false, "Auto Farm stopped"
        end

        local before = self:GetGateTimer(prompt)
        local fired = false
        local readPrompt, firePrompt = pcall(getGlobal, "fireproximityprompt")

        if readPrompt and type(firePrompt) == "function" then
            fired = pcall(firePrompt, prompt)
        end

        if not fired then
            fired = pcall(function()
                local duration = prompt.HoldDuration

                prompt.HoldDuration = 0
                prompt:InputHoldBegin()
                task.wait(0.1)
                prompt:InputHoldEnd()
                prompt.HoldDuration = duration
            end)
        end

        if not self.Running or self.Token ~= token then
            return false, "Auto Farm stopped"
        end

        if fired then
            local expires = os.clock() + 6

            repeat
                local seconds = self:GetGateTimer(prompt)
                local accepted = not prompt.Enabled
                    or seconds and before and seconds < before
                    or seconds and seconds < 120

                if accepted then
                    self.GateStartedAt = os.time() - (seconds and math.max(0, 120 - seconds) or 0)
                    self.Stats.GateActivations += 1
                    self:Persist()

                    return true
                end

                task.wait(0.25)
            until os.clock() >= expires
                or not self.Running
                or self.Token ~= token
                or library.Unloaded

            if not self.Running or self.Token ~= token then
                return false, "Auto Farm stopped"
            end
        end

        self.Stats.Retries += 1
        task.wait(attempt)
    end

    self.GateStartedAt = 0

    return false, "Gate activation was not confirmed"
end

function farm:GetSafeCFrame()
    local passage = self.GatePassage

    if not passage or typeof(passage.Position) ~= "Vector3" then
        return
    end

    local finalDoor = passage.FinalDoor
    local customsBuilding = finalDoor and finalDoor:FindFirstAncestor("CustomsBuilding")
    local prompt = teleports:GetEndPrompt()
    local holder = prompt and prompt.Parent
    local promptPosition = holder and holder:IsA("Attachment") and holder.WorldPosition
        or holder and holder:IsA("BasePart") and holder.Position
        or passage.Position
    local bestFloor
    local bestDistance = math.huge

    if customsBuilding then
        for _, office in customsBuilding:GetChildren() do
            if office.Name == "CustomsOffice" then
                local floor = office:FindFirstChild("Floor", true)

                if floor and floor:IsA("BasePart") then
                    local distance = (floor.Position - promptPosition).Magnitude

                    if distance < bestDistance then
                        bestFloor = floor
                        bestDistance = distance
                    end
                end
            end
        end
    end

    if bestFloor then
        local position = bestFloor.CFrame:PointToWorldSpace(Vector3.new(5, bestFloor.Size.Y * 0.5 + 3.25, 8))
        local rayParameters = RaycastParams.new()
        local overlapParameters = OverlapParams.new()

        rayParameters.FilterType = Enum.RaycastFilterType.Exclude
        rayParameters.FilterDescendantsInstances = player.Character and { player.Character } or {}
        rayParameters.RespectCanCollide = true
        overlapParameters.FilterType = Enum.RaycastFilterType.Exclude
        overlapParameters.FilterDescendantsInstances = player.Character and { player.Character } or {}

        local floorHit = workspace:Raycast(position, -Vector3.yAxis * 6, rayParameters)
        local roofHit = workspace:Raycast(position, Vector3.yAxis * 30, rayParameters)
        local blocked = false

        for _, part in workspace:GetPartBoundsInBox(CFrame.new(position), Vector3.new(3.5, 5.5, 3.5), overlapParameters) do
            if part.CanCollide and part ~= bestFloor then
                blocked = true
                break
            end
        end

        if floorHit and roofHit and not blocked then
            return CFrame.lookAt(
                position,
                Vector3.new(promptPosition.X, position.Y, promptPosition.Z),
                Vector3.yAxis
            )
        end
    end

    return
end

function farm:DisengageHelicopter()
    if flowOk and type(flowModule) == "table"
        and flow.PoliceHeli and type(flow.PoliceHeli.Despawn) == "function"
    then
        pcall(flow.PoliceHeli.Despawn)
    end
end

function farm:ReleaseSafeZone()
    local character = self.SafeCharacter
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if root and self.SafeRootAnchored ~= nil then
        root.Anchored = self.SafeRootAnchored
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end

    self.SafeCFrame = nil
    self.SafeCharacter = nil
    self.SafeRootAnchored = nil
end

-- STATE 3: hold a protected position while the gate counts down.
function farm:MoveToSafeZone(token)
    if not self:IsSafeGateWaitEnabled() then
        self:ReleaseSafeZone()
        return true
    end

    if not self.Running or self.Token ~= token then
        return false, "Auto Farm stopped"
    end

    local destination = self:GetSafeCFrame()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not destination or not humanoid or not root or humanoid.Health <= 0 then
        return false, "Safe gate position is unavailable"
    end

    self:ReleaseSafeZone()
    self.SafeCharacter = character
    self.SafeRootAnchored = root.Anchored
    self.SafeCFrame = destination

    local moved = teleports:Move(destination, nil, false)

    if not moved then
        self:ReleaseSafeZone()
        return false, "Could not enter the safe gate position"
    end

    if not self.Running or self.Token ~= token or library.Unloaded then
        self:ReleaseSafeZone()
        return false, "Auto Farm stopped"
    end

    if not self:IsSafeGateWaitEnabled() then
        self:ReleaseSafeZone()
        return true
    end

    if player.Character ~= character or self.SafeCharacter ~= character or self.SafeCFrame ~= destination then
        self:ReleaseSafeZone()
        return false, "Character changed while entering the safe zone"
    end

    root = character:FindFirstChild("HumanoidRootPart")

    if not root then
        self:ReleaseSafeZone()
        return false, "Character changed while entering the safe zone"
    end

    root.CFrame = destination
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.Anchored = true
    self:DisengageHelicopter()
    self:SetPhase("Safe Gate Wait", "Protected from the helicopter until the gate opens")

    return true
end

function farm:MaintainSafeZone(token)
    if not self:IsSafeGateWaitEnabled() then
        self:ReleaseSafeZone()
        return true
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if character ~= self.SafeCharacter or not self.SafeCFrame then
        return self:MoveToSafeZone(token)
    end

    if not humanoid or not root or humanoid.Health <= 0 then
        return false, "Character is unavailable in the safe zone"
    end

    root.CFrame = self.SafeCFrame
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.Anchored = true

    return true
end

function farm:WaitForGate(token, prompt)
    local timeout = options.RunawaysAutoFarmGateTimeout and options.RunawaysAutoFarmGateTimeout.Value or self.Config.GateTimeout
    local expires = os.clock() + timeout

    self:SetPhase("Waiting for Gate", "Holding position until the gate opens")

    repeat
        self.RunHeartbeat = os.clock()
        local endFrame = self:GetEndScreen()

        if endFrame then
            self:ReleaseSafeZone()
            local _, result = self:HandleEndScreen(token)

            return false, result
        end

        local safe, safeError = self:MaintainSafeZone(token)

        if not safe then
            self:ReleaseSafeZone()

            local resultExpires = os.clock() + 4

            repeat
                if self:GetEndScreen() then
                    local _, result = self:HandleEndScreen(token)

                    return false, result
                end

                task.wait(0.1)
            until not self.Running
                or self.Token ~= token
                or library.Unloaded
                or os.clock() >= resultExpires

            return false, safeError
        end

        local elapsed = math.max(0, os.time() - self.GateStartedAt)
        local seconds, text = self:GetGateTimer(prompt)

        if text then
            self.GateText = text
        else
            self.GateText = self:FormatDuration(math.max(120 - elapsed, 0)):sub(4)
        end

        self:UpdateUI()

        local passageRead, passageOpen = pcall(self.IsGatePassageOpen, self, self.GatePassage)
        local windowRead, gateWindowOpen = pcall(self.IsGateWindowOpen, self)
        local timedOpen = self.GateStartedAt > 0 and elapsed >= 120

        if passageRead and passageOpen or windowRead and gateWindowOpen or timedOpen then
            self:ReleaseSafeZone()
            return true
        end

        if os.clock() - self.LastPersistAt >= 10 then
            self:Persist()
        end

        task.wait(0.5)
    until not self.Running or self.Token ~= token or library.Unloaded or os.clock() >= expires

    if not self.Running or self.Token ~= token then
        self:ReleaseSafeZone()
        return false, "Auto Farm stopped"
    end

    self:ReleaseSafeZone()

    return false, "Gate wait timed out"
end

function farm:SetCrossNoclip(value)
    if value then
        if self.CrossCollisions then
            return
        end

        self.CrossCollisions = {}

        local character = player.Character

        if character then
            for _, part in character:GetDescendants() do
                if part:IsA("BasePart") then
                    self.CrossCollisions[part] = part.CanCollide
                    part.CanCollide = false
                end
            end
        end

        return
    end

    for part, canCollide in self.CrossCollisions or {} do
        if part.Parent then
            part.CanCollide = canCollide
        end
    end

    self.CrossCollisions = nil
end

function farm:WaitForFinishResult(token, duration)
    local expires = os.clock() + duration

    repeat
        if self.Teleporting then
            return true, "Teleporting"
        end

        local endFrame = self:GetEndScreen()

        if endFrame then
            self:SetCrossNoclip(false)
            return self:HandleEndScreen(token)
        end

        task.wait(0.2)
    until not self.Running
        or self.Token ~= token
        or library.Unloaded
        or os.clock() >= expires

    if not self.Running or self.Token ~= token then
        return true, "Stopped"
    end

    return false, "Finish result did not appear"
end

-- STATE 4: cross the opened gate and confirm the result.
function farm:CrossGate(token, prompt, direction, endZ)
    self:ReleaseSafeZone()
    self:SetPhase("Entering Finish", "Crossing the opened gate")
    self:SetCrossNoclip(true)

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not humanoid or not root or humanoid.Health <= 0 then
        self:SetCrossNoclip(false)
        return false, "Character is unavailable"
    end

    local passage = self.GatePassage or self:GetGatePassage(prompt, direction, endZ)

    if not passage then
        self:SetCrossNoclip(false)
        return false, "Gate passage is unavailable"
    end

    self:IsGatePassageOpen(passage)
    teleports:Stream(passage.Position)
    task.wait(0.4)

    local finishOffset = math.max(
        12,
        (tonumber(endZ) and (endZ - passage.Position.Z) * direction or 0) + 12
    )

    for _, offset in { -10, -3, 6, finishOffset, finishOffset + 24, finishOffset + 50, finishOffset + 85 } do
        if not self.Running or self.Token ~= token or library.Unloaded then
            self:SetCrossNoclip(false)
            return false, "Auto Farm stopped"
        end

        local position = passage.Position + Vector3.new(0, 0, direction * offset)
        local moved = teleports:Move(
            CFrame.lookAt(position, position + Vector3.new(0, 0, direction), Vector3.yAxis),
            nil,
            false
        )

        local crossedEnd = tonumber(endZ) and (position.Z - endZ) * direction >= 0 or offset >= 6

        if moved and crossedEnd and not self.FinishCrossed then
            self.FinishCrossed = true
            self:Persist()
        end

        task.wait(0.4)

        if self.Teleporting then
            self:SetCrossNoclip(false)
            return true, "Teleporting"
        end

        if self:GetEndScreen() then
            self:SetCrossNoclip(false)
            return self:HandleEndScreen(token)
        end
    end

    humanoid:MoveTo(passage.Position + Vector3.new(0, 0, direction * 110))

    local handled, result = self:WaitForFinishResult(token, 35)

    if handled then
        return true, result
    end

    self:SetCrossNoclip(false)

    return false, result
end

function farm:RunGame(token)
    if self.PendingFinish and self.LastGameJob ~= "" and self.LastGameJob ~= game.JobId then
        self:CompletePending("Replay transition confirmed")
    end

    if self:GetEndScreen() then
        return self:HandleEndScreen(token)
    end

    if self.LastGameJob ~= game.JobId then
        self:ReleaseSafeZone()
        self.BalanceWarmupUntil = os.clock() + 10
        self:SyncProgress()
        self.LastGameJob = game.JobId
        self.RunStartedAt = os.time()
        self.RunCashStart = self:GetEffectiveCredz()
        self.RunWinsStart = self:GetEffectiveWins()
        self.GateStartedAt = 0
        self.GatePassage = nil
        self.PendingFinish = false
        self.FinishCrossed = false
        self.PendingAt = 0
        self.ResultBusy = false
        self.ResultFinalized = false
        self.ReplayRequested = false
        self.SweepDone = false
        self.SweepIndex = 0
        self.Stats.Attempts += 1
        self:Persist()
    end

    self:SetPhase("Loading Game", "Waiting for the character and map")

    local expires = os.clock() + 30

    repeat
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")

        if humanoid and root and humanoid.Health > 0 and workspace:FindFirstChild("Map") then
            break
        end

        task.wait(0.25)
    until not self.Running or self.Token ~= token or os.clock() >= expires

    if not self.Running or self.Token ~= token then
        return true
    end

    do
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not root or humanoid.Health <= 0 or not workspace:FindFirstChild("Map") then
            return false, "Gameplay did not finish loading"
        end
    end

    local prompt, direction, endZ, reachError, gateAlreadyActivated = self:ReachGate(token)

    if not prompt and not gateAlreadyActivated then
        return false, reachError
    end

    if not gateAlreadyActivated then
        local activated, activationError = self:ActivateGate(prompt, direction, token)

        if not activated then
            return false, activationError
        end
    end

    local opened, gateError = self:WaitForGate(token, prompt)

    if not opened then
        if gateError == "Replay" or gateError == "Teleporting" or gateError == "Stopped" then
            return true, gateError
        end

        return false, gateError
    end

    self.PendingFinish = true
    self.FinishCrossed = true
    self.PendingAt = os.time()
    self:Persist()

    -- crossing the finish always requeues into a new match; the lobby is never
    -- the destination here, so this cannot be steered by a stale saved toggle
    local nextPlaceId = self.GamePlaceId

    self:SetPhase("Requeueing", "Queuing a new match")

    local queued, queueError = self:QueueTeleport("replay", nextPlaceId)

    if not queued then
        self.PendingFinish = false
        self.FinishCrossed = false
        self.PendingAt = 0
        return false, queueError
    end

    for attempt = 1, 3 do
        local crossed, crossError = self:CrossGate(token, prompt, direction, endZ)

        if crossed then
            return true, crossError
        end

        if not self.Running or self.Token ~= token then
            return true
        end

        self.Stats.Retries += 1
        self.LastError = crossError
        task.wait(attempt * 2)
    end

    self.PendingFinish = false
    self.FinishCrossed = false
    self.PendingAt = 0
    self:ReleaseSafeZone()

    return false, "Could not enter the finish"
end

function farm:ReleaseRun(token)
    if self.ActiveRunToken ~= token then
        return
    end

    self.RunActive = false
    self.ActiveRunToken = nil

    if self.Running and self.Token and self.Token ~= token and not library.Unloaded then
        task.spawn(self.Run, self, self.Token)
    end
end

function farm:Run(token)
    if self.RunActive then
        return
    end

    self.RunActive = true
    self.ActiveRunToken = token
    self.RunHeartbeat = os.clock()
    local failures = 0

    while self.Running and self.Token == token and not library.Unloaded do
        self.RunHeartbeat = os.clock()

        if self.TeleportRecovering then
            task.wait(0.25)
            continue
        end

        local executed, ok, message = xpcall(function()
            local context = self:GetContext()

            if context == "Lobby" then
                return self:RunLobby(token)
            end

            if context == "Game" then
                if not self.SweepDone then
                    local swept, sweepMessage = self:RunPawnSweep(token)

                    if not swept then
                        return false, sweepMessage
                    end
                end

                return self:RunGame(token)
            end

            return false, "Unsupported place: " .. tostring(game.PlaceId)
        end, function(message)
            if type(debug) == "table" and type(debug.traceback) == "function" then
                local read, trace = pcall(debug.traceback, tostring(message), 2)

                if read and type(trace) == "string" then
                    return trace
                end
            end

            return tostring(message)
        end)

        if not executed then
            message = ok
            ok = false
            self:ReleaseSafeZone()
            self:SetCrossNoclip(false)
            self.ResultBusy = false
            self.ReplayRequested = false
        end

        if self.TeleportRecovering then
            failures = 0
            task.wait(0.25)
            continue
        end

        if ok and message == "Replay" and not self.Teleporting and self.Running and self.Token == token then
            failures = 0
            task.wait(1)
            continue
        end

        if ok or self.Teleporting or not self.Running or self.Token ~= token then
            self:ReleaseRun(token)
            return
        end

        failures += 1
        self.Stats.Retries += 1

        self.LastError = tostring(message or "Unknown error")
        self:SetPhase("Retrying", self.LastError)
        self:Persist()

        local delay = options.RunawaysAutoFarmRetryDelay and options.RunawaysAutoFarmRetryDelay.Value or self.Config.RetryDelay
        local expires = os.clock() + math.min(delay * failures, 30)

        repeat
            self.RunHeartbeat = os.clock()
            task.wait(0.25)
        until not self.Running or self.Token ~= token or os.clock() >= expires
    end

    self:ReleaseRun(token)
end

function farm:Start()
    if self.Running then
        return
    end

    -- a resume only counts when a real session was carried across; otherwise this
    -- is a fresh start driven by the saved "leave it on" intent
    local resumed = self.ResumeRequested and self.SessionId ~= ""

    if not resumed then
        self.SessionId = tostring(player.UserId) .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
        self:ResetStats()
    elseif self.StartedAt <= 0 then
        self.StartedAt = os.time()
    end

    self.AutoEnabled = true
    self.ResumeRequested = false
    self.Running = true
    self.RunActive = false
    self.ActiveRunToken = nil
    self.Teleporting = false
    self.TeleportRecoveryGeneration += 1
    self.TeleportRetryCount = 0
    self.TeleportRetryDelay = 0
    self.TeleportRetryTarget = 0
    self.TeleportRetryOptions = nil
    self.TeleportRecovering = false
    self.LastTeleportFailureAt = 0
    self.QueueJob = nil
    self.ResultBusy = false
    self.ResultFinalized = false
    self.ReplayRequested = false
    self.RunHeartbeat = os.clock()
    self.TransitionToken = ""
    self.ExpectedPlaceId = 0
    self.TransitionAt = 0
    self.Token = {}
    self.QueueStatus = "Not armed"
    self:Persist()
    self:SetPhase("Starting", "Preparing Auto Farm")

    local context = self:GetContext()

    -- the loader is only required when we must move servers to begin; a lobby or game
    -- server can start immediately and re-check at every real transition
    if context ~= "Lobby" and context ~= "Game" then
        local queueError = self:GetTeleportQueueError(self.LobbyPlaceId)

        if queueError then
            self.Running = false
            self.Token = nil
            self.QueueStatus = queueError
            self.LastError = tostring(queueError)
            self:SetPhase("Start Failed", self.LastError)
            self:Persist()
            notify("Auto Farm: " .. queueError .. ".", 8)

            task.defer(function()
                if toggles.RunawaysAutoFarm and toggles.RunawaysAutoFarm.Value then
                    toggles.RunawaysAutoFarm:SetValue(false)
                end
            end)

            return
        end
    end

    if self:HasTeleportLoader() then
        notify("Auto Farm started - " .. self.Phase .. ".", 5)
    else
        self.QueueStatus = "Loader not set - single server only"

        notify("Auto Farm started without a loader - cross server resume is unavailable.", 8)
        self:UpdateUI()
    end

    task.spawn(function()
        local token = self.Token

        while self.Running and self.Token == token and not library.Unloaded do
            local context = self:GetContext()

            if context == "Game" then
                if self:IsForceAssistEnabled() then
                    local humanoid = getHumanoid()

                    if humanoid then
                        applyGodMode(humanoid)
                    end
                end

                -- never wipe NPCs while sweeping: the pawns are the loot source
                if not self.Sweeping then
                    self.Stats.NPCAttacks += killAllNPCs()
                end
            end

            task.wait(context == "Game" and 0.4 or 1)
        end
    end)

    task.spawn(function()
        local token = self.Token

        while self.Running and self.Token == token and not library.Unloaded do
            local context = self:GetContext()

            if context == "Game" and not self.ResultBusy and not self.RunActive then
                local endFrame = self:GetEndScreen()

                if endFrame then
                    self:ReleaseSafeZone()
                    self:SetCrossNoclip(false)
                    self.RunActive = false
                    self.ActiveRunToken = nil
                    self.RunHeartbeat = os.clock()
                    self:SetPhase("Recovering", "Handling the result screen")
                    task.spawn(self.Run, self, token)
                end
            end

            task.wait(context == "Game" and 0.5 or 1)
        end
    end)

    task.spawn(self.Run, self, self.Token)
end

function farm:Stop(silent)
    if not self.Running and not self.ResumeRequested and not self.AssistCaptured then
        return
    end

    self.Running = false
    self.ResumeRequested = false
    self.AutoEnabled = false
    self.Token = nil
    self.RunActive = false
    self.ActiveRunToken = nil
    self.Teleporting = false
    self.TeleportRecoveryGeneration += 1
    self.TeleportRetryCount = 0
    self.TeleportRetryDelay = 0
    self.TeleportRetryTarget = 0
    self.TeleportRetryOptions = nil
    self.TeleportRecovering = false
    self.LastTeleportFailureAt = 0
    self.QueueJob = nil
    self.TransitionToken = ""
    self.ExpectedPlaceId = 0
    self.TransitionAt = 0
    self.PendingFinish = false
    self.FinishCrossed = false
    self.PendingAt = 0
    self.ResultBusy = false
    self.ResultFinalized = false
    self.ReplayRequested = false
    self.RunHeartbeat = 0
    self.LastGameJob = ""
    self.RunStartedAt = 0
    self.RunCashStart = 0
    self.RunWinsStart = 0
    self.GateStartedAt = 0
    self.GatePassage = nil
    self.GateText = "--"
    self.QueueStatus = "Disabled"
    self:ReleaseSafeZone()
    self:SetCrossNoclip(false)
    self:DismissTeleportError()
    self:RestoreAssistState()

    if not (toggles.RunawaysPlayerGodMode and toggles.RunawaysPlayerGodMode.Value) then
        restoreGodMode()
    end

    pcall(function()
        local teleportService = game:GetService("TeleportService")
        teleportService:SetTeleportSetting(self.EnabledKey, false)
        teleportService:SetTeleportSetting(self.TransitionKey, "")
    end)

    self:SetPhase("Stopped", "Auto Farm is disabled")
    self:Persist()

    if not silent then
        notify("Auto Farm stopped.", 5)
    end
end

function farm:Destroy()
    self.Running = false
    self.ResumeRequested = false
    self.Token = nil
    self.RunActive = false
    self.ActiveRunToken = nil
    self.Teleporting = false
    self.TeleportRecoveryGeneration += 1
    self.TeleportRetryCount = 0
    self.TeleportRetryDelay = 0
    self.TeleportRetryTarget = 0
    self.TeleportRetryOptions = nil
    self.TeleportRecovering = false
    self.LastTeleportFailureAt = 0
    self.ResultBusy = false
    self.ResultFinalized = false
    self.ReplayRequested = false
    self:ReleaseSafeZone()
    self:SetCrossNoclip(false)
    self:DismissTeleportError()
    self:RestoreAssistState()

    if self.TeleportConnection then
        self.TeleportConnection:Disconnect()
        self.TeleportConnection = nil
    end

    if self.TeleportFailedConnection then
        self.TeleportFailedConnection:Disconnect()
        self.TeleportFailedConnection = nil
    end

    if not (toggles.RunawaysPlayerGodMode and toggles.RunawaysPlayerGodMode.Value) then
        restoreGodMode()
    end

    self.TransitionToken = ""
    self.ExpectedPlaceId = 0
    self.TransitionAt = 0
    env.RunawaysAutoFarmTransitionToken = nil

    pcall(function()
        local teleportService = game:GetService("TeleportService")
        teleportService:SetTeleportSetting(self.EnabledKey, false)
        teleportService:SetTeleportSetting(self.TransitionKey, "")
    end)

    self.PendingFinish = false
    self.FinishCrossed = false
    self.PendingAt = 0
    self.LastGameJob = ""
    self.RunStartedAt = 0
    self.RunCashStart = 0
    self.RunWinsStart = 0
    self.GateStartedAt = 0
    self.GatePassage = nil
    self.GateText = "--"
    self:Persist()
end

farm.TeleportConnection = player.OnTeleport:Connect(function(state)
    if not farm.Running then
        return
    end

    if state == Enum.TeleportState.Started or state == Enum.TeleportState.InProgress then
        if not farm.Teleporting then
            farm.Stats.Teleports += 1
        end

        farm.Teleporting = true
        farm:SetPhase("Teleporting", "Moving to the next server")
        farm:Persist()
    end
end)

farm.TeleportFailedConnection = game:GetService("TeleportService").TeleportInitFailed:Connect(
    function(failedPlayer, result, message, targetPlaceId, teleportOptions)
        if failedPlayer ~= player then
            return
        end

        farm:HandleTeleportFailure(result, message, targetPlaceId, teleportOptions)
    end
)

local tab = window:AddTab("Script2", "package", "")

local playerBox = tab:AddLeftGroupbox("Player", "user")
local combatBox = library.IsMobile and tab:AddLeftGroupbox("Combat", "crosshair") or tab:AddRightGroupbox("Combat", "crosshair")
local teleportBox = library.IsMobile and tab:AddLeftGroupbox("Teleports", "map-pin") or tab:AddRightGroupbox("Teleports", "map-pin")
local menuBox = tab:AddLeftGroupbox("Menu", "wrench")
local lootBox = library.IsMobile and tab:AddLeftGroupbox("Loot", "package-open") or tab:AddRightGroupbox("Loot", "package-open")
local espStyleBox = tab:AddLeftGroupbox("ESP Style", "palette")
local espNPCBox = library.IsMobile and tab:AddLeftGroupbox("NPC ESP", "user") or tab:AddRightGroupbox("NPC ESP", "user")
local farmBox = tab:AddLeftGroupbox("Auto Farm", "refresh-cw")

playerBox:AddToggle("RunawaysPlayerGodMode", {
    Text = "God Mode",
    Default = false,
    Callback = function(value)
        if not value then
            restoreGodMode()
        end
    end,
})

combatBox:AddSlider("RunawaysKillRange", {
    Text = "Kill Range",
    Default = 150,
    Min = 10,
    Max = 1000,
    Rounding = 0,
    Suffix = " studs",
})

combatBox:AddToggle("RunawaysKillAura", {
    Text = "NPC Kill Aura",
    Default = false,
    Callback = function(value)
        killAuraToken = value and {} or nil

        local token = killAuraToken

        if not token then
            return
        end

        task.spawn(function()
            while killAuraToken == token and not library.Unloaded do
                killAllNPCs(options.RunawaysKillRange.Value)
                task.wait(0.15)
            end
        end)
    end,
})

combatBox:AddButton("Kill NPCs Once", function()
    local count = killAllNPCs()

    notify(string.format("Attacked NPCs: %d.", count), 4)
end)

teleportBox:AddLabel("Route")
teleportBox:AddButton("Teleport to End Gate", function()
    teleports:ToEnd()
end)
teleportBox:AddDivider()
teleportBox:AddDropdown("RunawaysTeleportBuilding", {
    Values = { "None" },
    Default = 1,
    Multi = false,
    Text = "Building",
    Searchable = true,
    MaxVisibleDropdownItems = 12,
})
teleportBox:AddButton("Teleport to Building", function()
    teleports:Go("Buildings")
end)

lootBox:AddButton("Loot All", function()
    collect()
end)
lootBox:AddButton("Sell All", function()
    sellAllLoot()
end)

local autoFarmTab = window:AddTab("Auto Farm", "refresh-cw", "")
local autoFarmBox = autoFarmTab:AddLeftGroupbox("Auto Farm", "refresh-cw")

autoFarmBox:AddToggle("RunawaysAutoFarm", {
    Text = "Auto Farm",
    Default = false,
    Callback = function(value)
        if value then
            farm:Start()
        else
            farm:Stop()
        end
    end,
})

farmBox:AddToggle("RunawaysAutoFarmSafeGateWait", {
    Text = "Safe Gate Wait",
    Default = farm.Config.SafeGateWait,
    Callback = function(value)
        farm.Config.SafeGateWait = value
        farm:Persist()
    end,
})

farmBox:AddToggle("RunawaysAutoFarmForceAssist", {
    Text = "Force God Mode + Kill Aura during run",
    Default = farm.Config.ForceAssist,
    Callback = function(value)
        farm.Config.ForceAssist = value
        farm:Persist()

        if not value and farm.Running and not (toggles.RunawaysPlayerGodMode and toggles.RunawaysPlayerGodMode.Value) then
            restoreGodMode()
        end
    end,
})

farmBox:AddToggle("RunawaysAutoFarmAutoReplay", {
    Text = "Auto Replay Instead of Lobby",
    Default = farm.Config.AutoReplay,
    Callback = function(value)
        farm.Config.AutoReplay = value
        farm:Persist()
    end,
})

farmBox:AddSlider("RunawaysAutoFarmLobbyDelay", {
    Text = "Lobby Delay",
    Min = 0,
    Max = 60,
    Step = 1,
    Default = farm.Config.LobbyDelay,
    Callback = function(value)
        farm.Config.LobbyDelay = value
    end,
})

farmBox:AddSlider("RunawaysAutoFarmGateTimeout", {
    Text = "Gate Timeout",
    Min = 30,
    Max = 300,
    Step = 5,
    Default = farm.Config.GateTimeout,
    Callback = function(value)
        farm.Config.GateTimeout = value
    end,
})

farmBox:AddSlider("RunawaysAutoFarmRetryDelay", {
    Text = "Retry Delay",
    Min = 1,
    Max = 30,
    Step = 1,
    Default = farm.Config.RetryDelay,
    Callback = function(value)
        farm.Config.RetryDelay = value
    end,
})

farm.Labels.Status = farmBox:AddLabel("Status: Idle")
farm.Labels.Run = farmBox:AddLabel("Context: --")
farm.Labels.Queue = farmBox:AddLabel("Queue: Not armed")
farm.Labels.Session = farmBox:AddLabel("Session: --")
farm.Labels.Runs = farmBox:AddLabel("Runs: 0")
farm.Labels.Error = farmBox:AddLabel("Last error: None")


espStyleBox:AddToggle("RunawaysESPEnabled", {
    Text = "ESP Enabled",
    Default = false,
    Callback = function(value)
        if value and not drawingAvailable then
            notify("Drawing API is unavailable")
            task.defer(function()
                toggles.RunawaysESPEnabled:SetValue(false)
            end)
        elseif not value then
            clearESP()
        end
    end,
}):AddKeyPicker("RunawaysESPKeybind", {
    Default = "P",
    SyncToggleState = true,
    Mode = "Toggle",
    Text = "ESP Keybind",
})

espStyleBox:AddSlider("RunawaysESPTextSize", {
    Text = "Text Size",
    Default = 13,
    Min = 10,
    Max = 24,
    Rounding = 0,
})

espStyleBox:AddDropdown("RunawaysESPFont", {
    Values = { "UI", "System", "Plex", "Monospace" },
    Default = 3,
    Text = "Font",
})

espStyleBox:AddToggle("RunawaysESPTextOutline", {
    Text = "Text Outline",
    Default = true,
}):AddColorPicker("RunawaysESPOutlineColor", {
    Default = Color3.new(0, 0, 0),
    Title = "Outline Color",
    Transparency = 0,
})

espStyleBox:AddSlider("RunawaysESPBoxThickness", {
    Text = "Line Thickness",
    Default = 1,
    Min = 1,
    Max = 3,
    Rounding = 0,
})

espStyleBox:AddDropdown("RunawaysESPTracerOrigin", {
    Values = { "Bottom", "Center", "Mouse" },
    Default = 1,
    Text = "Tracer Origin",
})

espNPCBox:AddToggle("RunawaysESPNPCs", {
    Text = "NPC ESP",
    Default = true,
}):AddColorPicker("RunawaysESPNPCColor", {
    Default = Color3.fromRGB(255, 170, 60),
    Title = "NPC Color",
    Transparency = 0,
})

espNPCBox:AddToggle("RunawaysESPNPCName", {
    Text = "Show Name",
    Default = true,
})

espNPCBox:AddToggle("RunawaysESPNPCHealth", {
    Text = "Show Health",
    Default = true,
})

espNPCBox:AddToggle("RunawaysESPNPCDistance", {
    Text = "Show Distance",
    Default = true,
})

espNPCBox:AddToggle("RunawaysESPNPCBox", {
    Text = "Show Box",
    Default = true,
})

espNPCBox:AddToggle("RunawaysESPNPCHealthBar", {
    Text = "Show Health Bar",
    Default = false,
})

espNPCBox:AddToggle("RunawaysESPNPCTracer", {
    Text = "Show Tracer",
    Default = false,
})

espNPCBox:AddToggle("RunawaysESPNPCActiveOnly", {
    Text = "Active Only",
    Default = true,
})

espNPCBox:AddSlider("RunawaysESPNPCMaxDistance", {
    Text = "Maximum Distance",
    Default = 2000,
    Min = 100,
    Max = 5000,
    Rounding = 0,
    Suffix = " studs",
})

RunService:BindToRenderStep(espRenderName, Enum.RenderPriority.Camera.Value + 10, updateESP)

espScanToken = {}
task.spawn(function()
    local token = espScanToken

    while espScanToken == token and not library.Unloaded do
        scanESP()
        task.wait(0.5)
    end
end)

menuBox:AddLabel("Menu key"):AddKeyPicker("MenuKeybind", {
    Default = "RightShift",
    NoUI = true,
    Text = "Menu key",
})
menuBox:AddButton("Unload", function()
    library:Unload()
end)

library.ToggleKeybind = options.MenuKeybind

library:OnUnload(function()
    farm:Destroy()

    killAuraToken = nil
    restoreGodMode()
    espScanToken = nil

    pcall(function()
        RunService:UnbindFromRenderStep(espRenderName)
    end)

    clearESP()
    drawingAvailable = false

    if playerStepConnection then
        playerStepConnection:Disconnect()
        playerStepConnection = nil
    end

    if env.RunawaysScript2 == library then
        env.RunawaysScript2 = nil
    end
end)

playerStepConnection = RunService.PreSimulation:Connect(function()
    applyPlayerSettings()
end)

task.spawn(function()
    while not library.Unloaded do
        task.wait(1)

        if not library.Unloaded then
            teleports:Refresh()
        end
    end
end)

ThemeManager:SetLibrary(library)
SaveManager:SetLibrary(library)

SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })

ThemeManager:SetFolder("MyScriptHub")
SaveManager:SetFolder("MyScriptHub/RUNAWAYS2")
SaveManager:SetSubFolder(tostring(game.PlaceId))

SaveManager:BuildConfigSection(tab)
ThemeManager:ApplyToTab(tab)

teleports:Refresh(true)
SaveManager:LoadAutoloadConfig()
teleports:Refresh(true)

farm:LoadState()
farm.StateReady = true
farm:ApplyStoredOptions()
farm:UpdateUI()

if farm.ResumeRequested or (toggles.RunawaysAutoFarm and toggles.RunawaysAutoFarm.Value == true) then
    farm.ResumeRequested = true
    farm:Start()

    if farm.Running and toggles.RunawaysAutoFarm and not toggles.RunawaysAutoFarm.Value then
        toggles.RunawaysAutoFarm:SetValue(true)
    end
end


if flowOk and type(flowModule) == "table" then
    if not (flow.NPCs and type(flow.NPCs.Damage) == "function") then
        notify("flow.NPCs.Damage is unavailable - kill aura will not work.", 8)
    end
else
    notify("FlowClient failed to load - kill aura and damage blocking are disabled.", 8)
end

print("[Script2] READY - God Mode, Kill Aura, Auto Farm, Loot, and ESP are live")

return library
