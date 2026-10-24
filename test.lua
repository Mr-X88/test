local SCRIPT_VERSION = "v3.499"

-- =====================================================================
-- = USER CONFIGURATION SETTINGS                                       =
-- =====================================================================

-- [Subcategory: General Logs]
local ENABLE_MONITOR_LOGS = false

-- [Subcategory: Redstone Relay Pulse]
-- Modular loop rate (in ticks: 1 tick = 0.05s)
local LOOP_TICK_RATE = 20    -- How often the loop sleeps (e.g., 1 = 0.05s, 2 = 0.1s, 20 = 1s)

-- Pulse settings in LOOP_TICK_RATE ticks
local RELAY_PULSE_DURATION_TICKS = 1   -- ON-time of the pulse in ticks
local RELAY_PULSE_INTERVAL_TICKS = 2   -- Total repetition interval in ticks


-- =====================================================================
-- = INTERNAL SCRIPT VARIABLES & STATES                                =
-- =====================================================================

-- [Subcategory: Peripherals & Hardware Mapping]
local reactor = nil
local monitor = nil
local monitorName = nil
local relay = nil
local monitorWidth = 8
local monitorHeight = 25
local sides = {"top", "bottom", "left", "right", "front", "back"}

-- [Subcategory: Live Sensor Data & Throttled UI Cache]
local liveEF = 0
local liveER = 0
local liveCaseTemp = 0
local monitorCaseTemp = 0
local lastCaseTempMonitorUpdate = nil
local monitorEF = 0
local monitorER = 0
local lastEffErMonitorUpdate = nil
local liveIsRunning = false
local liveDataValid = false
local invalidReadCount = 0

-- [Subcategory: Reactor Control & Execution States]
local controlDirection = 1            -- 1 = + / increase, -1 = - / decrease
local hasEverRun = false
local executionGo = false
local lastPollEF = nil
local unchangedPollCount = 0
local stableExecutionEfficiency = nil
local lastExecutionTime = -3.0
local pendingAction = nil             -- Exactly one action waiting for re-evaluation
local deferredCycleLog = nil          -- Previous completed action; emitted on the next action's follow-up reading
local idleCycleEF = nil
local idleCycleER = nil
local idleSnapshotRefreshPending = false

-- [Subcategory: Wayfinding & Direction Finding]
local directionProbePending = false
local directionKnown = false          -- Confirmed only after an evaluable measurement
local waitingForIdleJump = false

-- [Subcategory: Deadlock & Nudge System]
local stuckPollCount = 0
local lastSensorEFForStuck = nil
local stuckNudgeActive = false
local stuckNudgeCounter = 0
local stuckNudgeBonus = 0

-- [Subcategory: Redstone Relay & Wakeup Pulse Control]
local wakeupPulseActive = false
local tickAccumulator = 0             -- Accurately tracks accumulated ticks

-- [Subcategory: Redstone Input Log Protocol]
local lastBottomState = false
local lastPulseTime = os.clock()
local lastDeltaT = nil
local lastDesiredMultiplier = 1
local pulseCountTotal = 0
local pulseLogHistory = {}

-- [Subcategory: Monitor UI Rendering & Caching]
local currentPage = 1
local lastRenderedPage = nil
local renderedLines = {}
local fullRedraw = true

-- [Subcategory: UI Logging & Diagnostics]
local logCounter = 0
local logHistory = {}
local secondCounter = 0
local secondsSinceLastGo = 0
local lastAppliedStepText = nil
local lastActionMode = "No action yet"
local stuckReason = "Waiting for reactor..."


-- =====================================================================
-- = PERFORMANCE & PRE-CALCULATIONS (Optimized Constants)              =
-- =====================================================================

-- [Subcategory: Timing & Loop Optimization]
-- Pre-calculated values to avoid runtime mathematical operations inside loops
local LOOP_SLEEP_SECONDS = LOOP_TICK_RATE * 0.05


print("==========================================")
print(" BETTER FUSION REACTOR CONTROLLER " .. SCRIPT_VERSION)
print("==========================================")

-- ==================== HELPER FUNCTIONS ====================
local function roundToThree(val)
    if type(val) ~= "number" then return val end
    return math.floor(val * 1000 + 0.5) / 1000
end

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

-- ==================== PERIPHERAL SCAN ====================
local function scanPeripherals()
    reactor = nil
    monitor = nil
    monitorName = nil
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
                monitorName = name
                pcall(function() monitor.setTextScale(0.5) end)
                local okSize, width, height = pcall(function() return monitor.getSize() end)
                if okSize then
                    if type(width) == "number" then monitorWidth = width end
                    if type(height) == "number" then monitorHeight = height end
                end
                print(" -> Color Monitor: " .. name .. " (WxH=" .. monitorWidth .. "x" .. monitorHeight .. ")")
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

local function monitorConnected()
    return monitor ~= nil and monitorName ~= nil and peripheral.isPresent(monitorName)
end

local function monitorLogsEnabled()
    return ENABLE_MONITOR_LOGS and monitorConnected()
end

scanPeripherals()

if not reactor then
    print("[ERROR] No Fusion Reactor Logic Adapter found! Rebooting...")
    sleep(2)
    pcall(os.reboot)
end

if monitorConnected() then pcall(function() monitor.clear() end) end

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
    local isCrashedOrStopped = hasEverRun and (not liveIsRunning or liveEF == 0) and not (liveEF == 0 and liveER == 0)
    local signalValue = isCrashedOrStopped and 15 or 0
    setRelayAll(signalValue, true)
end

local function wakeupPulseTimerLoop()
    while true do
        local isZeroState = liveDataValid and liveEF == 0 and liveER == 0 and hasEverRun

        if isZeroState and relay then
            tickAccumulator = tickAccumulator + LOOP_TICK_RATE

            local currentPhaseTicks = tickAccumulator % RELAY_PULSE_INTERVAL_TICKS

            if currentPhaseTicks < RELAY_PULSE_DURATION_TICKS then
                if not wakeupPulseActive then
                    setRelayAll(15, true)
                    wakeupPulseActive = true
                end
            else
                if wakeupPulseActive then
                    setRelayAll(0, true)
                    wakeupPulseActive = false
                end
            end
        else
            if wakeupPulseActive then
                setRelayAll(0, true)
                wakeupPulseActive = false
            end
            tickAccumulator = 0
            updateCrashRelay()
        end

        sleep(LOOP_SLEEP_SECONDS)
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

    efficiency = roundToThree(efficiency)

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

local function emitDeferredCycleLog(entry, measuredEfficiency, measuredError)
    if not entry or not monitorLogsEnabled() then return end

    if entry.cycleEndEfficiency ~= nil then
        measuredEfficiency = entry.cycleEndEfficiency
        if entry.cycleEndError ~= nil then measuredError = entry.cycleEndError end
    end

    local displayDelta = measuredEfficiency - entry.beforeEfficiency
    local displayDiag

    if entry.usedNudge then
        displayDiag = "Nudge"
    elseif math.abs(displayDelta) >= 16.0 then
        displayDiag = (displayDelta > 0) and "Move right direction" or "Move wrong direction"
    elseif entry.isProbe then
        displayDiag = (displayDelta == 0) and "Runs into a wall (100 or 0) or the effect is not being read correctly " or "TR JUMP Wayfinding"
    elseif displayDelta > 0 then
        displayDiag = "Move uncertain direction"
    elseif displayDelta < 0 then
        displayDiag = "Move Without checking the direction"
    else
        displayDiag = "Runs into a wall (100 or 0) or the effect is not being read correctly"
    end

    local logEfficiency = measuredEfficiency
    if displayDiag == "TR JUMP Wayfinding"
        and isFiniteNumber(entry.followingCycleStartEfficiency) then
        logEfficiency = entry.followingCycleStartEfficiency
    end

    local compactLog = string.format(
        "#%03d %ds %s eff:%.2f->%.2f%% Err:%.0f %s",
        entry.id, entry.cycleSeconds, entry.stepText, entry.beforeEfficiency, logEfficiency,
        measuredError, string.sub(displayDiag, 1, 16)
    )
    table.insert(logHistory, 1, compactLog)

    local maxLogLines = math.max(1, monitorHeight - 8)
    while #logHistory > maxLogLines do table.remove(logHistory) end
end

local function finishPendingAction(postEfficiency, postError, logsAllowed)
    if not pendingAction then return end
    if os.clock() < pendingAction.evaluateAt then return end

    local action = pendingAction
    local delta = postEfficiency - action.beforeEfficiency

    if action.isProbe then
        if delta > 0 then
            controlDirection = action.direction
            directionProbePending = false
            directionKnown = true
            stuckReason = "Direction test: direction confirmed"
        elseif delta < 0 then
            controlDirection = -action.direction
            directionProbePending = false
            directionKnown = true
            stuckReason = "Direction test: opposite direction confirmed"
        else
            controlDirection = -action.direction
            directionProbePending = true
            directionKnown = false
            stuckReason = "Direction unclear: re-probe +/-2 scheduled"
        end

        if postEfficiency >= 95.0 then
            waitingForIdleJump = true
            directionProbePending = false
            directionKnown = false
        end
    else
        if postEfficiency >= 95.0 then
            waitingForIdleJump = true
            directionProbePending = false
            directionKnown = false
            stuckReason = "Idle: waiting for jump"
        elseif delta > 0 then
            controlDirection = action.direction
            directionProbePending = false
            directionKnown = true
            if math.abs(delta) >= 16.0 then
                stuckReason = "Large jump (+): direction maintained"
            else
                stuckReason = "Re-evaluation: efficiency increased, direction kept"
            end
        elseif delta < 0 then
            controlDirection = -action.direction
            directionProbePending = false
            directionKnown = true
            if math.abs(delta) >= 16.0 then
                stuckReason = "Large jump (-): direction reversed"
            else
                stuckReason = "Re-evaluation: efficiency decreased, direction reversed"
            end
        else
            controlDirection = -action.direction
            directionProbePending = true
            directionKnown = false
            stuckReason = "No change: direction test +/-2 scheduled"
        end
    end

    if action.monitorLogsEnabled and logsAllowed then
        if deferredCycleLog then
            emitDeferredCycleLog(deferredCycleLog, postEfficiency, postError)
        end
        deferredCycleLog = {
            id = action.id,
            stepText = action.stepText,
            beforeEfficiency = action.beforeEfficiency,
            cycleSeconds = action.cycleSeconds,
            usedNudge = action.usedNudge,
            isProbe = action.isProbe
        }
    else
        deferredCycleLog = nil
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
            local hasMonitor = monitorConnected()
            local writePulseLogs = hasMonitor and ENABLE_MONITOR_LOGS
            if hasMonitor then
                lastDeltaT = deltaT
                pulseCountTotal = pulseCountTotal + 1
                if pulseCountTotal > 999 then
                    pulseCountTotal = 1
                end
            end

            local desiredMultiplier = lowPerfMultiplier
            local validInterval = deltaT >= 0.05 and deltaT <= 30.0

            if validInterval then
                if deltaT >= 8.0 then
                    desiredMultiplier = 8
                elseif deltaT >= 4.0 then
                    desiredMultiplier = 4
                elseif deltaT >= 2.0 then
                    desiredMultiplier = 2
                else
                    desiredMultiplier = 1
                end

                if hasMonitor then
                    lastDesiredMultiplier = desiredMultiplier
                end

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

            if writePulseLogs then
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
                local maxPulseLines = math.max(1, monitorHeight - 6)
                while #pulseLogHistory > maxPulseLines do table.remove(pulseLogHistory) end
            end
        end

        lastBottomState = bottomNow
    end
end

-- ==================== MONITOR TOUCH LISTENER ====================
local function touchListenerLoop()
    while true do
        local _, _, x, y = os.pullEvent("monitor_touch")
        if monitorConnected() and x and y then
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
end

-- ==================== ADAPTIVE SENSOR LOOP ====================
local lastSensorEF = nil

local function backgroundSensorLoop()
    while true do
        local multiplier = lowPerfMultiplier or 1
        local effectiveTicks = 4 * multiplier
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
                math.abs(eff - previousSensorEfficiency) >= 3.0
            local observedMovement = lastPollEF ~= nil and eff ~= lastPollEF

            if observedMovement then
                idleSnapshotRefreshPending = true
            end

            if observedJump and previousSensorEfficiency ~= nil and eff < previousSensorEfficiency then
                if idleCycleEF ~= nil and deferredCycleLog ~= nil and
                   deferredCycleLog.cycleEndEfficiency == nil then
                    deferredCycleLog.cycleEndEfficiency = idleCycleEF
                    deferredCycleLog.cycleEndError = idleCycleER
                end
            end

            if waitingForIdleJump then
                if observedJump and eff < 95.0 and running and eff > 0 then
                    waitingForIdleJump = false
                    directionProbePending = true
                    directionKnown = false
                    stuckReason = "Idle exited below threshold Wayfinding two-step"
                end
            elseif observedJump and pendingAction == nil and running and eff > 0 and eff < 95.0 then
                if directionKnown then
                    directionProbePending = false
                    if eff > previousSensorEfficiency then
                        stuckReason = "Corrects the eff to 100 direction confirmed from sensor"
                    elseif eff < previousSensorEfficiency then
                        controlDirection = -controlDirection
                        stuckReason = "Corrects It went wrong  direction reversed from sensor"
                    else
                        directionProbePending = true
                        directionKnown = false
                        stuckReason = "TR JUMP ambiguous start Wayfinding two-step"
                    end
                else
                    directionProbePending = true
                    stuckReason = "TR JUMP start Wayfinding two-step"
                end
            end

            if eff >= 95.0 then
                waitingForIdleJump = true
                directionProbePending = false
                directionKnown = false
            end

            if not stuckNudgeActive and running and
               eff > 0 and eff < 95.0 and
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

            local logsAllowed = monitorLogsEnabled()
            if logsAllowed then
                secondCounter = secondCounter + effectiveTicks
                while secondCounter >= 20 do
                    secondCounter = secondCounter - 20
                    secondsSinceLastGo = secondsSinceLastGo + 1
                end
            else
                secondCounter = 0
                secondsSinceLastGo = 0
                deferredCycleLog = nil
            end

            if lastPollEF ~= nil and eff == lastPollEF then
                unchangedPollCount = unchangedPollCount + 1
                if unchangedPollCount >= 2 then
                    executionGo = true
                    stableExecutionEfficiency = eff
                    unchangedPollCount = 0

                    if idleCycleEF == nil or
                       idleSnapshotRefreshPending then
                        idleCycleEF = eff
                        idleCycleER = err
                        idleSnapshotRefreshPending = false
                    end
                end
            else
                unchangedPollCount = 0
                executionGo = false
                stableExecutionEfficiency = nil
            end
            lastPollEF = eff

            if not running or eff == 0 then
                stuckReason = (hasEverRun and eff == 0) and "CRASH detected!" or "Standby"
            elseif directionProbePending then
                stuckReason = directionKnown and "TR JUMP Wayfinding two-step pending " or "Direction unclear Wayfinding two-step pending"
            elseif waitingForIdleJump then
                stuckReason = "Idle waiting for TR JUMP"
            elseif eff >= 95.0 then
                stuckReason = "Idle waiting for TR JUMP"
            else
                if lastSensorEF ~= nil then
                    local delta = eff - lastSensorEF
                    if math.abs(delta) >= 3.0 then
                        stuckReason = (delta < 0) and "Move wrong direction" or "Move right direction"
                    elseif delta > 0 then
                        stuckReason = "eff rising now"
                    elseif delta < 0 then
                        stuckReason = "eff falling now"
                    else
                        stuckReason = "Stalled"
                    end
                else
                    stuckReason = "Init"
                end
            end

            if eff > 0 then lastSensorEF = eff end

            finishPendingAction(eff, err, logsAllowed)
        else
            liveDataValid = false
            executionGo = false
            stableExecutionEfficiency = nil
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
           now - lastExecutionTime >= 3.0 then

            executionGo = false

            local currentEfficiency = stableExecutionEfficiency
            stableExecutionEfficiency = nil
            local errorLevel = liveER
            local probeAction = directionProbePending
            local canControl = liveDataValid and liveIsRunning and currentEfficiency > 0 and
                currentEfficiency < 95.0 and not waitingForIdleJump and
                errorLevel < 100

            if canControl then
                lastExecutionTime = now

                local stepSize
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
                    local hasMonitor = monitorConnected()
                    local actionLogsEnabled = hasMonitor and ENABLE_MONITOR_LOGS
                    local stepText
                    if hasMonitor then
                        local signChar = (actionDirection == 1) and "+" or "-"
                        if probeAction then
                            stepText = "Wf" .. signChar .. "2"
                        else
                            local loggedStrength = actualStrength or effectiveStep
                            stepText = signChar .. formatStep(loggedStrength)
                            if separateNudge and nudgeApplied then stepText = stepText .. "+1" end
                        end
                        lastAppliedStepText = stepText
                        lastActionMode = modeOrError
                    end

                    local actionLogId = nil
                    local actionCycleSeconds = nil
                    if actionLogsEnabled then
                        logCounter = logCounter + 1
                        if logCounter > 999 then
                            logCounter = 1
                        end
                        actionLogId = logCounter
                        actionCycleSeconds = secondsSinceLastGo

                        if deferredCycleLog and
                           deferredCycleLog.followingCycleStartEfficiency == nil then
                            deferredCycleLog.followingCycleStartEfficiency = currentEfficiency
                        end
                    end

                    pendingAction = {
                        id = actionLogId,
                        direction = actionDirection,
                        stepText = stepText,
                        beforeEfficiency = currentEfficiency,
                        evaluateAt = os.clock() + 1.5,
                        cycleSeconds = actionCycleSeconds,
                        monitorLogsEnabled = actionLogsEnabled,
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
                    stuckReason = "Idle waiting for TR JUMP"
                elseif currentEfficiency >= 95.0 then
                    stuckReason = "Idle waiting for TR JUMP"
                elseif not liveIsRunning or currentEfficiency == 0 then
                    stuckReason = "No control standby"
                end
            end
        end

        sleep(0.05)
    end
end

-- ==================== MONITOR UI ====================
local function clearLineAt(y)
    monitor.setCursorPos(1, y)
    monitor.clearLine()
end

local function renderCachedLine(y, painter, painterArg, ...)
    local cached = renderedLines[y]
    local count = select("#", ...)
    local changed = not cached or cached.count ~= count

    if not changed then
        for i = 1, count do
            if cached.values[i] ~= select(i, ...) then
                changed = true
                break
            end
        end
    end

    if not changed then return end

    local values = {}
    for i = 1, count do values[i] = select(i, ...) end
    renderedLines[y] = { count = count, values = values }

    if fullRedraw then
        monitor.setCursorPos(1, y)
    else
        clearLineAt(y)
    end
    painter(painterArg)
end

local function drawPage1Header()
    monitor.setBackgroundColor(colors.blue)
    monitor.setTextColor(colors.white)
    monitor.write(string.format("=== FUSION CONTROL %s %dx%d (1/2) ===", SCRIPT_VERSION, monitorWidth, monitorHeight))
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
end

local function drawPage1Mode()
    monitor.write("Mode: ")
    if not liveDataValid then
        monitor.setTextColor(colors.red)
        monitor.write("SENSOR No feedback ")
    elseif monitorEF >= 95.0 then
        monitor.setTextColor(colors.cyan)
        monitor.write("IDLE ")
    elseif liveIsRunning and monitorEF > 0 then
        monitor.setTextColor(colors.green)
        monitor.write("RUN  ")
    elseif hasEverRun and monitorEF == 0 then
        monitor.setTextColor(colors.red)
        monitor.write("CRASH")
    else
        monitor.setTextColor(colors.orange)
        monitor.write("STAND")
    end
    monitor.setTextColor(colors.white)
    monitor.write(string.format(" | EF: %.2f%%", monitorEF))
end

local function drawPage1Temperature()
    monitor.write(string.format("Case: %.1fM K | ER: ", monitorCaseTemp / 1000000))
    if monitorER > 50 then monitor.setTextColor(colors.red) end
    monitor.write(string.format("%.1f", monitorER))
    monitor.setTextColor(colors.white)
end

local function drawPage1Step()
    if lastAppliedStepText then
        monitor.write(string.format("Step: %s | Action: %s", lastAppliedStepText, lastActionMode))
    else
        monitor.write("Step: -- | No action yet")
    end
end

local function drawPage1Diagnostic()
    monitor.setTextColor(colors.cyan)
    monitor.write("Diag: " .. string.sub(stuckReason, 1, math.max(1, monitorWidth > 30 and 35 or 28)))
    monitor.setTextColor(colors.white)
end

local function drawPage1Sensor()
    local currentTicks = 4 * (lowPerfMultiplier or 1)
    monitor.write(string.format("Sensor: %dt / %.2fs | Factor x%d%s",
        currentTicks, currentTicks / 20, (lowPerfMultiplier or 1), " AUTO"))
end

local function drawPage1LogTitle()
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
end

local function drawPage1LogRow(index)
    if ENABLE_MONITOR_LOGS then
        local line = logHistory[index]
        if line then monitor.write(line) end
    elseif index == 1 then
        monitor.setTextColor(colors.gray)
        monitor.write("  (Logs are disabled)")
        monitor.setTextColor(colors.white)
    end
end

local function drawPage1Footer()
    monitor.setBackgroundColor(colors.gray)
    monitor.setTextColor(colors.yellow)
    monitor.write("[ Click for Page 2: Redstone Log ]")
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
end

local function drawPage2Header()
    monitor.setBackgroundColor(colors.blue)
    monitor.setTextColor(colors.white)
    monitor.write(string.format("=== REDSTONE INPUT LOG %dx%d (2/2) ===", monitorWidth, monitorHeight))
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
end

local function drawPage2PulseSummary()
    monitor.write("Computer-bottom: ")
    if lastBottomState then
        monitor.setTextColor(colors.green)
        monitor.write("AN ")
    else
        monitor.setTextColor(colors.lightGray)
        monitor.write("AUS ")
    end
    monitor.setTextColor(colors.white)
    local dtText = lastDeltaT and string.format("%.3fs", lastDeltaT) or "--"
    monitor.write(string.format("| Pulse: %d | Dt: %s", pulseCountTotal, dtText))
end

local function drawPage2Multiplier()
    local currentMultiplier = lowPerfMultiplier or 1
    local currentTicks = 4 * currentMultiplier
    monitor.write(string.format("Zieltakt: x%d | aktiv: x%d (%dt / %.2fs)",
        lastDesiredMultiplier, currentMultiplier, currentTicks, currentTicks / 20))
end

local function drawPage2LogTitle()
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
end

local function drawPage2LogRow(index)
    if ENABLE_MONITOR_LOGS then
        local line = pulseLogHistory[index]
        if line then monitor.write(line) end
    elseif index == 1 then
        monitor.setTextColor(colors.gray)
        monitor.write("  (Logs sind deaktiviert)")
        monitor.setTextColor(colors.white)
    end
end

local function drawPage2Footer()
    monitor.setBackgroundColor(colors.gray)
    monitor.setTextColor(colors.yellow)
    monitor.write("[ Click for Page 2: Main-UI ]")
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
end

local function uiLoop()
    while true do
        if monitorConnected() then
            if lastRenderedPage ~= currentPage then
                pcall(function() monitor.clear() end)
                lastRenderedPage = currentPage
                renderedLines = {}
                fullRedraw = true
            end

            if currentPage == 1 then
                local now = os.clock()
                if lastCaseTempMonitorUpdate == nil or now - lastCaseTempMonitorUpdate >= 5.0 then
                    monitorCaseTemp = liveCaseTemp
                    lastCaseTempMonitorUpdate = now
                end
                if lastEffErMonitorUpdate == nil or now - lastEffErMonitorUpdate >= 1.0 then
                    monitorEF = liveEF
                    monitorER = liveER
                    lastEffErMonitorUpdate = now
                end

                renderCachedLine(1, drawPage1Header, nil, SCRIPT_VERSION)
                renderCachedLine(2, drawPage1Mode, nil,
                    liveDataValid, monitorEF, liveIsRunning, hasEverRun)
                renderCachedLine(3, drawPage1Temperature, nil, monitorCaseTemp, monitorER)
                renderCachedLine(4, drawPage1Step, nil, lastAppliedStepText or false, lastActionMode)
                renderCachedLine(5, drawPage1Diagnostic, nil, stuckReason, monitorHeight)
                renderCachedLine(6, drawPage1Sensor, nil, lowPerfMultiplier)
                renderCachedLine(7, drawPage1LogTitle, nil, ENABLE_MONITOR_LOGS)

                local maxLogLines = monitorHeight - 8
                for i = 1, maxLogLines do
                    renderCachedLine(7 + i, drawPage1LogRow, i,
                        ENABLE_MONITOR_LOGS, logHistory[i] or false)
                end

                renderCachedLine(monitorHeight, drawPage1Footer, nil, monitorHeight)
            else
                renderCachedLine(1, drawPage2Header, nil, SCRIPT_VERSION)
                renderCachedLine(3, drawPage2PulseSummary, nil,
                    lastBottomState, pulseCountTotal, lastDeltaT or false)
                renderCachedLine(4, drawPage2Multiplier, nil,
                    lastDesiredMultiplier, lowPerfMultiplier)
                renderCachedLine(5, drawPage2LogTitle, nil, ENABLE_MONITOR_LOGS)

                local maxPulseLines = monitorHeight - 6
                for i = 1, maxPulseLines do
                    renderCachedLine(5 + i, drawPage2LogRow, i,
                        ENABLE_MONITOR_LOGS, pulseLogHistory[i] or false)
                end

                renderCachedLine(monitorHeight, drawPage2Footer, nil, monitorHeight)
            end
            fullRedraw = false
        else
            if lastRenderedPage ~= nil then
                lastRenderedPage = nil
                renderedLines = {}
                fullRedraw = true
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
