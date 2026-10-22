-- v3.02 OVERSHOOT-AWARE LEARNING CURVE:
--   * Neue Grundformel: etwas kräftiger im niedrigen/mittleren EF-Bereich,
--     etwas feiner nahe 95%.
--   * Koeffizienten A/B werden aus zuverlässigen Nachmessungen per gedämpftem Fit angepasst.
--   * Gelernte Koeffizienten und Stichproben werden in bfr_adaptive_curve.dat gespeichert.
--   * Größere Sprünge (möglicher TR-Wechsel), Richtungstests und Nudge-Schritte
--     werden nicht zum Lernen verwendet.
--   * EF-Snapshot, ACTION_EVAL_DELAY, EXECUTION_COOLDOWN und Sensor-Takt bleiben.
-- ============================================================
-- BETTER FUSION REACTOR CONTROLLER v3.02 OVERSHOOT-AWARE LEARNING CURVE
-- Basis: v2.96; beibehaltene Änderungen:
--   * Sensor-Sprünge nutzen bei bekannter Richtung die 4t-Messung statt pauschal TEST +/-2.
--   * TEST +/-2 wird nur verwendet, wenn die Richtung unbekannt ist oder eine Messung unverändert bleibt.
--   * Nach Idle >= 95% wird auf einen echten Sprung gewartet, bevor der Richtungstest erfolgt.
--   * Lernkurve: Step=K*(A*x+B*x^2), x=(100-EF)/100; Kurve auf Monitorseite 3.
--   * EF-Peaks >100 werden auch nach ACTION_EVAL_DELAY überwacht; bei bestätigtem Rückgang
--     wird K reduziert statt ein größerer Schritt gelernt. Cooldown bleibt unverändert.
-- Änderungen in v2.97 TEST:
--   * Obergrenze 15 bei direkter adjustReactivity()-Steuerung entfernt.
--   * Redstone-Fallback bleibt korrekt auf 15 begrenzt (CC:Tweaked-Redstone-Limit).
--   * Logs zeigen bei Relay-Fallback die tatsächlich verwendete Stärke.
-- Änderungen in v2.98 TEST:
--   * Direkte adjustReactivity()-Aufrufe behalten Dezimalstellen (auf 2 Stellen gerundet).
--   * calculateStep() gibt Dezimalschritte zurück statt auf ganze Zahlen zu runden.
--   * Der Redstone-Fallback rundet weiterhin auf eine ganze Signalstärke von 1 bis 15.
--   * Monitor/Logs formatieren Schrittwerte kompakt, z.B. +0.82 statt +1.
-- ============================================================
local SCRIPT_VERSION = "v3.02 OVERSHOOT-AWARE"

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
local EXECUTION_COOLDOWN = 3.0       -- Unverändert: Mindestpause zwischen Regelschritten
local ACTION_EVAL_DELAY = 1.5        -- Unverändert: Nachmessung nach einer Korrektur

-- Selbstlernende Verhaltenskurve.
-- x = (100 - EF) / 100; Startmodell ist äquivalent zu 0.12*d + 0.0048*d^2.
-- A und B werden aus bestätigten, kleinen, direkt ausgeführten Regelaktionen geschätzt.
local BASE_LINEAR_COEFF = 12.0
local BASE_QUADRATIC_COEFF = 48.0
local LINEAR_COEFF_MIN, LINEAR_COEFF_MAX = 4.0, 24.0
local QUADRATIC_COEFF_MIN, QUADRATIC_COEFF_MAX = 16.0, 80.0
local COEFF_FIT_BLEND = 0.20          -- nur 20% des neuen Fits übernehmen (Dämpfung)
local COEFF_PRIOR_WEIGHT = 4.0        -- hält die Schätzung nahe am Startmodell, solange Daten knapp sind
local MIN_FIT_SAMPLES = 4
local MIN_FIT_X_SPAN = 0.12
local MAX_LEARNING_SAMPLES = 32
local LEARNING_FILE = "bfr_adaptive_curve.dat"
local EXPECTED_GAIN_RATIO = 0.22
local EXPECTED_GAIN_MIN = 1.0
local EXPECTED_GAIN_MAX = 12.0

-- Überschwing-Schutz: EF-Spitzen über 100% gelten niemals als Beleg,
-- dass ein größerer Schritt nötig wäre. Stattdessen wird die Gesamtschrittweite
-- vorsichtig reduziert. K wird separat gespeichert, damit der normale Fit sie
-- nicht beim nächsten Lernpunkt sofort wieder hochzieht.
local OVERSHOOT_TARGET_EF = 100.0
local OVERSHOOT_SCALE_MIN = 0.35
local OVERSHOOT_SCALE_DEFAULT = 1.0
local OVERSHOOT_DROP_CONFIRM = 1.0       -- EF muss mindestens 1 Punkt vom Peak fallen
local OVERSHOOT_ACTION_WINDOW = 6.0     -- ordnet den Peak einer kürzlich gesendeten Direktkorrektur zu
local OVERSHOOT_LEARNING_LOCK = 6.0     -- nach Überschwingen vorübergehend keine Lernpunkte aufnehmen

local ENABLE_WAKEUP_PULSE = true
local WAKEUP_INTERVAL_TICKS = 40     -- Alle 2 Sekunden
local WAKEUP_PULSE_TICKS = 10        -- 0,5 Sekunden
local WAKEUP_STRENGTH = 15

local ENABLE_MONITOR_LOGS = true

local sides = {"top", "bottom", "left", "right", "front", "back"}

-- ==================== REGELUNGSVARIABLEN ====================
local controlDirection = 1           -- 1 = + / erhöhen, -1 = - / senken
local stepSize = 4
local coefficientLinear = BASE_LINEAR_COEFF
local coefficientQuadratic = BASE_QUADRATIC_COEFF
local overshootScale = OVERSHOOT_SCALE_DEFAULT
local overshootEvents = 0
local lastSuccessfulControlAt = nil
local lastSuccessfulControlBeforeEF = nil
local lastSuccessfulControlStrength = nil
local lastActionEligibleForOvershoot = false
local overshootEpisodeActive = false
local overshootEpisodePeak = nil
local overshootEpisodeStartEF = nil
local overshootEpisodePenaltyApplied = false
local learningLockUntil = 0
local learningSamples = {}
local learningUpdateCount = 0
local lastLearnStatus = "Startmodell; warte auf gültige Daten"
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
-- Snapshot des letzten EF-Werts, der nach zwei unveränderten Sensorintervallen
-- bestätigt wurde. Die Signalstärke wird genau aus diesem Wert berechnet.
local stableExecutionEfficiency = nil
local stableExecutionAt = nil
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

local function clampNumber(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function loadLearningModel()
    if not fs or not textutils or not fs.exists(LEARNING_FILE) then return end
    local handle = fs.open(LEARNING_FILE, "r")
    if not handle then return end
    local contents = handle.readAll()
    handle.close()

    local ok, saved = pcall(function() return textutils.unserialize(contents) end)
    if not ok or type(saved) ~= "table" then return end

    if isFiniteNumber(saved.a) then
        coefficientLinear = clampNumber(saved.a, LINEAR_COEFF_MIN, LINEAR_COEFF_MAX)
    end
    if isFiniteNumber(saved.b) then
        coefficientQuadratic = clampNumber(saved.b, QUADRATIC_COEFF_MIN, QUADRATIC_COEFF_MAX)
    end
    if isFiniteNumber(saved.k) then
        overshootScale = clampNumber(saved.k, OVERSHOOT_SCALE_MIN, OVERSHOOT_SCALE_DEFAULT)
    end
    if type(saved.overshoots) == "number" and saved.overshoots >= 0 then
        overshootEvents = math.floor(saved.overshoots)
    end
    if type(saved.updates) == "number" and saved.updates >= 0 then
        learningUpdateCount = math.floor(saved.updates)
    end
    if type(saved.samples) == "table" then
        learningSamples = {}
        for _, point in ipairs(saved.samples) do
            if type(point) == "table" and isFiniteNumber(point.x)
                and isFiniteNumber(point.eff) and isFiniteNumber(point.delta)
                and isFiniteNumber(point.step) and isFiniteNumber(point.targetStep)
                and point.x > 0 and point.x <= 1 and point.step > 0 and point.targetStep > 0 then
                table.insert(learningSamples, {
                    x = point.x,
                    eff = point.eff,
                    delta = point.delta,
                    step = point.step,
                    targetStep = point.targetStep
                })
                if #learningSamples >= MAX_LEARNING_SAMPLES then break end
            end
        end
    end
end

local function saveLearningModel()
    if not fs or not textutils then return false end
    local data = {
        version = 1,
        a = coefficientLinear,
        b = coefficientQuadratic,
        k = overshootScale,
        overshoots = overshootEvents,
        updates = learningUpdateCount,
        samples = learningSamples
    }
    local ok, contents = pcall(function() return textutils.serialize(data) end)
    if not ok or type(contents) ~= "string" then return false end
    local handle = fs.open(LEARNING_FILE, "w")
    if not handle then return false end
    handle.write(contents)
    handle.close()
    return true
end

loadLearningModel()

local function applyOvershootPenalty(peakEF, startEF)
    local amountAbove100 = math.max(0, peakEF - OVERSHOOT_TARGET_EF)
    local riseFromStart = (startEF and peakEF - startEF) or 0
    local penalty = clampNumber(0.92 - 0.015 * amountAbove100, 0.65, 0.92)

    -- Ein sehr großer Gesamtanstieg kann auch stark durch TR verursacht sein.
    -- In diesem Fall nur vorsichtig dämpfen, nie aus dem Ereignis heraus vergrößern.
    if riseFromStart >= LOG_JUMP_THRESHOLD then
        penalty = math.max(penalty, 0.96)
    end

    local oldScale = overshootScale
    overshootScale = clampNumber(overshootScale * penalty, OVERSHOOT_SCALE_MIN, OVERSHOOT_SCALE_DEFAULT)
    overshootEvents = overshootEvents + 1
    learningUpdateCount = learningUpdateCount + 1
    learningLockUntil = os.clock() + OVERSHOOT_LEARNING_LOCK
    lastLearnStatus = string.format(
        "EF-Peak %.2f%%, dann Rueckgang; K %.3f->%.3f, kein Hochlernen",
        peakEF, oldScale, overshootScale)
    saveLearningModel()
end

local function observeOvershootCycle(eff)
    local now = os.clock()

    if eff > OVERSHOOT_TARGET_EF then
        -- Einen Peak nur dann dem Lernmodell zurechnen, wenn zuvor kürzlich eine
        -- reguläre direkte Korrektur gesendet wurde. Probe-Schritte zählen nicht.
        if not overshootEpisodeActive then
            local recentEligibleAction = lastActionEligibleForOvershoot and
                lastSuccessfulControlAt ~= nil and
                (now - lastSuccessfulControlAt) <= OVERSHOOT_ACTION_WINDOW
            if recentEligibleAction then
                overshootEpisodeActive = true
                overshootEpisodePeak = eff
                overshootEpisodeStartEF = lastSuccessfulControlBeforeEF
                overshootEpisodePenaltyApplied = false
            end
        elseif eff > (overshootEpisodePeak or eff) then
            overshootEpisodePeak = eff
        end
    elseif overshootEpisodeActive then
        if eff > (overshootEpisodePeak or eff) then
            overshootEpisodePeak = eff
        end
        if not overshootEpisodePenaltyApplied and overshootEpisodePeak and
           eff <= (overshootEpisodePeak - OVERSHOOT_DROP_CONFIRM) then
            applyOvershootPenalty(overshootEpisodePeak, overshootEpisodeStartEF)
            overshootEpisodePenaltyApplied = true
        end
        -- Eine EF-Phase über 100% wird als eine Episode behandelt. Erst beim
        -- Rückgang unter IDLE_THRESHOLD kann eine neue Episode gestartet werden.
        if eff < IDLE_THRESHOLD then
            overshootEpisodeActive = false
            overshootEpisodePeak = nil
            overshootEpisodeStartEF = nil
            overshootEpisodePenaltyApplied = false
        end
    end
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

-- ==================== SELBSTLERNENDE REGELSCHRITT-FORMEL ====================
local function calculateStep(currentEff)
    -- Normierte Formel: Step = K * (A*x + B*x^2), x=max(0,100-EF)/100.
    -- Wenn EF über 100% lag, wird das NICHT als Grund für größere Schritte
    -- interpretiert. Die separate Skala K wird bei erkanntem Überschwingen gesenkt.
    local difference = math.max(0, OVERSHOOT_TARGET_EF - currentEff)
    local x = difference / 100
    local rawStep = overshootScale * ((coefficientLinear * x) + (coefficientQuadratic * x * x))
    local calculatedStep = math.floor(rawStep * 100 + 0.5) / 100
    if calculatedStep < 0.01 then calculatedStep = 0.01 end
    return calculatedStep
end

local function fitCoefficients()
    if #learningSamples < MIN_FIT_SAMPLES then return false, "zu wenige Lernpunkte" end

    local minX, maxX = math.huge, -math.huge
    local s11, s12, s22 = 0, 0, 0
    local t1, t2 = 0, 0
    for _, point in ipairs(learningSamples) do
        local x = point.x
        local x2 = x * x
        local y = point.targetStep
        if x < minX then minX = x end
        if x > maxX then maxX = x end
        s11 = s11 + x * x
        s12 = s12 + x * x2
        s22 = s22 + x2 * x2
        t1 = t1 + x * y
        t2 = t2 + x2 * y
    end

    -- Bei zu engem Effizienzbereich sind A und B rechnerisch kaum trennbar.
    if (maxX - minX) < MIN_FIT_X_SPAN then return false, "EF-Bereich zu eng" end

    -- Ridge-Regularisierung zum Startmodell, damit wenige/rauschende Daten
    -- nicht die Koeffizienten sprunghaft verändern.
    s11 = s11 + COEFF_PRIOR_WEIGHT
    s22 = s22 + COEFF_PRIOR_WEIGHT
    t1 = t1 + COEFF_PRIOR_WEIGHT * BASE_LINEAR_COEFF
    t2 = t2 + COEFF_PRIOR_WEIGHT * BASE_QUADRATIC_COEFF

    local determinant = s11 * s22 - s12 * s12
    if determinant <= 0.0000001 then return false, "Fit instabil" end

    local fitA = (t1 * s22 - t2 * s12) / determinant
    local fitB = (s11 * t2 - s12 * t1) / determinant
    if not isFiniteNumber(fitA) or not isFiniteNumber(fitB) then
        return false, "Fit ungültig"
    end

    fitA = clampNumber(fitA, LINEAR_COEFF_MIN, LINEAR_COEFF_MAX)
    fitB = clampNumber(fitB, QUADRATIC_COEFF_MIN, QUADRATIC_COEFF_MAX)
    local oldA, oldB = coefficientLinear, coefficientQuadratic
    coefficientLinear = clampNumber(
        oldA * (1 - COEFF_FIT_BLEND) + fitA * COEFF_FIT_BLEND,
        LINEAR_COEFF_MIN, LINEAR_COEFF_MAX)
    coefficientQuadratic = clampNumber(
        oldB * (1 - COEFF_FIT_BLEND) + fitB * COEFF_FIT_BLEND,
        QUADRATIC_COEFF_MIN, QUADRATIC_COEFF_MAX)

    if math.abs(coefficientLinear - oldA) + math.abs(coefficientQuadratic - oldB) < 0.0001 then
        return true, "Koeffizienten stabil"
    end
    return true, "Fit aktualisiert"
end

local function learnCoefficients(action, delta, postEfficiency, observedPeakEfficiency)
    -- Überschwingen wird VOR allen Idle-/Positivgewinn-Filtern behandelt.
    -- Dadurch kann EF >100% niemals in die normale Lernregel "zu wenig Gewinn -> mehr Schritt"
    -- gelangen. Die Spitze wird während des gesamten Nachmessfensters verfolgt.
    local peakEF = observedPeakEfficiency or postEfficiency
    if not isFiniteNumber(peakEF) then peakEF = postEfficiency end
    local trackedOvershoot = action.directAPI and not action.isProbe and not action.usedNudge
        and action.beforeEfficiency < IDLE_THRESHOLD and peakEF > OVERSHOOT_TARGET_EF
    if trackedOvershoot then
        -- Dieser Aktionsdatensatz wird ausgeschlossen. Der separate Sensor-Wächter
        -- senkt K erst dann einmalig, wenn er den Rückgang vom >100%-Peak bestätigt.
        -- So wird ein kurz überschrittener EF-Peak nicht als "zu wenig Wirkung" gelernt.
        lastLearnStatus = string.format("Peak %.2f%% >100: kein Hochlernen; warte auf Rueckgang", peakEF)
        return "OVERSHOOT"
    end
    if os.clock() < learningLockUntil then
        lastLearnStatus = "Lernen pausiert nach EF-Ueberschwingen"
        return "skip"
    end

    -- Nur Daten verwenden, bei denen ein sinnvoller direkter Wirkungshinweis vorliegt.
    -- TR wechselt zufällig; daher Sprünge, Richtungstests, Nudge und Relay-Fallback auslassen.
    if action.isProbe then
        lastLearnStatus = "Ignoriert: Richtungstest"
        return "skip"
    end
    if action.usedNudge then
        lastLearnStatus = "Ignoriert: Nudge"
        return "skip"
    end
    if not action.directAPI then
        lastLearnStatus = "Ignoriert: kein Direkt-API-Schritt"
        return "skip"
    end
    if math.abs(delta) >= LOG_JUMP_THRESHOLD then
        lastLearnStatus = "Ignoriert: großer Sprung/TR-Verdacht"
        return "skip"
    end
    if action.beforeEfficiency >= IDLE_THRESHOLD or postEfficiency >= IDLE_THRESHOLD then
        lastLearnStatus = "Ignoriert: Idle-Bereich"
        return "skip"
    end
    if delta <= 0 then
        lastLearnStatus = (delta == 0) and "Ignoriert: keine Wirkung" or "Ignoriert: Richtung/Trend negativ"
        return "skip"
    end

    local usedStep = action.requestedStrength
    if not isFiniteNumber(usedStep) or usedStep <= 0 then
        lastLearnStatus = "Ignoriert: Schrittstärke ungültig"
        return "skip"
    end

    local gap = math.max(0, IDLE_THRESHOLD - action.beforeEfficiency)
    local expectedGain = clampNumber(gap * EXPECTED_GAIN_RATIO, EXPECTED_GAIN_MIN, EXPECTED_GAIN_MAX)
    -- Zielschritt aus der gemessenen Wirkung ableiten, aber pro Datensatz nur um +/-25% ändern.
    local ratio = clampNumber(expectedGain / math.max(delta, 0.25), 0.75, 1.25)
    local targetStep = usedStep * ratio
    local x = clampNumber((100 - action.beforeEfficiency) / 100, 0.001, 1.0)
    local oldPrediction = coefficientLinear * x + coefficientQuadratic * x * x

    table.insert(learningSamples, 1, {
        x = x,
        eff = action.beforeEfficiency,
        delta = delta,
        step = usedStep,
        targetStep = targetStep
    })
    while #learningSamples > MAX_LEARNING_SAMPLES do table.remove(learningSamples) end
    learningUpdateCount = learningUpdateCount + 1

    local fitted, reason = fitCoefficients()
    local newPrediction = coefficientLinear * x + coefficientQuadratic * x * x
    local result = "sample"
    if fitted then
        if newPrediction > oldPrediction + 0.01 then
            result = "FIT+"
        elseif newPrediction < oldPrediction - 0.01 then
            result = "FIT-"
        else
            result = "FIT="
        end
        lastLearnStatus = string.format("%s; A=%.2f B=%.2f; N=%d", result,
            coefficientLinear, coefficientQuadratic, #learningSamples)
    else
        lastLearnStatus = string.format("Lernpunkt %d/%d (%s)", #learningSamples,
            MIN_FIT_SAMPLES, reason)
    end
    saveLearningModel()
    return result
end

local function formatStep(value)
    local text = string.format("%.2f", value)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

local function applyControlAction(direction, strength, separateNudge, nudgeIncluded)
    if not isFiniteNumber(strength) then
        return false, "Ungültige Schrittstärke", false, nil
    end

    -- Für die direkte API Dezimalstellen behalten; nur auf 2 Nachkommastellen runden.
    strength = math.max(0.01, math.floor(strength * 100 + 0.5) / 100)
    local nudgeApplied = nudgeIncluded == true

    -- Zuerst die direkte Mod-API versuchen: hier wird KEINE 15er-Obergrenze angewendet.
    if reactor and type(reactor.adjustReactivity) == "function" then
        local mainOK = pcall(function() reactor.adjustReactivity(direction * strength) end)
        if mainOK then
            if separateNudge then
                local nudgeOK = pcall(function() reactor.adjustReactivity(direction) end)
                if nudgeOK then
                    nudgeApplied = true
                else
                    return true, "Direkt unlimitiert (Nudge-Fehler)", false, strength
                end
            end
            return true, nudgeApplied and "Direkt unlimitiert +Nudge" or "Direkt unlimitiert", nudgeApplied, strength
        end
    end

    -- Nur der Redstone-Fallback bleibt auf 0..15 begrenzt.
    if not relay then
        return false, "Keine Direktsteuerung / kein Relay", false, nil
    end
    if type(relay.setAnalogOutput) ~= "function" then
        return false, "Relay kann keine analoge Schrittstärke senden", false, nil
    end

    -- Redstone-Analogausgänge erwarten hier eine ganzzahlige Stärke von 1 bis 15.
    local relayStrength = math.max(1, math.min(15, math.floor(strength + 0.5)))
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

    if not relayPulse(relayStrength) then
        setRelayAll(0, false)
        return false, "Relay-Ausgabe fehlgeschlagen", false, nil
    end

    if separateNudge then
        if relayPulse(1) then
            nudgeApplied = true
        else
            local relayMode = (strength > 15) and "Relay 15 (Nudge-Fehler)" or "Relay-Puls (Nudge-Fehler)"
            return true, relayMode, false, relayStrength
        end
    end

    local relayMode
    if strength > 15 then
        relayMode = nudgeApplied and "Relay 15 +Nudge (begrenzt)" or "Relay 15 (API fehlgeschlagen; begrenzt)"
    else
        relayMode = nudgeApplied and "Relay-Puls +Nudge" or "Relay-Puls"
    end
    return true, relayMode, nudgeApplied, relayStrength
end

local function finishPendingAction(postEfficiency, postError)
    if not pendingAction then return end
    if os.clock() < pendingAction.evaluateAt then return end

    local action = pendingAction
    local delta = postEfficiency - action.beforeEfficiency
    local peakEfficiency = action.peakEfficiencyDuringAction or math.max(action.beforeEfficiency, postEfficiency)
    local cycleDiag = "Stillstand"
    local directNonProbe = action.directAPI and not action.isProbe
    local crossedOver100 = directNonProbe and action.beforeEfficiency < IDLE_THRESHOLD
        and peakEfficiency > OVERSHOOT_TARGET_EF

    if crossedOver100 then
        -- EF-Spitze über 100% ist ein Überschwingen, kein Signal, stärker nachzulegen.
        -- Vorsorglich die Richtung umkehren. Bei EF>=95 bleiben wir im Idle-Merker;
        -- fällt EF bereits darunter, ist zunächst ein kleiner Gegenrichtungstest nötig.
        controlDirection = -action.direction
        directionKnown = false
        if postEfficiency >= IDLE_THRESHOLD then
            waitingForIdleJump = true
            directionProbePending = false
            cycleDiag = "OVER100-IDLE"
            stuckReason = string.format("Überschwingen: Peak %.1f%%; Schrittmaß reduziert, warte auf Sprung", peakEfficiency)
        else
            waitingForIdleJump = false
            directionProbePending = true
            cycleDiag = "OVER100-TEST"
            stuckReason = string.format("Überschwingen: Peak %.1f%%; Schrittmaß reduziert, Gegenprobe +/-2", peakEfficiency)
        end
    elseif action.isProbe then
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

    local fitResult = learnCoefficients(action, delta, postEfficiency, peakEfficiency)
    if fitResult == "OVERSHOOT" then
        cycleDiag = "OVER100"
    elseif fitResult == "FIT+" then
        cycleDiag = "FIT+ " .. cycleDiag
    elseif fitResult == "FIT-" then
        cycleDiag = "FIT- " .. cycleDiag
    elseif fitResult == "FIT=" then
        cycleDiag = "FIT= " .. cycleDiag
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
                currentPage = 3
            elseif y == 5 then
                ENABLE_MONITOR_LOGS = not ENABLE_MONITOR_LOGS
            end
        else
            if y == monitorHeight then
                currentPage = 1
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

            -- Unabhängiger Peak-Wächter: erfasst EF>100 auch noch nach ACTION_EVAL_DELAY,
            -- ohne Cooldown oder Sensor-Takt zu verändern.
            observeOvershootCycle(eff)

            -- Während einer Aktion jede EF-Spitze/-Senke im Nachmessfenster verfolgen.
            -- So geht ein kurzer Peak über 100% auch dann nicht verloren, wenn der
            -- Wert vor Ablauf von ACTION_EVAL_DELAY wieder gefallen ist.
            if pendingAction then
                local previousPeak = pendingAction.peakEfficiencyDuringAction or pendingAction.beforeEfficiency
                local previousLow = pendingAction.lowEfficiencyDuringAction or pendingAction.beforeEfficiency
                if eff > previousPeak then pendingAction.peakEfficiencyDuringAction = eff end
                if eff < previousLow then pendingAction.lowEfficiencyDuringAction = eff end
            end

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
                    -- Zwei unveränderte Intervalle bestätigt: EF genau hier sichern.
                    -- Bei Multiplikator x1 entspricht jedes Intervall 4 Ticks (0,2 s).
                    executionGo = true
                    stableExecutionEfficiency = eff
                    stableExecutionAt = os.clock()
                    unchangedPollCount = 0
                end
            else
                unchangedPollCount = 0
                -- Der gespeicherte Wert ist nicht mehr aktuell: erst erneut Stabilität
                -- feststellen, statt mit einem alten EF-Wert eine Stärke zu berechnen.
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
            stableExecutionEfficiency = nil
            stableExecutionAt = nil
            unchangedPollCount = 0
            stuckReason = "Sensor-Lesefehler"
        end

        sleep(pollSeconds)
    end
end

-- ==================== AUSFÜHRUNGS-SCHLEIFE ====================
local function executionLoop()
    while true do
        local now = os.clock()

        if executionGo and stableExecutionEfficiency ~= nil and
           stableExecutionEfficiency == liveEF and not pendingAction and
           (now - lastExecutionTime) >= EXECUTION_COOLDOWN then
            executionGo = false

            -- Für Formel, Schrittprotokoll und Vorher/Nachher-Vergleich wird derselbe
            -- letzte stabil bestätigte EF-Wert benutzt, nicht ein späterer Live-Wert.
            local currentEfficiency = stableExecutionEfficiency
            stableExecutionEfficiency = nil
            stableExecutionAt = nil
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
                -- Keine Schrittobergrenze für die direkte Mod-API; Nudge wird bei
                -- kleinen Schritten addiert, bei großen Schritten separat gesendet.
                local effectiveStep = probeAction and 2 or (stepSize + (nudgeIncluded and 1 or 0))
                local actionDirection = controlDirection
                local success, modeOrError, nudgeApplied, actualStrength = applyControlAction(
                    actionDirection, effectiveStep, separateNudge, nudgeIncluded
                )

                if success then
                    local signChar = (actionDirection == 1) and "+" or "-"
                    local stepText
                    if probeAction then
                        stepText = "TEST" .. signChar .. "2"
                    else
                        -- Falls die Direkt-API scheitert und Relay verwendet wird,
                        -- loggen wir die tatsächlich gesendete (max. 15) Stärke.
                        local loggedStrength = actualStrength or effectiveStep
                        stepText = signChar .. formatStep(loggedStrength)
                        if separateNudge and nudgeApplied then stepText = stepText .. "+1" end
                    end

                    lastAppliedStepText = stepText
                    lastActionMode = modeOrError
                    logCounter = logCounter + 1

                    local directAction = (type(reactor.adjustReactivity) == "function" and
                        modeOrError:find("Direkt", 1, true) ~= nil)
                    pendingAction = {
                        id = logCounter,
                        direction = actionDirection,
                        stepText = stepText,
                        beforeEfficiency = currentEfficiency,
                        appliedAt = os.clock(),
                        evaluateAt = os.clock() + ACTION_EVAL_DELAY,
                        cycleSeconds = secondsSinceLastGo,
                        usedNudge = nudgeApplied,
                        isProbe = probeAction,
                        requestedStrength = effectiveStep,
                        directAPI = directAction,
                        peakEfficiencyDuringAction = currentEfficiency,
                        lowEfficiencyDuringAction = currentEfficiency
                    }

                    -- Context für einen EF-Peak, der erst nach der kurzen Nachmessung auftritt.
                    -- Richtungstests gelten nicht als Trainings-/Überschwing-Aktion.
                    if directAction and not probeAction then
                        lastSuccessfulControlAt = os.clock()
                        lastSuccessfulControlBeforeEF = currentEfficiency
                        lastSuccessfulControlStrength = effectiveStep
                        lastActionEligibleForOvershoot = true
                    else
                        lastSuccessfulControlAt = nil
                        lastSuccessfulControlBeforeEF = nil
                        lastSuccessfulControlStrength = nil
                        lastActionEligibleForOvershoot = false
                    end

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
                writeHeader(string.format("=== FUSION CONTROL %s (1/3) ===", SCRIPT_VERSION))

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
                monitor.write(string.format("Sensor:%dt/%.2fs x%d%s N:%d",
                    currentTicks, currentTicks / 20,
                    ENABLE_LOW_PERF_MODE and lowPerfMultiplier or 1,
                    ENABLE_LOW_PERF_MODE and "A" or "F",
                    #learningSamples))

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
                    monitor.write("[Klick: Seite 2 Redstone-Log]")
                    monitor.setBackgroundColor(colors.black)
                    monitor.setTextColor(colors.white)
                end
            elseif currentPage == 2 then
                writeHeader("=== REDSTONE INPUT LOG (2/3) ===")

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
                    monitor.write("[Klick: Seite 3 Formelkurve]")
                    monitor.setBackgroundColor(colors.black)
                    monitor.setTextColor(colors.white)
                end
            else
                writeHeader("=== ADAPTIVE FORMULA (3/3) ===")
                if monitorHeight >= 3 then
                    clearLineAt(3)
                    monitor.write("Modell: Step = K*(A*x + B*x^2)")
                end
                if monitorHeight >= 4 then
                    clearLineAt(4)
                    monitor.write("x = (100 - EF) / 100")
                end
                if monitorHeight >= 5 then
                    clearLineAt(5)
                    monitor.write(string.format("A=%.3f  B=%.3f  N=%d", coefficientLinear, coefficientQuadratic, #learningSamples))
                end
                if monitorHeight >= 6 then
                    clearLineAt(6)
                    monitor.write("Lernungen gesamt: " .. tostring(learningUpdateCount))
                end
                if monitorHeight >= 7 then
                    clearLineAt(7)
                    monitor.setTextColor(colors.cyan)
                    monitor.write("Status: " .. string.sub(lastLearnStatus, 1, math.max(1, monitorHeight > 30 and 50 or 35)))
                    monitor.setTextColor(colors.white)
                end
                if monitorHeight >= 8 then
                    clearLineAt(8)
                    monitor.write(string.format("K=%.3f | Ueber100: %d", overshootScale, overshootEvents))
                end
                if monitorHeight >= 9 then
                    clearLineAt(9)
                    monitor.write("--- KURVE: EF -> Sollschritt ---")
                end
                local curveEfficiencies = {95, 90, 80, 70, 60, 50, 40, 30}
                for i, ef in ipairs(curveEfficiencies) do
                    local y = 9 + i
                    if monitorHeight >= y then
                        clearLineAt(y)
                        monitor.write(string.format("EF %3d%% -> Step %8s", ef, formatStep(calculateStep(ef))))
                    end
                end
                if monitorHeight >= 19 then
                    clearLineAt(19)
                    monitor.setTextColor(colors.lightGray)
                    monitor.write("--- LETZTE LERNPUNKTE ---")
                    monitor.setTextColor(colors.white)
                end
                for i = 1, math.min(5, #learningSamples) do
                    local y = 19 + i
                    if monitorHeight >= y then
                        local point = learningSamples[i]
                        clearLineAt(y)
                        monitor.write(string.format("EF%.0f dEF%+.1f St%.1f>Z%.1f",
                            point.eff, point.delta, point.step, point.targetStep))
                    end
                end
                if monitorHeight >= 1 then
                    clearLineAt(monitorHeight)
                    monitor.setBackgroundColor(colors.gray)
                    monitor.setTextColor(colors.yellow)
                    monitor.write("[Klick: Seite 1 Haupt-UI]")
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
