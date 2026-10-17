-- Fusion Reactor Controller (Mit Anti-Ping-Pong, Low-Signal-Schutz & Pause-Modus)
local reactor = nil
local monitor = nil

-- REGELUNGS-EINSTELLUNGEN
local TARGET_EFFICIENCY = 70    -- Dein gewünschter Ziel-EF-Wert
local REDSTONE_SIDE = "back"    -- Feste Seite für das analoge Steuersignal

-- Regelungs-Variablen
local currentSignal = 8         
local controlDirection = 1     
local stepSize = 1             
local recoveryCounter = 0      
local isPaused = true          -- STARTET IM PAUSIERTEN ZUSTAND!

-- Diagnose- & Log-Variablen
local stuckReason = "Pausiert - Warte auf Start..."
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

-- 4. Absolutes Redstone-Signal setzen
local function setSignalOutput(signal)
    if signal < 1 then signal = 1 end
    if signal > 15 then signal = 15 end
    
    currentSignal = signal
    pcall(function()
        redstone.setAnalogOutput(REDSTONE_SIDE, currentSignal)
    end)
end

local function logPrint(msg)
    print(msg)
end

-- Initiales Signal beim Start setzen (Standard: 8)
setSignalOutput(currentSignal)

-- ==========================================
-- ROUTINEN FÜR PARALLELE AUSFÜHRUNG
-- ==========================================

-- A. Der eigentliche Regelkreis (läuft im Hintergrund mit eigenen Pausen)
local function controlRoutine()
    while true do
        if isPaused then
            stuckReason = "Pausiert - Manueller Test aktiv"
            sleep(0.5)
        else
            logCounter = logCounter + 1
            local _, caseTemp, startEff, errorLevel = getReactorData()

            if (errorLevel >= 100) then
                pcall(function() reactor.stop() end)
                pcall(function() redstone.setAnalogOutput(REDSTONE_SIDE, 0) end)
                stuckReason = "NOTSTOPP: Fehlerlevel >= 100"
                logPrint(string.format("[LOG #%d] NOTSTOPP ausgelöst!", logCounter))
                isPaused = true
                return
            end

            local statusText = "STANDBY"
            if startEff > 0 then
                statusText = "RUN"
            elseif startEff == 0 then
                statusText = "CRUSH"
            end

            if statusText == "STANDBY" or statusText == "CRUSH" then
                pcall(function() redstone.setAnalogOutput(REDSTONE_SIDE, 0) end)
                currentSignal = 8
                controlDirection = 1
                stepSize = 1
                recoveryCounter = 0
                stuckReason = "Reaktor in " .. statusText
                sleep(1.0)
            else
                -- Anschlag-Schutz & Richtungswechsel
                if currentSignal >= 15 and controlDirection == 1 then
                    controlDirection = -1
                    stepSize = 1
                elseif currentSignal <= 1 and controlDirection == -1 then
                    controlDirection = 1
                    stepSize = 1
                end

                local oldSignal = currentSignal
                local targetSignal = currentSignal + (controlDirection * stepSize)
                setSignalOutput(targetSignal)

                stuckReason = "Cooldown: Ticks sammeln..."

                local efficiencyReadings = { startEff }
                for i = 1, 5 do
                    sleep(1.0)
                    -- Falls in der Zwischenzeit pausiert wird, abbrechen
                    if isPaused then break end
                    local _, _, currentEff = getReactorData()
                    table.insert(efficiencyReadings, currentEff)
                end

                if not isPaused then
                    local endEff = efficiencyReadings[#efficiencyReadings]
                    local trendDiff = endEff - startEff
                    local actionType = ""

                    if trendDiff < -0.5 then
                        controlDirection = -controlDirection
                        stepSize = 1
                        recoveryCounter = 4 
                        actionType = string.format("STURZ (%.2f) -> Sperre", trendDiff)
                    else
                        if recoveryCounter > 0 then
                            recoveryCounter = recoveryCounter - 1
                            stepSize = 1 
                            actionType = string.format("Erholung (%d)", recoveryCounter)
                        else
                            if currentSignal <= 4 then
                                stepSize = 1
                                actionType = string.format("Low-Signal Safe (%.2f)", trendDiff)
                            else
                                actionType = string.format("Stabil (%.2f) -> Formel", trendDiff)
                                local effDistance = math.abs(TARGET_EFFICIENCY - endEff)
                                stepSize = math.floor(effDistance * 0.3) + 1
                                if stepSize > 15 then stepSize = 15 end
                                if stepSize < 1 then stepSize = 1 end
                            end
                        end
                    end

                    logPrint(string.format("--- [LOG Zyklus #%d] ---", logCounter))
                    logPrint(string.format("  Start EF: %.2f%% | End EF: %.2f%% | Diff: %.2f%%", startEff, endEff, trendDiff))
                    logPrint(string.format("  Aktion: %s", actionType))
                    logPrint(string.format("  Schrittweite: %d", stepSize))
                    logPrint(string.format("  Signal: %d -> Neu: %d", oldSignal, currentSignal))
                    logPrint("------------------------")

                    stuckReason = string.format("Diff:%.1f | %s", trendDiff, actionType)
                end
            end
        end
    end
end

-- B. UI-Aktualisierungs-Routine (lädt flüssig alle 0.3 Sekunden neu)
local function uiRoutine()
    while true do
        if monitor then
            local logicMode, caseTemp, efficiency, errorLevel = getReactorData()
            updateStats(efficiency, errorLevel, caseTemp)

            local statusText = "STANDBY"
            if efficiency > 0 then
                statusText = "RUN"
            elseif efficiency == 0 then
                statusText = "CRUSH"
            end

            monitor.setCursorPos(1, 1)
            if isPaused then
                monitor.setBackgroundColor(colors.orange)
            else
                monitor.setBackgroundColor(colors.blue)
            end
            monitor.setTextColor(colors.white)
            monitor.write(isPaused and " === PAUSIERT (KLICK ZUM START) === " or " === FUSION REACTOR CONTROL === ")
            monitor.setBackgroundColor(colors.black)

            monitor.setCursorPos(1, 3)
            monitor.clearLine()
            monitor.write("Status: ")
            if isPaused then
                monitor.setTextColor(colors.orange)
                monitor.write("PAUSIERT      ")
            elseif statusText == "RUN" then
                monitor.setTextColor(colors.green)
                monitor.write("
