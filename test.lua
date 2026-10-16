-- Fusion Reactor Controller (Mit automatischer UI-Skalierung für große Monitore)
local reactor = nil
local monitor = nil

-- REGELUNGS-EINSTELLUNGEN
local TARGET_EFFICIENCY = 70   -- Dein gewünschter Ziel-EF-Wert

-- Regelungs-Variablen
local currentSignal = 8        
local controlDirection = 1     
local stepSize = 1             
local recoveryCounter = 0      

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
    -- Schriftgröße kleiner stellen, damit EXTREM viel auf den Monitor passt
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
    sleep(0.15)
    pcall(function()
        redstone.setAnalogOutput(side, 0)
    end)
end

-- Helper zum Ausgeben in Konsole UND Monitor (falls vorhanden)
local function logPrint(msg)
    print(msg)
end

-- 5. Intelligenter Regelkreis mit Anti-Ping-Pong-Schutz
local function runControlLoop()
    logCounter = logCounter + 1
    local _, caseTemp, startEff, errorLevel = getReactorData()

    if (errorLevel >= 100) then
        pcall(function() reactor.stop() end)
        redstone.setAnalogOutput("left", 0)
        redstone.setAnalogOutput("right", 0)
        stuckReason = "NOTSTOPP: Fehlerlevel >= 100"
        logPrint(string.format("[LOG #%d] NOTSTOPP ausgelöst!", logCounter))
        return
    end

    local statusText = "STANDBY"
    if startEff > 0 then
        statusText = "RUN"
    elseif startEff == 0 then
        statusText = "CRUSH"
    else
        statusText = "STANDBY"
    end

    if statusText == "STANDBY" or statusText == "CRUSH" then
        pcall(function()
            redstone.setAnalogOutput("left", 0)
            redstone.setAnalogOutput("right", 0)
        end)
        currentSignal = 8
        controlDirection = 1
        stepSize = 1
        recoveryCounter = 0
        stuckReason = "Reaktor in " .. statusText
        return
    end

    if currentSignal >= 15 and controlDirection == 1
