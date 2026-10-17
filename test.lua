-- ==========================================
-- SCRIPT VERSION 2.50 (URSPRÜNGLICHER STAND - FESTE 4T-SENSOR-SCHLEIFE)
-- ==========================================
local SCRIPT_VERSION = "v2.50"

local reactor = nil
local monitor = nil
local relay = nil  

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN
-- ==========================================
local TARGET_EFFICIENCY = 100        -- Ziel-EF-Wert
local IDLE_THRESHOLD = 95.0          -- Ab hier direkt Idle & Stopp
local POLL_INTERVAL_TICKS = 4        -- Fester Basis-Takt (0.2 Sekunden)

local JUMP_THRESHOLD = 3.0           -- Schwelle für Sensor-Diagnose
local LOG_JUMP_THRESHOLD = 16.0      -- Schwelle für Log-Sprünge
local EFF_TOLERANCE = 0.8            -- Toleranz-Schwelle für Rauschen

-- ==========================================
-- WECKRUF- / REDSTONE-RELAY EINSTELLUNGEN
-- ==========================================
local ENABLE_WAKEUP_PULSE = true     -- Aktiviert Weck-Impuls bei Stillstand
local WAKEUP_INTERVAL_TICKS = 40     -- 2 Sekunden
local WAKEUP_PULSE_TICKS = 10        -- 0.5 Sekunden
local WAKEUP_STRENGTH = 15           

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

-- Live-Daten für Hintergrund-Prozess
local liveEF = 0
local liveER = 0
local liveCaseTemp = 0
local liveIsRunning = false

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

-- 4. FESTE 4T SENSOR-SCHLEIFE
local lastSensorEF = 0
local lastSensorER = 0

local function backgroundSensorLoop()
    while true do
        local pollSeconds = POLL_INTERVAL_TICKS / 20  -- Fest 0.2 Sekunden (4 Ticks)
        
        local _, caseT, eff, err, running = getReactorData()
        
        liveCaseTemp = caseT
        liveEF = eff
        liveER = err
        liveIsRunning = running
        
        if eff > 0 then
            hasEverRun = true
        end

        -- Dynamische Richtungsbestimmung direkt im schnellen 4t-Takt
        if eff >= TARGET_EFFICIENCY then
            controlDirection = -1
        elseif err > 20 and err > lastSensorER then
            controlDirection = -1
        else
            if controlDirection == -1 and eff < TARGET_EFFICIENCY - 2 and err < 10 then
                controlDirection = 1
            end
        end

        lastSensorER = err

        secondCounter = secondCounter + POLL_INTERVAL_TICKS
        if secondCounter >= 20 then
            secondCounter = secondCounter - 20
            secondsSinceLastGo = secondsSinceLastGo + 1
        end

        -- Go-Signal Erkennung (überprüft Stabilisierung im 20-Tick-Fenster)
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
            wakeupTickCounter = wakeupTickCounter + POLL_INTERVAL_TICKS
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

-- 5. AUSFÜHRUNGS-SCHLEIFE (Synchronisiert über das 20t-Fenster)
local function executionLoop()
    while true do
        while not executionGo do
            sleep(0.05)
        end
        
        executionGo = false

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

            stepSize = calculateStepFromTable(currentEfficiency, TARGET_EFFICIENCY)
            
            -- Schutz bei hohem Error Level
            if errorLevel > 30 and stepSize > 4 then
                stepSize = 4
            end

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
                local maxLogLines = math.max(5, monitorHeight - 7)
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
    end
end

-- 6. MONITOR-UI SCHLEIFE
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
            monitor.write(string.format("Regel: %s%d | Sig: %-2d (T:4t)", signText, stepSize, currentSignal))

            monitor.setCursorPos(1, 5)
            monitor.clearLine()
            monitor.setTextColor(colors.cyan)
            monitor.write("Diag: " .. string.sub(stuckReason, 1, 28))
            monitor.setTextColor(colors.white)

            if ENABLE_MONITOR_LOGS then
                monitor.setCursorPos(1, 7)
                monitor.setTextColor(colors.lightGray)
                monitor.write("--- ZYKLEN-LOGS ---")

                local maxLogLines = math.max(5, monitorHeight - 7)
                for i = 1, maxLogLines do
                    monitor.setCursorPos(1, 7 + i)
                    monitor.clearLine()
                    if logHistory[i] then
                        monitor.write(logHistory[i])
                    end
                end
            end
        end
        sleep(0.25)
    end
end

-- 7. Parallele Ausführung
parallel.waitForAll(backgroundSensorLoop, executionLoop, uiLoop)
