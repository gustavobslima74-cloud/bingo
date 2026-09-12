-- [[ Rscripts Risk Notice ]]
-- This script is not verified by rscripts.net. Deal with caution.
-- [[ End Rscripts Risk Notice ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = Workspace.CurrentCamera

-- Limpa instancias antigas
for _, g in ipairs(PlayerGui:GetChildren()) do
    if g.Name == "KikoBingoGui" or g.Name == "KikoErrorGui" or g.Name == "BingoAutomationExactGui" then
        pcall(function() g:Destroy() end)
    end
end

local ENV = (getgenv and getgenv()) or _G
if ENV.KikoMenu and ENV.KikoMenu.Destroy then
    pcall(function() ENV.KikoMenu:Destroy() end)
    task.wait(0.1)
end

if ENV.BingoAutomationExact and ENV.BingoAutomationExact.Unload then
    pcall(function() ENV.BingoAutomationExact:Unload() end)
    task.wait(0.1)
end

-- ============================================================
-- GAME HOOKS E REQUIRES
-- ============================================================
local BingoShared = ReplicatedStorage:WaitForChild("BingoShared", 10)
assert(BingoShared, "[Bingo] ReplicatedStorage.BingoShared was not found")

local ConfigModule = BingoShared:WaitForChild("Config", 10)
local CardUtilModule = BingoShared:WaitForChild("CardUtil", 10)
assert(ConfigModule and CardUtilModule, "[Bingo] Config/CardUtil was not found")

local Config = require(ConfigModule)
local CardUtil = require(CardUtilModule)

local BingoRemotes = ReplicatedStorage:WaitForChild("BingoRemotes", 10)
local NumberCalled = BingoRemotes:WaitForChild("NumberCalled")
local RoundState = BingoRemotes:WaitForChild("RoundState")
local CardsAssigned = BingoRemotes:WaitForChild("CardsAssigned")
local ClaimBingo = BingoRemotes:WaitForChild("ClaimBingo")

local SetCardsRemote = BingoRemotes:FindFirstChild("SetCards") or BingoRemotes:FindFirstChild("UpdateCards") or BingoRemotes:FindFirstChild("RequestCards")

-- ============================================================
-- ESTADO & CONFIGURAÇÕES (Backend + Frontend)
-- ============================================================
local SETTINGS = {
    AutoDaubDelay = 0.5,
    MarkAllSpacing = 0.3,
    AutoClaimDelay = 0.4,
    MarkConfirmTimeout = 1.35,
    MarkConfirmPoll = 0.04,
    DaubSpacing = 0.035,
    RescanInterval = 0.75,
    ClaimCooldown = 0.35,
    MaxLogLines = 8,
}

local State = {
    Running = true,
    AutoDaub = true,
    AutoClaim = true,
    TargetCardCount = 6,
    AlreadyWonThisRound = false, -- Trava para contar apenas 1 vez por rodada
    Logs = {},
    Connections = {},
    Gui = nil,
    Cards = {},
    NumberIndex = {},
    CalledNumbers = {},
    LocalMarks = {},
    PendingMarks = {},
    ClaimGeneration = 0,
    LastClaimAt = 0,
    LastCalledNumber = nil,
    LastCalledCount = tonumber(Workspace:GetAttribute("BingoCalledCount")) or 0,
    LastPhase = Workspace:GetAttribute("BingoPhase"),
    LastStage = Workspace:GetAttribute("BingoStage"),
    ActivePattern = Workspace:GetAttribute("BingoPattern"),
    LastWinningCard = nil,
    Stats = {
        ReceivedCalls = 0,
        DaubsSent = 0,
        DaubsConfirmed = 0,
        DaubsFailed = 0,
        ClaimsTriggered = 0,
    },
}

ENV.KikoMenu = State

local function connect(signal, cb)
    local c = signal:Connect(cb)
    table.insert(State.Connections, c)
    return c
end

local function log(msg)
    table.insert(State.Logs, 1, os.date("%H:%M:%S") .. "  " .. tostring(msg))
    while #State.Logs > SETTINGS.MaxLogLines do table.remove(State.Logs) end
end

local function countDictionary(dictionary)
    local n = 0
    for _ in pairs(dictionary) do n += 1 end
    return n
end

-- ============================================================
-- LÓGICA CORE DO BINGO
-- ============================================================
local GRID = tonumber(Config.GRID) or 5
local FREE_COL = tonumber(Config.FREE_COL) or 3
local FREE_ROW = tonumber(Config.FREE_ROW) or 3
local MAX_CARDS = tonumber(Config.MAX_CARDS) or 6

local function isFreeCoordinate(c, r) return c == FREE_COL and r == FREE_ROW end

local function numberColumn(number)
    if Config.columnForNumber then
        local ok, col, let = pcall(Config.columnForNumber, number)
        if ok then return col, let end
    end
    for col, range in ipairs(Config.COLUMN_RANGES or {}) do
        if number >= range[1] and number <= range[2] then
            local let = Config.LETTERS and Config.LETTERS[col] or tostring(col)
            return col, let
        end
    end
    return nil, nil
end

local function getBingoGui() return PlayerGui:FindFirstChild("BingoGui") end
local function getCardArea()
    local gui = getBingoGui()
    return gui and gui:FindFirstChild("CardArea", true)
end
local function getBallSlots()
    local gui = getBingoGui()
    local ballRow = gui and gui:FindFirstChild("BallRow", true)
    return ballRow and ballRow:FindFirstChild("Slots", true)
end

local function cardIndexFromName(name)
    local value = type(name) == "string" and name:match("^Card(%d+)$")
    value = tonumber(value)
    if not value or value < 1 or value > MAX_CARDS then return nil end
    return value
end

local function getCardGrid(card)
    local gridArea = card and card:FindFirstChild("GridArea")
    return gridArea and gridArea:FindFirstChild("Grid")
end

local function normalizeNumber(value)
    if type(value) == "number" then return (value % 1 == 0 and value >= 1 and value <= 75) and value or nil end
    if type(value) ~= "string" then return nil end
    local direct = tonumber(value)
    if direct and direct % 1 == 0 and direct >= 1 and direct <= 75 then direct = math.clamp(direct, 1, 75); return direct end
    local digits = value:match("(%d+)")
    local num = tonumber(digits)
    return (num and num >= 1 and num <= 75) and num or nil
end

local function getCellNumber(cell)
    local numObj = cell and cell:FindFirstChild("Number")
    if not numObj then return nil end
    local ok, text = pcall(function() return numObj.Text end)
    return ok and normalizeNumber(text) or nil
end

local function cellKey(cardIndex, col, row) return string.format("%d:%d:%d", cardIndex, col, row) end

local function stampLooksMarked(cell)
    local stamp = cell and cell:FindFirstChild("Stamp")
    return stamp and stamp:IsA("GuiObject") and stamp.Visible == true
end

local function getCell(cardData, col, row)
    return cardData and cardData.Grid and cardData.Grid:FindFirstChild(string.format("C%d_%d", col, row))
end

local function scanCards()
    local cardArea = getCardArea()
    local discovered = {}
    local numberIndex = {}

    if cardArea then
        local descendants = cardArea:GetDescendants()
        for i = 1, #descendants do
            local object = descendants[i]
            local index = cardIndexFromName(object.Name)
            if index then
                local grid = getCardGrid(object)
                if grid then discovered[index] = { Index = index, Object = object, Grid = grid } end
            end
        end
    end

    for index = 1, MAX_CARDS do
        local cardData = discovered[index]
        if cardData then
            for col = 1, GRID do
                for row = 1, GRID do
                    if not isFreeCoordinate(col, row) then
                        local cell = getCell(cardData, col, row)
                        local number = getCellNumber(cell)
                        if number then
                            local matches = numberIndex[number] or {}
                            numberIndex[number] = matches
                            table.insert(matches, { CardData = cardData, Column = col, Row = row, Cell = cell })
                        end
                    end
                end
            end
        end
    end

    State.Cards = discovered
    State.NumberIndex = numberIndex
    return discovered
end

local function buildMarkedGrid(cardData)
    local marked = {}
    for col = 1, GRID do
        marked[col] = {}
        for row = 1, GRID do
            if isFreeCoordinate(col, row) then
                marked[col][row] = true
            else
                local cell = getCell(cardData, col, row)
                local number = getCellNumber(cell)
                local key = cellKey(cardData.Index, col, row)
                local stamped = stampLooksMarked(cell) or State.LocalMarks[key] == true
                marked[col][row] = stamped and number ~= nil and State.CalledNumbers[number] == true
            end
        end
    end
    return marked
end

local function currentPattern()
    local pattern = State.ActivePattern
    if not pattern or tostring(pattern) == "" then pattern = Workspace:GetAttribute("BingoPattern") end
    return (not pattern or tostring(pattern) == "") and "Line" or tostring(pattern)
end

local function checkCardBingo(cardData, pattern)
    if not cardData then return nil end
    local marked = buildMarkedGrid(cardData)
    local ok, result = pcall(function() return CardUtil.checkBingo(marked, pattern or currentPattern()) end)
    return ok and result or nil
end

local function findWinningCard(pattern)
    pattern = pattern or currentPattern()
    for index = 1, MAX_CARDS do
        local cardData = State.Cards[index]
        if cardData then
            local mask = checkCardBingo(cardData, pattern)
            if mask then return cardData, mask end
        end
    end
    return nil, nil
end

local function requestClaim()
    if not State.Running or (os.clock() - State.LastClaimAt < SETTINGS.ClaimCooldown) then return false end
    State.LastClaimAt = os.clock()
    local ok, err = pcall(function() ClaimBingo:FireServer() end)
    if not ok then log("Erro ao chamar bingo: " + tostring(err)); return false end
    
    -- Conta apenas uma vez por rodada para evitar o spam
    if not State.AlreadyWonThisRound then
        State.AlreadyWonThisRound = true
        State.Stats.ClaimsTriggered += 1
        log("BINGO CHAMADO E COMPUTADO COM SUCESSO!")
    end
    
    return true
end

local function tryAutoClaim(reason)
    if not State.AutoClaim or not State.Running or State.AlreadyWonThisRound then return false end
    local phase = tostring(Workspace:GetAttribute("BingoPhase") or ""):lower()
    if phase ~= "playing" and phase ~= "claimwindow" then return false end

    local cardData = findWinningCard(currentPattern())
    if not cardData then
        State.LastWinningCard = nil
        return false
    end
    State.LastWinningCard = cardData.Index
    return requestClaim()
end

local function connectionCount(signal)
    if type(getconnections) ~= "function" then return nil end
    local ok, conns = pcall(getconnections, signal)
    return (ok and type(conns) == "table") and #conns or nil
end

local function fireNativeCell(cell)
    if not cell or not cell:IsA("GuiButton") or stampLooksMarked(cell) then return false end
    local selected = cell.Activated
    if type(getconnections) == "function" then
        local act = connectionCount(cell.Activated) or 0
        local clk = connectionCount(cell.MouseButton1Click) or 0
        if act <= 0 and clk > 0 then selected = cell.MouseButton1Click
        elseif act <= 0 and clk <= 0 then return false end
    end
    if type(firesignal) == "function" then return pcall(function() firesignal(selected) end) end
    return pcall(function() cell:Activate() end)
end

local function markEntryNative(entry, number)
    if not State.Running then return false end
    local cardData, col, row = entry.CardData, entry.Column, entry.Row
    local cell = entry.Cell or getCell(cardData, col, row)
    if not cell then return false end

    local key = string.format("%d:%d:%d:%d", cardData.Index, col, row, number)
    local cKey = cellKey(cardData.Index, col, row)
    if stampLooksMarked(cell) then State.LocalMarks[cKey] = true return false end
    if State.PendingMarks[key] then return false end

    State.PendingMarks[key] = true
    if not fireNativeCell(cell) then
        State.PendingMarks[key] = nil; State.Stats.DaubsFailed += 1
        return false
    end
    State.Stats.DaubsSent += 1

    task.spawn(function()
        local deadline = os.clock() + 1.5
        while State.Running and os.clock() < deadline do
            if stampLooksMarked(cell) then
                State.LocalMarks[cKey] = true
                State.Stats.DaubsConfirmed += 1
                State.PendingMarks[key] = nil
                task.delay(SETTINGS.AutoClaimDelay, function() pcall(tryAutoClaim, "daub") end)
                return
            end
            task.wait(0.03)
        end
        State.PendingMarks[key] = nil
        State.Stats.DaubsFailed += 1
    end)
    return true
end

local function markNumberNative(number)
    local num = normalizeNumber(number)
    if not num then return 0 end
    local matches = State.NumberIndex[num]
    if not matches then return 0 end
    local marked = 0
    for i = 1, #matches do
        if markEntryNative(matches[i], num) then marked += 1 end
    end
    return marked
end

local function getVisibleCalledNumbers()
    local slots = getBallSlots()
    if not slots then return {} end
    local found = {}
    local children = slots:GetChildren()
    for i = 1, #children do
        local obj = children[i]
        local number = normalizeNumber(obj.Name)
        if not number then
            local nLbl = obj:FindFirstChild("NumberLabel", true)
            if nLbl then pcall(function() number = normalizeNumber(nLbl.Text) end) end
        end
        if number then found[number] = true end
    end
    local numbers = {}
    for num in pairs(found) do numbers[#numbers + 1] = num end
    table.sort(numbers)
    return numbers
end

local function syncVisibleBalls(silent)
    local numbers = getVisibleCalledNumbers()
    if #numbers == 0 then return 0, 0, 0 end
    scanCards()
    local matches, marks = 0, 0
    for i = 1, #numbers do
        if not State.Running then break end
        local number = numbers[i]
        State.CalledNumbers[number] = true
        local nMatches = State.NumberIndex[number]
        if nMatches and #nMatches > 0 then
            matches += 1
            for j = 1, #nMatches do
                if not State.Running then break end
                local entry = nMatches[j]
                local cell = entry.Cell or getCell(entry.CardData, entry.Column, entry.Row)
                if cell and not stampLooksMarked(cell) then
                    if markEntryNative(entry, number) then
                        marks += 1; task.wait(SETTINGS.MarkAllSpacing)
                    end
                end
            end
        end
    end
    if not silent then
        if marks > 0 then log(string.format("Sincronizado: %d chamadas · %d marcadas", #numbers, marks))
        else log(string.format("Sincronizado: %d chamadas · atualizado", #numbers)) end
    end
    return #numbers, matches, marks
end

local function equipCards(amount)
    amount = math.clamp(tonumber(amount) or 1, 1, MAX_CARDS)
    State.TargetCardCount = amount
    
    local success = false
    if SetCardsRemote then
        local ok = pcall(function() SetCardsRemote:FireServer(amount) end)
        if ok then success = true end
    end
    
    if not success then
        local remotes = BingoRemotes:GetChildren()
        for i = 1, #remotes do
            local remote = remotes[i]
            if remote:IsA("RemoteEvent") and (remote.Name:lower():find("card") or remote.Name:lower():find("setting")) then
                pcall(function() remote:FireServer(amount) end)
            end
        end
    end
    
    log(string.format("Comando de equipar enviado: %d cartela(s)", amount))
    task.spawn(function()
        task.wait(0.3)
        scanCards()
    end)
end

local function clearRoundState(reason)
    table.clear(State.CalledNumbers)
    table.clear(State.LocalMarks)
    table.clear(State.PendingMarks)
    State.LastCalledNumber = nil
    State.LastWinningCard = nil
    State.AlreadyWonThisRound = false -- Reseta a trava para a nova fase/rodada
    log("Rodada reiniciada")
    task.delay(0.2, function()
        if State.Running then scanCards(); syncVisibleBalls(true) end
    end)
end

-- ============================================================
-- TEMA — NEON GLASS
-- ============================================================
local THEME = {
    Bg = Color3.fromRGB(8, 6, 16),
    Surface = Color3.fromRGB(18, 14, 32),
    Surface2 = Color3.fromRGB(26, 20, 46),
    Surface3 = Color3.fromRGB(36, 28, 62),
    Border = Color3.fromRGB(50, 40, 84),
    Text = Color3.fromRGB(245, 240, 255),
    TextDim = Color3.fromRGB(150, 140, 195),
    Purple = Color3.fromRGB(168, 85, 247),
    Pink = Color3.fromRGB(236, 72, 153),
    Cyan = Color3.fromRGB(34, 211, 238),
    Green = Color3.fromRGB(74, 222, 128),
    Yellow = Color3.fromRGB(250, 204, 21),
    Gold = Color3.fromRGB(255, 200, 60),
    Red = Color3.fromRGB(248, 113, 113),
}

local function addCorner(obj, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = obj
    return c
end

local function addStroke(obj, color, transparency, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color or THEME.Border
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0
    s.Parent = obj
    return s
end

local function makeLabel(parent, text, size, position, font, textSize, color)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = size
    l.Position = position
    l.Font = font or Enum.Font.Gotham
    l.Text = text or ""
    l.TextSize = textSize or 12
    l.TextColor3 = color or THEME.Text
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Center
    l.Parent = parent
    return l
end

-- ============================================================
-- GUI
-- ============================================================
local BASE_W = 340
local BASE_H = 610
local HEADER_H = 60
local isTouch = UserInputService.TouchEnabled
local minimized = false

local ui = Instance.new("ScreenGui")
ui.Name = "KikoBingoGui"
ui.ResetOnSpawn = false
ui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ui.DisplayOrder = 1000
ui.IgnoreGuiInset = true

local uiParent = PlayerGui
if type(gethui) == "function" then
    local ok, hui = pcall(gethui)
    if ok and hui then uiParent = hui end
end
ui.Parent = uiParent
State.Gui = ui

local glow = Instance.new("Frame")
glow.Size = UDim2.fromOffset(BASE_W + 16, BASE_H + 16)
glow.Position = UDim2.new(0, 16, 0.5, -303)
glow.BackgroundColor3 = THEME.Purple
glow.BackgroundTransparency = 0.82
glow.BorderSizePixel = 0
glow.ZIndex = 0
glow.Parent = ui
addCorner(glow, 32)

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(BASE_W, BASE_H)
main.Position = UDim2.new(0, 24, 0.5, -295)
main.BackgroundColor3 = THEME.Bg
main.BorderSizePixel = 0
main.Active = true
main.ClipsDescendants = true
main.ZIndex = 1
main.Parent = ui
addCorner(main, 24)
addStroke(main, THEME.Border, 0.15, 1.5)

local mainScale = Instance.new("UIScale")
mainScale.Scale = 1
mainScale.Parent = main

-- Cabecalho
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, HEADER_H)
header.BackgroundColor3 = Color3.fromRGB(120, 40, 200)
header.BorderSizePixel = 0
header.Active = true
header.ZIndex = 2
header.Parent = main
addCorner(header, 24)

local headerGradient = Instance.new("UIGradient")
headerGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 40, 200)),
    ColorSequenceKeypoint.new(0.35, Color3.fromRGB(200, 45, 150)),
    ColorSequenceKeypoint.new(0.7, Color3.fromRGB(30, 160, 220)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 40, 200)),
})
headerGradient.Parent = header

local gradOffset = 0
connect(RunService.Heartbeat, function(dt)
    if not State.Running then return end
    gradOffset = (gradOffset + dt * 0.12) % 1
    headerGradient.Offset = Vector2.new(gradOffset - 0.5, 0)
end)

local logoDot = Instance.new("Frame")
logoDot.Size = UDim2.fromOffset(10, 10)
logoDot.Position = UDim2.fromOffset(16, 25)
logoDot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
logoDot.BorderSizePixel = 0
logoDot.ZIndex = 3
logoDot.Parent = header
addCorner(logoDot, 5)

makeLabel(header, "KIKO BINGO", UDim2.fromOffset(150, 20), UDim2.fromOffset(34, 16), Enum.Font.GothamBold, 15, Color3.fromRGB(255, 255, 255)).ZIndex = 3
makeLabel(header, "auto exact mode", UDim2.fromOffset(150, 14), UDim2.fromOffset(34, 34), Enum.Font.Gotham, 9, Color3.fromRGB(220, 200, 255)).ZIndex = 3

local phaseBadge = Instance.new("TextLabel")
phaseBadge.Size = UDim2.fromOffset(70, 22)
phaseBadge.Position = UDim2.new(1, -146, 0, 18)
phaseBadge.BackgroundColor3 = Color3.fromRGB(20, 15, 40)
phaseBadge.BackgroundTransparency = 0.45
phaseBadge.BorderSizePixel = 0
phaseBadge.Font = Enum.Font.GothamBold
phaseBadge.Text = "OCIOSO"
phaseBadge.TextSize = 9
phaseBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
phaseBadge.ZIndex = 3
phaseBadge.Parent = header
addCorner(phaseBadge, 11)

local minimize = Instance.new("TextButton")
minimize.Size = UDim2.fromOffset(26, 26)
minimize.Position = UDim2.new(1, -68, 0, 17)
minimize.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
minimize.BackgroundTransparency = 0.82
minimize.BorderSizePixel = 0
minimize.AutoButtonColor = false
minimize.Font = Enum.Font.GothamBold
minimize.Text = "-"
minimize.TextSize = 16
minimize.TextColor3 = Color3.fromRGB(255, 255, 255)
minimize.ZIndex = 3
minimize.Parent = header
addCorner(minimize, 9)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(26, 26)
closeBtn.Position = UDim2.new(1, -38, 0, 17)
closeBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.BackgroundTransparency = 0.82
closeBtn.BorderSizePixel = 0
closeBtn.AutoButtonColor = false
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Text = "x"
closeBtn.TextSize = 12
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.ZIndex = 3
closeBtn.Parent = header
addCorner(closeBtn, 9)

connect(closeBtn.MouseEnter, function() closeBtn.BackgroundColor3 = THEME.Red; closeBtn.BackgroundTransparency = 0.35 end)
connect(closeBtn.MouseLeave, function() closeBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255); closeBtn.BackgroundTransparency = 0.82 end)
connect(minimize.MouseEnter, function() minimize.BackgroundTransparency = 0.6 end)
connect(minimize.MouseLeave, function() minimize.BackgroundTransparency = 0.82 end)

-- Conteudo
local content = Instance.new("Frame")
content.Size = UDim2.new(1, -24, 1, -70)
content.Position = UDim2.fromOffset(12, 66)
content.BackgroundTransparency = 1
content.ZIndex = 2
content.Parent = main

-- Status row
local statusRow = Instance.new("Frame")
statusRow.Size = UDim2.new(1, 0, 0, 22)
statusRow.Position = UDim2.fromOffset(0, 0)
statusRow.BackgroundTransparency = 1
statusRow.Parent = content

local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.fromOffset(10, 10)
statusDot.Position = UDim2.fromOffset(4, 6)
statusDot.BackgroundColor3 = THEME.Green
statusDot.BorderSizePixel = 0
statusDot.Parent = statusRow
addCorner(statusDot, 5)

local statusDotScale = Instance.new("UIScale")
statusDotScale.Scale = 1
statusDotScale.Parent = statusDot

local statusText = makeLabel(statusRow, "PRONTO", UDim2.fromOffset(180, 22), UDim2.fromOffset(22, 0), Enum.Font.GothamBold, 10, THEME.Green)
local ballsLabel = makeLabel(statusRow, "0 bolas", UDim2.fromOffset(120, 22), UDim2.new(1, -120, 0, 0), Enum.Font.Gotham, 9, THEME.TextDim)
ballsLabel.TextXAlignment = Enum.TextXAlignment.Right

local pulseT = 0
connect(RunService.Heartbeat, function(dt)
    if not State.Running then return end
    pulseT = pulseT + dt
    local p = (math.sin(pulseT * 4) + 1) * 0.5
    statusDotScale.Scale = 1 + p * 0.35
end)

-- Banner Vitorias
local winsBanner = Instance.new("Frame")
winsBanner.Size = UDim2.new(1, 0, 0, 34)
winsBanner.Position = UDim2.fromOffset(0, 28)
winsBanner.BackgroundColor3 = Color3.fromRGB(60, 45, 15)
winsBanner.BorderSizePixel = 0
winsBanner.Parent = content
addCorner(winsBanner, 10)

local winsGradient = Instance.new("UIGradient")
winsGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 55, 15)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 80, 20)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 55, 15)),
})
winsGradient.Parent = winsBanner
addStroke(winsBanner, THEME.Gold, 0.35, 1.5)

makeLabel(winsBanner, "BINGOS GANHOS", UDim2.fromOffset(110, 34), UDim2.fromOffset(14, 0), Enum.Font.GothamBold, 10, THEME.Gold)
local winsNumber = makeLabel(winsBanner, "0", UDim2.new(0, 60, 1, 0), UDim2.new(1, -80, 0, 0), Enum.Font.GothamBold, 20, THEME.Gold)
winsNumber.TextXAlignment = Enum.TextXAlignment.Right

-- Chips
local function makeChip(x, y, labelText)
    local chip = Instance.new("Frame")
    chip.Size = UDim2.fromOffset(100, 44)
    chip.Position = UDim2.fromOffset(x, y)
    chip.BackgroundColor3 = THEME.Surface2
    chip.BorderSizePixel = 0
    chip.Parent = content
    addCorner(chip, 10)
    addStroke(chip, THEME.Border, 0.5)
    makeLabel(chip, labelText, UDim2.new(1, -12, 0, 12), UDim2.fromOffset(8, 5), Enum.Font.GothamBold, 7, THEME.TextDim)
    local value = makeLabel(chip, "-", UDim2.new(1, -12, 0, 22), UDim2.fromOffset(8, 18), Enum.Font.GothamBold, 13, THEME.Text)
    value.TextTruncate = Enum.TextTruncate.AtEnd
    return chip, value
end

local _, chipPadrao = makeChip(0, 70, "PADRAO")
local _, chipCartelas = makeChip(108, 70, "CARTELAS")
local _, chipUltimo = makeChip(216, 70, "ULT. BOLA")
local _, chipMarcadas = makeChip(0, 118, "MARCADAS")
local _, chipClaims = makeChip(108, 118, "CLAIMS")
local _, chipFase = makeChip(216, 118, "FASE")

-- ============================================================
-- PAINEL SLIDER DE CARTELAS
-- ============================================================
local cardEquipPanel = Instance.new("Frame")
cardEquipPanel.Size = UDim2.new(1, 0, 0, 52)
cardEquipPanel.Position = UDim2.fromOffset(0, 168)
cardEquipPanel.BackgroundColor3 = THEME.Surface
cardEquipPanel.BorderSizePixel = 0
cardEquipPanel.Parent = content
addCorner(cardEquipPanel, 10)
addStroke(cardEquipPanel, THEME.Border, 0.5)

makeLabel(cardEquipPanel, "CARTELAS:", UDim2.new(0, 70, 0, 20), UDim2.fromOffset(10, 6), Enum.Font.GothamBold, 9, THEME.TextDim)
local sliderValueLabel = makeLabel(cardEquipPanel, "6", UDim2.new(0, 30, 0, 20), UDim2.fromOffset(80, 6), Enum.Font.GothamBold, 11, THEME.Purple)

-- Slider customizado moderno
local sliderTrack = Instance.new("Frame")
sliderTrack.Size = UDim2.new(1, -95, 0, 6)
sliderTrack.Position = UDim2.fromOffset(10, 34)
sliderTrack.BackgroundColor3 = THEME.Bg
sliderTrack.BorderSizePixel = 0
sliderTrack.Parent = cardEquipPanel
addCorner(sliderTrack, 3)

local sliderFill = Instance.new("Frame")
sliderFill.Size = UDim2.new(1, 0, 1, 0)
sliderFill.BackgroundColor3 = THEME.Purple
sliderFill.BorderSizePixel = 0
sliderFill.Parent = sliderTrack
addCorner(sliderFill, 3)

local sliderThumb = Instance.new("Frame")
sliderThumb.Size = UDim2.fromOffset(14, 14)
sliderThumb.AnchorPoint = Vector2.new(0.5, 0.5)
sliderThumb.Position = UDim2.new(1, 0, 0.5, 0)
sliderThumb.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
sliderThumb.BorderSizePixel = 0
sliderThumb.Parent = sliderTrack
addCorner(sliderThumb, 7)
addStroke(sliderThumb, THEME.Pink, 0.2, 1.5)

-- Botão Equipar ao lado do slider
local equipBtn = Instance.new("TextButton")
equipBtn.Size = UDim2.fromOffset(75, 34)
equipBtn.Position = UDim2.new(1, -85, 0, 9)
equipBtn.BackgroundColor3 = THEME.Purple
equipBtn.BorderSizePixel = 0
equipBtn.AutoButtonColor = false
equipBtn.Font = Enum.Font.GothamBold
equipBtn.Text = "Equipar"
equipBtn.TextSize = 10
equipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
equipBtn.Parent = cardEquipPanel
addCorner(equipBtn, 8)
addStroke(equipBtn, THEME.Pink, 0.3)

connect(equipBtn.MouseEnter, function() equipBtn.BackgroundColor3 = THEME.Pink end)
connect(equipBtn.MouseLeave, function() equipBtn.BackgroundColor3 = THEME.Purple end)
connect(equipBtn.Activated, function()
    equipCards(State.TargetCardCount)
end)

-- Lógica do Slider Drag
local sliderDragging = false
local function updateSliderFromInput(inputPos)
    local absolutePos = sliderTrack.AbsolutePosition.X
    local absoluteSize = sliderTrack.AbsoluteSize.X
    if absoluteSize <= 0 then return end
    local relX = math.clamp((inputPos - absolutePos) / absoluteSize, 0, 1)
    local val = math.clamp(math.floor(relX * (MAX_CARDS - 1) + 0.5) + 1, 1, MAX_CARDS)
    
    State.TargetCardCount = val
    sliderValueLabel.Text = tostring(val)
    sliderFill.Size = UDim2.new((val - 1) / (MAX_CARDS - 1), 0, 1, 0)
    sliderThumb.Position = UDim2.new((val - 1) / (MAX_CARDS - 1), 0, 0.5, 0)
end

connect(sliderTrack.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        sliderDragging = true
        updateSliderFromInput(input.Position.X)
    end
end)
connect(UserInputService.InputChanged, function(input)
    if sliderDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        updateSliderFromInput(input.Position.X)
    end
end)
connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        sliderDragging = false
    end
end)

-- Progresso
makeLabel(content, "PROGRESSO DE MARCACAO", UDim2.new(1, 0, 0, 12), UDim2.fromOffset(2, 226), Enum.Font.GothamBold, 8, THEME.TextDim)
local progressBar = Instance.new("Frame")
progressBar.Size = UDim2.new(1, 0, 0, 7)
progressBar.Position = UDim2.fromOffset(0, 241)
progressBar.BackgroundColor3 = THEME.Surface
progressBar.BorderSizePixel = 0
progressBar.Parent = content
addCorner(progressBar, 4)

local progressFill = Instance.new("Frame")
progressFill.Size = UDim2.new(0, 0, 1, 0)
progressFill.BackgroundColor3 = THEME.Purple
progressFill.BorderSizePixel = 0
progressFill.Parent = progressBar
addCorner(progressFill, 4)

local fillGradient = Instance.new("UIGradient")
fillGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, THEME.Purple),
    ColorSequenceKeypoint.new(0.5, THEME.Pink),
    ColorSequenceKeypoint.new(1, THEME.Cyan),
})
fillGradient.Parent = progressFill

local progressText = makeLabel(content, "0 marcacoes enviadas", UDim2.new(1, 0, 0, 12), UDim2.fromOffset(2, 252), Enum.Font.Gotham, 9, THEME.TextDim)

-- Toggles (Pilulas)
local function makePill(y, labelText, initialOn, onChange)
    local pill = Instance.new("TextButton")
    pill.Size = UDim2.new(1, 0, 0, 40)
    pill.Position = UDim2.fromOffset(0, y)
    pill.BackgroundColor3 = THEME.Surface
    pill.BorderSizePixel = 0
    pill.AutoButtonColor = false
    pill.Text = ""
    pill.Parent = content
    addCorner(pill, 12)
    local pillStroke = addStroke(pill, THEME.Border, 0.5)

    local dot = Instance.new("Frame")
    dot.Size = UDim2.fromOffset(14, 14)
    dot.Position = UDim2.fromOffset(14, 13)
    dot.BackgroundColor3 = THEME.Surface3
    dot.BorderSizePixel = 0
    dot.Parent = pill
    addCorner(dot, 7)
    local dotStroke = addStroke(dot, THEME.Border, 0.3, 1.5)

    makeLabel(pill, labelText, UDim2.new(1, -110, 1, 0), UDim2.fromOffset(38, 0), Enum.Font.GothamMedium, 11, THEME.Text)
    local statusLbl = makeLabel(pill, "OFF", UDim2.new(0, 60, 1, 0), UDim2.new(1, -70, 0, 0), Enum.Font.GothamBold, 9, THEME.TextDim)
    statusLbl.TextXAlignment = Enum.TextXAlignment.Right

    local function refresh(on)
        if on then
            dot.BackgroundColor3 = THEME.Green; dotStroke.Color = THEME.Green; dotStroke.Transparency = 0.4
            statusLbl.Text = "ON"; statusLbl.TextColor3 = THEME.Green
            pill.BackgroundColor3 = Color3.fromRGB(22, 40, 32); pillStroke.Color = Color3.fromRGB(52, 120, 80); pillStroke.Transparency = 0.3
        else
            dot.BackgroundColor3 = THEME.Surface3; dotStroke.Color = THEME.Border; dotStroke.Transparency = 0.3
            statusLbl.Text = "OFF"; statusLbl.TextColor3 = THEME.TextDim
            pill.BackgroundColor3 = THEME.Surface; pillStroke.Color = THEME.Border; pillStroke.Transparency = 0.5
        end
    end
    refresh(initialOn)

    connect(pill.MouseEnter, function() if pill.BackgroundColor3 == THEME.Surface then pill.BackgroundColor3 = THEME.Surface2 end end)
    connect(pill.MouseLeave, function() if pill.BackgroundColor3 == THEME.Surface2 then pill.BackgroundColor3 = THEME.Surface end end)
    connect(pill.Activated, function()
        local novo = not initialOn
        initialOn = novo
        refresh(novo)
        if onChange then onChange(novo) end
    end)
    return pill, refresh
end

makePill(274, "MARCACAO AUTOMATICA", State.AutoDaub, function(on)
    State.AutoDaub = on
    if on then task.spawn(function() if State.Running then scanCards(); syncVisibleBalls(true) end end) end
    log(on and "Marcacao ativada" or "Marcacao desativada")
end)

makePill(320, "BINGO AUTOMATICO", State.AutoClaim, function(on)
    State.AutoClaim = on
    if on then task.defer(function() if State.Running then scanCards(); tryAutoClaim("reenabled") end end) end
    log(on and "Bingo automatico ativado" or "Bingo automatico desativado")
end)

-- Botoes Acao
local function makeActionButton(x, w, text, callback, accent)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(w, 32)
    btn.Position = UDim2.fromOffset(x, 370)
    btn.BackgroundColor3 = THEME.Surface2
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Font = Enum.Font.GothamBold
    btn.Text = text
    btn.TextSize = 10
    btn.TextColor3 = THEME.Text
    btn.Parent = content
    addCorner(btn, 10)
    addStroke(btn, accent or THEME.Border, 0.4)
    connect(btn.MouseEnter, function() btn.BackgroundColor3 = THEME.Surface3 end)
    connect(btn.MouseLeave, function() btn.BackgroundColor3 = THEME.Surface2 end)
    connect(btn.Activated, function() if callback then callback() end end)
    return btn
end

makeActionButton(0, 154, "Marcar Tudo", function()
    task.spawn(function()
        log("Iniciando varredura forçada: marcando TUDO...")
        scanCards()
        
        local totalMarcadas = 0
        
        -- Percorre todas as cartelas ativas (de 1 até MAX_CARDS)
        for index = 1, MAX_CARDS do
            local cardData = State.Cards[index]
            if cardData and cardData.Grid then
                -- Percorre todas as linhas e colunas da grade (padrão 5x5)
                for col = 1, GRID do
                    for row = 1, GRID do
                        -- Ignora o espaço livre central (Free)
                        if not isFreeCoordinate(col, row) then
                            local cell = getCell(cardData, col, row)
                            if cell and cell:IsA("GuiButton") then
                                -- Verifica se já está marcado visualmente
                                if not stampLooksMarked(cell) then
                                    local ok = pcall(function()
                                        if type(firesignal) == "function" then
                                            firesignal(cell.Activated)
                                        else
                                            cell:Activate()
                                        end
                                    end)
                                    
                                    if ok then
                                        totalMarcadas += 1
                                        -- Pequeno respiro em milissegundos para o jogo registrar sem crashar/travar
                                        task.wait(0.015)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        
        log(string.format("Varredura concluída: %d células clicadas!", totalMarcadas))
        -- Tenta checar o bingo logo após forçar tudo
        tryAutoClaim("force-mark-all")
    end)
end, THEME.Purple)

-- Log
local logPanel = Instance.new("Frame")
logPanel.Size = UDim2.new(1, 0, 0, 150)
logPanel.Position = UDim2.fromOffset(0, 412)
logPanel.BackgroundColor3 = THEME.Surface
logPanel.BorderSizePixel = 0
logPanel.Parent = content
addCorner(logPanel, 12)
addStroke(logPanel, THEME.Border, 0.5)

makeLabel(logPanel, "REGISTRO", UDim2.new(0, 120, 0, 16), UDim2.fromOffset(12, 8), Enum.Font.GothamBold, 9, THEME.TextDim)

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.fromOffset(46, 18)
clearBtn.Position = UDim2.new(1, -58, 0, 7)
clearBtn.BackgroundColor3 = THEME.Surface2
clearBtn.BorderSizePixel = 0
clearBtn.AutoButtonColor = false
clearBtn.Font = Enum.Font.GothamMedium
clearBtn.Text = "limpar"
clearBtn.TextSize = 8
clearBtn.TextColor3 = THEME.TextDim
clearBtn.Parent = logPanel
addCorner(clearBtn, 6)
addStroke(clearBtn, THEME.Border, 0.5)
connect(clearBtn.Activated, function() table.clear(State.Logs) end)

local logBox = Instance.new("TextLabel")
logBox.Size = UDim2.new(1, -20, 0, 116)
logBox.Position = UDim2.fromOffset(10, 28)
logBox.BackgroundColor3 = THEME.Bg
logBox.BorderSizePixel = 0
logBox.Font = Enum.Font.Code
logBox.Text = ""
logBox.TextSize = 9
logBox.TextColor3 = Color3.fromRGB(190, 180, 230)
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.TextWrapped = true
logBox.ClipsDescendants = true
logBox.Parent = logPanel
addCorner(logBox, 8)
local padLog = Instance.new("UIPadding")
padLog.PaddingLeft = UDim.new(0, 8)
padLog.PaddingTop = UDim.new(0, 6)
padLog.PaddingRight = UDim.new(0, 8)
padLog.Parent = logBox

-- ============================================================
-- ARRASTAR E RESPONSIVIDADE
-- ============================================================
local function getViewport() return Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720) end

local function calcScale()
    local vp = getViewport()
    if not isTouch then return 1 end
    local portrait = vp.Y >= vp.X
    local wS = (vp.X - (portrait and 20 or 24)) / BASE_W
    local hS = (vp.Y - (portrait and 140 or 60)) / BASE_H
    local s = math.min(wS, hS)
    return math.clamp(s, portrait and 0.6 or 0.48, portrait and 0.78 or 0.66)
end

local function clampPos()
    local vp = getViewport()
    local s = mainScale.Scale
    local m = isTouch and 8 or 4
    local x = math.clamp(main.Position.X.Offset, m, math.max(m, vp.X - (BASE_W * s) - m))
    local y = math.clamp(main.Position.Y.Offset, m, math.max(m, vp.Y - ((minimized and HEADER_H or BASE_H) * s) - m))
    main.Position = UDim2.fromOffset(x, y)
    glow.Position = UDim2.fromOffset(x - 8, y - 8)
end

local function applyLayout(keepPos)
    local s = calcScale()
    local lH = minimized and HEADER_H or BASE_H
    mainScale.Scale = s
    main.Size = UDim2.fromOffset(BASE_W, lH)
    if keepPos then clampPos(); return end
    local x = isTouch and 8 or 24
    local y = math.max(8, (getViewport().Y - (lH * s)) * 0.5)
    if isTouch and getViewport().X > getViewport().Y then y = 8 end
    main.Position = UDim2.fromOffset(x, y)
    glow.Position = UDim2.fromOffset(x - 8, y - 8)
end

applyLayout(false)
local vpConn
local function bindVP()
    if vpConn then pcall(function() vpConn:Disconnect() end); vpConn = nil end
    if Workspace.CurrentCamera then
        vpConn = connect(Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), function() applyLayout(true) end)
    end
end
bindVP()
connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function() bindVP(); applyLayout(true) end)

local dragging, dragStart, startPos, activeTouch
connect(header.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = main.Position
        if input.UserInputType == Enum.UserInputType.Touch then activeTouch = input end
    end
end)
connect(UserInputService.InputChanged, function(input)
    if not dragging then return end
    local isM = input.UserInputType == Enum.UserInputType.MouseMovement
    local isT = input.UserInputType == Enum.UserInputType.Touch and (activeTouch == nil or input == activeTouch)
    if not isM and not isT then return end
    local d = input.Position - dragStart
    local np = UDim2.fromOffset(startPos.X.Offset + d.X, startPos.Y.Offset + d.Y)
    main.Position = np
    glow.Position = UDim2.fromOffset(np.X.Offset - 8, np.Y.Offset - 8)
    clampPos()
end)
connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or (input.UserInputType == Enum.UserInputType.Touch and (activeTouch == nil or input == activeTouch)) then
        dragging = false; activeTouch = nil; clampPos()
    end
end)

connect(minimize.Activated, function()
    minimized = not minimized
    content.Visible = not minimized
    main.BackgroundTransparency = minimized and 1 or 0
    glow.Visible = not minimized
    
    for _, child in ipairs(main:GetChildren()) do
        if child:IsA("UIStroke") then
            child.Transparency = minimized and 1 or 0.15
        end
    end

    minimize.Text = minimized and "+" or "-"
    applyLayout(true)
end)

-- ============================================================
-- ATUALIZAÇÃO DA UI E EVENTOS
-- ============================================================
local function updateUi()
    if not State.Running or not ui.Parent then return end
    local phase = Workspace:GetAttribute("BingoPhase")
    local stage = Workspace:GetAttribute("BingoStage")
    local pattern = currentPattern()
    local phaseText = tostring(phase or "IDLE"):upper()
    
    phaseBadge.Text = phaseText
    if phaseText == "PLAYING" then
        statusText.Text = "JOGANDO"; statusText.TextColor3 = THEME.Green; statusDot.BackgroundColor3 = THEME.Green
        phaseBadge.BackgroundColor3 = Color3.fromRGB(28, 71, 51); phaseBadge.TextColor3 = THEME.Green
    elseif phaseText == "INTERMISSION" or phaseText == "WAITING" then
        statusText.Text = "AGUARDANDO"; statusText.TextColor3 = THEME.Yellow; statusDot.BackgroundColor3 = THEME.Yellow
        phaseBadge.BackgroundColor3 = Color3.fromRGB(71, 57, 29); phaseBadge.TextColor3 = THEME.Yellow
    else
        statusText.Text = phaseText; statusText.TextColor3 = THEME.TextDim; statusDot.BackgroundColor3 = THEME.TextDim
        phaseBadge.BackgroundColor3 = Color3.fromRGB(20, 15, 40); phaseBadge.TextColor3 = Color3.fromRGB(255,255,255)
    end

    chipPadrao.Text = tostring(pattern or "-")
    chipCartelas.Text = string.format("%d / %d", countDictionary(State.Cards), MAX_CARDS)
    chipUltimo.Text = State.LastCalledNumber and tostring(State.LastCalledNumber) or "-"
    chipMarcadas.Text = string.format("%d", State.Stats.DaubsConfirmed)
    chipClaims.Text = tostring(State.Stats.ClaimsTriggered)
    chipFase.Text = string.format("S%s", tostring(stage or "-"))
    
    winsNumber.Text = tostring(State.Stats.ClaimsTriggered)
    ballsLabel.Text = countDictionary(State.CalledNumbers) .. " bolas vistas"

    local maxPossivel = math.max(State.Stats.DaubsSent, 1)
    local progresso = math.clamp(State.Stats.DaubsConfirmed / maxPossivel, 0, 1)
    if State.Stats.DaubsSent == 0 then progresso = 0 end
    progressFill.Size = UDim2.new(progresso, 0, 1, 0)
    progressText.Text = string.format("%d de %d envios confirmados", State.Stats.DaubsConfirmed, State.Stats.DaubsSent)

    local lines = {}
    for i = 1, math.min(#State.Logs, SETTINGS.MaxLogLines) do table.insert(lines, State.Logs[i]) end
    logBox.Text = table.concat(lines, "\n")
end

local function extractNumber(...)
    local pack = table.pack(...)
    for i = 1, pack.n do
        local arg = pack[i]
        local n = normalizeNumber(arg)
        if n then return n end
        if type(arg) == "table" then
            for _, key in ipairs({"number", "Number", "calledNumber", "ball", "value"}) do
                if normalizeNumber(arg[key]) then return normalizeNumber(arg[key]) end
            end
        end
    end
    return nil
end

connect(NumberCalled.OnClientEvent, function(...)
    local number = extractNumber(...)
    if not number then return end
    local first = State.CalledNumbers[number] ~= true
    State.CalledNumbers[number] = true
    State.LastCalledNumber = number
    if first then State.Stats.ReceivedCalls += 1 end

    task.delay(SETTINGS.AutoDaubDelay, function()
        if not State.Running or not State.AutoDaub then return end
        scanCards()
        local marked = markNumberNative(number)
        if first and marked > 0 then
            local _, let = numberColumn(number)
            log(string.format("%s%d · %d marcadas", tostring(let or ""), number, marked))
        end
    end)
end)

connect(CardsAssigned.OnClientEvent, function()
    task.defer(function()
        if not State.Running then return end
        table.clear(State.PendingMarks)
        scanCards()
        if State.AutoDaub then task.spawn(function() syncVisibleBalls(true) end) end
    end)
end)

connect(RoundState.OnClientEvent, function(...)
    local pack = table.pack(...)
    for i = 1, pack.n do
        local payload = pack[i]
        if type(payload) == "table" and payload.pattern and tostring(payload.pattern) ~= "" then
            State.ActivePattern = tostring(payload.pattern)
            break
        end
    end
    task.defer(function() if State.Running then scanCards(); tryAutoClaim("round-state") end end)
end)

connect(Workspace:GetAttributeChangedSignal("BingoCalledCount"), function()
    local newCount = tonumber(Workspace:GetAttribute("BingoCalledCount")) or 0
    if newCount < State.LastCalledCount then clearRoundState("reset") end
    State.LastCalledCount = newCount
end)

connect(Workspace:GetAttributeChangedSignal("BingoPhase"), function()
    local phase = Workspace:GetAttribute("BingoPhase")
    State.LastPhase = phase
    local lower = tostring(phase or ""):lower()
    if lower == "intermission" or lower == "waiting" or lower == "starting" then
        clearRoundState("phase")
    elseif lower == "playing" or lower == "claimwindow" then
        task.defer(function() if State.Running then scanCards(); syncVisibleBalls(true); tryAutoClaim("phase") end end)
    end
end)

task.spawn(function()
    while State.Running do
        pcall(scanCards)
        pcall(tryAutoClaim, "maintenance")
        pcall(updateUi)
        task.wait(SETTINGS.RescanInterval)
    end
end)

function State:Destroy()
    if not self.Running then return end
    self.Running = false
    table.clear(self.PendingMarks)
    for i = 1, #self.Connections do pcall(function() self.Connections[i]:Disconnect() end) end
    table.clear(self.Connections)
    if self.Gui then pcall(function() self.Gui:Destroy() end); self.Gui = nil end
    if ENV.KikoMenu == self then ENV.KikoMenu = nil end
    print("[Kiko Bingo] Menu fechado e script descarregado.")
end

connect(closeBtn.Activated, function() State:Destroy() end)

scanCards()
log("Auto Bingo carregado na UI Kiko")
updateUi()

task.spawn(function()
    if State.Running then
        scanCards()
        syncVisibleBalls(true)
    end
end)
