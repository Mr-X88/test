-- ==========================================
-- SCRIPT VERSION 2.53 (Entkoppelte Brain-Arm Architektur mit Go-Sync & Sekundenzähler)
-- ==========================================
local SCRIPT_VERSION = "v2.53"

local reactor = nil
local monitor = nil
local relay = nil  

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN (HIER ANPASSBAR)
-- ==========================================
local TARGET_EFFICIENCY = 100        -- Ziel-EF-Wert
local IDLE_THRESHOLD = 95.0          -- Ab hier direkt Idle & Stopp
local FULL_POWER_DISTANCE = 43       -- Volle Power ab 43 Punkten Restabstand
local POLL_INTERVAL_TICKS = 4        -- Sensor-Intervall (0.2 Sekunden)
local EXECUTION_INTERVAL_TICKS = 20  -- Ausführungs-Takt für Befehle & Logs (20 Ticks = 1 Sekunde)
local JUMP_THRESHOLD = 3.0           -- Schwellenwert für Tick-Sprünge/-Einbrüche
local EFF_TOLERANCE = 0.8            -- Toleranz-Schwelle für normales Rauschen

-- ==========================================
-- WECKRUF- / REDSTONE-RELAY EINSTELLUNGEN
-- ==========================================
local ENABLE_WAKEUP_PULSE = true     -- Aktiviert den Weck-Impuls bei Totalstillstand (EF=0 und ER=0)
local WAKEUP_INTERVAL_TICKS = 40     -- Ticks zwischen den Weck-Versuchen (2 Sekunden)
local WAKEUP_PULSE_TICKS = 10        -- Länge des Impulses in Ticks (0.5 Sekunden)
local WAKEUP_STRENGTH = 15           -- Signalstärke des Weck-Impulses (1-15)

-- MONITOR LOG EINSTELLUNGEN
local ENABLE_MONITOR_LOGS = true 
local monitorWidth, monitorHeight = 39, 25

-- Regelungs-Variablen
local currentSignal = 8              
local controlDirection = 1      -- 1 = Erhöhen (+), -1 = Senken (-)
local stepSize = 4               
local lastEfficiency = 0
local maxEfficiencySeen = 0     
local hasEverRun = false        
local logCounter = 0
local logHistory = {}           
local wakeupTickCounter = 0     

-- Synchronisations-Variablen für Brain-Arm
local executionTickCounter = 0
local secondCounter = 0
local secondsSinceLastGo = 0
local executionGo = false

-- Live-Daten für den Hintergrund-Prozess (Geteilter Zustand)
local liveEF = 0
local liveER = 0
local liveCaseTemp = 0
local liveIsRunning = false
local tickJumpOccurred = false
local tickJumpDelta = 0

local stuckReason = "Warte auf Reaktor..."

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
    relay = nil
    
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
        elseif pType == "redstoneIntegrator" or pType == "relay" or lName:find("relay") or lName:find("modem") then
            local r = peripheral.wrap(name)
            if r and (type(r.setOutput) == "function" or type(r.setAnalogOutput) == "function") then
                relay = r
                print(" -> Redstone Relay / Integrator gefunden: " .. name)
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

local sides = {"top", "bottom", "left", "right", "front", "back"}

local function sendWakeupPulse()
    pcall(function()
        if relay then
            for _, side in ipairs(sides) do
                if type(relay.setAnalogOutput) == "function" then
                    relay.setAnalogOutput(side, WAKEUP_STRENGTH)
                elseif type(relay.setOutput) == "function" then
                    relay.setOutput(side, true)
                end
            end
        else
            for _, side in ipairs(sides) do
                redstone.setAnalogOutput(side, WAKEUP_STRENGTH)
            end
        end
    end)
    
    sleep(WAKEUP_PULSE_TICKS * 0.05)
    
    pcall(function()
        if relay then
            for _, side in ipairs(sides) do
                if type(relay.setAnalogOutput) == "function" then
                    relay.setAnalogOutput(side, 0)
                elseif type(relay.setOutput) == "function" then
                    relay.setOutput(side, false)
                end
            end
        else
            for _, side in ipairs(sides) do
                redstone.setAnalogOutput(side, 0)
            end
        end
    end)
end

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
        pcall(function() 
            if relay then
                for _, s in ipairs(sides) do relay.setAnalogOutput(s, strength) end
            else
                redstone.setAnalogOutput(sideName, strength)
            end
        end)
        sleep(0.1)
        pcall(function() 
            if relay then
                for _, s in ipairs(sides) do relay.setAnalogOutput(s, 0) end
            else
                redstone.setAnalogOutput(sideName, 0)
            end
        end)
    end
end

-- 3. DYNAMISCHE FORMEL (Berechnet die Schrittgröße über den Abstand 43)
local function calculateStepFromTable(currentEff, targetEff)
    local effDiff = targetEff - currentEff

    if effDiff >= FULL_POWER_DISTANCE then
        return 15
    elseif effDiff <= 2 then
        return 1
    end

    local calculatedStep = math.floor((effDiff / FULL_POWER_DISTANCE) * 14) + 1
    if calculatedStep > 15 then calculatedStep = 15 elseif calculatedStep < 1 then calculatedStep = 1 end
    
    return calculatedStep
end

-- 4. SCHNELLE 4-TICK SENSOR-SCHLEIFE (Das "Gehirn" / Trend, Richtung, Taktgeber & Sekundenzähler)
local lastSensorEF = 0

local function backgroundSensorLoop()
    local pollSeconds = POLL_INTERVAL_TICKS / 20  -- 0.2 Sekunden

    while true do
        local _, caseT, eff, err, running = getReactorData()
        
        liveCaseTemp = caseT
        liveEF = eff
        liveER = err
        liveIsRunning = running
        
        if eff > 0 then
            hasEverRun = true
        end

        -- Taktgeber, Go-Signal und Sekunden-Zähler
        executionTickCounter = executionTickCounter + POLL_INTERVAL_TICKS
        secondCounter = secondCounter + POLL_INTERVAL_TICKS

        if secondCounter >= 20 then
            secondCounter = secondCounter - 20
            secondsSinceLastGo = secondsSinceLastGo + 1
        end

        if executionTickCounter >= EXECUTION_INTERVAL_TICKS then
            executionTickCounter = 0
            executionGo = true
        end

        -- Weckruf-Prüfung bei absolutem Stillstand
        if ENABLE_WAKEUP_PULSE and eff == 0 and err == 0 then
            wakeupTickCounter = wakeupTickCounter + POLL_INTERVAL_TICKS
            if wakeupTickCounter >= WAKEUP_INTERVAL_TICKS then
                wakeupTickCounter = 0
                sendWakeupPulse()
            end
        else
            wakeupTickCounter = 0
        end

        -- Trend- und Richtungs-Erkennung
        if not running or eff == 0 then
            stuckReason = (hasEverRun and eff == 0) and "CRASH erkannt!" or "Standby"
        elseif eff >= IDLE_THRESHOLD then
            stuckReason = string.format("Idle & Stopp (>=%.1f%%)", eff)
        else
            if lastSensorEF > 0 then
                local delta = eff - lastSensorEF
                if math.abs(delta) >= JUMP_THRESHOLD then
                    tickJumpOccurred = true
                    tickJumpDelta = delta
                    if delta < 0 then
                        controlDirection = -controlDirection
                        stuckReason = "Tick-Einbruch (Wechsel)"
                    else
                        stuckReason = "Tick-Sprung (+)"
                    end
                else
                    if eff > lastSensorEF then
                        stuckReason = string.format("Steigt (Richtung %d)", controlDirection)
                    elseif eff < (lastSensorEF - EFF_TOLERANCE) then
                        controlDirection = -controlDirection
                        stuckReason = "Sinkt -> Wechsel"
                    else
                        controlDirection = -controlDirection
                        stuckReason = "Stillstand -> Wechsel"
                    end
                end
            else
                stuckReason = "Init"
            end
        end

        if eff > 0 then
            lastSensorEF = eff
        end

        updateStats(eff, err, caseT)
        sleep(pollSeconds)
    end
end

-- 5. KONFIGURIERBARE 20-TICK AUSFÜHRUNGS-SCHLEIFE (Der "Arm" & Protokoll, wartet auf Go)
local function executionLoop()
    while true do
        -- Solange kein Go vorliegt, wird gewartet (kein Signal, kein Log, aber Berechnung läuft im Hintergrund)
        while not executionGo do
            sleep(0.05)
        end
        
        -- Go sofort wieder verlieren, bis der nächste Takt ein neues Go gibt
        executionGo = false

        -- Sekunden für diesen Zyklus sichern und Zähler für den nächsten Zyklus auf 0 zurücksetzen
        local logSeconds = secondsSinceLastGo
        secondsSinceLastGo = 0

        local efficiency = liveEF
        local errorLevel = liveER

        if liveIsRunning and efficiency > 0 and efficiency < IDLE_THRESHOLD then
            if efficiency > maxEfficiencySeen then
                maxEfficiencySeen = efficiency
            end

            local startEffForLog = efficiency

            -- Schrittgröße per Formel berechnen
            stepSize = calculateStepFromTable(efficiency, TARGET_EFFICIENCY)

            -- Befehl an Reaktor / Relay ausführen
            applyControlAction(controlDirection, stepSize)

            currentSignal = currentSignal + (controlDirection * stepSize)
            if currentSignal > 15 then currentSignal = 15 elseif currentSignal < 1 then currentSignal = 1 end

            logCounter = logCounter + 1

            if ENABLE_MONITOR_LOGS then
                local signChar = (controlDirection == 1) and "+" or "-"
                local shortDiag = string.sub(stuckReason, 1, 10) 
                local compactLog = string.format("#%03d|%s%d|%.0f->%.0f|ER:%d/%ds|%s", 
                    logCounter, signChar, stepSize, startEffForLog, efficiency, math.floor(errorLevel + 0.5), logSeconds, shortDiag)
                
                table.insert(logHistory, 1, compactLog)
                local maxLogLines = math.max(5, monitorHeight - 7)
                if #logHistory > maxLogLines then
                    table.remove(logHistory)
                end
            end
        else
            -- Bei Stillstand oder Idle alle Relays/Signale sicher auf 0 setzen
            pcall(function()
                if relay then
                    for _, side in ipairs(sides) do relay.setAnalogOutput(side, 0) end
                else
                    for _, side in ipairs(sides) do redstone.setAnalogOutput(side, 0) end
                end
            end)
        end
    end
end

-- 6. MONITOR-UI SCHLEIFE (Anzeige)
local function uiLoop()
    while true do
        if monitor then
            local efficiency = liveEF
            local caseTemp = liveCaseTemp
            local errorLevel = liveER

            local statusText = "STANDBY"
            if efficiency > 0 then
                statusText = "RUN"
            elseif hasEverRun and efficiency == 0 then
                statusText = "CRUSH"
            else
                statusText = "STANDBY"
            end

            monitor.setBackgroundColor(colors.black)
            
            monitor.setCursorPos(1, 1)
            monitor.setBackgroundColor(colors.blue)
            monitor.setTextColor(colors.white)
            monitor.write(string.format("=== FUSION CONTROL %s ===", SCRIPT_VERSION))
            monitor.setBackgroundColor(colors.black)

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

            monitor.setCursorPos(1, 3)
            monitor.clearLine()
            monitor.write(string.format("Case: %.1fM K", caseTemp / 1000000))
            monitor.write(" | ER: ")
            if errorLevel > 50 then monitor.setTextColor(colors.red) end
            monitor.write(string.format("%.1f%%", errorLevel))
            monitor.setTextColor(colors.white)

            monitor.setCursorPos(1, 4)
            monitor.clearLine()
            local signText = (controlDirection == 1) and "+" or "-"
            local sideText = relay and "ALL-RELAY" or ((reactor and type(reactor.adjustReactivity) == "function") and "API" or "RED")
            monitor.write(string.format("Regel: %s%d | Sig: %-2d (%s)", signText, stepSize, currentSignal, sideText))

            monitor.setCursorPos(1, 5)
            monitor.clearLine()
            monitor.setTextColor(colors.cyan)
            monitor.write("Diag: " .. string.sub(stuckReason, 1, 28))
            monitor.setTextColor(colors.white)

            if ENABLE_MON
