-- Version: 1.5 (Mit linearer Tabellen-Formel & Turbo-Modus)
-- Fusion Reactor Controller (Mit linearer Formel aus Tabellendaten & Absoluten Signalen)
local reactor = nil
local monitor = nil

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN (HIER ANPASSBAR)
-- ==========================================
local TARGET_EFFICIENCY = 100   -- Ziel-EF-Wert (Standard auf ~100% angepasst)
local COOLDOWN_WAIT = 6.0       -- Wartezeit in Sekunden für den Reaktor-Cooldown

-- Regelungs-Variablen
local currentSignal = 8         -- Startwert in der Mitte (1-15)
local controlDirection = 1      -- 1 = Links (+ / Erhöhen), -1 = Rechts (- / Senken)
local stepSize = 1              -- Dynamische Schrittweite
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

-- 4. Absolutes Redstone-Signal auf Links oder Rechts setzen
local function setSignalOutput(direction, signal)
    if signal < 1 then signal = 1 end
    if signal > 15 then signal = 15 end
    
    currentSignal = signal
    pcall(function()
        if direction == 1 then
            redstone.setAnalogOutput("left", currentSignal)
            redstone.setAnalogOutput("right", 0)
        else
            redstone.setAnalogOutput("right", currentSignal)
            redstone.setAnalogOutput("left", 0)
        end
    end)
end

-- Alle Ausgänge beim Start sicherheitshalber zurücksetzen
redstone.setAnalogOutput("left", 0)
redstone.setAnalogOutput("right", 0)

-- 5. Lineare Formel basierend auf den Tabellendaten (CR zu EF)[cite: 2]
-- Aus den Daten ergibt sich ein linearer Anstieg von ca. 0.92 EF pro CR-Einheit.
local function calculateStepFromTable(currentEff, targetEff)
    local effDiff = targetEff - currentEff
    -- Umrechnung der Effizienz-Differenz in einen passenden Signal-Anpassungsschritt
    -- Steigung m ≈ 0.92 aus den Messwerten[cite: 2]
    local calculatedStep = math.floor(math.abs(effDiff) / 5.0) + 1
    
    if calculatedStep > 15 then
        calculatedStep = 15
    elseif calculatedStep < 1 then
        calculatedStep = 1
    end
    
    return calculatedStep
end

-- 6. Hill-Climbing Regelung mit linearer Formel & Turbo-Modus
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

    -- Wenn Standby oder Crush: Beide Redstone-Signale auf 0 setzen
    if statusText == "STANDBY" or statusText == "CRUSH" then
        pcall(function()
            redstone.setAnalogOutput("left", 0)
            redstone.setAnalogOutput("right", 0)
        end)
        lastEfficiency = 0 
        stuckReason = "Reaktor in " .. statusText
        return
    end

    -- Neuen Zielwert berechnen und absolut auf die entsprechende Seite legen
    local targetSignal = currentSignal + (controlDirection * stepSize)
    
    if targetSignal > 15 then
        targetSignal = 15
        controlDirection = -1 -- Richtung wechseln
    elseif targetSignal < 1 then
        targetSignal = 1
        controlDirection = 1  -- Richtung wechseln
    end

    setSignalOutput(controlDirection, targetSignal)

    -- Cooldown abwarten
    stuckReason = string.format("Cooldown (%.1fs)...", COOLDOWN_WAIT)
    sleep(COOLDOWN_WAIT)

    -- Erst nach dem Cooldown den neuen Wert abfragen
    local _, _, newEfficiency = getReactorData()

    -- Auswertung & Anwendung der linearen Tabellen-Formel
    if lastEfficiency > 0 then
        if newEfficiency < lastEfficiency then
            -- Wert wurde schlechter -> Richtung wechseln und Schritt verkleinern
            controlDirection = -controlDirection
            stepSize = 1
            stuckReason = "Schlechter -> Richtung gewechselt"
        else
            -- Wert wurde besser oder gleich -> Richtung beibehalten!
            if newEfficiency < 50 then
                -- TURBO-MODUS: Unter 50% EF und Richtung stimmt -> Volle Kraft (+15)
                stepSize = 15
                stuckReason = "Turbo (<50% EF) -> Max Power (15)"
            else
                -- Ab 50% EF: Nutzung der linearen Formel aus der Tabelle[cite: 2] für präzise Annäherung
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
    monitor.write(" === FUSION REACTOR CONTROL === ")
    monitor.setBackgroundColor(colors.black)

    -- Status
    monitor.setCursorPos(1, 3)
    monitor.clearLine()
    monitor.write("Modus: ")
    if statusText == "RUN" then
        monitor.setTextColor(colors.green)
    elseif statusText == "CRUSH" then
        monitor.setTextColor(colors.red)
    else
        monitor.setTextColor(colors.orange)
    end
    monitor.write(statusText .. "    ")
    monitor.setTextColor(colors.white)

    -- Case Temperatur
    monitor.setCursorPos(1, 5)
    monitor.clearLine()
    monitor.write(string.format("Case Temp: %.2fM K", caseTemp / 1000000))

    -- EF (Efficiency) mit Anzeige des Ziels
    monitor.setCursorPos(1, 7)
    monitor.clearLine()
    monitor.setTextColor(colors.yellow)
    monitor.write(string.format("EF: %.1f%% (Ziel:%d Min:%.1f Max:%.1f)", efficiency, TARGET_EFFICIENCY, stats.minEff == math.huge and 0 or stats.minEff, stats.maxEff))
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

    -- Regelung, Signalstärke und Seite (Links / Rechts)
    monitor.setCursorPos(1, 11)
    monitor.clearLine()
    local signText = (controlDirection == 1) and "+" or "-"
    local sideText = (controlDirection == 1) and "Links" or "Rechts"
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
