-- ==========================================
-- SCRIPT VERSION 2.8 (Ohne Notstopp, mit Blitz-Recovery)
-- ==========================================
local SCRIPT_VERSION = "v2.8"

local reactor = nil
local monitor = nil

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN (HIER ANPASSBAR)
-- ==========================================
local TARGET_EFFICIENCY = 100   -- Ziel-EF-Wert
local IDLE_THRESHOLD = 90.0     -- Sicherer Idle-Punkt bei 90% (verhindert 95%-Crashs)
local COOLDOWN_WAIT = 5.0       -- Wartezeit in Sekunden für den Reaktor-Cooldown
local PULSE_LENGTH = 0.15       -- Dauer des Redstone-Impulses in Sekunden (für Fallback)
local JUMP_THRESHOLD = 5.0      -- Schwellenwert für sprunghafte EF-Änderungen durch TR-Drift
local EFF_TOLERANCE = 0.8       -- Toleranz-Schwelle für normales Rauschen

-- MONITOR LOG EINSTELLUNGEN
local ENABLE_MONITOR_LOGS = true -- true = Logs auf Monitor anzeigen, false = Aus
local monitorWidth, monitorHeight = 39, 25

-- Regelungs-Variablen
local currentSignal = 8         -- Startwert in der Mitte (1-15)
local controlDirection = 1      -- 1 = Links / Erhöhen (+), -1 = Rechts / Senken (-)
local stepSize = 5              -- Start-Suchschrittweite
local lastEfficiency = 0
local maxEfficiencySeen = 0     
local logCounter = 0
local logHistory = {}           -- Speicher für die Monitor-Logs

-- Diagnose-Variable
local stuckReason = "Warte auf Reaktor..."

-- Statistiken für Min/Max
local stats = {
    minEff = math.huge, maxEff = -math.huge,
    minErr = math.huge, maxErr = -math.huge,
    minCase = math.huge, maxCase = 0
}

print("==========================================")
print(" FUSION REACTOR CONTROLLER " .. SCRIPT_VERSION)
print("==========================================")

-- 1. Peripherie automatisch erkennen
local function scanPeripherals()
    reactor = nil
    monitor = nil
    
    print("--- Suche Peripherie ---")
    for _, name in ipairs(peripheral.getNames()) do
        local pType = peripheral.getType(name)
        local lName = name:lower()
        
        if pType == "fusionReactor" or lName:find("logicadapter") then
            reactor = peripheral.wrap(name)
            print(" -> Reaktor Logic Adapter gefunden: " .. name)
        elseif pType == "monitor" or lName:find("monitor") then
            local m = peripheral.wrap(name)
            if m and m.isColor and m.isColor() then
                monitor = m
                monitorWidth, monitorHeight = m.getSize()
                m.setTextScale(0.5)
                print(" -> Farb-Monitor gefunden: " .. name .. " (" .. monitorWidth .. "x" .. monitorHeight .. ")")
            end
        end
    end
    print("------------------------")
end

scanPeripherals()

if not reactor then
    print("[DIAGNOSE FEHLER] Kein Fusion Reactor Logic Adapter gefunden!")
    return
end

if monitor then
    monitor.setTextScale(0.5)
    monitor.clear()
end

-- 2. Daten sicher abfragen
local function getReactorData()
    if not reactor then return "STANDBY", 0, 0, 0, false end
    
    local logicMode = "STANDBY"
    local caseTemp = 0
    local efficiency = 0
    local errorLevel = 0
    
    pcall(function()
        logicMode = reactor.getLogicMode()
        caseTemp = reactor.getCaseTemperature()
        efficiency = reactor.getEfficiency()
        errorLevel = reactor.getErrorLevel()
    end)
    
    local isRunning = (logicMode == "ACTIVE" or logicMode == "RUNNING" or logicMode == "READY")
    pcall(function() if reactor.getStatus then isRunning = reactor.getStatus() end end)
    
    return logicMode, caseTemp, efficiency, errorLevel, isRunning
end

-- 3. Statistiken aktualisieren
local function updateStats(eff, err, caseT)
    if eff > 0 then
        if eff < stats.minEff then stats.minEff = eff end
        if eff > stats.maxEff then stats.maxEff = eff end
    end
    if err < stats.minErr then stats.minErr = err end
    if err > stats.maxErr then stats.maxErr = err end
    if caseT < stats.minCase then stats.minCase = caseT end
    if caseT > stats.maxCase then stats.maxCase = caseT end
end

-- 4. Redstone-Impuls senden (Fallback)
local function sendPulse(side, strength)
    if strength < 1 then strength = 1 end
    if strength > 15 then strength = 15 end
    
    pcall(function()
        redstone.setAnalogOutput(side, strength)
    end)
    sleep(PULSE_LENGTH)
    pcall(function()
        redstone.setAnalogOutput(side, 0)
    end)
end

-- Steuerungs-Funktion
local function applyControlAction(direction, strength)
    if strength > 15 then strength = 15 end
    local success = false
    
    if reactor and type(reactor.adjustReactivity) == "function" then
        pcall(function()
            reactor.adjustReactivity(direction * strength)
            success = true
        end)
    end
    
    if not success then
        local sideName = (direction == 1) and "left" or "right"
        sendPulse(sideName, strength)
    end
end

redstone.setAnalogOutput("left", 0)
redstone.setAnalogOutput("right", 0)

-- 5. Intelligente Formel mit dynamischer Skalierung
local function calculateStepFromTable(currentEff, targetEff)
    if currentEff >= 85.0 then
        return 1
    end

    local effDiff = targetEff - currentEff
    local calculatedStep = math.floor(math.abs(effDiff) * 0.18) + 1
    
    if calculatedStep > 15 then
        calculatedStep = 15
    elseif calculatedStep < 1 then
        calculatedStep = 1
    end
    
    return calculatedStep
end

-- 6. Regelungsschleife mit BLITZ-RECOVERY (ohne erzwungenen Notstopp)
local function runControlLoop()
    logCounter = logCounter + 1
    local _, caseTemp, efficiency, errorLevel = getReactorData()

    if efficiency > maxEfficiencySeen then
        maxEfficiencySeen = efficiency
    end

    local statusText = "STANDBY"
    if efficiency > 0 then
        statusText = "RUN"
    elseif maxEfficiencySeen > 0 and efficiency == 0 then
        statusText = "CRUSH"
    else
        statusText = "STANDBY"
    end

    if statusText == "STANDBY" or statusText == "CRUSH" then
        pcall(function()
            redstone.setAnalogOutput("left", 0)
            redstone.setAnalogOutput("right", 0)
        end)
        lastEfficiency = 0 
        stuckReason = "Reaktor " .. statusText
        sleep(1.0)
        return
    end

    if efficiency >= IDLE_THRESHOLD then
        pcall(function()
            redstone.setAnalogOutput("left", 0)
            redstone.setAnalogOutput("right", 0)
        end)
        lastEfficiency = efficiency
        stuckReason = string.format("Ziel erreicht (>=%.1f%%)", IDLE_THRESHOLD)
        sleep(1.0)
        return
    end

    local startEffForLog = efficiency

    applyControlAction(controlDirection, stepSize)

    currentSignal = currentSignal + (controlDirection * stepSize)
    if currentSignal > 15 then 
        currentSignal = 15 
        controlDirection = -1 
    elseif currentSignal < 1 then 
        currentSignal = 1 
        controlDirection = 1 
    end

    stuckReason = string.format("Cooldown (%.1fs)...", COOLDOWN_WAIT)
    sleep(COOLDOWN_WAIT)

    local _, _, newEfficiency = getReactorData()

    if lastEfficiency > 0 then
        local effDelta = newEfficiency - lastEfficiency
        local isSpontaneousJump = math.abs(effDelta) > JUMP_THRESHOLD

        if isSpontaneousJump then
            if effDelta < 0 then
                -- EINBRUCH durch TR-Drift! -> BLITZ-RECOVERY EINLEITEN!
                controlDirection = 1   
                stepSize = 14          
                stuckReason = "TR-Drift Einbruch! BLITZ-REC (+14)"
            else
                stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                stuckReason = string.format("Sprung+, Ziel nah (Step %d)", stepSize)
            end
        else
            if newEfficiency < (lastEfficiency - EFF_TOLERANCE) then
                controlDirection = -controlDirection
                stepSize = math.max(3, calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY))
                stuckReason = "Sinkt (>Tol) -> Aggressiver Wechsel"
            elseif newEfficiency >= lastEfficiency then
                stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                stuckReason = string.format("Stabil/Besser -> Step %d", stepSize)
            else
                stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                stuckReason = string.format("Im Toleranzbereich -> Halte")
            end
        end
    else
        stepSize = 3
        stuckReason = "Initialisierung"
    end

    lastEfficiency = newEfficiency

    -- Log-Eintrag hinzufügen
    local signChar = (controlDirection == 1) and "+" or "-"
    local shortDiag = string.sub(stuckReason, 1, 18)
    local compactLog = string.format("#%03d|%s%d|EF:%.1f->%.1f|%s", logCounter, signChar, stepSize, startEffForLog, newEfficiency, shortDiag)
    table.insert(logHistory, 1, compactLog)
    
    local maxLogLines = math.max(5, monitorHeight - 9)
    if #logHistory > maxLogLines then
        table.remove(logHistory)
    end
end

-- 7. Monitor im Ultrakompakt-Layout zeichnen
local function drawUI()
    if not monitor then return end

    local logicMode, caseTemp, efficiency, errorLevel = getReactorData()
    updateStats(efficiency, errorLevel, caseTemp)

    local statusText = "STANDBY"
    if efficiency > 0 then
        statusText = "RUN"
    elseif maxEfficiencySeen > 0 and efficiency == 0 then
        statusText = "CRUSH"
    else
        statusText = "STANDBY"
    end

    monitor.setBackgroundColor(colors.black)
    
    -- Zeile 1: Titelleiste
    monitor.setCursorPos(1, 1)
    monitor.setBackgroundColor(colors.blue)
    monitor.setTextColor(colors.white)
    monitor.write(string.format("=== FUSION CONTROL %s ===", SCRIPT_VERSION))
    monitor.setBackgroundColor(colors.black)

    -- Zeile 2: Status & EF
    monitor.setCursorPos(1, 2)
    monitor.clearLine()
    monitor.write("Modus: ")
    if efficiency >= IDLE_THRESHOLD then
        monitor.setTextColor(colors.cyan)
        monitor.write("IDLE ")
    elseif statusText == "RUN" then
        monitor.setTextColor(colors.green)
        monitor.write("RUN  ")
    elseif statusText == "CRUSH" then
        monitor.setTextColor(colors.red)
        monitor.write("CRUSH")
    else
        monitor.setTextColor(colors.orange)
        monitor.write("STAND")
    end
    monitor.setTextColor(colors.white)
    monitor.write(string.format(" | EF: %.1f%% (Z:%d)", efficiency, TARGET_EFFICIENCY))

    -- Zeile 3: Case Temperatur & Error Level
    monitor.setCursorPos(1, 3)
    monitor.clearLine()
    monitor.write(string.format("Case: %.1fM K", caseTemp / 1000000))
    monitor.write(" | ER: ")
    if errorLevel > 50 then monitor.setTextColor(colors.red) end
    monitor.write(string.format("%.1f%%", errorLevel))
    monitor.setTextColor(colors.white)

    -- Zeile 4: Regelung & Signal
    monitor.setCursorPos(1, 4)
    monitor.clearLine()
    local signText = (controlDirection == 1) and "+" or "-"
    local sideText = (reactor and type(reactor.adjustReactivity) == "function") and "API" or ((controlDirection == 1) and "L" or "R")
    monitor.write(string.format("Regel: %s%d | Sig: %-2d (%s)", signText, stepSize, currentSignal, sideText))

    -- Zeile 5: Diagnose
    monitor.setCursorPos(1, 5)
    monitor.clearLine()
    monitor.setTextColor(colors.cyan)
    monitor.write("Diag: " .. string.sub(stuckReason, 1, 28))
    monitor.setTextColor(colors.white)

    -- Zeile 7+: MONITOR-LOGS
    if ENABLE_MONITOR_LOGS then
        monitor.setCursorPos(1, 7)
        monitor.setTextColor(colors.lightGray)
        monitor.write("--- ZYKLEN-LOGS ---")

        local maxLogLines = math.max(5, monitorHeight - 8)
        for i = 1, maxLogLines do
            monitor.setCursorPos(1, 7 + i)
            monitor.clearLine()
            if logHistory[i] then
                monitor.write(logHistory[i])
            end
        end
    end
end

-- 8. Hauptschleife
while true do
    runControlLoop()
    drawUI()
end
