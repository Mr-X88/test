-- ==========================================
-- SCRIPT VERSION 2.3 (Reine Formel-Steuerung)
-- ==========================================
local SCRIPT_VERSION = "v2.3"

local reactor = nil
local monitor = nil

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN (HIER ANPASSBAR)
-- ==========================================
local TARGET_EFFICIENCY = 100   -- Ziel-EF-Wert
local IDLE_THRESHOLD = 95.0     -- EF-Schwelle: Ab hier stoppt die Regelung, bis es wieder sinkt
local COOLDOWN_WAIT = 5.0       -- Wartezeit in Sekunden für den Reaktor-Cooldown
local PULSE_LENGTH = 0.15       -- Dauer des Redstone-Impulses in Sekunden (für Fallback)
local JUMP_THRESHOLD = 8.0      -- Schwellenwert für sprunghafte EF-Änderungen durch TR-Drift

-- MONITOR LOG EINSTELLUNGEN
local ENABLE_MONITOR_LOGS = true -- true = Logs auf Monitor anzeigen, false = Aus
local MAX_LOG_LINES = 10        -- Maximale Anzahl an Log-Zeilen

-- Regelungs-Variablen
local currentSignal = 8         -- Startwert in der Mitte (1-15)
local controlDirection = 1      -- 1 = Links / Erhöhen (+), -1 = Rechts / Senken (-)
local stepSize = 2              -- Start-Suchschrittweite
local lastEfficiency = 0
local maxEfficiencySeen = 0     
local logCounter = 0
local logHistory = {}           -- Speicher für die kompakten Monitor-Logs

-- Diagnose-Variable
local stuckReason = "Warte auf Reaktor..."

-- Statistiken für Min/Max
local stats = {
    minEff = math.huge, maxEff = -math.huge,
    minErr = math.huge, maxErr = -math.huge,
    minCase = math.huge, maxCase = 0
}

-- Start-Informationen im Computer-Terminal ausgeben
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
                print(" -> Farb-Monitor gefunden: " .. name)
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

-- Steuerungs-Funktion: Versucht adjustReactivity, nutzt Redstone als Fallback
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

-- Alle Ausgänge beim Start sicherheitshalber zurücksetzen
redstone.setAnalogOutput("left", 0)
redstone.setAnalogOutput("right", 0)

-- 5. Natürliche Formel-Steuerung (Proportional-Anpassung ohne künstlichen Deckel)
local function calculateStepFromTable(currentEff, targetEff)
    local effDiff = targetEff - currentEff
    
    -- Faktor 0.12 skaliert den Schritt organisch:
    -- Bei 70% Differenz -> 70 * 0.12 = 8.4 -> Schritt von ca. 9 (sicher und effektiv)
    -- Bei 10% Differenz -> 10 * 0.12 = 1.2 -> Schritt von 2 (feinfühlig)
    local calculatedStep = math.floor(math.abs(effDiff) * 0.12) + 1
    
    -- Physikalische Signal-Obergrenze des Ports (1 bis 15)
    if calculatedStep > 15 then
        calculatedStep = 15
    elseif calculatedStep < 1 then
        calculatedStep = 1
    end
    
    return calculatedStep
end

-- 6. Hill-Climbing Regelung mit reiner Formel-Dynamik
local function runControlLoop()
    logCounter = logCounter + 1
    local _, caseTemp, efficiency, errorLevel = getReactorData()

    if (errorLevel >= 100) then
        pcall(function() reactor.stop() end)
        redstone.setAnalogOutput("left", 0)
        redstone.setAnalogOutput("right", 0)
        stuckReason = "NOTSTOPP: Err>=100"
        return
    end

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

    -- Regelungsbefehl direkt über die Formel-Schrittweite senden
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
            local oldDistance = math.abs(TARGET_EFFICIENCY - lastEfficiency)
            local newDistance = math.abs(TARGET_EFFICIENCY - newEfficiency)

            if newDistance < oldDistance then
                stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                stuckReason = string.format("Sprung+, Ziel nah (Step %d)", stepSize)
            else
                controlDirection = -controlDirection
                stepSize = 1
                stuckReason = "Sprung-, weg -> Richtungsel."
            end
        else
            if newEfficiency < lastEfficiency then
                controlDirection = -controlDirection
                stepSize = 1
                stuckReason = "Schlechter -> Richtungswechsel"
            else
                stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                stuckReason = string.format("Formel -> Step %d", stepSize)
            end
        end
    else
        stepSize = 2
        stuckReason = "Initialisierung"
    end

    lastEfficiency = newEfficiency

    -- Kompakten und auf Monitorbreite optimierten Log-Eintrag erstellen
    local signChar = (controlDirection == 1) and "+" or "-"
    local shortDiag = string.sub(stuckReason, 1, 16)
    local compactLog = string.format("#%03d|%s%d|EF:%.1f->%.1f|%s", logCounter, signChar, stepSize, startEffForLog, newEfficiency, shortDiag)
    table.insert(logHistory, 1, compactLog)
    if #logHistory > MAX_LOG_LINES then
        table.remove(logHistory)
    end
end

-- 7. Monitor grafisch zeichnen
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

    monitor.setCursorPos(1, 1)
    monitor.setBackgroundColor(colors.blue)
    monitor.setTextColor(colors.white)
    monitor.write(" === FUSION CONTROL " .. SCRIPT_VERSION .. " === ")
    monitor.setBackgroundColor(colors.black)

    -- Status
    monitor.setCursorPos(1, 3)
    monitor.clearLine()
    monitor.write("Modus: ")
    if efficiency >= IDLE_THRESHOLD then
        monitor.setTextColor(colors.cyan)
        monitor.write("IDLE (>= " .. IDLE_THRESHOLD .. "%)")
    elseif statusText == "RUN" then
        monitor.setTextColor(colors.green)
        monitor.write("RUN           ")
    elseif statusText == "CRUSH" then
        monitor.setTextColor(colors.red)
        monitor.write("CRUSH         ")
    else
        monitor.setTextColor(colors.orange)
        monitor.write("STANDBY       ")
    end
    monitor.setTextColor(colors.white)

    -- Case Temperatur
    monitor.setCursorPos(1, 5)
    monitor.clearLine()
    monitor.write(string.format("Case Temp: %.2fM K", caseTemp / 1000000))

    -- EF (Efficiency)
    monitor.setCursorPos(1, 7)
    monitor.clearLine()
    monitor.setTextColor(colors.yellow)
    monitor.write(string.format("EF: %.1f%% (Ziel:%d Min:%.1f)", efficiency, TARGET_EFFICIENCY, stats.minEff == math.huge and 0 or stats.minEff))
    monitor.setTextColor(colors.white)

    -- ER (Error Level)
    monitor.setCursorPos(1, 8)
    monitor.clearLine()
    if errorLevel > 50 then monitor.setTextColor(colors.red) end
    monitor.write(string.format("ER (Err):  %.2f%% (Min:%.2f Max:%.2f)", errorLevel, stats.minErr == math.huge and 0 or stats.minErr, stats.maxErr))
    monitor.setTextColor(colors.white)

    -- Fuel Type
    monitor.setCursorPos(1, 10)
    monitor.clearLine()
    monitor.write("Fuel Type: D-T Fuel")

    -- Regelung, Signalstärke und Seite
    monitor.setCursorPos(1, 11)
    monitor.clearLine()
    local signText = (controlDirection == 1) and "+" or "-"
    local sideText = (reactor and type(reactor.adjustReactivity) == "function") and "API" or ((controlDirection == 1) and "Links" or "Rechts")
    monitor.write(string.format("Regelung: %s%d | Sig: %-2d (%s)", signText, stepSize, currentSignal, sideText))

    -- Diagnose-Zeile
    monitor.setCursorPos(1, 13)
    monitor.clearLine()
    monitor.setTextColor(colors.cyan)
    monitor.write("Diag: " .. string.sub(stuckReason, 1, 24))

    -- MONITOR-LOGS (Auf Bildschirmbreite optimiert und gekürzt)
    if ENABLE_MONITOR_LOGS then
        monitor.setCursorPos(1, 15)
        monitor.setTextColor(colors.lightGray)
        monitor.write("--- ZYKLEN-LOGS ---")

        for i = 1, MAX_LOG_LINES do
            monitor.setCursorPos(1, 15 + i)
            monitor.clearLine()
            if logHistory[i] then
                monitor.write(logHistory[i])
            end
        end
    end

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.lightGray)
end

-- 8. Hauptschleife
while true do
    runControlLoop()
    drawUI()
end
