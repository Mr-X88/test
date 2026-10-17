-- ==========================================
-- SCRIPT VERSION 2.75 (Mit 3s-Cooldown & 2x-Go Richtungswechsel)
-- ==========================================
local SCRIPT_VERSION = "v2.75"

local reactor = nil
local monitor = nil
local relay = nil  

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN (HIER ANPASSBAR)
-- ==========================================
local TARGET_EFFICIENCY = 100        -- Ziel-EF-Wert
local IDLE_THRESHOLD = 95.0          -- Ab hier direkt Idle & Stopp

-- ADAPTIVE / LOW PERFORMANCE EINSTELLUNGEN (Redstone-Puls-basiert)
local ENABLE_LOW_PERF_MODE = true    -- Schaltet die automatische Takt-Anpassung ein/aus
local POLL_INTERVAL_TICKS = 4        -- Feste Basis-Tickrate (0.2 Sekunden)
local lowPerfMultiplier = 1          -- Startet mit Multiplikator 1 (effektiv 4 Ticks)

local JUMP_THRESHOLD = 3.0           -- Unberührt für die kleine Sensor-Schleife
local LOG_JUMP_THRESHOLD = 16.0      -- Eigene Schwelle für Sprünge im Log (ab 16)
local EFF_TOLERANCE = 0.8            -- Toleranz-Schwelle für normales Rauschen
local EXECUTION_COOLDOWN = 3.0       -- Mindestens 3 Sekunden Pause zwischen Regelschritten/Logs

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
local maxEfficiencySeen = 0     
local hasEverRun = false        
local logCounter = 0
local logHistory = {}           
local wakeupTickCounter = 0     

-- Synchronisations-Variablen für Brain-Arm & Sekundenzähler
local secondCounter = 0
local secondsSinceLastGo = 0
local executionGo = false
local lastPollEF = -1
local unchangedPollCount = 0
local previousLoggedEff = -1
local lastExecutionTime = 0     -- Timer für die 3-Sekunden-Mindestdauer
local consecutiveGoStuck = 0    -- Zählt aufeinanderfolgende Go-Signale ohne Effizienzänderung

-- Variablen für die Redstone-Puls-Messung & Hysterese von unten
local lastPulseTime = os.clock()
local pulseTargetMultiplier = 1
local pulseStreakCount = 0

-- Variablen für die Monitor-Seiten & Redstone-Log
local currentPage = 1                -- 1 = Haupt-UI & Logs, 2 = Redstone-Diagnose & Puls-Logs
local pulseCountTotal = 0
local lastDeltaT = 0
local pulseLogHistory = {}

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

-- 3. NICHT-LINEARE KURVEN-FORMEL
local function calculateStepFromTable(currentEff, targetEff)
    local effDiff = targetEff - currentEff

    if effDiff <= 0 then
        return 1
    end

    local crNeeded = (0.0927 * effDiff) + (0.00464 * (effDiff ^ 2))
    local calculatedStep = math.floor(crNeeded)

    if calculatedStep > 15 then 
        calculatedStep = 15 
    elseif calculatedStep < 1 then 
        calculatedStep = 1 
    end
    
    return calculatedStep
end

-- 4. SEPARATER EVENT-LISTENER FÜR REDSTONE-PULSE VON UNTEN
local function pulseListenerLoop()
    while true do
        os.pullEvent("redstone")
        
        if ENABLE_LOW_PERF_MODE and redstone.getInput("bottom") then
            local now = os.clock()
            local deltaT = now - lastPulseTime
            lastPulseTime = now
            lastDeltaT = deltaT
            pulseCountTotal = pulseCountTotal + 1
            
            -- Filter gegen extreme Ausreißer
            if deltaT >= 0.05 and deltaT <= 3.0 then
                local desiredMultiplier = 1
                
                if deltaT >= 0.75 then
                    desiredMultiplier = 1 -- Faktor 1 (4t)
                elseif deltaT >= 0.375 then
                    desiredMultiplier = 2 -- Faktor 2 (8t)
                elseif deltaT >= 0.187 then
                    desiredMultiplier = 4 -- Faktor 4 (16t)
                else
                    desiredMultiplier = 8 -- Faktor 8 (32t)
                end
                
                -- Puls in die Log-Historie aufnehmen
                local pulseLogLine = string.format("#%03d|Dt:%.3fs|Faktor:%d", pulseCountTotal, deltaT, desiredMultiplier)
                table.insert(pulseLogHistory, 1, pulseLogLine)
                local maxPulseLines = math.max(5, monitorHeight - 8)
                if #pulseLogHistory > maxPulseLines then
                    table.remove(pulseLogHistory)
                end

                -- Hysterese: Erst umschalten, wenn der Bereich 3 mal hintereinander erreicht wurde
                if desiredMultiplier ~= lowPerfMultiplier then
                    if desiredMultiplier == pulseTargetMultiplier then
                        pulseStreakCount = pulseStreakCount + 1
                        if pulseStreakCount >= 3 then
                            lowPerfMultiplier = desiredMultiplier
                            pulseStreakCount = 0
                        end
                    else
                        pulseTargetMultiplier = desiredMultiplier
                        pulseStreakCount = 1
                    end
                else
                    pulseTargetMultiplier = lowPerfMultiplier
                    pulseStreakCount = 0
                end
            end
        end
    end
end

-- 5. MONITOR-TOUCH LISTENER FÜR SEITENWECHSEL & LOG-SCHALTER
local function touchListenerLoop()
    while true do
        local event, side, x, y = os.pullEvent("monitor_touch")
        if currentPage == 1 then
            if y == monitorHeight then
                currentPage = 2
            elseif y == 7 then
                ENABLE_MONITOR_LOGS = not ENABLE_MONITOR_LOGS
            end
        elseif currentPage == 2 then
            if y == monitorHeight then
                currentPage = 1
            end
        end
    end
end

-- 6. ADAPTIVE SENSOR-SCHLEIFE
local lastSensorEF = 0

local function backgroundSensorLoop()
    while true do
        local effectiveTicks = POLL_INTERVAL_TICKS * lowPerfMultiplier
        local pollSeconds = effectiveTicks / 20  
        
        local _, caseT, eff, err, running = getReactorData()
        
        liveCaseTemp = caseT
        liveEF = eff
        liveER = err
        liveIsRunning = running
        
        if eff > 0 then
            hasEverRun = true
        end

        secondCounter = secondCounter + effectiveTicks
        if secondCounter >= 20 then
            secondCounter = secondCounter - 20
            secondsSinceLastGo = secondsSinceLastGo + 1
        end

        -- Go-Signal Erkennung
        if lastPollEF >= 0 and math.abs(eff - lastPollEF) < 0.1 then
            unchangedPollCount = unchangedPollCount + 1
            if unchangedPollCount >= 2 then
                executionGo = true
                unchangedPollCount = 0
            end
        else
            unchangedPollCount = 0
        end
        lastPollEF = eff

        if ENABLE_WAKEUP_PULSE and eff == 0 and err == 0 then
            wakeupTickCounter = wakeupTickCounter + effectiveTicks
            if wakeupTickCounter >= WAKEUP_INTERVAL_TICKS then
                wakeupTickCounter = 0
                sendWakeupPulse()
            end
        else
            wakeupTickCounter = 0
        end

        if not running or eff == 0 then
            stuckReason = (hasEverRun and eff == 0) and "CRASH erkannt!" or "Standby"
        elseif eff >= IDLE_THRESHOLD then
            stuckReason = string.format("Idle & Stopp (>=%.1f%%)", eff)
        else
            if lastSensorEF > 0 then
                local delta = eff - lastSensorEF
                if math.abs(delta) >= JUMP_THRESHOLD then
                    if delta < 0 then
                        stuckReason = "Einbruch"
                    else
                        stuckReason = "Sprung (+)"
                    end
                else
                    if eff > lastSensorEF then
                        stuckReason = "Steigt"
                    elseif eff < (lastSensorEF - EFF_TOLERANCE) then
                        stuckReason = "Sinkt"
                    else
                        stuckReason = "Stillstand"
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

-- 7. AUSFÜHRUNGS-SCHLEIFE (Mit 3s-Cooldown & 2x-Go Richtungswechsel)
local function executionLoop()
    while true do
        while not executionGo do
            sleep(0.05)
        end
        
        executionGo = false

        -- 3-SEKUNDEN-MINDESTDAUER PRÜFUNG (Cooldown)
        local currentTime = os.clock()
        if (currentTime - lastExecutionTime) < EXECUTION_COOLDOWN then
            -- Wenn noch keine 3 Sekunden vergangen sind, verwerfen wir diesen Ausführungs-Zyklus
            goto continueExecution
        end
        lastExecutionTime = currentTime

        local logSeconds = secondsSinceLastGo
        secondsSinceLastGo = 0

        local currentEfficiency = liveEF
        local errorLevel = liveER

        if previousLoggedEff < 0 then
            previousLoggedEff = currentEfficiency
        end

        local startEffForLog = previousLoggedEff

        if liveIsRunning and currentEfficiency > 0 and currentEfficiency < IDLE_THRESHOLD then
            if currentEfficiency > maxEfficiencySeen then
                maxEfficiencySeen = currentEfficiency
            end

            -- 2x-GO RICHTUNGSWECHSEL BEI STILLSTAND / FESTHÄNGEN (z.B. bei 0 oder 100)
            local effChange = math.abs(currentEfficiency - startEffForLog)
            if effChange < 1.0 then
                consecutiveGoStuck = consecutiveGoStuck + 1
                if consecutiveGoStuck >= 2 then
                    controlDirection = -controlDirection -- Richtung umkehren!
                    consecutiveGoStuck = 0
                end
            else
                consecutiveGoStuck = 0
            end

            stepSize = calculateStepFromTable(currentEfficiency, TARGET_EFFICIENCY)
            applyControlAction(controlDirection, stepSize)

            currentSignal = currentSignal + (controlDirection * stepSize)
            if currentSignal > 15 then currentSignal = 15 elseif currentSignal < 1 then currentSignal = 1 end

            logCounter = logCounter + 1

            if ENABLE_MONITOR_LOGS then
                local effDelta = currentEfficiency - startEffForLog
                local cycleDiag = "Stillstand"

                if math.abs(effDelta) >= LOG_JUMP_THRESHOLD then
                    if effDelta > 0 then
                        cycleDiag = "Sprung (+)"
                    else
                        cycleDiag = "Sprung (-)"
                    end
                elseif effDelta > EFF_TOLERANCE then
                    cycleDiag = "Steigt"
                elseif effDelta < -EFF_TOLERANCE then
                    cycleDiag = "Sinkt"
                else
                    cycleDiag = "Stillstand"
                end

                local signChar = (controlDirection == 1) and "+" or "-"
                local shortDiag = string.sub(cycleDiag, 1, 10) 
                local compactLog = string.format("#%03d|%s%d|%.0f->%.0f|ER:%d/%ds|%s", 
                    logCounter, signChar, stepSize, startEffForLog, currentEfficiency, math.floor(errorLevel + 0.5), logSeconds, shortDiag)
                
                table.insert(logHistory, 1, compactLog)
                local maxLogLines = math.max(5, monitorHeight - 9)
                if #logHistory > maxLogLines then
                    table.remove(logHistory)
                end
            end
        else
            pcall(function()
                if relay then
                    for _, side in ipairs(sides) do relay.setAnalogOutput(side, 0) end
                else
                    for _, side in ipairs(sides) do redstone.setAnalogOutput(side, 0) end
                end
            end)
        end

        previousLoggedEff = currentEfficiency
        
        ::continueExecution::
    end
end

-- 8. MONITOR-UI SCHLEIFE (Zwei Seiten mit Klick-Navigation & Log-Button)
local function uiLoop()
    while true do
        if monitor then
            monitor.setBackgroundColor(colors.black)
            monitor.clear()

            if currentPage == 1 then
                -- === SEITE 1: HAUPT-UI & ZYKLEN-LOGS ===
                local efficiency = liveEF
                local caseTemp = liveCaseTemp
                local errorLevel = liveER
                local effectiveTicks = POLL_INTERVAL_TICKS * lowPerfMultiplier

                local statusText = "STANDBY"
                if efficiency > 0 then
                    statusText = "RUN"
                elseif hasEverRun and efficiency == 0 then
                    statusText = "CRUSH"
                else
                    statusText = "STANDBY"
                end
                
                monitor.setCursorPos(1, 1)
                monitor.setBackgroundColor(colors.blue)
                monitor.setTextColor(colors.white)
                monitor.write(string.format("=== FUSION CONTROL %s (1/2) ===", SCRIPT_VERSION))
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
                monitor.write(string.format("Regel: %s%d | Sig: %-2d (T:%dt)", signText, stepSize, currentSignal, effectiveTicks))

                monitor.setCursorPos(1, 5)
                monitor.clearLine()
                monitor.setTextColor(colors.cyan)
                monitor.write("Diag: " .. string.sub(stuckReason, 1, 28))
                monitor.setTextColor(colors.white)

                -- Klickbarer Log-Header in Zeile 7
                monitor.setCursorPos(1, 7)
                monitor.clearLine()
                monitor.setTextColor(colors.lightGray)
                monitor.write("--- ZYKLEN-LOGS [")
                if ENABLE_MONITOR_LOGS then
                    monitor.setTextColor(colors.green)
                    monitor.write("AN")
                else
                    monitor.setTextColor(colors.red)
                    monitor.write("AUS")
                end
                monitor.setTextColor(colors.lightGray)
                monitor.write("] ---")

                if ENABLE_MONITOR_LOGS then
                    local maxLogLines = math.max(5, monitorHeight - 8)
                    for i = 1, maxLogLines do
                        monitor.setCursorPos(1, 7 + i)
                        monitor.clearLine()
                        if logHistory[i] then
                            monitor.write(logHistory[i])
                        end
                    end
                else
                    monitor.setCursorPos(1, 9)
                    monitor.setTextColor(colors.gray)
                    monitor.write("  (Logs sind deaktiviert)")
                end

                -- Footer / Button für Seitenwechsel
                monitor.setCursorPos(1, monitorHeight)
                monitor.setBackgroundColor(colors.gray)
                monitor.setTextColor(colors.yellow)
                monitor.write("[ Klick für Seite 2: Redstone-Log ]")
                monitor.setBackgroundColor(colors.black)

            else
                -- === SEITE 2: REDSTONE-DIAGNOSE & PULS-LOGS ===
                monitor.setCursorPos(1, 1)
                monitor.setBackgroundColor(colors.blue)
                monitor.setTextColor(colors.white)
                monitor.write(string.format("=== REDSTONE PULS LOG (2/2) ===", SCRIPT_VERSION))
                monitor.setBackgroundColor(colors.black)

                local bottomState = redstone.getInput("bottom")

                monitor.setCursorPos(1, 3)
                monitor.write("Unten: ")
                if bottomState then
                    monitor.setTextColor(colors.green)
                    monitor.write("AN ")
                else
                    monitor.setTextColor(colors.lightGray)
                    monitor.write("AUS ")
                end
                monitor.setTextColor(colors.white)
                monitor.write(string.format("| Pulse:%d | Aktif:%dx (T:%dt)", pulseCountTotal, lowPerfMultiplier, POLL_INTERVAL_TICKS * lowPerfMultiplier))

                monitor.setCursorPos(1, 5)
                monitor.setTextColor(colors.lightGray)
                monitor.write("--- PULS-LOGS (Zeit & Faktor) ---")

                local maxPulseLines = math.max(5, monitorHeight - 7)
                for i = 1, maxPulseLines do
                    monitor.setCursorPos(1, 5 + i)
                    monitor.clearLine()
                    if pulseLogHistory[i] then
                        monitor.write(pulseLogHistory[i])
                    end
                end

                -- Footer / Button für Seitenwechsel
                monitor.setCursorPos(1, monitorHeight)
                monitor.setBackgroundColor(colors.gray)
                monitor.setTextColor(colors.yellow)
                monitor.write("[ Klick für Seite 1: Haupt-UI ]")
                monitor.setBackgroundColor(colors.black)
            end
        end
        sleep(0.25)
    end
end

-- 9. Parallele Ausführung aller Prozesse (inkl. Touch- und Puls-Listener)
parallel.waitForAll(backgroundSensorLoop, executionLoop, uiLoop, pulseListenerLoop, touchListenerLoop)
