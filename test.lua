-- ============================================================
-- BETTER FUSION REACTOR CONTROLLER v3.11 (Strict Idle Hold)
-- Change in v3.11:
--   * No control action is allowed while the current EF is >= IDLE_THRESHOLD.
--   * A queued probe cannot bypass idle; idle releases only on a significant jump below threshold.
--   * Formula, cooldown, polling, UI, and logging otherwise remain unchanged.
-- ============================================================
local SCRIPT_VERSION = "v3.11"

local reactor = nil
local monitor = nil
local relay = nil
local monitorHeight = 25

-- ==================== SETTINGS ====================
local IDLE_THRESHOLD = 95.0          -- No further control steps beyond this point (shutdown limit)

local ENABLE_LOW_PERF_MODE = true
local POLL_INTERVAL_TICKS = 4        -- Base: 4 ticks = 0.2 seconds
local lowPerfMultiplier = 1
local pulseTargetMultiplier = 1
local pulseStreakCount = 0

local JUMP_THRESHOLD = 3.0
local LOG_JUMP_THRESHOLD = 16.0
local EXECUTION_COOLDOWN = 3.0       -- Minimum pause between control steps
local ACTION_EVAL_DELAY = 1.5        -- Re-evaluation delay after correction

local ENABLE_WAKEUP_PULSE = true
local WAKEUP_INTERVAL_TICKS = 40     -- Every 2 seconds
local WAKEUP_PULSE_TICKS = 10        -- 0.5 seconds
local WAKEUP_STRENGTH = 15

local ENABLE_MONITOR_LOGS = true

local sides = {"top", "bottom", "left", "right", "front", "back"}

-- ==================== CONTROL VARIABLES ====================
local controlDirection = 1           -- 1 = + / increase, -1 = - / decrease
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
local stableExecutionEfficiency = nil
local stableExecutionAt = nil
local lastExecutionTime = -EXECUTION_COOLDOWN
local pendingAction = nil           -- Exactly one action waiting for re-evaluation

-- Direction finding for unknown effect and after Idle >= 95%.
local directionProbePending = false
local directionKnown = false          -- Confirmed only after an evaluable measurement
local waitingForIdleJump = false

-- Deadlock-Nudge & Log Flag
local stuckPollCount = 0
local lastSensorEFForStuck = nil
local stuckNudgeActive = false
local stuckNudgeCounter = 0
local stuckNudgeBonus = 0

-- Redstone Input Log Protocol
local lastBottomState = false
local lastPulseTime = os.clock()
local lastDeltaT = nil
local lastDesiredMultiplier = 1
local pulseCountTotal = 0
local pulseLogHistory = {}

local currentPage = 1
local lastRenderedPage = nil

-- Current shared sensor values
local liveEF = 0
local liveER = 0
local liveCaseTemp = 0
local liveIsRunning = false
local liveDataValid = false
local invalidReadCount = 0

local lastAppliedStepText = nil
local lastActionMode = "No action yet"
local stuckReason = "Waiting for reactor..."

print("==========================================")
print(" BETTER FUSION REACTOR CONTROLLER " .. SCRIPT_VERSION)
print("==========================================")

-- ==================== PERIPHERAL SCAN ====================
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

    print("--- Scanning Peripherals ---")
    for _, name in ipairs(peripheral.getNames()) do
        local pType = peripheral.getType(name)
        local lowerName = name:lower()
        local wrapped = peripheral.wrap(name)

        if wrapped and (typeMatches(pType, "fusionReactor") or lowerName:find("logicadapter", 1, true)) then
            reactor = wrapped
            print(" -> Reactor Logic Adapter: " .. name)
        elseif wrapped and (typeMatches(pType, "monitor") or lowerName:find("monitor", 1, true)) then
            local okColor, isColor = pcall(function() return wrapped.isColor() end)
            if okColor and isColor then
                monitor = wrapped
                pcall(function() monitor.setTextScale(0.5) end)
                local okSize, _, height = pcall(function() return monitor.getSize() end)
                if okSize and type(height) == "number" then monitorHeight = height end
                print(" -> Color Monitor: " .. name .. " (H=" .. monitorHeight .. ")")
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
                print(" -> Redstone Relay/Integrator: " .. name)
            end
        end
    end
    print("------------------------")
end

scanPeripherals()

if not reactor then
    print("[ERROR] No Fusion Reactor Logic Adapter found! Rebooting...")
    sleep(2)
    pcall(os.reboot)
end

if monitor then pcall(function() monitor.clear() end) end

-- ==================== RELAY HELPER FUNCTIONS ====================
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

local function updateCrashRelay()
    if not relay or wakeupPulseActive then return end
    local isCrashedOrStopped = hasEverRun and (not liveIsRunning or liveEF == 0)
    local signalValue = isCrashedOrStopped and 15 or 0
    setRelayAll(signalValue, true)
end

local function sendWakeupPulseStart()
    if not relay then
        stuckReason = "Wakeup pulse: no relay"
        return false
    end
    local ok = setRelayAll(WAKEUP_STRENGTH, true)
    if not ok then
        stuckReason = "Wakeup pulse: relay error"
        return false
    end
    wakeupPulseActive = true
    wakeupPulseEndsAt = os.clock() + (WAKEUP_PULSE_TICKS * 0.05)
    return true
end

local function stopWakeupPulseIfDue()
    if wakeupPulseActive and os.clock() >= wakeupPulseEndsAt then
        wakeupPulseActive = false
        updateCrashRelay()
    end
end

-- ==================== SAFELY READ REACTOR DATA ====================
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

-- ==================== CALCULATE CONTROL STEP ====================
-- Direct formula: Efficiency = min(100, max(0, 22 / ((|TR - CR| / 100) + 0.2) - 10))
local function calculateEfficiencyFromDelta(deltaReactivity)
    local absDelta = math.abs(deltaReactivity)
    local rawEff = (22 / ((absDelta / 100) + 0.2)) - 10
    return math.min(100, math.max(0, rawEff))
end

-- Inverted formula: Solves for DeltaR given current Efficiency (currentEff -> 100% target)
-- DeltaR = 100 * (22 / (EF + 10) - 0.2)
local function calculateStep(currentEff)
    currentEff = math.min(100, math.max(0, currentEff))
    local requiredDelta = 100 * ((22 / (currentEff + 10)) - 0.2)
    local calculatedStep = math.floor(math.max(0, requiredDelta) * 100 + 0.5) / 100

    if calculatedStep < 0.01 then calculatedStep = 0.01 end
    return calculatedStep
end

local function formatStep(value)
    local text = string.format("%.2f", value)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

local function applyControlAction(direction, strength, separateNudge, nudgeIncluded)
    if not isFiniteNumber(strength) then
        return false, "Invalid step strength", false, nil
    end

    strength = math.max(0.01, math.floor(strength * 100 + 0.5) / 100)
    local nudgeApplied = nudgeIncluded == true

    if reactor and type(reactor.adjustReactivity) == "function" then
        local mainOK = pcall(function() reactor.adjustReactivity(direction * strength) end)
        if mainOK then
            if separateNudge then
                local nudgeOK = pcall(function() reactor.adjustReactivity(direction) end)
                if nudgeOK then
                    nudgeApplied = true
                else
                    return true, "Direct unlimited (Nudge Error)", false, strength
                end
            end
            return true, nudgeApplied and "Direct unlimited +Nudge" or "Direct unlimited", nudgeApplied, strength
        end
    end

    return false, "Reactor API unavailable / adjustReactivity failed", false, nil
end

local function finishPendingAction(postEfficiency, postError)
    if not pendingAction then return end
    if os.clock() < pendingAction.evaluateAt then return end

    local action = pendingAction
    local delta = postEfficiency - action.beforeEfficiency
    local cycleDiag = "Stable"

    if action.isProbe then
        if delta > 0 then
            controlDirection = action.direction
            directionProbePending = false
            directionKnown = true
            cycleDiag = "TR JUMP Wayfinding"
            stuckReason = "Direction test: direction confirmed"
        elseif delta < 0 then
            controlDirection = -action.direction
            directionProbePending = false
            directionKnown = true
            cycleDiag = "TR JUMP Wayfinding"
            stuckReason = "Direction test: opposite direction confirmed"
        else
            controlDirection = -action.direction
            directionProbePending = true
            directionKnown = false
            cycleDiag = "Test?"
            stuckReason = "Direction unclear: re-probe +/-2 scheduled"
        end

        -- Strict idle latch: even an ambiguous probe must return to idle
        -- if its completed measurement is at or above the threshold.
        if postEfficiency >= IDLE_THRESHOLD then
            waitingForIdleJump = true
            directionProbePending = false
            directionKnown = false
        end
    else
        if postEfficiency >= IDLE_THRESHOLD then
            waitingForIdleJump = true
            directionProbePending = false
            directionKnown = false
            if math.abs(delta) >= LOG_JUMP_THRESHOLD then
                cycleDiag = (delta > 0) and "Jump (+)" or "Jump (-)"
            elseif delta > 0 then
                cycleDiag = "+"
            elseif delta < 0 then
                cycleDiag = "Falling"
            end
            stuckReason = string.format("Idle >= %.1f%%: waiting for jump", IDLE_THRESHOLD)
        elseif delta > 0 then
            controlDirection = action.direction
            directionProbePending = false
            directionKnown = true
            if math.abs(delta) >= LOG_JUMP_THRESHOLD then
                cycleDiag = "Jump (+)"
                stuckReason = "Large jump (+): direction maintained"
            else
                cycleDiag = "+"
                stuckReason = "Re-evaluation: efficiency increased, direction kept"
            end
        elseif delta < 0 then
            controlDirection = -action.direction
            directionProbePending = false
            directionKnown = true
            if math.abs(delta) >= LOG_JUMP_THRESHOLD then
                cycleDiag = "Jump (-)"
                stuckReason = "Large jump (-): direction reversed"
            else
                cycleDiag = "Falling"
                stuckReason = "Re-evaluation: efficiency decreased, direction reversed"
            end
        else
            controlDirection = -action.direction
            directionProbePending = true
            directionKnown = false
            cycleDiag = "Test?"
            stuckReason = "No change: direction test +/-2 scheduled"
        end
    end

    if action.usedNudge then cycleDiag = "Nudge" end

    if ENABLE_MONITOR_LOGS then
        local compactLog = string.format(
            "#%03d St:%s Eff:%.0f->%.0f%% Err:%.0f(%ds) %s",
            action.id, action.stepText, action.beforeEfficiency, postEfficiency,
            postError, action.cycleSeconds, string.sub(cycleDiag, 1, 12)
        )
        table.insert(logHistory, 1, compactLog)
        local maxLogLines = math.max(1, math.min(monitorHeight - 9, 18))
        while #logHistory > maxLogLines do table.remove(logHistory) end
    end

    pendingAction = nil
end

-- ==================== REDSTONE INPUT LISTENER ====================
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
                "#%03d %s Fac:%d Act:%d",
                pulseCountTotal, intervalText, lastDesiredMultiplier, lowPerfMultiplier
            )
            table.insert(pulseLogHistory, 1, pulseLine)
            local maxPulseLines = math.max(1, math.min(monitorHeight - 7, 18))
            while #pulseLogHistory > maxPulseLines do table.remove(pulseLogHistory) end
        end

        lastBottomState = bottomNow
    end
end

-- ==================== MONITOR TOUCH LISTENER ====================
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

-- ==================== ADAPTIVE SENSOR LOOP ====================
local lastSensorEF = nil

local function backgroundSensorLoop()
    while true do
        stopWakeupPulseIfDue()

        local multiplier = ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1
        local effectiveTicks = POLL_INTERVAL_TICKS * multiplier
        local pollSeconds = effectiveTicks / 20

        local _, caseT, eff, err, running, valid = getReactorData()
        if valid then
            invalidReadCount = 0
            liveCaseTemp = caseT
            liveEF = eff
            liveER = err
            liveIsRunning = running
            liveDataValid = true

            if eff > 0 then hasEverRun = true end

            updateCrashRelay()

            local previousSensorEfficiency = lastSensorEF
            local observedJump = previousSensorEfficiency ~= nil and
                math.abs(eff - previousSensorEfficiency) >= JUMP_THRESHOLD

            if waitingForIdleJump then
                -- Keep idle while EF remains >= threshold. Only a noticeable
                -- jump observed below the threshold can release the idle hold.
                if observedJump and eff < IDLE_THRESHOLD and running and eff > 0 then
                    waitingForIdleJump = false
                    directionProbePending = true
                    directionKnown = false
                    stuckReason = "Idle exited below threshold: direction test +/-2"
                end
            elseif observedJump and pendingAction == nil and running and eff > 0 and eff < IDLE_THRESHOLD then
                if directionKnown then
                    directionProbePending = false
                    if eff > previousSensorEfficiency then
                        stuckReason = "Jump (+): direction confirmed from sensor"
                    elseif eff < previousSensorEfficiency then
                        controlDirection = -controlDirection
                        stuckReason = "Jump (-): direction reversed from sensor"
                    else
                        directionProbePending = true
                        directionKnown = false
                        stuckReason = "Jump ambiguous: direction test +/-2"
                    end
                else
                    directionProbePending = true
                    stuckReason = "Jump: direction unknown, test +/-2"
                end
            end

            -- Latch idle whenever a live sensor sample reaches the threshold,
            -- even if a probe was queued or an action is still being evaluated.
            if eff >= IDLE_THRESHOLD then
                waitingForIdleJump = true
                directionProbePending = false
                directionKnown = false
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
                    stableExecutionEfficiency = eff
                    stableExecutionAt = os.clock()
                    unchangedPollCount = 0
                end
            else
                unchangedPollCount = 0
                executionGo = false
                stableExecutionEfficiency = nil
                stableExecutionAt = nil
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
                stuckReason = (hasEverRun and eff == 0) and "CRASH detected!" or "Standby"
            elseif directionProbePending then
                stuckReason = directionKnown and "Jump: test step +/-2 pending" or "Direction unclear: test +/-2 pending"
            elseif waitingForIdleJump then
                stuckReason = string.format("Idle >= %.1f%%: waiting for jump", IDLE_THRESHOLD)
            elseif eff >= IDLE_THRESHOLD then
                stuckReason = string.format("Idle: EF >= %.1f%%", IDLE_THRESHOLD)
            else
                if lastSensorEF ~= nil then
                    local delta = eff - lastSensorEF
                    if math.abs(delta) >= JUMP_THRESHOLD then
                        stuckReason = (delta < 0) and "Sensor jump (-)" or "Sensor jump (+)"
                    elseif delta > 0 then
                        stuckReason = "+"
                    elseif delta < 0 then
                        stuckReason = "-"
                    else
                        stuckReason = "Stalled"
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
            stableExecutionEfficiency = nil
            stableExecutionAt = nil
            unchangedPollCount = 0
            invalidReadCount = invalidReadCount + 1
            stuckReason = "Sensor read error (" .. invalidReadCount .. ")"

            if invalidReadCount >= 5 then
                stuckReason = "Rescanning peripherals..."
                scanPeripherals()
                invalidReadCount = 0

                if not reactor then
                    stuckReason = "Reactor gone! Rebooting..."
                    sleep(2)
                    pcall(os.reboot)
                end
            end
        end

        sleep(pollSeconds)
    end
end

-- ==================== EXECUTION LOOP ====================
local function executionLoop()
    while true do
        local now = os.clock()

        if executionGo and stableExecutionEfficiency ~= nil and
           stableExecutionEfficiency == liveEF and not pendingAction and
           (now - lastExecutionTime) >= EXECUTION_COOLDOWN then
            executionGo = false

            local currentEfficiency = stableExecutionEfficiency
            stableExecutionEfficiency = nil
            stableExecutionAt = nil
            local errorLevel = liveER
            local probeAction = directionProbePending
            local normalControlAllowed = currentEfficiency < IDLE_THRESHOLD and not waitingForIdleJump
            -- Hard safety gate for idle: a queued direction probe may not bypass it.
            local canControl = liveDataValid and liveIsRunning and currentEfficiency > 0 and
                currentEfficiency < IDLE_THRESHOLD and not waitingForIdleJump and
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
                local effectiveStep = probeAction and 2 or (stepSize + (nudgeIncluded and 1 or 0))
                local actionDirection = controlDirection
                local success, modeOrError, nudgeApplied, actualStrength = applyControlAction(
                    actionDirection, effectiveStep, separateNudge, nudgeIncluded
                )

                if success then
                    local signChar = (actionDirection == 1) and "+" or "-"
                    local stepText
                    if probeAction then
                        stepText = "Wf" .. signChar .. "2"
                    else
                        local loggedStrength = actualStrength or effectiveStep
                        stepText = signChar .. formatStep(loggedStrength)
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
                        stuckReason = "Test step +/-2 executed; re-evaluation pending"
                    else
                        stuckReason = "Step executed: " .. modeOrError .. "; re-evaluation pending"
                    end
                else
                    stuckReason = modeOrError
                end
            elseif liveDataValid then
                if errorLevel >= 100 then
                    stuckReason = "SAFETY: ER >= 100"
                elseif directionProbePending then
                    stuckReason = "Direction test +/-2 pending"
                elseif waitingForIdleJump then
                    stuckReason = "Idle: waiting for jump"
                elseif currentEfficiency >= IDLE_THRESHOLD then
                    stuckReason = string.format("Idle: EF >= %.1f%%", IDLE_THRESHOLD)
                elseif not liveIsRunning or currentEfficiency == 0 then
                    stuckReason = "No control: standby"
                end
            end
        end

        sleep(0.05)
    end
end

-- ==================== WAKEUP PULSE TIMER ====================
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

-- ==================== MONITOR UI ====================
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
                monitor.write("Mode: ")
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
                    monitor.write("CRASH")
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
                    monitor.write(string.format("Step: %s | Action: %s", lastAppliedStepText, lastActionMode))
                else
                    monitor.write("Step: -- | No action yet")
                end

                clearLineAt(5)
                monitor.setTextColor(colors.cyan)
                monitor.write("Diag: " .. string.sub(stuckReason, 1, math.max(1, monitorHeight > 30 and 35 or 28)))
                monitor.setTextColor(colors.white)

                clearLineAt(6)
                local currentTicks = POLL_INTERVAL_TICKS * (ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1)
                monitor.write(string.format("Sensor: %dt / %.2fs | Factor x%d%s",
                    currentTicks, currentTicks / 20,
                    ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1,
                    ENABLE_LOW_PERF_MODE and " AUTO" or " FIX"))

                clearLineAt(7)
                monitor.setTextColor(colors.lightGray)
                monitor.write("--- CYCLE LOGS [")
                if ENABLE_MONITOR_LOGS then
                    monitor.setTextColor(colors.green)
                    monitor.write("ON")
                else
                    monitor.setTextColor(colors.red)
                    monitor.write("OFF")
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
                    monitor.write("  (Logs are disabled)")
                    monitor.setTextColor(colors.white)
                end

                if monitorHeight >= 1 then
                    clearLineAt(monitorHeight)
                    monitor.setBackgroundColor(colors.gray)
                    monitor.setTextColor(colors.yellow)
                    monitor.write("[ Click for Page 2: Redstone Log ]")
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

-- ==================== PARALLEL START ====================
parallel.waitForAll(
    backgroundSensorLoop,
    executionLoop,
    uiLoop,
    pulseListenerLoop,
    touchListenerLoop,
    wakeupPulseTimerLoop
)
