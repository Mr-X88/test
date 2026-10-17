-- ==========================================
-- SCRIPT VERSION 2.0
-- ==========================================
local SCRIPT_VERSION = "v2.0"

local reactor = nil
local monitor = nil

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN (HIER ANPASSBAR)
-- ==========================================
local TARGET_EFFICIENCY = 100   -- Ziel-EF-Wert
local IDLE_THRESHOLD = 95.0     -- EF-Schwelle: Ab hier stoppt die Regelung, bis es wieder sinkt
local COOLDOWN_WAIT = 5.0       -- Wartezeit in Sekunden für den Reaktor-Cooldown
local PULSE_LENGTH = 0.15       -- Dauer des Redstone-Impulses in Sekunden (für Fallback)
local JUMP_THRESHOLD = 4.0      -- Schwellenwert für sprunghafte EF-Änderungen durch TR-Drift

-- Regelungs-Variablen
local currentSignal = 8         -- Startwert in der Mitte (1-15)
local controlDirection = 1      -- 1 = Links / Erhöhen (+), -1 = Rechts / Senken (-)
local stepSize = 2              -- Start-Suchschrittweite
local lastEfficiency = 0
local maxEfficiencySeen = 0     

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
    local success = false
    
    -- Versuche die direkte API-Funktion des Logic Adapters
    if reactor and type(reactor.adjustReactivity) == "function" then
        pcall(function()
            -- Übergabe mit Vorzeichen: direction (1 oder -1) * strength
            reactor.adjustReactivity(direction * strength)
            success = true
        end)
    end
    
    -- Wenn adjustReactivity nicht verfügbar ist oder fehlschlägt -> Redstone-Fallback
    if not success then
        local sideName = (direction == 1) and "left" or "right"
        sendPulse(sideName, strength)
    end
end

-- Alle Ausgänge beim Start sicherheitshalber zurücksetzen
redstone.setAnalogOutput("left", 0)
redstone.setAnalogOutput("right", 0)

-- 5. Lineare Formel basierend auf den Tabellendaten (CR zu EF)[cite: 2]
local function calculateStepFromTable(currentEff, targetEff)
    local effDiff = targetEff - currentEff
    local calculatedStep = math.floor(math.abs(effDiff) / 5.0) + 1
    
    if calculatedStep > 15 then
        calculatedStep = 15
    elseif calculatedStep < 1 then
        calculatedStep = 1
    end
    
    return calculatedStep
end

-- 6. Hill-Climbing Regelung mit adjustReactivity & Fallback
local function runControlLoop()
    local _, caseTemp, efficiency, errorLevel = getReactorData()

    if (errorLevel >= 100) then
        pcall(function() reactor.stop() end)
        redstone.setAnalogOutput("left", 0)
        redstone.setAnalogOutput("right", 0)
        stuckReason = "NOTSTOPP: Fehlerlevel >= 100"
        return
    end

    if efficiency > maxEfficiencySeen then
        maxEfficiencySeen = efficiency
    end

    -- Status bestimmen (Standby / Run / Crush)
    local statusText = "STANDBY"
    if efficiency > 0 then
        statusText = "RUN"
    elseif maxEfficiencySeen > 0 and efficiency == 0 then
        statusText = "CRUSH"
    else
        statusText = "STANDBY"
    end

    -- Wenn Standby oder Crush: Keine Signale senden
    if statusText == "STANDBY" or statusText == "CRUSH" then
        pcall(function()
            redstone.setAnalogOutput("left", 0)
            redstone.setAnalogOutput("right", 0)
        end)
        lastEfficiency = 0 
        stuckReason = "Reaktor in " .. statusText
        sleep(1.0)
        return
    end

    -- Wenn der Reaktor den Schwellenwert (z.B. 95%) erreicht hat -> Warten, bis er wieder sinkt
    if efficiency >= IDLE_THRESHOLD then
        pcall(function()
            redstone.setAnalogOutput("left", 0)
            redstone.setAnalogOutput("right", 0)
        end)
        lastEfficiency = efficiency
        stuckReason = string.format("Ziel erreicht (>=%.1f%%) -> Pausiert", IDLE_THRESHOLD)
        sleep(1.0)
        return
    end

    -- Regelungsbefehl senden (Nutzt adjustReactivity oder Redstone-Fallback)
    applyControlAction(controlDirection, stepSize)

    -- Internen Signalwert nachführen
    currentSignal = currentSignal + (controlDirection * stepSize)
    if currentSignal > 15 then 
        currentSignal = 15 
        controlDirection = -1 
    elseif currentSignal < 1 then 
        currentSignal = 1 
        controlDirection = 1 
    end

    -- Cooldown abwarten
    stuckReason = string.format("Cooldown (%.1fs)...", COOLDOWN_WAIT)
    sleep(COOLDOWN_WAIT)

    -- Erst nach dem Cooldown den neuen Wert abfragen
    local _, _, newEfficiency = getReactorData()

    -- Auswertung mit Spontan-Sprung-Erkennung (TR/EF-Schwankungen abfangen)
    if lastEfficiency > 0 then
        local effDelta = newEfficiency - lastEfficiency
        local isSpontaneousJump = math.abs(effDelta) > JUMP_THRESHOLD

        if isSpontaneousJump then
            local oldDistance = math.abs(TARGET_EFFICIENCY - lastEfficiency)
            local newDistance = math.abs(TARGET_EFFICIENCY - newEfficiency)

            if newDistance < oldDistance then
                stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                stuckReason = string.format("Sprung (+), Ziel näher -> Step %d", stepSize)
            else
                controlDirection = -controlDirection
                stepSize = 1
                stuckReason = "Sprung (-), weg vom Ziel -> Richtung gewechselt"
            end
        else
            if newEfficiency < lastEfficiency then
                controlDirection = -controlDirection
                stepSize = 1
                stuckReason = "Schlechter -> Richtung gewechselt"
            else
                stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                stuckReason = string.format("Tabellen-Formel -> Step %d", stepSize)
            end
        end
    else
        stepSize = 2
        stuckReason = "Initialisierung (Suche)"
    end

    lastEfficiency = newEfficiency
end

-- 7. Monitor grafisch zeichnen (mit Versionsnummer)
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

    -- EF (Efficiency) mit Anzeige des Ziels und der Idle-Grenze
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

    -- Regelung, Signalstärke und Seite (Links / Rechts / API)
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

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.lightGray)
end

-- 8. Hauptschleife
while true do
    runControlLoop()
    drawUI()
end
