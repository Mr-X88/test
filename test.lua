-- Better Fusion Reactor Controller for CC:Tweaked
-- Optimized monitor refresh + adaptive efficiency hill-climbing
-- Native adjustReactivity() is used when available; otherwise left/right redstone pulses.

local reactor = nil
local monitor = nil
local running = true

-- Tuning
local CFG = {
    monitorInterval = 0.25,     -- monitor refresh: 4 times per second
    pulseLength = 0.15,         -- pulse length when redstone fallback is used
    cooldown = 5.0,             -- total wait after an adjustment
    sampleCount = 5,            -- average five samples at the end of the cooldown
    sampleInterval = 0.20,
    initialStep = 2,
    minStep = 1,
    maxStep = 8,                -- capped so adjustments do not jump too far
    efficiencyDeadband = 0.20,  -- ignore very small changes/noise
    leftSide = "left",          -- positive reactivity adjustment
    rightSide = "right",        -- negative reactivity adjustment
    maxErrorLevel = 100,
    textScale = 0.5,
}

local stepSize = CFG.initialStep
local controlDirection = 1      -- +1 increases reactivity, -1 decreases it
local lastAdjustment = 0
local lastEfficiency = nil
local maxEfficiencySeen = 0
local improvementStreak = 0
local stuckReason = "Warte auf Reaktor..."
local lastData = {
    logicMode = "STANDBY",
    caseTemp = 0,
    efficiency = 0,
    errorLevel = 0,
    isRunning = false,
}

local stats = {
    minEff = math.huge, maxEff = 0,
    minErr = math.huge, maxErr = 0,
    minCase = math.huge, maxCase = 0,
}

-- Detect the reactor and monitor.
local function scanPeripherals()
    print("--- Suche Peripherie ---")
    for _, name in ipairs(peripheral.getNames()) do
        local pType = peripheral.getType(name)
        local lName = name:lower()

        if pType == "fusionReactor" or lName:find("logicadapter", 1, true) then
            reactor = peripheral.wrap(name)
            print(" -> Reaktor Logic Adapter: " .. name)
        elseif pType == "monitor" or lName:find("monitor", 1, true) then
            local m = peripheral.wrap(name)
            if m and type(m.isColor) == "function" then
                local ok, isColor = pcall(m.isColor)
                if ok and isColor then
                    monitor = m
                    print(" -> Farb-Monitor: " .. name)
                end
            elseif m then
                monitor = m
                print(" -> Monitor: " .. name)
            end
        end
    end
    print("------------------------")
end

scanPeripherals()

if not reactor then
    print("[FEHLER] Kein Fusion Reactor Logic Adapter gefunden!")
    return
end

local directApiAvailable = type(reactor.adjustReactivity) == "function"
local controlMethod = directApiAvailable and "API" or "Redstone"

local monitorWidth = 80
if monitor then
    pcall(monitor.setTextScale, CFG.textScale)
    pcall(monitor.clear)
    local ok, width = pcall(function()
        local w = monitor.getSize()
        return w
    end)
    if ok and type(width) == "number" then monitorWidth = width end
end

local function safeCall(methodName, fallback)
    if not reactor then return fallback end
    local method = reactor[methodName]
    if type(method) ~= "function" then return fallback end
    local ok, value = pcall(method)
    if ok and value ~= nil then return value end
    return fallback
end

local function finiteNumber(value, fallback)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return fallback
    end
    return value
end

local function getReactorData()
    local logicMode = safeCall("getLogicMode", "UNKNOWN")
    local caseTemp = finiteNumber(safeCall("getCaseTemperature", 0), 0)
    local efficiency = finiteNumber(safeCall("getEfficiency", 0), 0)
    local errorLevel = finiteNumber(safeCall("getErrorLevel", 0), 0)
    local status = safeCall("getStatus", nil)
    local isRunning = (logicMode == "ACTIVE" or logicMode == "RUNNING" or logicMode == "READY")
    if type(status) == "boolean" then isRunning = status end

    lastData = {
        logicMode = tostring(logicMode),
        caseTemp = caseTemp,
        efficiency = efficiency,
        errorLevel = errorLevel,
        isRunning = isRunning,
    }
    return logicMode, caseTemp, efficiency, errorLevel, isRunning
end

local function clearOutputs()
    pcall(redstone.setAnalogOutput, CFG.leftSide, 0)
    pcall(redstone.setAnalogOutput, CFG.rightSide, 0)
end

local function stopForSafety()
    stuckReason = "NOTSTOPP: Fehlerlevel >= " .. CFG.maxErrorLevel
    pcall(function()
        if type(reactor.stop) == "function" then reactor.stop() end
    end)
    clearOutputs()
    running = false
end

local function safetyCheck()
    local errorLevel = finiteNumber(safeCall("getErrorLevel", 0), 0)
    if errorLevel >= CFG.maxErrorLevel then
        stopForSafety()
        return false
    end
    return running
end

local function updateStats(eff, err, caseTemp)
    if eff > 0 then
        stats.minEff = math.min(stats.minEff, eff)
        stats.maxEff = math.max(stats.maxEff, eff)
        maxEfficiencySeen = math.max(maxEfficiencySeen, eff)
    end
    stats.minErr = math.min(stats.minErr, err)
    stats.maxErr = math.max(stats.maxErr, err)
    stats.minCase = math.min(stats.minCase, caseTemp)
    stats.maxCase = math.max(stats.maxCase, caseTemp)
end

-- Native API: apply a signed reactivity adjustment directly.
-- Fallback: send a short pulse on the configured left/right redstone output.
local function applyAdjustment(amount)
    if directApiAvailable then
        local ok = pcall(reactor.adjustReactivity, amount)
        if ok then
            lastAdjustment = amount
            stuckReason = "API-Korrektur " .. (amount > 0 and "+" or "") .. amount
            return true
        end
        -- If the API call fails, automatically fall back to redstone.
        directApiAvailable = false
        controlMethod = "Redstone"
        stuckReason = "API fehlgeschlagen; Redstone-Fallback"
    end

    local side = amount > 0 and CFG.leftSide or CFG.rightSide
    local strength = math.max(1, math.min(15, math.abs(amount)))
    local ok = pcall(redstone.setAnalogOutput, side, strength)
    if not ok then
        stuckReason = "Redstone-Ausgabe fehlgeschlagen"
        return false
    end
    sleep(CFG.pulseLength)
    pcall(redstone.setAnalogOutput, side, 0)
    lastAdjustment = amount
    stuckReason = "Redstone-Impuls " .. (amount > 0 and "+" or "") .. amount
    return true
end

-- Average readings to reduce noise from one-off efficiency changes.
local function sampleEfficiency(count, interval)
    local total = 0
    local samples = 0
    for _ = 1, count do
        sleep(interval)
        if not safetyCheck() then return nil end
        local _, _, eff, err = getReactorData()
        if err >= CFG.maxErrorLevel then
            stopForSafety()
            return nil
        end
        total = total + eff
        samples = samples + 1
    end
    if samples == 0 then return nil end
    return total / samples
end

local function waitCooldown(seconds)
    local elapsed = 0
    while running and elapsed < seconds do
        local pause = math.min(0.25, seconds - elapsed)
        sleep(pause)
        elapsed = elapsed + pause
        if not safetyCheck() then return false end
    end
    return running
end

local function runControlLoop()
    -- Establish a smoothed baseline before the first adjustment.
    lastEfficiency = sampleEfficiency(CFG.sampleCount, CFG.sampleInterval)

    while running do
        if not safetyCheck() then break end
        local _, _, currentEff, currentErr = getReactorData()

        if currentEff <= 0 then
            stuckReason = (maxEfficiencySeen > 0) and "Reaktor inaktiv/abgestuerzt" or "Warte auf aktiven Reaktor"
            clearOutputs()
            lastEfficiency = sampleEfficiency(CFG.sampleCount, CFG.sampleInterval)
            if running then sleep(0.5) end
        else
            -- If the reactor has just become active, take a fresh baseline first.
            if not lastEfficiency or lastEfficiency <= 0 then
                lastEfficiency = sampleEfficiency(CFG.sampleCount, CFG.sampleInterval)
            else
                local adjustment = controlDirection * stepSize
                if not applyAdjustment(adjustment) then
                    running = false
                    break
                end

                -- The monitor keeps updating independently during this wait.
                -- Leave the final second for a five-reading average.
                if not waitCooldown(math.max(0, CFG.cooldown - CFG.sampleCount * CFG.sampleInterval)) then
                    break
                end
                local newEfficiency = sampleEfficiency(CFG.sampleCount, CFG.sampleInterval)
                if not running then break end

                if newEfficiency and newEfficiency > 0 and lastEfficiency and lastEfficiency > 0 then
                    local change = newEfficiency - lastEfficiency

                    if change < -CFG.efficiencyDeadband then
                        -- This move made efficiency worse: reverse and take a smaller step.
                        controlDirection = -controlDirection
                        stepSize = math.max(CFG.minStep, math.floor(stepSize / 2))
                        improvementStreak = 0
                        stuckReason = string.format("Effizienz %.2f: Richtung umgekehrt", change)
                    elseif change > CFG.efficiencyDeadband then
                        -- Improvement: keep going; increase size only after repeated gains.
                        improvementStreak = improvementStreak + 1
                        if improvementStreak >= 2 then
                            stepSize = math.min(CFG.maxStep, stepSize + 1)
                            improvementStreak = 0
                        end
                        stuckReason = string.format("Effizienz +%.2f: Richtung gehalten", change)
                    else
                        -- Near-flat result: avoid flip-flopping on tiny changes.
                        improvementStreak = 0
                        stuckReason = string.format("Nahezu gleich: Delta %.2f", change)
                    end
                else
                    stuckReason = "Messung ungueltig; suche weiter"
                end

                lastEfficiency = newEfficiency or lastEfficiency
            end
        end
    end
end

local function statusTextFor(eff)
    if eff > 0 then return "RUN" end
    if maxEfficiencySeen > 0 then return "CRUSH / INAKTIV" end
    return "STANDBY"
end

local function writeLine(y, text, fg, bg)
    if not monitor then return end
    text = tostring(text)
    if #text > monitorWidth then text = text:sub(1, monitorWidth) end
    pcall(function()
        monitor.setCursorPos(1, y)
        monitor.setBackgroundColor(bg or colors.black)
        monitor.setTextColor(fg or colors.white)
        monitor.clearLine()
        monitor.write(text)
    end)
end

local function drawUI()
    if not monitor then return end
    local _, caseTemp, eff, err = getReactorData()
    updateStats(eff, err, caseTemp)

    local status = statusTextFor(eff)
    local statusColor = colors.orange
    if status == "RUN" then statusColor = colors.green end
    if status ~= "RUN" and maxEfficiencySeen > 0 then statusColor = colors.red end

    writeLine(1, "=== FUSION REACTOR CONTROL ===", colors.white, colors.blue)
    writeLine(3, "Modus: " .. status .. " | API: " .. controlMethod, statusColor)
    writeLine(5, string.format("Case Temp: %.2fM K", caseTemp / 1000000), colors.white)
    writeLine(7, string.format("EF: %.2f%%  Min:%.2f Max:%.2f", eff,
        stats.minEff == math.huge and 0 or stats.minEff, stats.maxEff), colors.yellow)
    writeLine(8, string.format("ER: %.2f  Min:%.2f Max:%.2f", err,
        stats.minErr == math.huge and 0 or stats.minErr, stats.maxErr),
        err > 50 and colors.red or colors.white)
    writeLine(10, "Fuel Type: D-T Fuel", colors.white)
    writeLine(11, string.format("Korrektur: %s%d | Schritt: %d | Seite: %s",
        lastAdjustment > 0 and "+" or "", lastAdjustment, stepSize,
        controlDirection > 0 and "Links/+" or "Rechts/-"), colors.white)
    writeLine(12, string.format("Beste gemessene Effizienz: %.2f%%", maxEfficiencySeen), colors.lime)
    writeLine(14, "Diag: " .. stuckReason, colors.cyan)
    pcall(monitor.setBackgroundColor, colors.black)
    pcall(monitor.setTextColor, colors.lightGray)
end

local function displayLoop()
    while running do
        drawUI()
        sleep(CFG.monitorInterval)
    end
    -- One final refresh with the latest state.
    drawUI()
end

-- Keep monitor refresh independent of the controller's five-second cooldown.
local ok, err = pcall(function()
    parallel.waitForAll(runControlLoop, displayLoop)
end)

clearOutputs()
if monitor then
    pcall(monitor.setBackgroundColor, colors.black)
    pcall(monitor.setTextColor, colors.white)
end
if not ok and tostring(err) ~= "Terminated" then
    print("[CONTROLLER-FEHLER] " .. tostring(err))
end
print("Fusion Reactor Controller beendet.")
