-- ==========================================
-- SCRIPT VERSION 2.59 (Mit nicht-linearer Kurvenformel & ohne Full-Power-Distance)
-- ==========================================
local SCRIPT_VERSION = "v2.59"

local reactor = nil
local monitor = nil
local relay = nil  

-- ==========================================
-- REGELUNGS-EINSTELLUNGEN (HIER ANPASSBAR)
-- ==========================================
local TARGET_EFFICIENCY = 100        -- Ziel-EF-Wert
local IDLE_THRESHOLD = 95.0          -- Ab hier direkt Idle & Stopp
local POLL_INTERVAL_TICKS = 4        -- Sensor-Intervall (0.2 Sekunden)
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

-- 3. NEUE NICHT-LINEARE KURVEN-FORMEL (Basierend auf deinen Messwerten)
local function calculateStepFromTable(currentEff, targetEff)
    local effDiff = targetEff - currentEff

    if effDiff <= 0 then
        return 1
    end

    -- Kurvenformel aus den Messpunkten
    local crNeeded = (0.0927 * effDiff) + (0.00464 * (effDiff ^ 2))
    local calculatedStep = math.floor(crNeeded)

    if calculatedStep > 15 then 
        calculatedStep = 15 
    elseif calculatedStep < 1 then 
        calculatedStep = 1 
    end
    
    return calculatedStep
end

-- 4. SCHNELLE 4-TICK SENSOR-SCHLEIFE (Das "Gehirn" / Trend, Richtung, Sekundenzähler & EF-Stabilitäts-Go)
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

        -- Sekundenzähler läuft kontinuierlich im Hintergrund hoch
        secondCounter = secondCounter + POLL_INTERVAL_TICKS
        if secondCounter >= 20 then
            secondCounter = secondCounter - 20
            secondsSinceLastGo = secondsSinceLastGo + 1
        end

        -- Go-Signal, wenn sich der EF-Wert innerhalb von 2 4-Ticken nicht ändert
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
