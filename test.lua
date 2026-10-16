-- Fusion Reactor Controller (Korrigierter Echtzeit-Vergleich: Start vs. End EF)
local reactor = nil
local monitor = nil

-- REGELUNGS-EINSTELLUNGEN
local TARGET_EFFICIENCY = 70   -- Dein gewünschter Ziel-EF-Wert

-- Regelungs-Variablen
local currentSignal = 8        -- Startwert in der Mitte (1-15)
local controlDirection = 1     -- 1 = Links (+ / Erhöhen), -1 = Rechts (- / Senken)
local stepSize = 2             -- Startet im sicheren Suchmodus
local maxEfficiencySeen = 0    

-- Diagnose- & Log-Variablen
local stuckReason = "Warte auf Reaktor..."
local logCounter = 0

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
    print("[FEHLER] Kein Fusion Reactor Logic Adapter gefunden!")
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

-- 4. Redstone-Impuls senden
local function sendPulse(side, strength)
    pcall(function()
        redstone.setAnalogOutput(side, strength)
    end)
    sleep(0.15) -- Kurzer Impuls
    pcall(function()
        redstone.setAnalogOutput(side, 0)
    end)
end

-- 5. Korrigierter Regelkreis mit direktem Start-zu-End-Vergleich
local function runControlLoop()
    logCounter = logCounter + 1
    local _, caseTemp, startEff, errorLevel = getReactorData()

    if (errorLevel >= 100) then
        pcall(function() reactor.stop() end)
        redstone.setAnalogOutput("left", 0)
        redstone.setAnalogOutput("right", 0)
        stuckReason = "NOTSTOPP: Fehlerlevel >= 100"
        print(string.format("[LOG #%d] NOTSTOPP ausgelöst!", logCounter))
        return
    end

    if startEff > maxEfficiencySeen then
        maxEfficiencySeen = startEff
    end

    local statusText = "STANDBY"
    if startEff > 0 then
        statusText = "RUN"
    elseif maxEfficiencySeen > 0 and startEff == 0 then
        statusText = "CRUSH"
    else
        statusText = "STANDBY"
    end

    -- Wenn Standby oder Crush: Keine Signale senden & Reset
    if statusText == "STANDBY" or statusText == "CRUSH" then
        pcall(function()
            redstone.setAnalogOutput("left", 0)
            redstone.setAnalogOutput("right", 0)
        end)
        currentSignal = 8
        controlDirection = 1
        stepSize = 2
        stuckReason = "Reaktor in " .. statusText
        return
    end

    -- Schritt 1: Signalwert mathematisch aktualisieren und begrenzen
    local oldSignal = currentSignal
    currentSignal = currentSignal + (controlDirection * stepSize)
    if currentSignal > 15 then 
        currentSignal = 15 
        controlDirection = -1 
    elseif currentSignal < 1 then 
        currentSignal = 1 
        controlDirection = 1 
    end

    -- Schritt 2: Impuls an die entsprechende Seite senden
    local sideName = (controlDirection == 1) and "Links (+)" or "Rechts (-)"
    sendPulse(controlDirection == 1 and "left" or "right", stepSize)

    stuckReason = "Cooldown: Ticks sammeln..."

    -- Schritt 3: 5 Sekunden Cooldown mit sekündlicher Live-Messung abwarten
    local efficiencyReadings = { startEff }
    for i = 1, 5 do
        sleep(1.0)
        local _, _, currentEff = getReactorData()
        table.insert(efficiencyReadings, currentEff)
    end

    local endEff = efficiencyReadings[#efficiencyReadings]
    
    -- Schritt 4: DIREKTER VERGLEICH (Was hat der Impuls in DIESEM Zyklus bewirkt?)
    local trendDiff = endEff - startEff
    local actionType = ""

    if trendDiff < -0.2 then
        -- Wert ist gesunken -> Impuls ging in die FALSCHE Richtung!
        controlDirection = -controlDirection -- Richtung für den NÄCHSTEN Zyklus umkehren
        stepSize = 2                        -- Auf sicheren Suchschritt zurückfallen
        actionType = "Sinkt! Richtung gedreht (±2)"
    else
        -- Wert ist gestiegen oder stabil -> Richtung war korrekt, Formel anwenden
        actionType = "Steigt/Stabil -> Formel-Schritt"
        local effDistance = math.abs(TARGET_EFFICIENCY - endEff)
        stepSize = math.floor(effDistance * 0.4) + 2
        if stepSize > 15 then stepSize = 15 end
        if stepSize < 2 then stepSize = 2 end
    end

    -- Terminal-Log für die Fehlerverfolgung
    print(string.format("--- [LOG Zyklus #%d] ---", logCounter))
    print(string.format("  Start EF: %.2f%% | End EF: %.2f%% | Diff: %.2f%%", startEff, endEff, trendDiff))
    print(string.format("  Aktion: %s", actionType))
    print(string.format("  Impuls-Seite: %s | Schrittweite: %d", sideName, stepSize))
    print(string.format("  Signal: %d -> Neu: %d", oldSignal, currentSignal))
    print("------------------------")

    stuckReason = string.format("Diff:%.1f | %s", trendDiff, actionType)
end

-- 6. Monitor grafisch zeichnen
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

    -- EF (Efficiency)
    monitor.setCursorPos(1, 7)
    monitor.clearLine()
    monitor.setTextColor(colors.yellow)
    monitor.write(string.format("EF (Eff):  %.2f%% (Min:%.2f Max:%.2f)", efficiency, stats.minEff == math.huge and 0 or stats.minEff, stats.maxEff))
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

-- 7. Hauptschleife
while true do
    runControlLoop()
    drawUI()
end
