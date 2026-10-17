-- ============================================================
-- BETTER FUSION REACTOR CONTROLLER v2.82
-- Änderungen:
--   * Kein TARGET_EFFICIENCY mehr; IDLE_THRESHOLD ist die einzige Grenze.
--   * Feste Sensorabfrage alle 4 Ticks (0,2 Sekunden).
--   * Gleichheit wird exakt mit == geprüft.
--   * Kein Computer-Redstone-Ausgang für die Reaktorsteuerung.
--   * Steuerung bevorzugt adjustReactivity(); andernfalls analoger
--     Redstone-Relay-Impuls auf allen Relay-Seiten.
--   * Deadlock-Bonus bleibt erhalten, bis ein Regelschritt ihn nutzt.
--   * Monitor wird ohne vollständiges Löschen jedes Frames aktualisiert.
-- ============================================================
local SCRIPT_VERSION = "v2.82"

local reactor = nil
local monitor = nil
local relay = nil
local monitorHeight = 25

-- ==================== EINSTELLUNGEN ====================
local IDLE_THRESHOLD = 95.0          -- Ab hier keine weiteren Regelschritte
local POLL_INTERVAL_TICKS = 4        -- Fest: 4 Ticks = 0,2 Sekunden
local POLL_INTERVAL_SECONDS = POLL_INTERVAL_TICKS / 20

local JUMP_THRESHOLD = 3.0
local LOG_JUMP_THRESHOLD = 16.0
local EFF_TOLERANCE = 0.8            -- Toleranz nur für Trend-/Logauswertung
local EXECUTION_COOLDOWN = 3.0       -- Mindestpause zwischen Regelschritten

-- Weckimpuls: Computer liest bottom ein; das Relay gibt den Impuls aus.
local ENABLE_WAKEUP_PULSE = true
local WAKEUP_INTERVAL_TICKS = 40     -- Alle 2 Sekunden
local WAKEUP_PULSE_TICKS = 10        -- 0,5 Sekunden
local WAKEUP_STRENGTH = 15

local ENABLE_MONITOR_LOGS = true

local sides = {"top", "bottom", "left", "right", "front", "back"}

-- ==================== REGELUNGSVARIABLEN ====================
local controlDirection = 1           -- 1 = + / erhöhen, -1 = - / senken
local stepSize = 4
local hasEverRun = false
local logCounter = 0
local logHistory = {}
local wakeupTickCounter = 0
local wakeupPulseActive = false
local wakeupPulseEndsAt = 0

local secondCounter = 0
local secondsSinceLastGo = 0
local executionGo = false
local lastPollEF = nil
local unchangedPollCount = 0
local previousLoggedEff = nil
local lastExecutionTime = -EXECUTION_COOLDOWN -- erster Regelschritt darf sofort erfolgen

-- Deadlock-Nudge: Zähl- und Zeitlogik bleibt bei 10 + 2 Sensor-Iterationen.
local stuckPollCount = 0
local lastSensorEFForStuck = nil
local stuckNudgeActive = false
local stuckNudgeCounter = 0
local stuckNudgeBonus = 0

-- Redstone-Eingangsprotokoll (Computer-bottom; keine Ausgangssteuerung darüber)
local lastBottomState = false
local lastPulseTime = nil
local lastDeltaT = nil
local pulseCountTotal = 0
local pulseLogHistory = {}

local currentPage = 1
local lastRenderedPage = nil

-- Aktuelle, gemeinsam genutzte Sensorwerte
local liveEF = 0
local liveER = 0
local liveCaseTemp = 0
local liveIsRunning = false
local liveDataValid = false

-- Anzeige des tatsächlichen letzten Regelschritts
local lastAppliedStep = nil
local lastAppliedDirection = nil
local lastActionMode = "Noch kein Schritt"
local stuckReason = "Warte auf Reaktor..."

print("==========================================")
print(" BETTER FUSION REACTOR CONTROLLER " .. SCRIPT_VERSION)
print("==========================================")

-- ==================== PERIPHERIE-SUCHE ====================
local function typeMatches(pType, expected)
    if type(pType) == "string" then
        return pType == expected
    elseif type(pType) == "table" then
        for _, value in pairs(pType) do
            if value == expected then return true end
        end
    end
    return false
end

local function scanPeripherals()
    reactor = nil
    monitor = nil
    relay = nil

    print("--- Suche Peripherie ---")
    for _, name in ipairs(peripheral.getNames()) do
        local pType = peripheral.getType(name)
        local lowerName = name:lower()
        local wrapped = peripheral.wrap(name)

        if wrapped and (typeMatches(pType, "fusionReactor") or lowerName:find("logicadapter", 1, true)) then
            reactor = wrapped
            print(" -> Reaktor-Logic-Adapter: " .. name)
        elseif wrapped and (typeMatches(pType, "monitor") or lowerName:find("monitor", 1, true)) then
            local okColor, isColor = pcall(function() return wrapped.isColor() end)
            if okColor and isColor then
                monitor = wrapped
                pcall(function() monitor.setTextScale(0.5) end)
                local okSize, _, height = pcall(function() return monitor.getSize() end)
                if okSize and type(height) == "number" then monitorHeight = height end
                print(" -> Farbmonitor: " .. name .. " (H=" .. monitorHeight .. ")")
            end
        elseif wrapped and (
            typeMatches(pType, "redstoneIntegrator") or
            typeMatches(pType, "relay") or
            lowerName:find("relay", 1, true)
        ) then
            local hasAnalog = type(wrapped.setAnalogOutput) == "function"
            local hasDigital = type(wrapped.setOutput) == "function"
            if hasAnalog or hasDigital then
                relay = wrapped
                print(" -> Redstone-Relay/Integrator: " .. name .. (hasAnalog and " (analog)" or " (nur AN/AUS)"))
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

if monitor then pcall(function() monitor.clear() end) end
if relay and type(relay.setAnalogOutput) ~= "function" then
    print("[WARNUNG] Relay hat kein setAnalogOutput(); es kann keine analoge Schrittstärke ausgeben.")
end

-- ==================== RELAY-HILFSFUNKTIONEN ====================
-- Setzt alle Seiten des externen Relays. Der Computer selbst gibt keine
-- Redstone-Ausgänge aus; redstone.getInput("bottom") bleibt nur Eingang.
local function setRelayAll(value, allowDigital)
    if not relay then return false end

    local success = true
    local usedAny = false
    for _, side in ipairs(sides) do
        local ok = false
        if type(relay.setAnalogOutput) == "function" then
            ok = pcall(function() relay.setAnalogOutput(side, value) end)
        elseif allowDigital and type(relay.setOutput) == "function" then
            ok = pcall(function() relay.setOutput(side, value > 0) end)
        end
        if ok then
            usedAny = true
        else
            success = false
        end
    end
    return success and usedAny
end

local function sendWakeupPulseStart()
    if not relay then
        stuckReason = "Weckimpuls: kein Relay"
        return false
    end
    local ok = setRelayAll(WAKEUP_STRENGTH, true)
    if not ok then
        stuckReason = "Weckimpuls: Relay-Fehler"
        return false
    end
    wakeupPulseActive = true
    wakeupPulseEndsAt = os.clock() + (WAKEUP_PULSE_TICKS * 0.05)
    return true
end

local function stopWakeupPulseIfDue()
    if wakeupPulseActive and os.clock() >= wakeupPulseEndsAt then
        setRelayAll(0, true)
        wakeupPulseActive = false
    end
end

-- ==================== REAKTORDATEN SICHER LESEN ====================
local function safeRead(methodName, fallback)
    if not reactor or type(reactor[methodName]) ~= "function" then
        return fallback, false
    end
    local ok, value = pcall(function() return reactor[methodName]() end)
    if not ok or value == nil then return fallback, false end
    return value, true
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function getReactorData()
    local logicMode = safeRead("getLogicMode", "UNKNOWN")
    local caseTemp, tempOK = safeRead("getCaseTemperature", liveCaseTemp)
    local efficiency, effOK = safeRead("getEfficiency", liveEF)
    local errorLevel, errOK = safeRead("getErrorLevel", liveER)

    if not isFiniteNumber(caseTemp) or not isFiniteNumber(efficiency) or not isFiniteNumber(errorLevel) then
        return logicMode, liveCaseTemp, liveEF, liveER, liveIsRunning, false
    end

    local dataValid = tempOK and effOK and errOK
    local isRunning = (logicMode == "ACTIVE" or logicMode == "RUNNING" or logicMode == "READY")

    local status, statusOK = safeRead("getStatus", nil)
    if statusOK then
        if type(status) == "boolean" then
            isRunning = status
        elseif type(status) == "string" then
            local upperStatus = status:upper()
            if upperStatus == "ACTIVE" or upperStatus == "RUNNING" or upperStatus == "READY" then
                isRunning = true
            elseif upperStatus == "STANDBY" or upperStatus == "STOPPED" or upperStatus == "IDLE" then
                isRunning = false
            end
        end
    elseif efficiency > 0 then
        -- Fallback, falls getLogicMode/getStatus nicht unterstützt werden.
        isRunning = true
    end

    return logicMode, caseTemp, efficiency, errorLevel, isRunning, dataValid
end

-- ==================== REGELSCHRITT BERECHNEN ====================
local function calculateStep(currentEff)
    local difference = IDLE_THRESHOLD - currentEff
    if difference <= 0 then return 1 end

    local rawStep = (0.0927 * difference) + (0.00464 * (difference ^ 2))
    local calculatedStep = math.floor(rawStep)
    if calculatedStep > 15 then calculatedStep = 15 end
    if calculatedStep < 1 then calculatedStep = 1 end
    return calculatedStep
end

-- Richtungssteuerung bevorzugt direkt den Logic-Adapter. Falls das nicht
-- verfügbar ist, kommt ein kurzer analoger Impuls auf allen Relay-Seiten.
-- Es gibt absichtlich KEINEN Computer-redstone.setAnalogOutput()-Fallback.
local function applyControlAction(direction, strength)
    strength = math.max(1, math.min(15, math.floor(strength)))

    if reactor and type(reactor.adjustReactivity) == "function" then
        local ok = pcall(function() reactor.adjustReactivity(direction * strength) end)
        if ok then return true, "Direkt" end
    end

    if not relay then
        return false, "Kein Relay / keine Direktsteuerung"
    end
    if type(relay.setAnalogOutput) ~= "function" then
        return false, "Relay kann keine analoge Schrittstärke senden"
    end

    local startOK = setRelayAll(strength, false)
    if not startOK then
        setRelayAll(0, false)
        return false, "Relay-Ausgabe fehlgeschlagen"
    end

    sleep(0.1) -- gewollter kurzer Steuerimpuls
    local stopOK = setRelayAll(0, false)
    if not stopOK then
        return false, "Relay konnte Impuls nicht sicher zurücksetzen"
    end
    return true, "Relay-Puls"
end

-- ==================== REDSTONE-EINGANGS-LISTENER ====================
-- bottom wird ausschließlich am Computer als Eingang ausgewertet. Es wird
-- nur eine steigende Flanke als neuer Impuls gezählt.
local function pulseListenerLoop()
    lastBottomState = redstone.getInput("bottom")

    while true do
        os.pullEvent("redstone")
        local bottomNow = redstone.getInput("bottom")

        if bottomNow and not lastBottomState then
            local now = os.clock()
            local deltaT = lastPulseTime and (now - lastPulseTime) or nil
            lastPulseTime = now
            lastDeltaT = deltaT
            pulseCountTotal = pulseCountTotal + 1

            local pulseLine
            if deltaT then
                pulseLine = string.format("#%03d|Dt:%.3fs|Eingang EIN", pulseCountTotal, deltaT)
            else
                pulseLine = string.format("#%03d|Erster Impuls|Eingang EIN", pulseCountTotal)
            end
            table.insert(pulseLogHistory, 1, pulseLine)
            local maxPulseLines = math.max(1, monitorHeight - 7)
            while #pulseLogHistory > maxPulseLines do table.remove(pulseLogHistory) end
        end

        lastBottomState = bottomNow
    end
end

-- ==================== MONITOR-TOUCH LISTENER ====================
local function touchListenerLoop()
    while true do
        local _, _, x, y = os.pullEvent("monitor_touch")
        if currentPage == 1 then
            if y == monitorHeight then
                currentPage = 2
            elseif y == 7 then
                ENABLE_MONITOR_LOGS = not ENABLE_MONITOR_LOGS
            end
        elseif currentPage == 2 and y == monitorHeight then
            currentPage = 1
        end
    end
end

-- ==================== SENSOR-SCHLEIFE: FEST 0,2 SEKUNDEN ====================
local lastSensorEF = nil

local function backgroundSensorLoop()
    while true do
        stopWakeupPulseIfDue()

        local _, caseT, eff, err, running, valid = getReactorData()
        if valid then
            liveCaseTemp = caseT
            liveEF = eff
            liveER = err
            liveIsRunning = running
            liveDataValid = true

            if eff > 0 then hasEverRun = true end

            -- Richtungsumkehr bleibt trendbasiert. IDLE_THRESHOLD ist die einzige
            -- Effizienzgrenze; ab dort werden keine Regelschritte ausgeführt.
            if eff < IDLE_THRESHOLD and lastSensorEF ~= nil and lastSensorEF > 0 then
                if (eff - lastSensorEF) < -EFF_TOLERANCE then
                    controlDirection = -controlDirection
                end
            end

            -- Stillstandserkennung anhand exakt gleicher Messwerte.
            -- Die ursprüngliche Zeitlogik (10 Iterationen + 2 Iterationen) bleibt.
            if running and eff > 0 and eff < IDLE_THRESHOLD and
               lastSensorEFForStuck ~= nil and eff == lastSensorEFForStuck then
                stuckPollCount = stuckPollCount + 1
                if stuckPollCount >= 10 then
                    stuckNudgeActive = true
                    stuckNudgeCounter = 2
                    stuckNudgeBonus = 1
                    stuckPollCount = 0
                end
            else
                stuckPollCount = 0
            end
            lastSensorEFForStuck = eff

            -- Timer bleibt wie zuvor; der Bonus wird hier NICHT gelöscht.
            -- Er bleibt bestehen, bis applyControlAction einen Schritt erfolgreich ausführt.
            if stuckNudgeActive then
                stuckNudgeCounter = stuckNudgeCounter - 1
                if stuckNudgeCounter <= 0 then
                    stuckNudgeActive = false
                end
            end

            secondCounter = secondCounter + POLL_INTERVAL_TICKS
            if secondCounter >= 20 then
                secondCounter = secondCounter - 20
                secondsSinceLastGo = secondsSinceLastGo + 1
            end

            -- Genau gleicher Messwert (kein EFF_TOLERANCE/0,1-Schwellwert).
            if lastPollEF ~= nil and eff == lastPollEF then
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
                if wakeupTickCounter >= WAKEUP_INTERVAL_TICKS and not wakeupPulseActive then
                    wakeupTickCounter = 0
                    sendWakeupPulseStart()
                end
            else
                wakeupTickCounter = 0
            end

            if not running or eff == 0 then
                stuckReason = (hasEverRun and eff == 0) and "CRASH erkannt!" or "Standby"
            elseif eff >= IDLE_THRESHOLD then
                stuckReason = string.format("Idle: EF >= %.1f%%", IDLE_THRESHOLD)
            else
                if lastSensorEF ~= nil then
                    local delta = eff - lastSensorEF
                    if math.abs(delta) >= JUMP_THRESHOLD then
                        stuckReason = (delta < 0) and "Einbruch" or "Sprung (+)"
                    elseif delta > EFF_TOLERANCE then
                        stuckReason = "Steigt"
                    elseif delta < -EFF_TOLERANCE then
                        stuckReason = "Sinkt"
                    else
                        stuckReason = "Stillstand"
                    end
                else
                    stuckReason = "Init"
                end
            end

            if eff > 0 then lastSensorEF = eff end
        else
            liveDataValid = false
            executionGo = false
            stuckReason = "Sensor-Lesefehler"
        end

        sleep(POLL_INTERVAL_SECONDS)
    end
end

-- ==================== AUSFÜHRUNGS-SCHLEIFE ====================
local function executionLoop()
    while true do
        if executionGo then
            executionGo = false
            local now = os.clock()

            -- Kein goto: Cooldown blockiert nur diesen Regelschritt, nicht den Thread.
            if (now - lastExecutionTime) >= EXECUTION_COOLDOWN then
                local currentEfficiency = liveEF
                local errorLevel = liveER
                local canControl = liveDataValid and liveIsRunning and
                    currentEfficiency > 0 and currentEfficiency < IDLE_THRESHOLD and errorLevel < 100

                if canControl then
                    lastExecutionTime = now

                    if previousLoggedEff == nil then previousLoggedEff = currentEfficiency end
                    local startEffForLog = previousLoggedEff

                    stepSize = calculateStep(currentEfficiency)
                    local effectiveStep = math.min(15, stepSize + stuckNudgeBonus)
                    local actionDirection = controlDirection
                    local success, modeOrError = applyControlAction(actionDirection, effectiveStep)

                    if success then
                        lastAppliedStep = effectiveStep
                        lastAppliedDirection = actionDirection
                        lastActionMode = modeOrError
                        -- Bonus erst nach tatsächlich erfolgreich ausgeführtem Schritt verbrauchen.
                        if stuckNudgeBonus > 0 then stuckNudgeBonus = 0 end

                        logCounter = logCounter + 1
                        if ENABLE_MONITOR_LOGS then
                            local delta = currentEfficiency - startEffForLog
                            local cycleDiag = "Stillstand"
                            if math.abs(delta) >= LOG_JUMP_THRESHOLD then
                                cycleDiag = (delta > 0) and "Sprung (+)" or "Sprung (-)"
                            elseif delta > EFF_TOLERANCE then
                                cycleDiag = "Steigt"
                            elseif delta < -EFF_TOLERANCE then
                                cycleDiag = "Sinkt"
                            end

                            local signChar = (actionDirection == 1) and "+" or "-"
                            local compactLog = string.format(
                                "#%03d|%s%d|%.0f->%.0f|ER:%d/%ds|%s",
                                logCounter, signChar, effectiveStep, startEffForLog,
                                currentEfficiency, math.floor(errorLevel + 0.5),
                                secondsSinceLastGo, string.sub(cycleDiag, 1, 10)
                            )
                            table.insert(logHistory, 1, compactLog)
                            local maxLogLines = math.max(1, monitorHeight - 9)
                            while #logHistory > maxLogLines do table.remove(logHistory) end
                        end

                        previousLoggedEff = currentEfficiency
                        secondsSinceLastGo = 0
                        stuckReason = "Schritt ausgeführt: " .. modeOrError
                    else
                        stuckReason = modeOrError
                    end
                elseif liveDataValid then
                    if errorLevel >= 100 then
                        stuckReason = "SICHERHEIT: ER >= 100"
                    elseif currentEfficiency >= IDLE_THRESHOLD then
                        stuckReason = string.format("Idle: EF >= %.1f%%", IDLE_THRESHOLD)
                    elseif not liveIsRunning or currentEfficiency == 0 then
                        stuckReason = "Keine Regelung: Standby"
                    end
                end
            end
        end
        sleep(0.05)
    end
end

-- ==================== MONITOR-UI ====================
local function clearLineAt(y)
    monitor.setCursorPos(1, y)
    monitor.clearLine()
end

local function writeHeader(text)
    monitor.setCursorPos(1, 1)
    monitor.setBackgroundColor(colors.blue)
    monitor.setTextColor(colors.white)
    monitor.clearLine()
    monitor.write(text)
    monitor.setBackgroundColor(colors.black)
end

local function uiLoop()
    while true do
        if monitor then
            if lastRenderedPage ~= currentPage then
                pcall(function() monitor.clear() end)
                lastRenderedPage = currentPage
            end

            if currentPage == 1 then
                writeHeader(string.format("=== FUSION CONTROL %s (1/2) ===", SCRIPT_VERSION))

                clearLineAt(2)
                monitor.write("Modus: ")
                if not liveDataValid then
                    monitor.setTextColor(colors.red)
                    monitor.write("SENSOR? ")
                elseif liveEF >= IDLE_THRESHOLD then
                    monitor.setTextColor(colors.cyan)
                    monitor.write("IDLE ")
                elseif liveIsRunning and liveEF > 0 then
                    monitor.setTextColor(colors.green)
                    monitor.write("RUN  ")
                elseif hasEverRun and liveEF == 0 then
                    monitor.setTextColor(colors.red)
                    monitor.write("CRUSH")
                else
                    monitor.setTextColor(colors.orange)
                    monitor.write("STAND")
                end
                monitor.setTextColor(colors.white)
                monitor.write(string.format(" | EF: %.1f%%", liveEF))

                clearLineAt(3)
                monitor.write(string.format("Case: %.1fM K | ER: ", liveCaseTemp / 1000000))
                if liveER > 50 then monitor.setTextColor(colors.red) end
                monitor.write(string.format("%.1f", liveER))
                monitor.setTextColor(colors.white)

                clearLineAt(4)
                local sign = (lastAppliedDirection == -1) and "-" or "+"
                if lastAppliedStep then
                    monitor.write(string.format("Schritt: %s%d | Ausgang: %s", sign, lastAppliedStep, lastActionMode))
                else
                    monitor.write("Schritt: -- | Noch keine Aktion")
                end

                clearLineAt(5)
                monitor.setTextColor(colors.cyan)
                monitor.write("Diag: " .. string.sub(stuckReason, 1, math.max(1, monitorHeight > 30 and 35 or 28)))
                monitor.setTextColor(colors.white)

                clearLineAt(7)
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
                monitor.setTextColor(colors.white)

                if ENABLE_MONITOR_LOGS then
                    local maxLogLines = math.max(1, math.min(monitorHeight - 9, 18))
                    for i = 1, maxLogLines do
                        clearLineAt(7 + i)
                        if logHistory[i] then monitor.write(logHistory[i]) end
                    end
                else
                    clearLineAt(8)
                    monitor.setTextColor(colors.gray)
                    monitor.write("  (Logs sind deaktiviert)")
                    monitor.setTextColor(colors.white)
                end

                if monitorHeight >= 1 then
                    clearLineAt(monitorHeight)
                    monitor.setBackgroundColor(colors.gray)
                    monitor.setTextColor(colors.yellow)
                    monitor.write("[ Klick für Seite 2: Redstone-Log ]")
                    monitor.setBackgroundColor(colors.black)
                    monitor.setTextColor(colors.white)
                end
            else
                writeHeader("=== REDSTONE INPUT LOG (2/2) ===")

                clearLineAt(3)
                local bottomState = redstone.getInput("bottom")
                monitor.write("Computer-bottom: ")
                if bottomState then
                    monitor.setTextColor(colors.green)
                    monitor.write("AN ")
                else
                    monitor.setTextColor(colors.lightGray)
                    monitor.write("AUS ")
                end
                monitor.setTextColor(colors.white)
                local dtText = lastDeltaT and string.format("%.3fs", lastDeltaT) or "--"
                monitor.write(string.format("| Pulse: %d | letztes Dt: %s", pulseCountTotal, dtText))

                clearLineAt(5)
                monitor.setTextColor(colors.lightGray)
                monitor.write("--- EINGANGSIMPULSE (Zeitabstand) ---")
                monitor.setTextColor(colors.white)

                local maxPulseLines = math.max(1, math.min(monitorHeight - 7, 18))
                for i = 1, maxPulseLines do
                    clearLineAt(5 + i)
                    if pulseLogHistory[i] then monitor.write(pulseLogHistory[i]) end
                end

                if monitorHeight >= 1 then
                    clearLineAt(monitorHeight)
                    monitor.setBackgroundColor(colors.gray)
                    monitor.setTextColor(colors.yellow)
                    monitor.write("[ Klick für Seite 1: Haupt-UI ]")
                    monitor.setBackgroundColor(colors.black)
                    monitor.setTextColor(colors.white)
                end
            end
        end
        sleep(0.25)
    end
end

-- ==================== PARALLELER START ====================
parallel.waitForAll(
    backgroundSensorLoop,
    executionLoop,
    uiLoop,
    pulseListenerLoop,
    touchListenerLoop
)
