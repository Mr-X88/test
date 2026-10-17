
-- Better Fusion Reactor Controller
-- Minecraft 1.20.1 | CC:Tweaked / Advanced Peripherals
-- Effizienzoptimierung mit Anti-Ping-Pong und Monitor
--
-- WICHTIG:
-- left  = Erhöhen (Annahme)
-- right = Verringern (Annahme)
-- Automatik startet AUS.
--
-- Tasten:
-- A = Automatik ein/aus
-- Q = Beenden und Ausgänge auf 0 setzen
--
-- Die Reactor-API muss zu deiner Mod-Version passen.

local CFG = {
    targetEfficiency = 70,  -- Mindestziel; danach weiter optimieren
    deadband = 0.35,        -- ignorierte Effizienzschwankung
    maxError = 100,         -- ab hier Automatik pausieren
    warningError = 50,

    minSignal = 1,
    maxSignal = 15,
    initialSignal = 8,
    initialStep = 1,
    maxStep = 2,

    sampleInterval = 1,     -- Sekunden
    displayInterval = 1,    -- Sekunden
    samplesPerTrial = 5,
    monitorScale = 0.5,

    increaseSide = "left",
    decreaseSide = "right",

    -- Erst aktivieren, wenn du eine sichere Temperaturgrenze kennst.
    useCaseTempLimit = false,
    criticalCaseTemp = 10000000
}

local reactor, reactorName
local monitor, monitorName
local auto = false
local running = true

local status = "Initialisierung"
local detail = "Suche Peripherie..."
local lastAction = "Keine"
local lastError = nil
local logicMode = "Unbekannt"

local signal = CFG.initialSignal
local direction = 1 -- +1 = erhöhen, -1 = verringern
local step = CFG.initialStep

local trial = nil
local samples = {}
local cycles = 0
local bestEfficiency = nil

local data = {
    efficiency = nil,
    errorLevel = nil,
    caseTemp = nil
}

local stats = {
    minEff = math.huge,
    maxEff = -math.huge,
    minError = math.huge,
    maxError = -math.huge,
    minTemp = math.huge,
    maxTemp = -math.huge
}

-- Sichere API-Aufrufe
local function hasMethod(obj, method)
    if not obj then return false end
    local ok, fn = pcall(function()
        return obj[method]
    end)
    return ok and type(fn) == "function"
end

local function safeCall(obj, method, ...)
    if not obj then
        return false, nil, "Peripherie nicht verfügbar"
    end

    local okFn, fn = pcall(function()
        return obj[method]
    end)

    if not okFn or type(fn) ~= "function" then
        return false, nil, "Methode fehlt: " .. method
    end

    local args = {...}
    local unpackArgs = table.unpack or unpack

    local ok, result = pcall(function()
        return fn(unpackArgs(args))
    end)

    if not ok then
        return false, nil, tostring(result)
    end

    return true, result
end

local function scanPeripherals()
    reactor, reactorName = nil, nil
    monitor, monitorName = nil, nil

    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then
        return false
    end

    -- getNames() umfasst auch sichtbare Geräte über Wired Modems.
    for _, name in ipairs(names) do
        local obj = peripheral.wrap(name)
        local okType, pType = pcall(peripheral.getType, name)

        local lowerName = tostring(name):lower()
        local lowerType = tostring(pType or ""):lower()

        if not reactor and obj
            and hasMethod(obj, "getEfficiency")
            and hasMethod(obj, "getErrorLevel")
            and hasMethod(obj, "getCaseTemperature")
            and (
                hasMethod(obj, "getLogicMode")
                or lowerName:find("logicadapter", 1, true)
            )
        then
            reactor = obj
            reactorName = name
        end

        if not monitor and obj
            and (
                lowerType:find("monitor", 1, true)
                or lowerName:find("monitor", 1, true)
            )
            and hasMethod(obj, "setCursorPos")
            and hasMethod(obj, "write")
            and hasMethod(obj, "getSize")
        then
            monitor = obj
            monitorName = name
        end
    end

    return reactor ~= nil
end

local function readNumber(method)
    local ok, value, err = safeCall(reactor, method)

    if not ok then
        return nil, err
    end

    if type(value) ~= "number"
        or value ~= value
        or value == math.huge
        or value == -math.huge
    then
        return nil, method .. " lieferte keinen gültigen Zahlenwert"
    end

    return value
end

local function readData()
    if not reactor then
        return false, "Reaktoradapter nicht verbunden"
    end

    local eff, e1 = readNumber("getEfficiency")
    local err, e2 = readNumber("getErrorLevel")
    local temp, e3 = readNumber("getCaseTemperature")

    if eff == nil or err == nil or temp == nil then
        local errors = {}

        if eff == nil then
            errors[#errors + 1] = e1 or "Effizienz nicht verfügbar"
        end
        if err == nil then
            errors[#errors + 1] = e2 or "Fehlerlevel nicht verfügbar"
        end
        if temp == nil then
            errors[#errors + 1] = e3 or "Temperatur nicht verfügbar"
        end

        return false, table.concat(errors, " | ")
    end

    -- Ungültige Messwerte dürfen keine Regelaktion auslösen.
    if eff < 0 or eff > 1000 or err < 0 or temp < 0 then
        return false, "Messwert außerhalb des plausiblen Bereichs"
    end

    data.efficiency = eff
    data.errorLevel = err
    data.caseTemp = temp

    local okMode, mode = safeCall(reactor, "getLogicMode")
    logicMode = okMode and tostring(mode) or "Unbekannt"

    if eff > 0 then
        stats.minEff = math.min(stats.minEff, eff)
        stats.maxEff = math.max(stats.maxEff, eff)
    end

    stats.minError = math.min(stats.minError, err)
    stats.maxError = math.max(stats.maxError, err)
    stats.minTemp = math.min(stats.minTemp, temp)
    stats.maxTemp = math.max(stats.maxTemp, temp)

    return true
end

-- Ausgänge immer zuerst in einen definierten Zustand bringen.
local function clearOutputs()
    pcall(redstone.setAnalogOutput, CFG.increaseSide, 0)
    pcall(redstone.setAnalogOutput, CFG.decreaseSide, 0)
end

local function applySignal()
    signal = math.floor(math.max(
        CFG.minSignal,
        math.min(CFG.maxSignal, signal)
    ))

    if direction > 0 then
        redstone.setAnalogOutput(CFG.increaseSide, signal)
        redstone.setAnalogOutput(CFG.decreaseSide, 0)
        lastAction = "Erhöhen: " .. signal
    else
        redstone.setAnalogOutput(CFG.increaseSide, 0)
        redstone.setAnalogOutput(CFG.decreaseSide, signal)
        lastAction = "Verringern: " .. signal
    end
end

local function average(values)
    if #values == 0 then return nil end

    local sum = 0
    for _, value in ipairs(values) do
        sum = sum + value
    end

    return sum / #values
end

local function safetyCheck()
    if not data.efficiency
        or not data.errorLevel
        or not data.caseTemp
    then
        return false, "Messwerte fehlen"
    end

    if data.errorLevel >= CFG.maxError then
        return false, "Kritisches Fehlerlevel"
    end

    if CFG.useCaseTempLimit
        and data.caseTemp >= CFG.criticalCaseTemp
    then
        return false, "Temperaturgrenze erreicht"
    end

    return true
end

-- Beginnt einen einzelnen Optimierungsversuch.
local function beginTrial()
    if not auto then
        status = "PAUSIERT"
        detail = "A drücken, um Automatik einzuschalten"
        return
    end

    local safe, reason = safetyCheck()

    if not safe then
        auto = false
        clearOutputs()
        trial = nil
        samples = {}
        status = "SICHERHEITSPAUSE"
        detail = reason
        return
    end

    local actualStep = step

    -- Bei erhöhtem Fehlerlevel nur minimal verändern.
    if data.errorLevel >= CFG.warningError then
        actualStep = 1
    end

    trial = {
        beforeEfficiency = data.efficiency,
        oldSignal = signal,
        oldDirection = direction,
        oldStep = actualStep
    }

    signal = signal + direction * actualStep

    -- An der Grenze nicht ständig in dieselbe Richtung weiterlaufen.
    if signal > CFG.maxSignal then
        signal = CFG.maxSignal
        direction = -1
    elseif signal < CFG.minSignal then
        signal = CFG.minSignal
        direction = 1
    end

    samples = {}

    applySignal()

    status = "MESSVERSUCH"
    detail = string.format(
        "Ziel mindestens %.1f%% | Messung läuft",
        CFG.targetEfficiency
    )
end

local function finishTrial()
    if not trial or #samples < CFG.samplesPerTrial then
        return
    end

    local measuredEfficiency = average(samples)
    local change = measuredEfficiency - trial.beforeEfficiency
    cycles = cycles + 1

    local safe, reason = safetyCheck()

    if not safe then
        auto = false
        clearOutputs()
        trial = nil
        samples = {}
        status = "SICHERHEITSPAUSE"
        detail = reason
        return
    end

    if measuredEfficiency < CFG.targetEfficiency then
        detail = string.format(
            "Unter Mindestziel; Änderung %+.2f",
            change
        )
    else
        detail = string.format(
            "Messwertänderung %+.2f Prozentpunkte",
            change
        )
    end

    -- Anti-Ping-Pong:
    -- Nur bei einer eindeutigen Verschlechterung umkehren.
    if change < -CFG.deadband then
        direction = -trial.oldDirection
        signal = trial.oldSignal
        step = 1

        applySignal()

        status = "RICHTUNG GEWECHSELT"
        detail = string.format(
            "Verschlechterung %+.2f; Signal zurückgesetzt",
            change
        )

    elseif change > CFG.deadband then
        -- Verbesserung: Richtung beibehalten.
        direction = trial.oldDirection

        if data.errorLevel >= CFG.warningError then
            step = 1
        elseif math.abs(change) >= 2 then
            step = math.min(CFG.maxStep, trial.oldStep + 1)
        else
            step = trial.oldStep
        end

        bestEfficiency = math.max(
            bestEfficiency or measuredEfficiency,
            measuredEfficiency
        )

        status = "VERBESSERUNG"
        detail = string.format(
            "Effizienz verbessert um %+.2f",
            change
        )

    else
        -- Kleine Änderung gilt als Messrauschen.
        direction = trial.oldDirection
        step = 1

        status = "TOLERANZBEREICH"
        detail = string.format(
            "Änderung %+.2f ignoriert; kleiner Schritt",
            change
        )
    end

    trial = nil
    samples = {}
end

local function drawMonitor()
    if not monitor then return end

    local ok = pcall(function()
        monitor.setTextScale(CFG.monitorScale)

        local width, height = monitor.getSize()

        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
        monitor.clear()

        local function line(y, text, color)
            if y > height then return end

            monitor.setCursorPos(1, y)
            monitor.setTextColor(color or colors.white)
            monitor.write(tostring(text):sub(1, width))
        end

        line(1, "BETTER FUSION REACTOR", colors.cyan)
        line(2, "Adapter: " .. tostring(reactorName))
        line(3, "Modus: " .. logicMode)
        line(4, "Automatik: " .. (auto and "AN" or "AUS"),
            auto and colors.lime or colors.orange)
        line(5, "Status: " .. status)

        line(6, "Effizienz: " ..
            (data.efficiency and string.format("%.2f%%", data.efficiency)
                or "N/A"))

        line(7, "Bestwert: " ..
            (bestEfficiency and string.format("%.2f%%", bestEfficiency)
                or "N/A"))

        line(8, "Fehlerlevel: " ..
            (data.errorLevel and string.format("%.2f", data.errorLevel)
                or "N/A"),
            data.errorLevel and data.errorLevel >= CFG.warningError
                and colors.red or colors.white)

        line(9, "Gehäusetemp.: " ..
            (data.caseTemp and string.format("%.1f K", data.caseTemp)
                or "N/A"))

        line(10, "Signal: " .. signal .. "/15 Schritt: " .. step)
        line(11, "Richtung: " ..
            (direction > 0 and "ERHOEHEN" or "VERRINGERN"))
        line(12, "Mindestziel: " .. CFG.targetEfficiency .. "%")
        line(13, "Zyklen: " .. cycles)
        line(14, "Aktion: " .. lastAction)
        line(15, "Info: " .. detail)

        if lastError then
            line(16, "Fehler: " .. lastError, colors.red)
        end

        line(height, "A=Automatik | Q=Beenden", colors.lightGray)
        monitor.setTextColor(colors.white)
    end)

    if not ok then
        monitor = nil
        monitorName = nil
    end
end

local function drawTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    print("Better Fusion Reactor Controller")
    print("Adapter: " .. tostring(reactorName or "nicht gefunden"))
    print("Monitor: " .. tostring(monitorName or "nicht gefunden"))
    print("Modus: " .. logicMode)
    print("Status: " .. status)
    print("Automatik: " .. (auto and "AN" or "AUS"))

    print("Effizienz: " ..
        (data.efficiency and string.format("%.2f%%", data.efficiency)
            or "N/A"))

    print("Fehlerlevel: " ..
        (data.errorLevel and string.format("%.2f", data.errorLevel)
            or "N/A"))

    print("Gehäusetemperatur: " ..
        (data.caseTemp and string.format("%.1f K", data.caseTemp)
            or "N/A"))

    print("Signal: " .. signal .. "/15 | Schritt: " .. step)
    print("Richtung: " ..
        (direction > 0 and "ERHOEHEN" or "VERRINGERN"))

    print("Info: " .. detail)

    if lastError then
        print("Lesefehler: " .. lastError)
    end

    print("")
    print("A = Automatik umschalten")
    print("Q = Beenden und Ausgaenge loeschen")
end

local function shutdown()
    auto = false
    running = false
    clearOutputs()
    status = "BEENDET"
    detail = "Ausgaenge auf 0 gesetzt"
end

local function main()
    print("Suche Reaktoradapter und Monitor...")

    if not scanPeripherals() then
        print("Kein kompatibler Reaktoradapter gefunden.")

        for _, name in ipairs(peripheral.getNames()) do
            print(name .. " (" ..
                tostring(peripheral.getType(name)) .. ")")
        end

        return
    end

    clearOutputs()

    status = "PAUSIERT"
    detail = "Messwerte und Verkabelung prüfen; dann A drücken"

    local sampleTimer = os.startTimer(CFG.sampleInterval)
    local displayTimer = os.startTimer(CFG.displayInterval)

    drawTerminal()
    drawMonitor()

    while running do
        local event, p1 = os.pullEvent()

        if event == "key" then
            if p1 == keys.q then
                shutdown()

            elseif p1 == keys.a then
                auto = not auto

                if not auto then
                    clearOutputs()
                    trial = nil
                    samples = {}
                    status = "PAUSIERT"
                    detail = "Ausgaenge auf 0 gesetzt"
                else
                    trial = nil
                    samples = {}
                    status = "AUTOMATIK AKTIVIERT"
                    detail = "Sicherheitspruefung vor Regelung"
                end

                drawTerminal()
                drawMonitor()

            end

        elseif event == "peripheral"
            or event == "peripheral_detach"
        then
            scanPeripherals()

            if not reactor then
                auto = false
                clearOutputs()
                trial = nil
                status = "ADAPTER VERLOREN"
                detail = "Regelung pausiert"
            end

            drawTerminal()
            drawMonitor()

        elseif event == "timer" then
            if p1 == sampleTimer then
                local ok, err = readData()

                if not ok then
                    lastError = err
                    auto = false
                    clearOutputs()
                    trial = nil
                    samples = {}

                    status = "LESEFEHLER - PAUSIERT"
                    detail = "Keine Regelaktion bei ungueltigen Werten"

                else
                    lastError = nil

                    if trial then
                        samples[#samples + 1] = data.efficiency

                        status = string.format(
                            "MESSUNG %d/%d",
                            #samples,
                            CFG.samplesPerTrial
                        )

                        if #samples >= CFG.samplesPerTrial then
                            finishTrial()
                        end

                    elseif auto then
                        beginTrial()
                    else
                        status = "PAUSIERT"
                    end
                end

                sampleTimer = os.startTimer(CFG.sampleInterval)

            elseif p1 == displayTimer then
                drawTerminal()
                drawMonitor()

                displayTimer = os.startTimer(CFG.displayInterval)
            end
        end
    end
end

local ok, err = pcall(main)

-- Auch bei einem Lua-Fehler die konfigurierten Ausgänge löschen.
clearOutputs()

if not ok then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    print("Controller-Fehler:")
    print(tostring(err))
    print("Konfigurierte Redstone-Ausgaenge wurden geloescht.")
end
