-- ============================================================
-- BETTER FUSION REACTOR CONTROLLER v2.96 (Sprungerkennung + kalibrierte Schrittformel)
-- Änderungen gegenüber v2.95:
--   * Sensor-Sprünge nutzen bei bekannter Richtung die 4t-Messung statt pauschal TEST +/-2.
--   * TEST +/-2 wird nur verwendet, wenn die Richtung unbekannt ist oder eine Messung unverändert bleibt.
--   * Nach Idle >= 95% wird auf einen echten Sprung gewartet, bevor der Richtungstest erfolgt.
--   * Neue Schrittformel: 0.142*difference + 0.0036*difference^2, auf nächste Ganzzahl gerundet.
-- ============================================================
local SCRIPT_VERSION = "v2.96"

local reactor = nil
local monitor = nil
local relay = nil
local monitorHeight = 25

-- ==================== EINSTELLUNGEN ====================
local IDLE_THRESHOLD = 95.0          -- Ab hier keine weiteren Regelschritte (Abschaltgrenze)

local ENABLE_LOW_PERF_MODE = true
local POLL_INTERVAL_TICKS = 4        -- Basis: 4 Ticks = 0,2 Sekunden
local lowPerfMultiplier = 1
local pulseTargetMultiplier = 1
local pulseStreakCount = 0

local JUMP_THRESHOLD = 3.0
local LOG_JUMP_THRESHOLD = 16.0
local EXECUTION_COOLDOWN = 3.0       -- Mindestpause zwischen Regelschritten
local ACTION_EVAL_DELAY = 1.5        -- Nachmessung nach einer Korrektur (Richtung erst danach bewerten)

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
local lastExecutionTime = -EXECUTION_COOLDOWN
local pendingAction = nil           -- genau eine Aktion wartet auf ihre Nachmessung

-- Richtungsfindung bei unbekannter Wirkung und nach Idle >= 95%.
-- waitingForIdleJump hält die normale Regelung an, bis ein echter Messsprung erkannt wird.
local directionProbePending = false
local directionKnown = false          -- Erst nach einer auswertbaren Messung als bestätigt markieren
local waitingForIdleJump = false

-- Deadlock-Nudge & Log-Flag
local stuckPollCount = 0
local lastSensorEFForStuck = nil
local stuckNudgeActive = false
local stuckNudgeCounter = 0
local stuckNudgeBonus = 0

-- Redstone-Eingangsprotokoll
local lastBottomState = false
local lastPulseTime = os.clock()
local lastDeltaT = nil
local lastDesiredMultiplier = 1
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

local lastAppliedStepText = nil
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
        isRunning = true
    end

    return logicMode, caseTemp, efficiency, errorLevel, isRunning, dataValid
end

-- ==================== REGELSCHRITT BERECHNEN ====================
local function calculateStep(currentEff)
    -- Neue empirische Formel aus den bereitgestellten CR/TR/EF-Messwerten.
    -- Difference bezieht sich auf 100 %, die Schrittstärke bleibt auf 1..15 begrenzt.
    local difference = math.max(0, 100 - currentEff)
    local rawStep = (0.142 * difference) + (0.0036 * (difference ^ 2))

    -- Rundung auf die nächste Ganzzahl statt pauschalem Abrunden.
    local calculatedStep = math.floor(rawStep + 0.5)
    if calculatedStep > 15 then calculatedStep = 15 end
    if calculatedStep < 1 then calculatedStep = 1 end
    return calculatedStep
end

local function applyControlAction(direction, strength, separateNudge, nudgeIncluded)
    strength = math.max(1, math.min(15, math.floor(strength)))
    local nudgeApplied = nudgeIncluded == true

    if reactor and type(reactor.adjustReactivity) == "function" then
        local mainOK = pcall(function() reactor.adjustReactivity(direction * strength) end)
        if mainOK then
            if separateNudge then
                local nudgeOK = pcall(function() reactor.adjustReactivity(direction) end)
                if nudgeOK then
                    nudgeApplied = true
                else
                    return true, "Direkt (Nudge-Fehler)", false
                end
            end
            return true, nudgeApplied and "Direkt +Nudge" or "Direkt", nudgeApplied
        end
    end

    if not relay then
        return false, "Kein Relay / keine Direktsteuerung", false
    end
    if type(relay.setAnalogOutput) ~= "function" then
        return false, "Relay kann keine analoge Schrittstärke senden", false
    end

    local function relayPulse(pulseStrength)
        local startOK = setRelayAll(pulseStrength, false)
        if not startOK then
            setRelayAll(0, false)
            return false
        end
        sleep(0.1)
        local stopOK = setRelayAll(0, false)
        return stopOK
    end

    if not relayPulse(strength) then
        setRelayAll(0, false)
        return false, "Relay-Ausgabe fehlgeschlagen", false
    end

    if separateNudge then
        if relayPulse(1) then
            nudgeApplied = true
        else
            return true, "Relay-Puls (Nudge-Fehler)", false
        end
    end
    return true, nudgeApplied and "Relay-Puls +Nudge" or "Relay-Puls", nudgeApplied
end

local function finishPendingAction(postEfficiency, postError)
    if not pendingAction then return end
    if os.clock() < pendingAction.evaluateAt then return end

    local action = pendingAction
    local delta = postEfficiency - action.beforeEfficiency
    local cycleDiag = "Stillstand"

    if action.isProbe then
        -- Ein TEST +/-2 ist nur zur Richtungsfindung da.
        if delta > 0 then
            controlDirection = action.direction
            directionProbePending = false
            directionKnown = true
            cycleDiag = "TEST OK"
            stuckReason = "Richtungstest: Richtung bestätigt"
        elseif delta < 0 then
            controlDirection = -action.direction
            directionProbePending = false
            directionKnown = true
            cycleDiag = "TEST REV"
            stuckReason = "Richtungstest: Gegenrichtung bestätigt"
        else
            -- Keine messbare Reaktion: Richtung kann nicht abgeleitet werden.
            controlDirection = -action.direction
            directionProbePending = true
            directionKnown = false
            cycleDiag = "TEST?"
            stuckReason = "Richtung unklar: Gegenprobe +/-2 vorgemerkt"
        end

        if not directionProbePending and postEfficiency >= IDLE_THRESHOLD then
            waitingForIdleJump = true
        end
    else
        if postEfficiency >= IDLE_THRESHOLD then
            -- Wie gewünscht: inaktiv bleiben, aber den nächsten echten Sprung merken.
            waitingForIdleJump = true
            directionProbePending = false
            directionKnown = false
            if math.abs(delta) >= LOG_JUMP_THRESHOLD then
                cycleDiag = (delta > 0) and "Sprung (+)" or "Sprung (-)"
            elseif delta > 0 then
                cycleDiag = "Steigt"
            elseif delta < 0 then
                cycleDiag = "Sinkt"
            end
            stuckReason = string.format("Idle >= %.1f%%: warte auf Sprung", IDLE_THRESHOLD)
        elseif delta > 0 then
            -- Auch bei einem großen Sprung ist die Richtung durch das Vorzeichen erkennbar.
            -- Eine große Änderung ist kein automatischer Grund für den TEST +/-2-Modus.
            controlDirection = action.direction
            directionProbePending = false
            directionKnown = true
            if math.abs(delta) >= LOG_JUMP_THRESHOLD then
                cycleDiag = "Sprung (+)"
                stuckReason = "Großer Sprung (+): Richtung beibehalten"
            else
                cycleDiag = "Steigt"
                stuckReason = "Nachmessung: Effizienz gestiegen, Richtung gehalten"
            end
        elseif delta < 0 then
            controlDirection = -action.direction
            directionProbePending = false
            directionKnown = true
            if math.abs(delta) >= LOG_JUMP_THRESHOLD then
                cycleDiag = "Sprung (-)"
                stuckReason = "Großer Sprung (-): Richtung umgekehrt"
            else
                cycleDiag = "Sinkt"
                stuckReason = "Nachmessung: Effizienz gesunken, Richtung umgekehrt"
            end
        else
            -- Nur wenn der Messwert exakt unverändert bleibt, ist die Richtung nicht ableitbar.
            controlDirection = -action.direction
            directionProbePending = true
            directionKnown = false
            cycleDiag = "TEST?"
            stuckReason = "Keine Änderung: Richtungstest +/-2 vorgemerkt"
        end
    end

    if action.usedNudge then cycleDiag = "STUCK" end

    if ENABLE_MONITOR_LOGS then
        local compactLog = string.format(
            "#%03d|%s|%.0f>%.0f|ER:%d/%ds|%s",
            action.id, action.stepText, action.beforeEfficiency, postEfficiency,
            math.floor(postError + 0.5), action.cycleSeconds, string.sub(cycleDiag, 1, 10)
        )
        table.insert(logHistory, 1, compactLog)
        local maxLogLines = math.max(1, math.min(monitorHeight - 9, 18))
        while #logHistory > maxLogLines do table.remove(logHistory) end
    end

    pendingAction = nil
end

-- ==================== REDSTONE-EINGANGS-LISTENER ====================
local function pulseListenerLoop()
    lastBottomState = redstone.getInput("bottom")

    while true do
        os.pullEvent("redstone")
        local bottomNow = redstone.getInput("bottom")

        if bottomNow and not lastBottomState then
            local now = os.clock()
            local deltaT = now - lastPulseTime
            lastPulseTime = now
            lastDeltaT = deltaT
            pulseCountTotal = pulseCountTotal + 1

            local desiredMultiplier = lowPerfMultiplier
            local validInterval = deltaT >= 0.05 and deltaT <= 30.0

            if ENABLE_LOW_PERF_MODE and validInterval then
                if deltaT >= 8.0 then
                    desiredMultiplier = 8
                elseif deltaT >= 4.0 then
                    desiredMultiplier = 4
                elseif deltaT >= 2.0 then
                    desiredMultiplier = 2
                else
                    desiredMultiplier = 1
                end

                lastDesiredMultiplier = desiredMultiplier

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

            local intervalText
            if validInterval then
                intervalText = string.format("Dt:%.3fs", deltaT)
            else
                intervalText = string.format("Dt:%.3f(out)", deltaT)
            end
            local pulseLine = string.format(
                "#%03d|%s|Faktor:%d|Aktiv:%d",
                pulseCountTotal, intervalText, lastDesiredMultiplier, lowPerfMultiplier
            )
            table.insert(pulseLogHistory, 1, pulseLine)
            local maxPulseLines = math.max(1, math.min(monitorHeight - 7, 18))
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
        elseif currentPage == 2 then
            if y == monitorHeight then
                currentPage = 1
            elseif y == 5 then
                ENABLE_MONITOR_LOGS = not ENABLE_MONITOR_LOGS
            end
        end
    end
end

-- ==================== ADAPTIVE SENSOR-SCHLEIFE ====================
local lastSensorEF = nil

local function backgroundSensorLoop()
    while true do
        stopWakeupPulseIfDue()

        local multiplier = ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1
        local effectiveTicks = POLL_INTERVAL_TICKS * multiplier
        local pollSeconds = effectiveTicks / 20

        local _, caseT, eff, err, running, valid = getReactorData()
        if valid then
            liveCaseTemp = caseT
            liveEF = eff
            liveER = err
            liveIsRunning = running
            liveDataValid = true

            if eff > 0 then hasEverRun = true end

            local previousSensorEfficiency = lastSensorEF
            local observedJump = previousSensorEfficiency ~= nil and
                math.abs(eff - previousSensorEfficiency) >= JUMP_THRESHOLD

            if waitingForIdleJump then
                -- Nach Erreichen von 95 % bleibt die Regelung inaktiv, bis wirklich
                -- ein Sprung (mindestens JUMP_THRESHOLD) gemessen wurde. Erst dann
                -- wird der +/-2-Test ausgeführt, auch wenn EF noch >= 95 % beträgt.
                if observedJump then
                    waitingForIdleJump = false
                    directionProbePending = true
                    directionKnown = false
                    stuckReason = "Idle-Sprung erkannt: Richtungstest +/-2"
                end
            elseif observedJump and pendingAction == nil and running and eff > 0 and eff < IDLE_THRESHOLD then
                if directionKnown then
                    -- Ein Sprung wird mit dem 4t-Sensor anhand seines Vorzeichens
                    -- ausgewertet. Positiv: bisherige Richtung halten; negativ:
                    -- Richtung umkehren. Große Sprünge lösen nicht pauschal TEST +/-2 aus.
                    directionProbePending = false
                    if eff > previousSensorEfficiency then
                        stuckReason = "Sprung (+): Richtung aus Sensor bestätigt"
                    elseif eff < previousSensorEfficiency then
                        controlDirection = -controlDirection
                        stuckReason = "Sprung (-): Richtung aus Sensor umgekehrt"
                    else
                        -- Sicherheits-Fallback: falls trotz Sprung keine Richtung ableitbar ist.
                        directionProbePending = true
                        directionKnown = false
                        stuckReason = "Sprung uneindeutig: Richtungstest +/-2"
                    end
                else
                    -- Nur wenn die bisherige Richtung unbekannt ist, wird getestet.
                    directionProbePending = true
                    stuckReason = "Sprung: Richtung unbekannt, Test +/-2"
                end
            end

            -- Nur außerhalb einer laufenden Nachmessung in den Idle-Merker wechseln.
            -- Die Aktion, die gerade die 95%-Grenze erreicht, wird zuerst ausgewertet.
            if eff >= IDLE_THRESHOLD and not directionProbePending and pendingAction == nil then
                waitingForIdleJump = true
            end

            if not stuckNudgeActive and running and
               eff > 0 and eff < IDLE_THRESHOLD and
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

            if stuckNudgeActive and stuckNudgeCounter > 0 then
                stuckNudgeCounter = stuckNudgeCounter - 1
            end
            if stuckNudgeCounter <= 0 and stuckNudgeBonus <= 0 then
                stuckNudgeActive = false
            end

            secondCounter = secondCounter + effectiveTicks
            while secondCounter >= 20 do
                secondCounter = secondCounter - 20
                secondsSinceLastGo = secondsSinceLastGo + 1
            end

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
                wakeupTickCounter = wakeupTickCounter + effectiveTicks
                if wakeupTickCounter >= WAKEUP_INTERVAL_TICKS and not wakeupPulseActive then
                    wakeupTickCounter = wakeupTickCounter - WAKEUP_INTERVAL_TICKS
                    sendWakeupPulseStart()
                end
            else
                wakeupTickCounter = 0
            end

            if not running or eff == 0 then
                stuckReason = (hasEverRun and eff == 0) and "CRASH erkannt!" or "Standby"
            elseif directionProbePending then
                stuckReason = directionKnown and "Sprung: Testschritt +/-2 ausstehend" or "Richtung unklar: Test +/-2 ausstehend"
            elseif waitingForIdleJump then
                stuckReason = string.format("Idle >= %.1f%%: warte auf Sprung", IDLE_THRESHOLD)
            elseif eff >= IDLE_THRESHOLD then
                stuckReason = string.format("Idle: EF >= %.1f%%", IDLE_THRESHOLD)
            else
                if lastSensorEF ~= nil then
                    local delta = eff - lastSensorEF
                    if math.abs(delta) >= JUMP_THRESHOLD then
                        stuckReason = (delta < 0) and "Messsprung (-)" or "Messsprung (+)"
                    elseif delta > 0 then
                        stuckReason = "Steigt"
                    elseif delta < 0 then
                        stuckReason = "Sinkt"
                    else
                        stuckReason = "Stillstand"
                    end
                else
                    stuckReason = "Init"
                end
            end

            if eff > 0 then lastSensorEF = eff end

            finishPendingAction(eff, err)
        else
            liveDataValid = false
            executionGo = false
            stuckReason = "Sensor-Lesefehler"
        end

        sleep(pollSeconds)
    end
end

-- ==================== AUSFÜHRUNGS-SCHLEIFE ====================
local function executionLoop()
    while true do
        local now = os.clock()

        if executionGo and not pendingAction and (now - lastExecutionTime) >= EXECUTION_COOLDOWN then
            executionGo = false

            local currentEfficiency = liveEF
            local errorLevel = liveER
            local probeAction = directionProbePending
            local normalControlAllowed = currentEfficiency < IDLE_THRESHOLD and not waitingForIdleJump
            local canControl = liveDataValid and liveIsRunning and currentEfficiency > 0 and
                errorLevel < 100 and (probeAction or normalControlAllowed)

            if canControl then
                lastExecutionTime = now

                if probeAction then
                    stepSize = 2
                else
                    stepSize = calculateStep(currentEfficiency)
                end

                local nudgeRequested = (not probeAction) and stuckNudgeBonus > 0
                local separateNudge = nudgeRequested and stepSize >= 15
                local nudgeIncluded = nudgeRequested and not separateNudge
                local effectiveStep = probeAction and 2 or
                    (separateNudge and 15 or math.min(15, stepSize + (nudgeIncluded and 1 or 0)))
                local actionDirection = controlDirection
                local success, modeOrError, nudgeApplied = applyControlAction(
                    actionDirection, effectiveStep, separateNudge, nudgeIncluded
                )

                if success then
                    local signChar = (actionDirection == 1) and "+" or "-"
                    local stepText
                    if probeAction then
                        stepText = "TEST" .. signChar .. "2"
                    else
                        stepText = signChar .. tostring(effectiveStep)
                        if separateNudge and nudgeApplied then stepText = stepText .. "+1" end
                    end

                    lastAppliedStepText = stepText
                    lastActionMode = modeOrError
                    logCounter = logCounter + 1

                    pendingAction = {
                        id = logCounter,
                        direction = actionDirection,
                        stepText = stepText,
                        beforeEfficiency = currentEfficiency,
                        appliedAt = os.clock(),
                        evaluateAt = os.clock() + ACTION_EVAL_DELAY,
                        cycleSeconds = secondsSinceLastGo,
                        usedNudge = nudgeApplied,
                        isProbe = probeAction
                    }

                    if nudgeApplied then
                        stuckNudgeBonus = 0
                        stuckNudgeActive = false
                        stuckNudgeCounter = 0
                        stuckPollCount = 0
                    end

                    secondsSinceLastGo = 0
                    if probeAction then
                        stuckReason = "Testschritt +/-2 ausgeführt; Nachmessung ausstehend"
                    else
                        stuckReason = "Schritt ausgeführt: " .. modeOrError .. "; Nachmessung ausstehend"
                    end
                else
                    stuckReason = modeOrError
                end
            elseif liveDataValid then
                if errorLevel >= 100 then
                    stuckReason = "SICHERHEIT: ER >= 100"
                elseif directionProbePending then
                    stuckReason = "Richtungstest +/-2 ausstehend"
                elseif waitingForIdleJump then
                    stuckReason = "Idle: warte auf Sprung"
                elseif currentEfficiency >= IDLE_THRESHOLD then
                    stuckReason = string.format("Idle: EF >= %.1f%%", IDLE_THRESHOLD)
                elseif not liveIsRunning or currentEfficiency == 0 then
                    stuckReason = "Keine Regelung: Standby"
                end
            end
        end

        sleep(0.05)
    end
end

-- ==================== WECKIMPULS-TIMER ====================
local function wakeupPulseTimerLoop()
    while true do
        if wakeupPulseActive then
            local remaining = wakeupPulseEndsAt - os.clock()
            if remaining > 0 then
                sleep(remaining)
            else
                stopWakeupPulseIfDue()
            end
        else
            sleep(0.05)
        end
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
                if lastAppliedStepText then
                    monitor.write(string.format("Schritt: %s | Ausgang: %s", lastAppliedStepText, lastActionMode))
                else
                    monitor.write("Schritt: -- | Noch keine Aktion")
                end

                clearLineAt(5)
                monitor.setTextColor(colors.cyan)
                monitor.write("Diag: " .. string.sub(stuckReason, 1, math.max(1, monitorHeight > 30 and 35 or 28)))
                monitor.setTextColor(colors.white)

                clearLineAt(6)
                local currentTicks = POLL_INTERVAL_TICKS * (ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1)
                monitor.write(string.format("Sensor: %dt / %.2fs | Faktor x%d%s",
                    currentTicks, currentTicks / 20,
                    ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1,
                    ENABLE_LOW_PERF_MODE and " AUTO" or " FIX"))

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
                    local maxLogLines = math.max(1, monitorHeight - 9)
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
                monitor.write(string.format("| Pulse: %d | Dt: %s", pulseCountTotal, dtText))
                clearLineAt(4)
                local currentTicks = POLL_INTERVAL_TICKS * (ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1)
                monitor.write(string.format("Zieltakt: x%d | aktiv: x%d (%dt / %.2fs)",
                    lastDesiredMultiplier, ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1,
                    currentTicks, currentTicks / 20))

                clearLineAt(5)
                monitor.setTextColor(colors.lightGray)
                monitor.write("--- EINGANGSIMPULSE [")
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
                    local maxPulseLines = math.max(1, math.min(monitorHeight - 7, 18))
                    for i = 1, maxPulseLines do
                        if pulseLogHistory[i] then
                            clearLineAt(5 + i)
                            monitor.write(pulseLogHistory[i])
                        end
                    end
                else
                    clearLineAt(7)
                    monitor.setTextColor(colors.gray)
                    monitor.write("  (Logs sind deaktiviert)")
                    monitor.setTextColor(colors.white)
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
    touchListenerLoop,
    wakeupPulseTimerLoop
)
