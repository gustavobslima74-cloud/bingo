
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local ENV = (getgenv and getgenv()) or _G
local Camera = Workspace.CurrentCamera
local IS_TOUCH = UserInputService.TouchEnabled
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

if ENV.BingoAutomationExact and ENV.BingoAutomationExact.Unload then
    pcall(function()
        ENV.BingoAutomationExact:Unload()
    end)
    task.wait()
end

local BingoShared = ReplicatedStorage:WaitForChild("BingoShared", 10)
assert(BingoShared, "[Bingo] ReplicatedStorage.BingoShared was not found")

local ConfigModule = BingoShared:WaitForChild("Config", 10)
local CardUtilModule = BingoShared:WaitForChild("CardUtil", 10)
assert(ConfigModule and CardUtilModule, "[Bingo] Config/CardUtil was not found")

local Config = require(ConfigModule)
local CardUtil = require(CardUtilModule)

local BingoRemotes = ReplicatedStorage:WaitForChild("BingoRemotes", 10)
assert(BingoRemotes, "[Bingo] ReplicatedStorage.BingoRemotes was not found")

local NumberCalled = BingoRemotes:WaitForChild("NumberCalled")
local RoundState = BingoRemotes:WaitForChild("RoundState")
local CardsAssigned = BingoRemotes:WaitForChild("CardsAssigned")
local Daub = BingoRemotes:WaitForChild("Daub")
local ClaimBingo = BingoRemotes:WaitForChild("ClaimBingo")
local Notify = BingoRemotes:FindFirstChild("Notify")

local SETTINGS = {
    AutoDaub = true,
    AutoClaim = true,

    AutoDaubDelay = 0.5,
    MarkAllSpacing = 0.3,
    AutoClaimDelay = 0.4,

    NativeCellDaub = true,

    DirectRemoteFallback = true,

    MarkConfirmTimeout = 1.35,
    MarkConfirmPoll = 0.04,

    DaubSpacing = 0.035,

    PostDaubClaimDelay = 0.12,

    RescanInterval = 0.75,

    DuplicateDaubCooldown = 1.25,

    ClaimCooldown = 0.35,

    MaxLogLines = 6,

    ConsoleDebug = false,
}

local Runtime = {
    Running = true,
    Connections = {},
    GuiConnections = {},
    Cards = {},
    NumberIndex = {},
    CalledNumbers = {},
    LocalMarks = {},
    PendingMarks = {},
    ClaimGeneration = 0,
    ClaimKeys = {},
    LastClaimAt = 0,
    LastCalledNumber = nil,
    LastCalledCount = tonumber(Workspace:GetAttribute("BingoCalledCount")) or 0,
    LastPhase = Workspace:GetAttribute("BingoPhase"),
    LastStage = Workspace:GetAttribute("BingoStage"),
    LastPattern = Workspace:GetAttribute("BingoPattern"),
    ActivePattern = Workspace:GetAttribute("BingoPattern"),
    LastWinningCard = nil,
    Logs = {},
    Stats = {
        ReceivedCalls = 0,
        DaubsSent = 0,
        DaubsConfirmed = 0,
        DaubsFailed = 0,
        ClaimsTriggered = 0,
        CardRescans = 0,
        Errors = 0,
    },
}

ENV.BingoAutomationExact = Runtime

local function addConnection(signal, callback, bucket)
    local connection = signal:Connect(callback)
    table.insert(bucket or Runtime.Connections, connection)
    return connection
end

local function disconnectBucket(bucket)
    for _, connection in ipairs(bucket) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(bucket)
end

local function safe(callback, ...)
    local args = table.pack(...)
    local ok, result = xpcall(function()
        return callback(table.unpack(args, 1, args.n))
    end, debug.traceback)

    if not ok then
        Runtime.Stats.Errors += 1
        if SETTINGS.ConsoleDebug then
            warn("[Bingo] " .. tostring(result))
        end
        return false, result
    end

    return true, result
end

local function log(message)
    message = tostring(message)
    table.insert(Runtime.Logs, 1, os.date("%H:%M:%S") .. "  " .. message)

    while #Runtime.Logs > SETTINGS.MaxLogLines do
        table.remove(Runtime.Logs)
    end

    if SETTINGS.ConsoleDebug then
        print("[Bingo] " .. message)
    end
end

local function countDictionary(dictionary)
    local n = 0
    for _ in pairs(dictionary) do
        n += 1
    end
    return n
end

local GRID = tonumber(Config.GRID) or 5
local FREE_COL = tonumber(Config.FREE_COL) or 3
local FREE_ROW = tonumber(Config.FREE_ROW) or 3
local MAX_CARDS = tonumber(Config.MAX_CARDS) or 6

local function isFreeCoordinate(column, row)
    return column == FREE_COL and row == FREE_ROW
end

local function numberColumn(number)
    if Config.columnForNumber then
        local ok, column, letter = pcall(Config.columnForNumber, number)
        if ok then
            return column, letter
        end
    end

    for column, range in ipairs(Config.COLUMN_RANGES or {}) do
        if number >= range[1] and number <= range[2] then
            local letter = Config.LETTERS and Config.LETTERS[column] or tostring(column)
            return column, letter
        end
    end

    return nil, nil
end

local function supportedPatternSummary()
    local names = { "Line", "DoubleRow", "Blackout", "FourCorners", "X" }
    for _, pattern in ipairs(Config.ROUND2_PATTERNS or {}) do
        if pattern.name then
            table.insert(names, pattern.name)
        end
    end
    return names
end

local SUPPORTED_PATTERNS = supportedPatternSummary()

local function getBingoGui()
    return PlayerGui:FindFirstChild("BingoGui")
end

local function getCardArea()
    local gui = getBingoGui()
    if not gui then
        return nil
    end
    return gui:FindFirstChild("CardArea", true)
end

local function getBingoButton()
    local gui = getBingoGui()
    if not gui then
        return nil
    end

    local direct = gui:FindFirstChild("BingoButton")
    if direct and direct:IsA("GuiButton") then
        return direct
    end

    local recursive = gui:FindFirstChild("BingoButton", true)
    if recursive and recursive:IsA("GuiButton") then
        return recursive
    end

    return nil
end

local function getBallSlots()
    local gui = getBingoGui()
    if not gui then
        return nil
    end

    local ballRow = gui:FindFirstChild("BallRow", true)
    if not ballRow then
        return nil
    end

    return ballRow:FindFirstChild("Slots", true)
end

local function cardIndexFromName(name)
    local value = type(name) == "string" and name:match("^Card(%d+)$")
    value = tonumber(value)
    if not value or value < 1 or value > MAX_CARDS then
        return nil
    end
    return value
end

local function getCardGrid(card)
    if not card then
        return nil
    end

    local gridArea = card:FindFirstChild("GridArea")
    if not gridArea then
        return nil
    end

    return gridArea:FindFirstChild("Grid")
end

local function parseCellName(name)
    if type(name) ~= "string" then
        return nil
    end

    local column, row = name:match("^C(%d+)_(%d+)$")
    column = tonumber(column)
    row = tonumber(row)

    if not column or not row then
        return nil
    end

    if column < 1 or column > GRID or row < 1 or row > GRID then
        return nil
    end

    return column, row
end

local function normalizeNumber(value)
    if type(value) == "number" then
        if value % 1 == 0 and value >= 1 and value <= 75 then
            return value
        end
        return nil
    end

    if type(value) ~= "string" then
        return nil
    end

    local direct = tonumber(value)
    if direct and direct % 1 == 0 and direct >= 1 and direct <= 75 then
        return direct
    end

    local digits = value:match("(%d+)")
    local number = tonumber(digits)
    if number and number >= 1 and number <= 75 then
        return number
    end

    return nil
end

local function getCellNumber(cell)
    if not cell then
        return nil
    end

    local numberObject = cell:FindFirstChild("Number")
    if not numberObject then
        return nil
    end

    local ok, text = pcall(function()
        return numberObject.Text
    end)

    if not ok then
        return nil
    end

    return normalizeNumber(text)
end

local function cellKey(cardIndex, column, row)
    return string.format("%d:%d:%d", cardIndex, column, row)
end

local function stampLooksMarked(cell)
    if not cell then
        return false
    end

    local stamp = cell:FindFirstChild("Stamp")
    if not stamp or not stamp:IsA("GuiObject") then
        return false
    end

    return stamp.Visible == true
end

local function getCell(cardData, column, row)
    if not cardData or not cardData.Grid then
        return nil
    end

    return cardData.Grid:FindFirstChild(string.format("C%d_%d", column, row))
end

local function scanCards()
    local cardArea = getCardArea()
    local discovered = {}
    local numberIndex = {}

    if cardArea then
        for _, object in ipairs(cardArea:GetDescendants()) do
            local index = cardIndexFromName(object.Name)

            if index then
                local grid = getCardGrid(object)

                if grid then
                    discovered[index] = {
                        Index = index,
                        Object = object,
                        Grid = grid,
                    }
                end
            end
        end
    end

    for index = 1, MAX_CARDS do
        local cardData = discovered[index]

        if cardData then
            for column = 1, GRID do
                for row = 1, GRID do
                    if not isFreeCoordinate(column, row) then
                        local cell = getCell(cardData, column, row)

                        if cell then
                            local number = getCellNumber(cell)

                            if number then
                                local matches = numberIndex[number]

                                if not matches then
                                    matches = {}
                                    numberIndex[number] = matches
                                end

                                matches[#matches + 1] = {
                                    CardData = cardData,
                                    Column = column,
                                    Row = row,
                                    Cell = cell,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    local oldCount = countDictionary(Runtime.Cards)
    local newCount = countDictionary(discovered)

    Runtime.Cards = discovered
    Runtime.NumberIndex = numberIndex
    Runtime.Stats.CardRescans += 1

    if oldCount ~= newCount then
        log(string.format("Cards: %d", newCount))
    end

    return discovered
end

local function buildMarkedGrid(cardData)
    local marked = {}

    for column = 1, GRID do
        marked[column] = {}

        for row = 1, GRID do
            if isFreeCoordinate(column, row) then
                marked[column][row] = true
            else
                local cell = getCell(cardData, column, row)
                local number = getCellNumber(cell)
                local key = cellKey(cardData.Index, column, row)
                local stamped = stampLooksMarked(cell) or Runtime.LocalMarks[key] == true

                marked[column][row] = stamped
                    and number ~= nil
                    and Runtime.CalledNumbers[number] == true
            end
        end
    end

    return marked
end

local function currentPattern()
    local pattern = Runtime.ActivePattern

    if pattern == nil or tostring(pattern) == "" then
        pattern = Workspace:GetAttribute("BingoPattern")
    end

    if pattern == nil or tostring(pattern) == "" then
        return "Line"
    end

    return tostring(pattern)
end

local function checkCardBingo(cardData, pattern)
    if not cardData then
        return nil
    end

    local marked = buildMarkedGrid(cardData)

    local ok, result = pcall(function()
        return CardUtil.checkBingo(marked, pattern or currentPattern())
    end)

    if not ok then
        return nil
    end

    return result
end

local function findWinningCard(pattern)
    pattern = pattern or currentPattern()

    for index = 1, MAX_CARDS do
        local cardData = Runtime.Cards[index]
        if cardData then
            local mask = checkCardBingo(cardData, pattern)
            if mask then
                return cardData, mask
            end
        end
    end

    return nil, nil
end

local function requestClaim(source)
    if not Runtime.Running then
        return false
    end

    local now = os.clock()
    if now - Runtime.LastClaimAt < SETTINGS.ClaimCooldown then
        return false
    end

    Runtime.LastClaimAt = now

    local ok, err = pcall(function()
        ClaimBingo:FireServer()
    end)

    if not ok then
        log("Claim failed: " .. tostring(err))
        return false
    end

    Runtime.Stats.ClaimsTriggered += 1
    return true
end

local function tryAutoClaim(reason)
    if not SETTINGS.AutoClaim or not Runtime.Running then
        return false
    end

    local phase = tostring(Workspace:GetAttribute("BingoPhase") or "")
    local lower = phase:lower()

    if lower ~= "playing" and lower ~= "claimwindow" then
        return false
    end

    local pattern = currentPattern()
    local cardData = findWinningCard(pattern)

    if not cardData then
        Runtime.LastWinningCard = nil
        return false
    end

    Runtime.LastWinningCard = cardData.Index
    return requestClaim()
end

local function connectionCount(signal)
    if type(getconnections) ~= "function" then
        return nil
    end

    local ok, connections = pcall(getconnections, signal)

    if not ok or type(connections) ~= "table" then
        return nil
    end

    return #connections
end

local function fireNativeCell(cell)
    if not cell or not cell:IsA("GuiButton") then
        return false
    end

    if stampLooksMarked(cell) then
        return false
    end

    local selected = cell.Activated

    if type(getconnections) == "function" then
        local activated = connectionCount(cell.Activated) or 0
        local click = connectionCount(cell.MouseButton1Click) or 0

        if activated <= 0 and click > 0 then
            selected = cell.MouseButton1Click
        elseif activated <= 0 and click <= 0 then
            return false
        end
    end

    if type(firesignal) == "function" then
        return pcall(function()
            firesignal(selected)
        end)
    end

    return pcall(function()
        cell:Activate()
    end)
end

local function scheduleAutoClaim()
    if not SETTINGS.AutoClaim or not Runtime.Running then
        return
    end

    Runtime.ClaimGeneration += 1
    local generation = Runtime.ClaimGeneration

    task.delay(SETTINGS.AutoClaimDelay, function()
        if not Runtime.Running or generation ~= Runtime.ClaimGeneration then
            return
        end

        safe(tryAutoClaim, "settled")
    end)
end

local function markEntryNative(entry, number)
    if not Runtime.Running then
        return false
    end

    local cardData = entry.CardData
    local column = entry.Column
    local row = entry.Row
    local cell = entry.Cell or getCell(cardData, column, row)

    if not cell then
        return false
    end

    local key = string.format("%d:%d:%d:%d", cardData.Index, column, row, number)

    if stampLooksMarked(cell) then
        Runtime.LocalMarks[cellKey(cardData.Index, column, row)] = true
        return false
    end

    if Runtime.PendingMarks[key] then
        return false
    end

    Runtime.PendingMarks[key] = true

    local ok = fireNativeCell(cell)

    if not ok then
        Runtime.PendingMarks[key] = nil
        Runtime.Stats.DaubsFailed += 1
        return false
    end

    Runtime.Stats.DaubsSent += 1

    task.spawn(function()
        local deadline = os.clock() + 1.5

        while Runtime.Running and os.clock() < deadline do
            if stampLooksMarked(cell) then
                Runtime.LocalMarks[cellKey(cardData.Index, column, row)] = true
                Runtime.CalledNumbers[number] = true -- NOVO: Registra no histórico ao confirmar visualmente
                Runtime.Stats.DaubsConfirmed += 1
                Runtime.PendingMarks[key] = nil
                scheduleAutoClaim()
                return
            end

            task.wait(0.03)
        end

        Runtime.PendingMarks[key] = nil
        Runtime.Stats.DaubsFailed += 1
    end)

    return true
end

local function markNumberNative(number)
    number = normalizeNumber(number)

    if not number then
        return 0
    end

    local matches = Runtime.NumberIndex[number]

    if not matches then
        return 0
    end

    local marked = 0

    for _, entry in ipairs(matches) do
        if markEntryNative(entry, number) then
            marked += 1
        end
    end

    return marked
end

local function processCalledNumber(number, source, quiet)
    number = normalizeNumber(number)

    if not number then
        return false, 0
    end

    local firstSeen = Runtime.CalledNumbers[number] ~= true

    Runtime.CalledNumbers[number] = true
    Runtime.LastCalledNumber = number

    if firstSeen then
        Runtime.Stats.ReceivedCalls += 1
    end

    if not Runtime.NumberIndex[number] then
        scanCards()
    end

    local marked = 0

    if SETTINGS.AutoDaub then
        marked = markNumberNative(number)
    end

    if firstSeen and not quiet and marked > 0 then
        local _, letter = numberColumn(number)
        log(string.format("%s%d · %d", tostring(letter or ""), number, marked))
    end

    return true, marked
end

local NUMBER_KEYS = {
    "number",
    "Number",
    "calledNumber",
    "CalledNumber",
    "called_number",
    "ball",
    "Ball",
    "value",
    "Value",
}

local function findNumberInTable(tbl, seen, depth)
    if depth > 5 or seen[tbl] then
        return nil
    end

    seen[tbl] = true

    for _, key in ipairs(NUMBER_KEYS) do
        local value = rawget(tbl, key)
        local number = normalizeNumber(value)
        if number then
            return number
        end
    end

    for _, value in pairs(tbl) do
        if type(value) == "table" then
            local number = findNumberInTable(value, seen, depth + 1)
            if number then
                return number
            end
        end
    end

    return nil
end

local function extractCalledNumber(...)
    local args = table.pack(...)

    for i = 1, args.n do
        local number = normalizeNumber(args[i])
        if number then
            return number
        end
    end

    for i = 1, args.n do
        if type(args[i]) == "table" then
            local number = findNumberInTable(args[i], {}, 0)
            if number then
                return number
            end
        end
    end

    return nil
end

local function getVisibleCalledNumbers()
    local slots = getBallSlots()

    if not slots then
        return {}
    end

    local found = {}

    for _, object in ipairs(slots:GetChildren()) do
        local number = normalizeNumber(object.Name)

        if not number then
            local numberLabel = object:FindFirstChild("NumberLabel", true)

            if numberLabel then
                local ok, value = pcall(function()
                    return numberLabel.Text
                end)

                if ok then
                    number = normalizeNumber(value)
                end
            end
        end

        if number then
            found[number] = true
        end
    end

    local numbers = {}

    for number in pairs(found) do
        numbers[#numbers + 1] = number
    end

    table.sort(numbers)
    return numbers
end

local function syncVisibleBalls(silent)
    -- 1. Captura bolas da interface e adiciona ao histórico
    local visibleNumbers = getVisibleCalledNumbers()
    for _, number in ipairs(visibleNumbers) do
        Runtime.CalledNumbers[number] = true
    end

    -- 2. Consolida todos os números (Interface + Histórico do Servidor)
    local numbers = {}
    for number in pairs(Runtime.CalledNumbers) do
        table.insert(numbers, number)
    end
    table.sort(numbers)

    if #numbers == 0 then
        return 0, 0, 0
    end

    scanCards()

    local numbersWithMatches = 0
    local marks = 0

    for _, number in ipairs(numbers) do
        if not Runtime.Running then
            break
        end

        local matches = Runtime.NumberIndex[number]

        if matches and #matches > 0 then
            numbersWithMatches += 1

            for _, entry in ipairs(matches) do
                if not Runtime.Running then
                    break
                end

                local cell = entry.Cell or getCell(entry.CardData, entry.Column, entry.Row)

                if cell and not stampLooksMarked(cell) then
                    if markEntryNative(entry, number) then
                        marks += 1
                        task.wait(SETTINGS.MarkAllSpacing)
                    end
                end
            end
        end
    end

    if not silent then
        if marks > 0 then
            log(string.format("Sync: %d analisadas · %d marcadas", #numbers, marks))
        else
            log(string.format("Sync: %d analisadas · tudo atualizado", #numbers))
        end
    end

    return #numbers, numbersWithMatches, marks
end

local function clearRoundState(reason)
    table.clear(Runtime.CalledNumbers)
    table.clear(Runtime.LocalMarks)
    table.clear(Runtime.PendingMarks)
    table.clear(Runtime.ClaimKeys)
    Runtime.ClaimGeneration += 1

    Runtime.LastCalledNumber = nil
    Runtime.LastWinningCard = nil

    log("Round reset")

    task.delay(0.2, function()
        if Runtime.Running then
            scanCards()
            syncVisibleBalls(true)
        end
    end)
end

local function resetClaimEpoch(reason)
    table.clear(Runtime.ClaimKeys)
    Runtime.LastWinningCard = nil
    if reason then
        log("Pattern updated")
    end

    task.delay(0.1, function()
        if Runtime.Running then
            tryAutoClaim("stage/pattern update")
        end
    end)
end

addConnection(NumberCalled.OnClientEvent, function(...)
    local number = extractCalledNumber(...)

    if not number then
        log("Call payload error")
        return
    end

    local firstSeen = Runtime.CalledNumbers[number] ~= true

    Runtime.CalledNumbers[number] = true
    Runtime.LastCalledNumber = number

    if firstSeen then
        Runtime.Stats.ReceivedCalls += 1
    end

    task.delay(SETTINGS.AutoDaubDelay, function()
        if not Runtime.Running or not SETTINGS.AutoDaub then
            return
        end

        scanCards()

        local marked = markNumberNative(number)

        if firstSeen and marked > 0 then
            local _, letter = numberColumn(number)
            log(string.format("%s%d · %d", tostring(letter or ""), number, marked))
        end
    end)
end)

addConnection(CardsAssigned.OnClientEvent, function(...)
    task.defer(function()
        if not Runtime.Running then
            return
        end

        table.clear(Runtime.PendingMarks)
        scanCards()

        if SETTINGS.AutoDaub then
            task.spawn(function()
                syncVisibleBalls(true)
            end)
        end
    end)
end)

addConnection(RoundState.OnClientEvent, function(...)
    local args = table.pack(...)

    for i = 1, args.n do
        local payload = args[i]

        if type(payload) == "table" then
            local pattern = rawget(payload, "pattern")
            
            if pattern ~= nil and tostring(pattern) ~= "" then
                Runtime.ActivePattern = tostring(pattern)
                Runtime.LastPattern = Runtime.ActivePattern
            end

            -- NOVO: Extrair histórico de números para quem entra atrasado
            for _, key in ipairs({"called", "calledNumbers", "balls", "numbers", "history"}) do
                local val = rawget(payload, key)
                if type(val) == "table" then
                    for _, item in pairs(val) do
                        local num = normalizeNumber(item)
                        if num then
                            Runtime.CalledNumbers[num] = true
                        end
                    end
                end
            end
            break
        end
    end

    task.defer(function()
        if Runtime.Running then
            scanCards()
            tryAutoClaim("round-state")
        end
    end)
end)

if Notify then
    addConnection(Notify.OnClientEvent, function(...)

        task.defer(function()
            if Runtime.Running then
                scanCards()
            end
        end)
    end)
end

addConnection(Workspace:GetAttributeChangedSignal("BingoCalledCount"), function()
    local newCount = tonumber(Workspace:GetAttribute("BingoCalledCount")) or 0

    if newCount < Runtime.LastCalledCount then
        clearRoundState(string.format("count %d -> %d", Runtime.LastCalledCount, newCount))
    end

    Runtime.LastCalledCount = newCount
end)

addConnection(Workspace:GetAttributeChangedSignal("BingoPhase"), function()
    local previous = Runtime.LastPhase
    local phase = Workspace:GetAttribute("BingoPhase")
    Runtime.LastPhase = phase

    if tostring(previous) ~= tostring(phase) then
        log("Phase: " .. tostring(phase))
    end

    local lower = tostring(phase or ""):lower()
    if lower == "intermission"
        or lower == "waiting"
        or lower == "seating"
        or lower == "lobby"
        or lower == "starting"
    then
        clearRoundState("phase " .. tostring(phase))
    elseif lower == "playing" or lower == "claimwindow" then
        task.defer(function()
            if Runtime.Running then
                scanCards()
                syncVisibleBalls(true)
                tryAutoClaim("phase")
            end
        end)
    end
end)

addConnection(Workspace:GetAttributeChangedSignal("BingoStage"), function()
    local stage = Workspace:GetAttribute("BingoStage")
    local previous = Runtime.LastStage
    Runtime.LastStage = stage

    if stage ~= previous then
        resetClaimEpoch(string.format("stage %s -> %s", tostring(previous), tostring(stage)))
    end
end)

addConnection(Workspace:GetAttributeChangedSignal("BingoPattern"), function()
    local pattern = Workspace:GetAttribute("BingoPattern")
    local previous = Runtime.LastPattern

    Runtime.LastPattern = pattern

    if pattern ~= nil and tostring(pattern) ~= "" then
        Runtime.ActivePattern = tostring(pattern)
    end

    if pattern ~= previous then
        resetClaimEpoch("pattern")
    end
end)

addConnection(Workspace:GetAttributeChangedSignal("BingoWinner"), function()
    local winner = Workspace:GetAttribute("BingoWinner")
    if winner ~= nil and tostring(winner) ~= "" then
        log("Winner: " .. tostring(winner))
    end
end)

addConnection(PlayerGui.ChildAdded, function(child)
    if child.Name == "BingoGui" then
        task.delay(0.25, function()
            if Runtime.Running then
                scanCards()
                syncVisibleBalls(true)
            end
        end)
    end
end)

local THEME = {
    Background = Color3.fromRGB(15, 16, 21),
    Surface = Color3.fromRGB(22, 24, 31),
    Surface2 = Color3.fromRGB(28, 30, 39),
    Surface3 = Color3.fromRGB(34, 36, 46),
    Border = Color3.fromRGB(53, 56, 70),
    Text = Color3.fromRGB(241, 243, 248),
    Muted = Color3.fromRGB(151, 156, 172),
    Accent = Color3.fromRGB(125, 95, 255),
    AccentSoft = Color3.fromRGB(74, 59, 135),
    Success = Color3.fromRGB(78, 205, 135),
    Warning = Color3.fromRGB(244, 184, 76),
    Danger = Color3.fromRGB(235, 92, 104),
}

local function addCorner(object, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius or 8)
    corner.Parent = object
    return corner
end

local function addStroke(object, color, transparency)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color or THEME.Border
    stroke.Thickness = 1
    stroke.Transparency = transparency or 0
    stroke.Parent = object
    return stroke
end

local function makeLabel(parent, text, size, position, font, textSize, color)
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = size
    label.Position = position
    label.Font = font or Enum.Font.Gotham
    label.Text = text or ""
    label.TextSize = textSize or 12
    label.TextColor3 = color or THEME.Text
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Parent = parent
    return label
end

local ui = Instance.new("ScreenGui")
ui.Name = "BingoAutomationExactGui"
ui.ResetOnSpawn = false
ui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ui.DisplayOrder = 1000

local uiParent = PlayerGui
if type(gethui) == "function" then
    pcall(function()
        uiParent = gethui()
    end)
end
ui.Parent = uiParent
Runtime.Gui = ui

local shadow = Instance.new("Frame")
shadow.Name = "Shadow"
shadow.Size = UDim2.fromOffset(390, 462)
shadow.Position = UDim2.new(0, 29, 0.5, -226)
shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
shadow.BackgroundTransparency = 0.58
shadow.BorderSizePixel = 0
shadow.Parent = ui
addCorner(shadow, 15)

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(390, 462)
main.Position = UDim2.new(0, 24, 0.5, -231)
main.BackgroundColor3 = THEME.Background
main.BorderSizePixel = 0
main.Active = true
main.Parent = ui
addCorner(main, 15)
addStroke(main, THEME.Border, 0.15)

local mainScale = Instance.new("UIScale")
mainScale.Scale = 1
mainScale.Parent = main

local shadowScale = Instance.new("UIScale")
shadowScale.Scale = 1
shadowScale.Parent = shadow

local panelMinimized = false
local BASE_WIDTH = 390
local BASE_HEIGHT = 462
local HEADER_HEIGHT = 58

local function getViewportSize()
    local camera = Workspace.CurrentCamera or Camera
    if camera then
        return camera.ViewportSize
    end
    return Vector2.new(1280, 720)
end

local function calculatePanelScale()
    local viewport = getViewportSize()

    if not IS_TOUCH then
        return 1
    end

    local portrait = viewport.Y >= viewport.X
    local horizontalPadding = portrait and 18 or 24
    local verticalPadding = portrait and 120 or 46
    local widthScale = (viewport.X - horizontalPadding) / BASE_WIDTH
    local heightScale = (viewport.Y - verticalPadding) / BASE_HEIGHT
    local scale = math.min(widthScale, heightScale)

    if portrait then
        return math.clamp(scale, 0.68, 0.78)
    end

    return math.clamp(scale, 0.52, 0.64)
end

local function clampPanelPosition()
    local viewport = getViewportSize()
    local scale = mainScale.Scale
    local visualWidth = BASE_WIDTH * scale
    local visualHeight = (panelMinimized and HEADER_HEIGHT or BASE_HEIGHT) * scale
    local margin = IS_TOUCH and 8 or 4

    local x = math.clamp(main.Position.X.Offset, margin, math.max(margin, viewport.X - visualWidth - margin))
    local y = math.clamp(main.Position.Y.Offset, margin, math.max(margin, viewport.Y - visualHeight - margin))

    main.Position = UDim2.fromOffset(x, y)
    shadow.Position = UDim2.fromOffset(x + 5, y + 5)
end

local function applyResponsiveLayout(keepPosition)
    local viewport = getViewportSize()
    local scale = calculatePanelScale()
    local logicalHeight = panelMinimized and HEADER_HEIGHT or BASE_HEIGHT

    mainScale.Scale = scale
    shadowScale.Scale = scale
    main.Size = UDim2.fromOffset(BASE_WIDTH, logicalHeight)
    shadow.Size = UDim2.fromOffset(BASE_WIDTH, logicalHeight)

    if keepPosition then
        clampPanelPosition()
        return
    end

    local visualHeight = logicalHeight * scale
    local x = IS_TOUCH and 8 or 24
    local y = math.max(8, (viewport.Y - visualHeight) * 0.5)

    if IS_TOUCH and viewport.X > viewport.Y then
        y = 8
    end

    main.Position = UDim2.fromOffset(x, y)
    shadow.Position = UDim2.fromOffset(x + 5, y + 5)
end

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 58)
header.BackgroundTransparency = 1
header.Active = true
header.Parent = main

local accentBar = Instance.new("Frame")
accentBar.Size = UDim2.fromOffset(3, 30)
accentBar.Position = UDim2.fromOffset(12, 14)
accentBar.BackgroundColor3 = THEME.Accent
accentBar.BorderSizePixel = 0
accentBar.Parent = header
addCorner(accentBar, 3)

local title = makeLabel(
    header,
    "Bingo Automation",
    UDim2.fromOffset(210, 24),
    UDim2.fromOffset(25, 17),
    Enum.Font.GothamBold,
    16,
    THEME.Text
)

local phaseBadge = Instance.new("TextLabel")
phaseBadge.Name = "PhaseBadge"
phaseBadge.Size = UDim2.fromOffset(72, 24)
phaseBadge.Position = UDim2.new(1, -150, 0, 17)
phaseBadge.BackgroundColor3 = THEME.Surface3
phaseBadge.BorderSizePixel = 0
phaseBadge.Font = Enum.Font.GothamBold
phaseBadge.Text = "IDLE"
phaseBadge.TextSize = 9
phaseBadge.TextColor3 = THEME.Muted
phaseBadge.Parent = header
addCorner(phaseBadge, 12)

local unload = Instance.new("TextButton")
unload.Name = "Unload"
unload.Size = UDim2.fromOffset(26, 26)
unload.Position = UDim2.new(1, -34, 0, 16)
unload.BackgroundColor3 = THEME.Surface2
unload.BorderSizePixel = 0
unload.AutoButtonColor = false
unload.Font = Enum.Font.GothamBold
unload.Text = "×"
unload.TextSize = 17
unload.TextColor3 = THEME.Muted
unload.Parent = header
addCorner(unload, 8)
addStroke(unload, THEME.Border, 0.3)

local minimize = Instance.new("TextButton")
minimize.Name = "Minimize"
minimize.Size = UDim2.fromOffset(26, 26)
minimize.Position = UDim2.new(1, -64, 0, 16)
minimize.BackgroundColor3 = THEME.Surface2
minimize.BorderSizePixel = 0
minimize.AutoButtonColor = false
minimize.Font = Enum.Font.GothamBold
minimize.Text = "−"
minimize.TextSize = 16
minimize.TextColor3 = THEME.Muted
minimize.Parent = header
addCorner(minimize, 8)
addStroke(minimize, THEME.Border, 0.3)

addConnection(unload.MouseEnter, function()
    unload.BackgroundColor3 = Color3.fromRGB(62, 34, 40)
    unload.TextColor3 = THEME.Danger
end, Runtime.GuiConnections)

addConnection(unload.MouseLeave, function()
    unload.BackgroundColor3 = THEME.Surface2
    unload.TextColor3 = THEME.Muted
end, Runtime.GuiConnections)

local headerDivider = Instance.new("Frame")
headerDivider.Size = UDim2.new(1, -24, 0, 1)
headerDivider.Position = UDim2.fromOffset(12, 57)
headerDivider.BackgroundColor3 = THEME.Border
headerDivider.BackgroundTransparency = 0.35
headerDivider.BorderSizePixel = 0
headerDivider.Parent = main

local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, -24, 1, -70)
content.Position = UDim2.fromOffset(12, 66)
content.BackgroundTransparency = 1
content.Parent = main

addConnection(minimize.Activated, function()
    panelMinimized = not panelMinimized
    content.Visible = not panelMinimized
    headerDivider.Visible = not panelMinimized
    minimize.Text = panelMinimized and "+" or "−"
    applyResponsiveLayout(true)
end, Runtime.GuiConnections)

local function makeToggle(y, titleText, callback)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, 0, 0, IS_TOUCH and 44 or 40)
    button.Position = UDim2.fromOffset(0, y)
    button.BackgroundColor3 = THEME.Surface
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.Text = ""
    button.Parent = content
    addCorner(button, 9)
    addStroke(button, THEME.Border, 0.35)

    makeLabel(
        button,
        titleText,
        UDim2.new(1, -72, 1, 0),
        UDim2.fromOffset(12, 0),
        Enum.Font.GothamMedium,
        11,
        THEME.Text
    )

    local switch = Instance.new("Frame")
    switch.Name = "Switch"
    switch.Size = UDim2.fromOffset(42, 22)
    switch.Position = UDim2.new(1, -54, 0.5, -11)
    switch.BackgroundColor3 = THEME.Surface3
    switch.BorderSizePixel = 0
    switch.Parent = button
    addCorner(switch, 11)

    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.Size = UDim2.fromOffset(18, 18)
    knob.Position = UDim2.fromOffset(2, 2)
    knob.BackgroundColor3 = Color3.fromRGB(230, 232, 238)
    knob.BorderSizePixel = 0
    knob.Parent = switch
    addCorner(knob, 9)

    addConnection(button.MouseEnter, function()
        button.BackgroundColor3 = THEME.Surface2
    end, Runtime.GuiConnections)

    addConnection(button.MouseLeave, function()
        button.BackgroundColor3 = THEME.Surface
    end, Runtime.GuiConnections)

    addConnection(button.Activated, function()
        safe(callback, button)
    end, Runtime.GuiConnections)

    return button, switch, knob
end

local autoDaubButton, autoDaubSwitch, autoDaubKnob = makeToggle(
    0,
    "Auto Daub",
    function()
        SETTINGS.AutoDaub = not SETTINGS.AutoDaub

        if SETTINGS.AutoDaub then
            task.spawn(function()
                if Runtime.Running then
                    scanCards()
                    syncVisibleBalls(true)
                end
            end)
        end
    end
)

local autoClaimButton, autoClaimSwitch, autoClaimKnob = makeToggle(
    46,
    "Auto Claim",
    function()
        SETTINGS.AutoClaim = not SETTINGS.AutoClaim

        if SETTINGS.AutoClaim then
            task.defer(function()
                if Runtime.Running then
                    scanCards()
                    tryAutoClaim("reenabled")
                end
            end)
        end
    end
)

local function makeActionButton(x, width, text, callback)
    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(width, 32)
    button.Position = UDim2.fromOffset(x, 94)
    button.BackgroundColor3 = THEME.Surface2
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.Font = Enum.Font.GothamMedium
    button.Text = text
    button.TextSize = 10
    button.TextColor3 = THEME.Text
    button.Parent = content
    addCorner(button, 8)
    addStroke(button, THEME.Border, 0.35)

    addConnection(button.MouseEnter, function()
        button.BackgroundColor3 = THEME.Surface3
    end, Runtime.GuiConnections)

    addConnection(button.MouseLeave, function()
        button.BackgroundColor3 = THEME.Surface2
    end, Runtime.GuiConnections)

    addConnection(button.Activated, function()
        safe(callback, button)
    end, Runtime.GuiConnections)

    return button
end

local syncButton = makeActionButton(0, 179, "Mark All Called Balls", function()
    task.spawn(function()
        local total, _, marked = syncVisibleBalls(false)

        if total == 0 then
            log("Sync: no called balls")
        elseif marked == 0 then
            log(string.format("Sync: %d called · up to date", total))
        end
    end)
end)

local rescanButton = makeActionButton(187, 179, "Rescan Cards", function()
    task.spawn(function()
        scanCards()
        local _, _, marked = syncVisibleBalls(true)
        log(marked > 0 and string.format("Rescan: %d marked", marked) or "Rescan: up to date")
    end)
end)

local statsPanel = Instance.new("Frame")
statsPanel.Name = "Stats"
statsPanel.Size = UDim2.new(1, 0, 0, 108)
statsPanel.Position = UDim2.fromOffset(0, 134)
statsPanel.BackgroundColor3 = THEME.Surface
statsPanel.BorderSizePixel = 0
statsPanel.Parent = content
addCorner(statsPanel, 10)
addStroke(statsPanel, THEME.Border, 0.35)

local statsTitle = makeLabel(
    statsPanel,
    "ROUND STATUS",
    UDim2.fromOffset(110, 18),
    UDim2.fromOffset(12, 7),
    Enum.Font.GothamBold,
    9,
    THEME.Muted
)

local function makeMetric(x, y, width, labelText)
    local metric = Instance.new("Frame")
    metric.Size = UDim2.fromOffset(width, 34)
    metric.Position = UDim2.fromOffset(x, y)
    metric.BackgroundColor3 = THEME.Surface2
    metric.BorderSizePixel = 0
    metric.Parent = statsPanel
    addCorner(metric, 7)

    local label = makeLabel(
        metric,
        labelText,
        UDim2.new(1, -10, 0, 13),
        UDim2.fromOffset(7, 3),
        Enum.Font.Gotham,
        8,
        THEME.Muted
    )

    local value = makeLabel(
        metric,
        "-",
        UDim2.new(1, -10, 0, 15),
        UDim2.fromOffset(7, 16),
        Enum.Font.GothamBold,
        10,
        THEME.Text
    )

    return value
end

local phaseValue = makeMetric(10, 27, 110, "PHASE")
local patternValue = makeMetric(128, 27, 110, "PATTERN")
local cardsValue = makeMetric(246, 27, 110, "CARDS")
local lastValue = makeMetric(10, 67, 110, "LAST CALL")
local marksValue = makeMetric(128, 67, 110, "MARKS")
local claimsValue = makeMetric(246, 67, 110, "CLAIMS")

local logPanel = Instance.new("Frame")
logPanel.Name = "LogPanel"
logPanel.Size = UDim2.new(1, 0, 0, 128)
logPanel.Position = UDim2.fromOffset(0, 250)
logPanel.BackgroundColor3 = THEME.Surface
logPanel.BorderSizePixel = 0
logPanel.Parent = content
addCorner(logPanel, 10)
addStroke(logPanel, THEME.Border, 0.35)

local logTitle = makeLabel(
    logPanel,
    "EVENT LOG",
    UDim2.fromOffset(90, 20),
    UDim2.fromOffset(12, 7),
    Enum.Font.GothamBold,
    9,
    THEME.Muted
)

local clearLogs = Instance.new("TextButton")
clearLogs.Size = UDim2.fromOffset(42, 20)
clearLogs.Position = UDim2.new(1, -52, 0, 6)
clearLogs.BackgroundColor3 = THEME.Surface2
clearLogs.BorderSizePixel = 0
clearLogs.AutoButtonColor = false
clearLogs.Font = Enum.Font.GothamMedium
clearLogs.Text = "Clear"
clearLogs.TextSize = 8
clearLogs.TextColor3 = THEME.Muted
clearLogs.Parent = logPanel
addCorner(clearLogs, 6)

addConnection(clearLogs.Activated, function()
    table.clear(Runtime.Logs)
end, Runtime.GuiConnections)

local logBox = Instance.new("TextLabel")
logBox.Name = "Log"
logBox.Size = UDim2.new(1, -20, 0, 92)
logBox.Position = UDim2.fromOffset(10, 29)
logBox.BackgroundColor3 = THEME.Background
logBox.BorderSizePixel = 0
logBox.Font = Enum.Font.Code
logBox.Text = ""
logBox.TextSize = 9
logBox.TextColor3 = Color3.fromRGB(185, 189, 202)
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.TextWrapped = false
logBox.ClipsDescendants = true
logBox.Parent = logPanel
addCorner(logBox, 7)

local logPadding = Instance.new("UIPadding")
logPadding.PaddingLeft = UDim.new(0, 7)
logPadding.PaddingTop = UDim.new(0, 6)
logPadding.PaddingRight = UDim.new(0, 7)
logPadding.Parent = logBox

local footer = makeLabel(
    content,
    "Waiting for round data...",
    UDim2.new(1, 0, 0, 18),
    UDim2.fromOffset(1, 380),
    Enum.Font.Gotham,
    8,
    THEME.Muted
)
footer.TextXAlignment = Enum.TextXAlignment.Center

local dragging = false
local dragStart = nil
local startPosition = nil
local activeTouch = nil

local function beginDrag(input)
    dragging = true
    dragStart = input.Position
    startPosition = main.Position

    if input.UserInputType == Enum.UserInputType.Touch then
        activeTouch = input
    end
end

addConnection(header.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
    then
        beginDrag(input)
    end
end, Runtime.GuiConnections)

addConnection(UserInputService.InputChanged, function(input)
    if not dragging then
        return
    end

    local isMouse = input.UserInputType == Enum.UserInputType.MouseMovement
    local isTouch = input.UserInputType == Enum.UserInputType.Touch and (activeTouch == nil or input == activeTouch)

    if not isMouse and not isTouch then
        return
    end

    local delta = input.Position - dragStart
    local newPosition = UDim2.fromOffset(
        startPosition.X.Offset + delta.X,
        startPosition.Y.Offset + delta.Y
    )

    main.Position = newPosition
    shadow.Position = UDim2.fromOffset(
        newPosition.X.Offset + 5,
        newPosition.Y.Offset + 5
    )

    clampPanelPosition()
end, Runtime.GuiConnections)

addConnection(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or (input.UserInputType == Enum.UserInputType.Touch and (activeTouch == nil or input == activeTouch))
    then
        dragging = false
        activeTouch = nil
        clampPanelPosition()
    end
end, Runtime.GuiConnections)

local function setToggleVisual(switch, knob, enabled)
    if enabled then
        switch.BackgroundColor3 = THEME.Accent
        knob.Position = UDim2.fromOffset(22, 2)
        knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    else
        switch.BackgroundColor3 = THEME.Surface3
        knob.Position = UDim2.fromOffset(2, 2)
        knob.BackgroundColor3 = Color3.fromRGB(210, 213, 222)
    end
end

local function updateUi()
    if not Runtime.Running or not ui.Parent then
        return
    end

    setToggleVisual(autoDaubSwitch, autoDaubKnob, SETTINGS.AutoDaub)
    setToggleVisual(autoClaimSwitch, autoClaimKnob, SETTINGS.AutoClaim)

    local phase = Workspace:GetAttribute("BingoPhase")
    local stage = Workspace:GetAttribute("BingoStage")
    local pattern = currentPattern()
    local calledCount = tonumber(Workspace:GetAttribute("BingoCalledCount")) or 0
    local winner = Workspace:GetAttribute("BingoWinner")
    local phaseText = tostring(phase or "Idle")
    local phaseLower = phaseText:lower()

    phaseBadge.Text = string.upper(phaseText)
    if phaseLower == "playing" then
        phaseBadge.BackgroundColor3 = Color3.fromRGB(28, 71, 51)
        phaseBadge.TextColor3 = THEME.Success
    elseif phaseLower == "intermission" or phaseLower == "waiting" then
        phaseBadge.BackgroundColor3 = Color3.fromRGB(71, 57, 29)
        phaseBadge.TextColor3 = THEME.Warning
    else
        phaseBadge.BackgroundColor3 = THEME.Surface3
        phaseBadge.TextColor3 = THEME.Muted
    end

    phaseValue.Text = string.format("%s · S%s", phaseText, tostring(stage or "-"))
    patternValue.Text = tostring(pattern or "-")
    cardsValue.Text = string.format("%d / %d", countDictionary(Runtime.Cards), MAX_CARDS)

    if Runtime.LastCalledNumber then
        local _, letter = numberColumn(Runtime.LastCalledNumber)
        lastValue.Text = string.format("%s%d", tostring(letter or ""), Runtime.LastCalledNumber)
    else
        lastValue.Text = "-"
    end

    marksValue.Text = string.format(
        "%d / %d",
        Runtime.Stats.DaubsConfirmed,
        Runtime.Stats.DaubsSent
    )
    if Runtime.Stats.DaubsFailed > 0 then
        marksValue.TextColor3 = THEME.Warning
    else
        marksValue.TextColor3 = THEME.Success
    end

    claimsValue.Text = tostring(Runtime.Stats.ClaimsTriggered)

    local winnerText = (winner and tostring(winner) ~= "") and tostring(winner) or "None"
    footer.Text = string.format(
        "%d/%d calls seen  •  Winning card: %s  •  Winner: %s",
        countDictionary(Runtime.CalledNumbers),
        calledCount,
        tostring(Runtime.LastWinningCard or "-"),
        winnerText
    )

    local lines = {}
    for i = 1, math.min(#Runtime.Logs, 5) do
        lines[#lines + 1] = Runtime.Logs[i]
    end
    logBox.Text = table.concat(lines, "\n")
end

applyResponsiveLayout(false)

local viewportConnection = nil

local function bindViewportWatcher()
    if viewportConnection then
        pcall(function()
            viewportConnection:Disconnect()
        end)
        viewportConnection = nil
    end

    local camera = Workspace.CurrentCamera
    if camera then
        viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            applyResponsiveLayout(true)
        end)
        table.insert(Runtime.GuiConnections, viewportConnection)
    end
end

bindViewportWatcher()

addConnection(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
    Camera = Workspace.CurrentCamera
    bindViewportWatcher()
    applyResponsiveLayout(true)
end, Runtime.GuiConnections)

task.spawn(function()
    while Runtime.Running do
        safe(scanCards)
        safe(tryAutoClaim, "maintenance")
        safe(updateUi)
        task.wait(SETTINGS.RescanInterval)
    end
end)

function Runtime:Unload()
    if not self.Running then
        return
    end

    self.Running = false
    self.ClaimGeneration += 1
    table.clear(self.PendingMarks)
    disconnectBucket(self.Connections)
    disconnectBucket(self.GuiConnections)

    if self.Gui then
        pcall(function()
            self.Gui:Destroy()
        end)
        self.Gui = nil
    end

    if ENV.BingoAutomationExact == self then
        ENV.BingoAutomationExact = nil
    end

    if SETTINGS.ConsoleDebug then
        print("[Bingo] Unloaded")
    end
end

addConnection(unload.Activated, function()
    Runtime:Unload()
end, Runtime.GuiConnections)

scanCards()
log("Ready")
updateUi()

task.spawn(function()
    if Runtime.Running then
        scanCards()
        syncVisibleBalls(true)
        scheduleAutoClaim()
    end
end)
