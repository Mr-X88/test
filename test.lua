-- ==========================================
-- SCRIPT VERSION 2.43 (Mit Redstone-Relay Weckruf & 43er Full-Power-Abstand)
-- ==========================================
local SCRIPT_VERSION = "v2.43"

local reactor = nil
local monitor = nil
local relay = nil  -- Variable für das Redstone Relay / Modem

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN (HIER ANPASSBAR)
-- ==========================================
local TARGET_EFFICIENCY = 100       -- Ziel-EF-Wert
local IDLE_THRESHOLD = 95.0         -- Ab hier direkt Idle & Stopp
local FULL_POWER_DISTANCE = 43      -- Auf 43 erhöht für längeren Voll-Power-Bereich
local POLL_INTERVAL_TICKS = 4       -- Abfrage-Intervall auf 4 Ticks (0.2 Sekunden)
local MIN_CYCLE_WAIT = 5.0          -- Strikte Mindestwartezeit pro Zyklus in Sekunden
local JUMP_THRESHOLD = 3.0          -- Schwellenwert für Tick-Sprünge/-Einbrüche
local EFF_TOLERANCE = 0.8           -- Toleranz-Schwelle für normales Rauschen

-- ==========================================
-- WECKHOF- / REDSTONE-RELAY EINSTELLUNGEN
-- ==========================================
local ENABLE_WAKEUP_PULSE = true    -- Aktiviert den Weck-Impuls bei Totalstillstand (EF=0 und ER=0)
local WAKEUP_INTERVAL_TICKS = 40    -- Ticks zwischen den Weck-Versuchen (40 Ticks = 2 Sekunden)
local WAKEUP_PULSE_TICKS = 10       -- Länge des Impulses in Ticks (10 Ticks = 0.5 Sekunden)
local WAKEUP_STRENGTH = 15          -- Signalstärke des Weck-Impulses (1-15)
local WAKEUP_SIDE = "left"          -- Standard-Redstone-Seite (falls kein Relay-Peripheral gefunden wird)

-- MONITOR LOG EINSTELLUNGEN
local ENABLE_MONITOR_LOGS = true 
local monitorWidth, monitorHeight = 39, 25

-- Regelungs-Variablen
local currentSignal = 8         -- Startwert in der Mitte (1-15)
local controlDirection = 1      -- 1 = Links / Erhöhen (+), -1 = Rechts / Senken (-)
local stepSize = 4              -- Start-Suchschrittweite
local lastEfficiency = 0
local maxEfficiencySeen = 0     
local hasEverRun = false        -- Merker für Crash-Erkennung
local logCounter = 0
local logHistory = {}           -- Speicher für die Monitor-Logs
local wakeupTickCounter = 0     -- Zähler für den Weck-Intervall

-- Live-Daten für den Hintergrund-Prozess
local liveEF = 0
local liveER = 0
local liveCaseTemp = 0
local liveIsRunning = false

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

-- 1. Peripherie automatisch erkennen (inkl. Redstone Relay / Modem)
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

-- 4. Universelle Redstone- / Relay-Impuls-Funktion
local function sendWakeupPulse()
    pcall(function()
        if relay then
            if type(relay.setAnalogOutput) == "function" then
                relay.setAnalogOutput(WAKEUP_SIDE, WAKEUP_STRENGTH)
            elseif type(relay.setOutput) == "function" then
                relay.setOutput(WAKEUP_SIDE, true)
            end
        else
            redstone.setAnalogOutput(WAKEUP_SIDE, WAKEUP_STRENGTH)
        end
    end)
    
    -- Impuls-Länge in Sekunden umgerechnet (1 Tick = 0.05s)
    sleep(WAKEUP_PULSE_TICKS * 0.05)
    
    pcall(function()
        if relay then
            if type(relay.setAnalogOutput) == "function" then
                relay.setAnalogOutput(WAKEUP_SIDE, 0)
            elseif type(relay.setOutput) == "function" then
                relay.setOutput(WAKEUP_SIDE, false)
            end
        else
            redstone.setAnalogOutput(WAKEUP_SIDE, 0)
        end
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
        pcall(function() redstone.setAnalogOutput(sideName, strength) end)
        sleep(0.1)
        pcall(function() redstone.setAnalogOutput(sideName, 0) end)
    end
end

pcall(function()
    redstone.setAnalogOutput("left", 0)
    redstone.setAnalogOutput("right", 0)
end)

-- 5. DYNAMISCHE FORMEL (mit FULL_POWER_DISTANCE = 43)
local function calculateStepFromTable(currentEff, targetEff)
    local effDiff = targetEff - currentEff

    if effDiff >= FULL_POWER_DISTANCE then
        return 15
    elseif effDiff <= 2 then
        return 1
    end

    local calculatedStep = math.floor((effDiff / FULL_POWER_DISTANCE) * 14) + 1
    
    if calculatedStep > 15 then
        calculatedStep = 15
    elseif calculatedStep < 1 then
        calculatedStep = 1
    end
    
    return calculatedStep
end

-- PARALLELE HINTERGRUND-ÜBERWACHUNG (4 Ticks / 0.2s Takt + Weckruf-Logik)
local lastTickEF = 0
local tickJumpOccurred = false
local tickJumpDelta = 0

local function backgroundSensorLoop()
    local pollSeconds = POLL_INTERVAL_TICKS / 20 

    while true do
        local _, caseT, eff, err, running = getReactorData()
        
        -- Weckruf-Prüfung: Wenn EF == 0 und ER == 0 (vollkommener Stillstand/Aus)
        if ENABLE_WAKEUP_PULSE and eff == 0 and err == 0 then
            wakeupTickCounter = wakeupTickCounter + POLL_INTERVAL_TICKS
            if wakeupTickCounter >= WAKEUP_INTERVAL_TICKS then
                wakeupTickCounter = 0
                sendWakeupPulse()
            end
        else
            wakeupTickCounter = 0
        end

        if lastTickEF > 0 and eff > 0 then
            local delta = eff - lastTickEF
            if math.abs(delta) >= JUMP_THRESHOLD then
                tickJumpOccurred = true
                tickJumpDelta = delta
            end
        end
        if eff > 0 then
            lastTickEF = eff
        end

        liveCaseTemp = caseT
        liveEF = eff
        liveER = err
        liveIsRunning = running
        
        updateStats(eff, err, caseT)
        sleep(pollSeconds)
    end
end

-- 6. Haupt-Regelungsschleife mit Deadlock-Schutz
local function controlLoop()
    while true do
        local efficiency = liveEF
        local errorLevel = liveER

        if efficiency > 0 then
            hasEverRun = true
        end

        if not liveIsRunning or efficiency == 0 then
            pcall(function()
                redstone.setAnalogOutput("left", 0)
                redstone.setAnalogOutput("right", 0)
            end)
            lastEfficiency = 0 
            maxEfficiencySeen = 0 
            stuckReason = (hasEverRun and efficiency == 0) and "CRASH erkannt!" or "Standby"
            sleep(1.0)
        elseif efficiency >= IDLE_THRESHOLD then
            pcall(function()
                redstone.setAnalogOutput("left", 0)
                redstone.setAnalogOutput("right", 0)
            end)
            lastEfficiency = efficiency
            stuckReason = string.format("Idle & Stopp (>=%.1f%%)", efficiency)
            sleep(1.0)
        else
            if efficiency > maxEfficiencySeen then
                maxEfficiencySeen = efficiency
            end

            local startEffForLog = efficiency
            local cycleStartTime = os.clock() 

            tickJumpOccurred = false
            tickJumpDelta = 0

            applyControlAction(controlDirection, stepSize)

            currentSignal = currentSignal + (controlDirection * stepSize)
            if currentSignal > 15 then 
                currentSignal = 15 
            elseif currentSignal < 1 then 
                currentSignal = 1 
            end

            local elapsedWait = 0
            while elapsedWait < MIN_CYCLE_WAIT do
                sleep(0.25)
                elapsedWait = os.clock() - cycleStartTime
            end

            local cycleDuration = os.clock() - cycleStartTime 
            local newEfficiency = liveEF
            local recordedER = liveER 

            if lastEfficiency > 0 then
                if tickJumpOccurred then
                    if tickJumpDelta > 0 then
                        stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                        stuckReason = "Tick-Sprung (+)"
                    else
                        controlDirection = -controlDirection
                        stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                        stuckReason = "Tick-Einbruch (Wechsel)"
                    end
                else
                    if newEfficiency > lastEfficiency then
                        stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                        stuckReason = string.format("Steigt -> Step %d", stepSize)
                    else
                        controlDirection = -controlDirection
                        stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                        stuckReason = "Stillstand -> Wechsel"
                    end
                end
            else
                if tickJumpOccurred and tickJumpDelta < 0 then
                    controlDirection = -controlDirection
                    stepSize = 2
                    stuckReason = "Init Einbruch (+2)"
                else
                    stepSize = calculateStepFromTable(newEfficiency, TARGET_EFFICIENCY)
                    stuckReason = "Init"
                end
            end

            lastEfficiency = newEfficiency
            logCounter = logCounter + 1

            if ENABLE_MONITOR_LOGS then
                local signChar = (controlDirection == 1) and "+" or "-"
                local shortDiag = string.sub(stuckReason, 1, 10) 
                local compactLog = string.format("#%03d|%s%d|%.0f->%.0f|ER:%d-%ds|%s", 
                    logCounter, signChar, stepSize, startEffForLog, newEfficiency, math.floor(recordedER + 0.5), math.floor(cycleDuration + 0.5), shortDiag)
                
                table.insert(logHistory, 1, compactLog)
                
                local maxLogLines = math.max(5, monitorHeight - 7)
                if #logHistory > maxLogLines then
                    table.remove(logHistory)
                end
            end
        end
    end
end

-- 7. Monitor-UI Schleife
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
            local sideText = relay and "RELAY" or ((reactor and type(reactor.adjustReactivity) == "function") and "API" or "RED")
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

-- 8. Parallele Ausführung aller Prozesse
parallel.waitForAll(backgroundSensorLoop, controlLoop, uiLoop)
