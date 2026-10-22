-- ============================================================
-- BETTER FUSION REACTOR CONTROLLER v3.22
-- v3.22: Monitor rows are redrawn only when their displayed inputs change.
--         Preserves the 0.25s UI check while avoiding repeat formatting and terminal writes.
-- v3.21: Defaults monitor logs to OFF and gates monitor/log work on a connected monitor.
-- Changes in v3.18:
--   * Removes unused calculation helper and dead state/log fields.
--   * Inlines immutable settings except SCRIPT_VERSION and ENABLE_MONITOR_LOGS.
--   * Retains the one-time fixed relay-side list; removes redundant local state.
--   * Keeps control decisions, sensor timing, stability checks, and log behavior unchanged.
-- Preserves v3.17 cycle-end EF/ER snapshot behavior and Jump diagnostic labels.
-- v3.20 pairs TR JUMP Wayfinding only with the immediately adjacent rendered Jump (+) row.
-- ============================================================
local SCRIPT_VERSION = "v3.22"

local reactor = nil
local monitor = nil
local monitorName = nil
local relay = nil
local monitorHeight = 25
local sides = {"top", "bottom", "left", "right", "front", "back"}

-- ==================== SETTINGS ====================

local lowPerfMultiplier = 1
local pulseTargetMultiplier = 1
local pulseStreakCount = 0

local ENABLE_MONITOR_LOGS = false

-- ==================== CONTROL VARIABLES ====================
local controlDirection = 1           -- 1 = + / increase, -1 = - / decrease
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
local lastExecutionTime = -3.0
local pendingAction = nil           -- Exactly one action waiting for re-evaluation
local deferredCycleLog = nil        -- Previous completed action; emitted on the next action's follow-up reading
local lastEmittedLogDiag = nil       -- Diagnostic of the row currently directly below the next inserted row
local lastEmittedLogStartEF = nil     -- Start EF of that row, used only for exact TR/Jump log pairing
-- Settled EF/ER snapshot. Refreshed only after the existing EF stability check succeeds.
-- Kept until the next idle jump so the deferred log can report the pre-jump cycle end.
local idleCycleEF = nil
local idleCycleER = nil
local idleSnapshotRefreshPending = false

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
local renderedLines = {}
local fullRedraw = true

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

-- A wrapped monitor can remain as a stale Lua object after it is unplugged.
-- Check presence before doing monitor-only work or attempting to render.
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
    local isCrashedOrStopped = hasEverRun and (not liveIsRunning or liveEF == 0)
    local signalValue = isCrashedOrStopped and 15 or 0
    setRelayAll(signalValue, true)
end

local function sendWakeupPulseStart()
    if not relay then
        stuckReason = "Wakeup pulse: no relay"
        return false
    end
    local ok = setRelayAll(15, true)
    if not ok then
        stuckReason = "Wakeup pulse: relay error"
        return false
    end
    wakeupPulseActive = true
    wakeupPulseEndsAt = os.clock() + (10 * 0.05)
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

    -- High-precision rounding to 3 decimal places for EF
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

-- Emit the previous action's log using the current cycle's follow-up EF/ER.
-- This intentionally shifts visible log output by one completed action.
local function emitDeferredCycleLog(entry, measuredEfficiency, measuredError)
    if not entry or not monitorLogsEnabled() then return end

    -- For an idle-jump cycle, use the settled EF/ER captured before the jump.
    if entry.cycleEndEfficiency ~= nil then
        measuredEfficiency = entry.cycleEndEfficiency
        if entry.cycleEndError ~= nil then measuredError = entry.cycleEndError end
    end

    local displayDelta = measuredEfficiency - entry.beforeEfficiency
    local displayDiag

    if entry.usedNudge then
        displayDiag = "Nudge"
    elseif math.abs(displayDelta) >= 16.0 then
        displayDiag = (displayDelta > 0) and "Jump (+)" or "Jump (-)"
    elseif entry.isProbe then
        displayDiag = (displayDelta == 0) and "Test?" or "TR JUMP Wayfinding"
    elseif displayDelta > 0 then
        displayDiag = "+"
    elseif displayDelta < 0 then
        displayDiag = "Falling"
    else
        displayDiag = "Stable"
    end

    -- Logs are inserted at the top of logHistory. Therefore the previously
    -- emitted row becomes the row directly below this new row. Pair a TR JUMP
    -- Wayfinding row only with that immediately adjacent Jump (+) row; never
    -- reuse a stale Jump value from several rows earlier.
    -- This changes only the displayed second EF, not sensor/control values.
    local logEfficiency = measuredEfficiency
    if displayDiag == "TR JUMP Wayfinding"
        and lastEmittedLogDiag == "Jump (+)"
        and lastEmittedLogStartEF ~= nil then
        logEfficiency = lastEmittedLogStartEF
    end

    local compactLog = string.format(
        "#%03d St:%s Eff:%.2f->%.2f%% Err:%.0f(%ds) %s",
        entry.id, entry.stepText, entry.beforeEfficiency, logEfficiency,
        measuredError, entry.cycleSeconds, string.sub(displayDiag, 1, 12)
    )
    table.insert(logHistory, 1, compactLog)

    -- Track only the row just inserted. Reset the EF for every other row so
    -- an unrelated Jump (+) cannot be incorrectly reused later.
    lastEmittedLogDiag = displayDiag
    lastEmittedLogStartEF = (displayDiag == "Jump (+)") and entry.beforeEfficiency or nil
    local maxLogLines = math.max(1, math.min(monitorHeight - 9, 18))
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
            stuckReason = "Idle >= 95.0%: waiting for jump"
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

    -- The displayed cycle log is one action behind by design:
    -- emit the previously saved row with this current follow-up measurement,
    -- then save this action for display when the next action has a follow-up reading.
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
        lastEmittedLogDiag = nil
        lastEmittedLogStartEF = nil
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
                local maxPulseLines = math.max(1, math.min(monitorHeight - 7, 18))
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
        stopWakeupPulseIfDue()

        local multiplier = lowPerfMultiplier
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

            -- Any EF movement requires a fresh snapshot after the same existing
            -- stability check succeeds. Do not attach the old snapshot here:
            -- an ordinary step toward the peak is not the end-of-cycle jump.
            if observedMovement then
                idleSnapshotRefreshPending = true
            end

            -- A falling jump marks the end of the previously settled cycle.
            -- Preserve its last stable snapshot without requiring EF >= 95%.
            -- Rising jumps must not pin the older, lower value to this log row.
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
                    stuckReason = "Idle exited below threshold: direction test +/-2"
                end
            elseif observedJump and pendingAction == nil and running and eff > 0 and eff < 95.0 then
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
                lastEmittedLogDiag = nil
                lastEmittedLogStartEF = nil
            end

            if lastPollEF ~= nil and eff == lastPollEF then
                unchangedPollCount = unchangedPollCount + 1
                if unchangedPollCount >= 2 then
                    executionGo = true
                    stableExecutionEfficiency = eff
                    unchangedPollCount = 0

                    -- Snapshot follows the existing unchanged-EF stability check;
                    -- EF does not have to be >= 95.0 to be saved.
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

            if eff == 0 and err == 0 then
                wakeupTickCounter = wakeupTickCounter + effectiveTicks
                if wakeupTickCounter >= 40 and not wakeupPulseActive then
                    wakeupTickCounter = wakeupTickCounter - 40
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
                stuckReason = "Idle >= 95.0%: waiting for jump"
            elseif eff >= 95.0 then
                stuckReason = "Idle: EF >= 95.0%"
            else
                if lastSensorEF ~= nil then
                    local delta = eff - lastSensorEF
                    if math.abs(delta) >= 3.0 then
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
        -- POINT A FIX: Strictly enforce 3.0 regardless of executionGo
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
                        actionLogId = logCounter
                        actionCycleSeconds = secondsSinceLastGo
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
                    stuckReason = "Idle: waiting for jump"
                elseif currentEfficiency >= 95.0 then
                    stuckReason = "Idle: EF >= 95.0%"
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

-- Compares the values that determine a row's visible content. Formatting and
-- monitor API calls happen only when at least one of these values changes.
-- Painter functions are defined once (not created in the 0.25s loop) to avoid
-- per-refresh closure allocations.
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
    monitor.write(string.format("=== FUSION CONTROL %s (1/2) ===", SCRIPT_VERSION))
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
end

local function drawPage1Mode()
    monitor.write("Mode: ")
    if not liveDataValid then
        monitor.setTextColor(colors.red)
        monitor.write("SENSOR? ")
    elseif liveEF >= 95.0 then
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
    monitor.write(string.format(" | EF: %.2f%%", liveEF))
end

local function drawPage1Temperature()
    monitor.write(string.format("Case: %.1fM K | ER: ", liveCaseTemp / 1000000))
    if liveER > 50 then monitor.setTextColor(colors.red) end
    monitor.write(string.format("%.1f", liveER))
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
    monitor.write("Diag: " .. string.sub(stuckReason, 1, math.max(1, monitorHeight > 30 and 35 or 28)))
    monitor.setTextColor(colors.white)
end

local function drawPage1Sensor()
    local currentTicks = 4 * lowPerfMultiplier
    monitor.write(string.format("Sensor: %dt / %.2fs | Factor x%d%s",
        currentTicks, currentTicks / 20, lowPerfMultiplier, " AUTO"))
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
    monitor.write("=== REDSTONE INPUT LOG (2/2) ===")
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
    local currentTicks = 4 * lowPerfMultiplier
    monitor.write(string.format("Zieltakt: x%d | aktiv: x%d (%dt / %.2fs)",
        lastDesiredMultiplier, lowPerfMultiplier, currentTicks, currentTicks / 20))
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
    monitor.write("[ Klick für Seite 1: Haupt-UI ]")
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
                renderCachedLine(1, drawPage1Header, nil, SCRIPT_VERSION)
                renderCachedLine(2, drawPage1Mode, nil,
                    liveDataValid, liveEF, liveIsRunning, hasEverRun)
                renderCachedLine(3, drawPage1Temperature, nil, liveCaseTemp, liveER)
                renderCachedLine(4, drawPage1Step, nil, lastAppliedStepText or false, lastActionMode)
                renderCachedLine(5, drawPage1Diagnostic, nil, stuckReason, monitorHeight)
                renderCachedLine(6, drawPage1Sensor, nil, lowPerfMultiplier)
                renderCachedLine(7, drawPage1LogTitle, nil, ENABLE_MONITOR_LOGS)

                local maxLogLines = math.max(1, monitorHeight - 9)
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

                local maxPulseLines = math.max(1, math.min(monitorHeight - 7, 18))
                for i = 1, maxPulseLines do
                    renderCachedLine(5 + i, drawPage2LogRow, i,
                        ENABLE_MONITOR_LOGS, pulseLogHistory[i] or false)
                end

                renderCachedLine(monitorHeight, drawPage2Footer, nil, monitorHeight)
            end
            fullRedraw = false
        else
            -- Force a clean redraw if the monitor is disconnected and later returns.
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
