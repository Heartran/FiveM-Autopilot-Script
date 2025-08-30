-- =========================
-- CONFIG
-- =========================
local KEY_DEFAULT = 'F6'
local SUMMON_RANGE_START_FOLLOW = 15.0   -- quando è a questa distanza, passa al follow persistente
local FOLLOW_MIN_DISTANCE = 8.0          -- distanza “di cortesia” dietro di te
local DRIVE_SPEED = 28.0                 -- m/s (~100 km/h)
local DRIVING_STYLE = 786603             -- stile di guida sicuro/stradale
local MAKE_DRIVER_INVISIBLE = false -- DEBUG: disabilita invisibilità temporaneamente
local MAKE_DRIVER_INVINCIBLE = true
local HONK_ON_FINISH = false             -- non serve più il clacson, lasciamolo spento
local RETASK_INTERVAL_MS = 2000          -- ogni quanto riaffido il compito di follow

-- =========================
-- UTILS
-- =========================
local function Notify(msg)
    -- Puoi sostituire con la tua notifica fancy (mythic, okok, ecc.)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, false)
end

RegisterNetEvent('autopilot:notify', function(msg)
    Notify(msg)
end)

-- Enumeratore veicoli (nel caso serva fallback per plate nearby)
local function EnumerateEntities(initFunc, moveFunc, disposeFunc)
    return coroutine.wrap(function()
        local iter, id = initFunc()
        if not id or id == 0 then
            disposeFunc(iter)
            return
        end
        local enum = {handle = iter, destructor = disposeFunc}
        setmetatable(enum, {__gc = function(enum)
            if enum.handle then
                enum.destructor(enum.handle)
            end
        end})
        local next = true
        repeat
            coroutine.yield(id)
            next, id = moveFunc(iter)
        until not next
        enum.destructor(iter)
    end)
end

local function EnumerateVehicles()
    return EnumerateEntities(FindFirstVehicle, FindNextVehicle, EndFindVehicle)
end

local function GetPlateTrimmed(veh)
    return (string.gsub(string.upper(GetVehicleNumberPlateText(veh) or ''), '%s+', ''))
end

-- =========================
-- STATE
-- =========================
local Personal = nil             -- { netId, plate }
local ActiveSummon = false
local ActiveFollow = false   -- nuovo: modalità “seguimi”
local DriverPed = nil
local DebugEnabled = false
local SuperDebugEnabled = false

local function Debug(msg)
    if SuperDebugEnabled then
        print(('[SUPERDEBUG] %s'):format(msg))
    elseif DebugEnabled then
        local out = ('[DEBUG] %s'):format(msg)
        print(out)
        Notify(out)
    end
end

local function StartSuperDebugThread()
    CreateThread(function()
        while SuperDebugEnabled do
            local veh = Personal and NetworkGetEntityFromNetworkId(Personal.netId or -1)
            local x, y, z, speed = 0.0, 0.0, 0.0, 0.0
            if veh and veh ~= 0 then
                local coords = GetEntityCoords(veh)
                x, y, z = coords.x, coords.y, coords.z
                speed = GetEntitySpeed(veh)
            end
            Debug(('STATE: summon=%s follow=%s driver=%s veh=%s coords=%.2f %.2f %.2f speed=%.2f'):format(
                tostring(ActiveSummon), tostring(ActiveFollow), tostring(DriverPed), tostring(veh), x, y, z, speed))
            Wait(1000)
        end
    end)
end

-- IPC server → client callback
RegisterNetEvent('autopilot:cbPersonal', function(data)
    Personal = data
end)

local function RequestPersonalFromServer(cb)
    RegisterNetEvent('__autopilot:cbtmp', cb)
end

-- Richiama stato dal server
local function PullPersonalSync()
    Debug('PullPersonalSync triggered')
    TriggerServerEvent('autopilot:getPersonal')
end

-- =========================
-- DRIVER IA
-- =========================
local function EnsureModelLoaded(hash)
    Debug('EnsureModelLoaded: ' .. tostring(hash))
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 200 do
        Wait(10)
        tries = tries + 1
    end
    local loaded = HasModelLoaded(hash)
    Debug(('EnsureModelLoaded result %s'):format(tostring(loaded)))
    return loaded
end

local function SpawnDriverInVehicle(veh)
    Debug('SpawnDriverInVehicle: ' .. tostring(veh))
    local model = joaat('s_m_m_scientist_01')
    RequestModel(model)
    local t = 0; while not HasModelLoaded(model) and t < 200 do Wait(10) t = t + 1 end
    if not HasModelLoaded(model) then Notify('Modello driver non caricato'); return nil end

    -- kick eventuale driver esistente
    local old = GetPedInVehicleSeat(veh, -1)
    if old ~= 0 then
        TaskLeaveVehicle(old, veh, 16); Wait(600)
    end

    -- crea il ped FUORI e poi warpa (è più stabile in rete)
    local vx, vy, vz = table.unpack(GetEntityCoords(veh))
    local ped = CreatePed(26, model, vx + 0.5, vy + 0.5, vz, GetEntityHeading(veh), true, true)

    -- network control su ped e veicolo
    local vehNet = NetworkGetNetworkIdFromEntity(veh)
    SetNetworkIdCanMigrate(vehNet, true)
    local tries = 0
    while not NetworkHasControlOfEntity(veh) and tries < 60 do
        NetworkRequestControlOfEntity(veh); Wait(0); tries = tries + 1
    end
    if not NetworkHasControlOfEntity(veh) then Debug('No network control on VEH after spawn attempts') end

    local pedNet = NetworkGetNetworkIdFromEntity(ped)
    SetNetworkIdCanMigrate(pedNet, true)
    tries = 0
    while not NetworkHasControlOfEntity(ped) and tries < 60 do
        NetworkRequestControlOfEntity(ped); Wait(0); tries = tries + 1
    end
    if not NetworkHasControlOfEntity(ped) then Debug('No network control on PED after spawn attempts') end

    -- preparazione veicolo
    FreezeEntityPosition(veh, false)
    SetVehicleUndriveable(veh, false)
    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleHandbrake(veh, false)
    SetVehicleBrake(veh, false)
    SetVehicleDoorsLocked(veh, 1)
    SetVehicleTyresCanBurst(veh, true)
    SetEntityAsMissionEntity(veh, true, false)

    -- assicurati che sia dritto e “sul mondo”
    if not IsVehicleOnAllWheels(veh) then SetVehicleOnGroundProperly(veh); Debug('Vehicle was not on all wheels; corrected') end
    RequestCollisionAtCoord(vx, vy, vz)
    local c = 0; while not HasCollisionLoadedAroundEntity(veh) and c < 100 do Wait(10) c = c + 1 end
    if not HasCollisionLoadedAroundEntity(veh) then Debug('Collision not fully loaded around vehicle after spawn wait') end

    -- ped sane defaults
    SetEntityAsMissionEntity(ped, true, true)
    SetPedIntoVehicle(ped, veh, -1)
    Debug('Ped inserito nel veicolo (driver seat)')
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanBeDraggedOut(ped, false)
    SetPedStayInVehicleWhenJacked(ped, true)
    SetPedNeverLeavesVehicle(ped, true)
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, true)
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, 0.6)
    SetPedKeepTask(ped, true)

    -- invisibile/immortale (se vuoi)
    if MAKE_DRIVER_INVISIBLE then
        SetEntityVisible(ped, false, false)
        SetEntityAlpha(ped, 0, false)
        if NetworkSetEntityInvisibleToNetwork then
            NetworkSetEntityInvisibleToNetwork(ped, true)
        end
    end
    if MAKE_DRIVER_INVINCIBLE then
        SetEntityInvincible(ped, true)
        SetEntityProofs(ped, true, true, true, true, true, true, true, true)
    end

    -- piccolo “nudge” per sbloccare alcune fisiche addormentate
    SetVehicleForwardSpeed(veh, 1.0)

    SetModelAsNoLongerNeeded(model)
    Debug('SpawnDriverInVehicle completed')
    return ped
end

local function TakeControl(entity, maxTries)
    maxTries = maxTries or 30
    local tries = 0
    while not NetworkHasControlOfEntity(entity) and tries < maxTries do
        NetworkRequestControlOfEntity(entity)
        Wait(0)
        tries = tries + 1
    end
    return NetworkHasControlOfEntity(entity)
end

local function StopAndDismissDriver(veh, ped)
    Debug('StopAndDismissDriver called')
    if ped and DoesEntityExist(ped) then
        ClearPedTasks(ped)
        TaskVehicleTempAction(ped, veh, 1, 1000) -- frena un attimo
        TaskVehiclePark(ped, veh, GetEntityCoords(veh), GetEntityHeading(veh), 0, 20.0, true)
        Wait(700)
        TaskLeaveVehicle(ped, veh, 0)
        Wait(500)
        DeleteEntity(ped)
    end
end

-- =========================
-- SUMMON LOGIC
-- =========================
local function FindVehicleFromPersonal()
    if not Personal then return nil end
    local veh = NetworkGetEntityFromNetworkId(Personal.netId or -1)
    if veh ~= 0 and DoesEntityExist(veh) then
        return veh
    end

    -- Fallback: prova a trovare per plate nei veicoli streamati localmente
    local targetPlate = (Personal.plate or ''):gsub('%s+', ''):upper()
    if targetPlate ~= '' then
        for vehIt in EnumerateVehicles() do
            if GetPlateTrimmed(vehIt) == targetPlate then
                return vehIt
            end
        end
    end
    return nil
end

local function SummonVehicleToPlayer()
    Debug('SummonVehicleToPlayer called')
    if ActiveSummon or ActiveFollow then
        Notify('L’autopilota è già attivo.')
        return
    end

    PullPersonalSync()
    Wait(150)

    if not Personal then
        Notify('Nessun veicolo personale registrato. Siediti in un’auto e premi il tasto per registrarla.')
        return
    end

    local veh = FindVehicleFromPersonal()
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        Notify('Non trovo il tuo veicolo (deve essere spawnato/OneSync attivo).')
        return
    end
    if not TakeControl(veh) then
        Notify('Non ho il controllo del veicolo. Riprova tra poco.')
        return
    end

    SetVehicleUndriveable(veh, false)
    SetVehicleDoorsLocked(veh, 1)
    SetVehicleEngineOn(veh, true, true, false)


    DriverPed = SpawnDriverInVehicle(veh)
    if not DriverPed then
        Notify('Driver IA non creato.')
        return
    end
    Debug('DriverPed creato: ' .. tostring(DriverPed))
    if not IsPedInVehicle(DriverPed, veh, false) then
        Debug('ATTENZIONE: Il ped non è nel veicolo dopo SpawnDriverInVehicle!')
    else
        Debug('Il ped è correttamente nel veicolo.')
    end

    ActiveSummon = true
    Notify('Arrivo in corso…')

    CreateThread(function()
        while ActiveSummon and DoesEntityExist(veh) and DoesEntityExist(DriverPed) do
            local pped = PlayerPedId()
            local pcoords = GetEntityCoords(pped)

            -- assicurati di avere controllo e che il veicolo sia pronto
            if not NetworkHasControlOfEntity(veh) then NetworkRequestControlOfEntity(veh); Debug('Requesting control: VEH (summon loop)') end
            if not NetworkHasControlOfEntity(DriverPed) then NetworkRequestControlOfEntity(DriverPed); Debug('Requesting control: PED (summon loop)') end
            SetVehicleEngineOn(veh, true, true, false)
            SetVehicleUndriveable(veh, false)

            -- finché non è vicino, guidagli addosso in maniera “stradale”
            SetDriveTaskDrivingStyle(DriverPed, DRIVING_STYLE)
            SetDriveTaskMaxCruiseSpeed(DriverPed, DRIVE_SPEED)
            TaskVehicleDriveToCoordLongrange(DriverPed, veh, pcoords.x, pcoords.y, pcoords.z, DRIVE_SPEED, DRIVING_STYLE, 20.0)
            Debug('TaskVehicleDriveToCoordLongrange assegnato: ' .. string.format('%.2f %.2f %.2f', pcoords.x, pcoords.y, pcoords.z))

            -- quando è abbastanza vicino, passiamo alla modalità follow persistente
            local dist = #(pcoords - GetEntityCoords(veh))
            if dist <= SUMMON_RANGE_START_FOLLOW then
                ActiveSummon = false
                ActiveFollow = true
                Notify('Ti sto seguendo rimanendo in strada.')
                break
            end

            Wait(RETASK_INTERVAL_MS)
        end

        -- FOLLOW LOOP
        while ActiveFollow and DoesEntityExist(veh) and DoesEntityExist(DriverPed) do
            local pped = PlayerPedId()

            -- Se per qualsiasi motivo il driver è fuori, rimettilo dentro
            if not IsPedInVehicle(DriverPed, veh, false) then
                SetPedIntoVehicle(DriverPed, veh, -1)
                SetPedNeverLeavesVehicle(DriverPed, true)
                Debug('Driver was outside vehicle; warped back to driver seat')
            end

            -- Se sali sul veicolo → stop follow e cleanup
            if IsPedInVehicle(pped, veh, false) then
                Notify('Sei salito a bordo. Autopilota disattivato.')
                ActiveFollow = false
                StopAndDismissDriver(veh, DriverPed)
                DriverPed = nil
                break
            end

            -- assicurati di avere controllo e che il veicolo sia pronto
            if not NetworkHasControlOfEntity(veh) then NetworkRequestControlOfEntity(veh) end
            if not NetworkHasControlOfEntity(DriverPed) then NetworkRequestControlOfEntity(DriverPed) end
            SetVehicleEngineOn(veh, true, true, false)
            SetVehicleUndriveable(veh, false)

            -- Insegui il player rispettando la strada
            TaskVehicleFollow(DriverPed, veh, pped, DRIVE_SPEED, DRIVING_STYLE, FOLLOW_MIN_DISTANCE)
            SetDriveTaskDrivingStyle(DriverPed, DRIVING_STYLE)
            SetDriveTaskMaxCruiseSpeed(DriverPed, DRIVE_SPEED)

            -- Kick se rimane fermo
            local speed = GetEntitySpeed(veh)
            if speed < 0.5 then
                TaskVehicleFollow(DriverPed, veh, pped, DRIVE_SPEED, DRIVING_STYLE, FOLLOW_MIN_DISTANCE)
                SetVehicleForwardSpeed(veh, 2.0)
                Debug('Stuck detected (speed<0.5): reapplied follow and nudged forward')
            end

            -- Riprogramma periodicamente per “svegliarlo” se resta bloccato
            Wait(RETASK_INTERVAL_MS)
        end

        -- Cleanup di sicurezza se qualcosa interrompe
        if DriverPed and DoesEntityExist(DriverPed) then
            ClearPedTasks(DriverPed)
        end
    end)
end

-- =========================
-- REGISTRAZIONE VEICOLO
-- =========================
local function TryRegisterCurrentVehicle()
    Debug('TryRegisterCurrentVehicle called')
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) or GetPedInVehicleSeat(GetVehiclePedIsIn(ped, false), -1) ~= ped then
        Notify('Siediti al posto di guida di un veicolo per registrarlo come personale.')
        return
    end
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then
        Notify('Veicolo non valido.')
        return
    end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local plate = GetVehicleNumberPlateText(veh) or 'N/A'
    SetNetworkIdCanMigrate(netId, true)
    SetEntityAsMissionEntity(veh, true, false)
    TriggerServerEvent('autopilot:registerPersonal', netId, plate)
    Personal = { netId = netId, plate = plate }
    Debug(('Registered personal vehicle %s (netId %s)'):format(plate, netId))
end

-- =========================
-- INPUT / KEYBIND
-- =========================
RegisterCommand('autopilot', function()
    PullPersonalSync()
    Wait(120)
    if not Personal then
        -- prova a registrare
        TryRegisterCurrentVehicle()
    else
        -- richiama
        SummonVehicleToPlayer()
    end
end, false)

-- Permette il remap in game (Impostazioni → Key Bindings)
RegisterKeyMapping('autopilot', 'Autopilota: registra/chiama veicolo personale', 'keyboard', KEY_DEFAULT)

-- Fallback comando per forzare solo summon (se vuoi)
RegisterCommand('autopilot_summon', function()
    SummonVehicleToPlayer()
end)

-- Toggle debug logging
RegisterCommand('autopilot_debug', function(source, args, raw)
    local onoff = args and args[1]
    if onoff == 'on' then DebugEnabled = true
    elseif onoff == 'off' then DebugEnabled = false
    else DebugEnabled = not DebugEnabled end
    local status = DebugEnabled and 'ON' or 'OFF'
    Notify(('Debug: %s'):format(status))

    if DebugEnabled then
        local veh = Personal and NetworkGetEntityFromNetworkId(Personal.netId or -1)
        if veh and veh ~= 0 and DoesEntityExist(veh) then
            Debug(('veh exists=%s, engine=%s, speed=%.2f'):format(tostring(DoesEntityExist(veh)), tostring(GetIsVehicleEngineRunning(veh)), GetEntitySpeed(veh)))
        else
            Debug('No vehicle entity found for current Personal')
        end
    end
end, false)

-- Super debug: stampa informazioni estese in console
RegisterCommand('autopilot_superdebug', function(source, args, raw)
    local onoff = args and args[1]
    if onoff == 'on' then SuperDebugEnabled = true
    elseif onoff == 'off' then SuperDebugEnabled = false
    else SuperDebugEnabled = not SuperDebugEnabled end
    Notify(('SuperDebug: %s'):format(SuperDebugEnabled and 'ON' or 'OFF'))
    if SuperDebugEnabled then
        StartSuperDebugThread()
    end
end, false)

-- Comando per fermare follow/summon e ripulire il driver
RegisterCommand('autopilot_stop', function()
    local veh = Personal and NetworkGetEntityFromNetworkId(Personal.netId or -1)
    if ActiveFollow or ActiveSummon then
        ActiveFollow = false
        ActiveSummon = false
        if veh and DoesEntityExist(veh) and DriverPed and DoesEntityExist(DriverPed) then
            StopAndDismissDriver(veh, DriverPed)
        end
        DriverPed = nil
        Notify('Autopilota fermato.')
    else
        Notify('Nessun autopilota attivo.')
    end
end)

-- Comando per resettare il personale
RegisterCommand('autopilot_clear', function()
    Personal = nil
    TriggerServerEvent('autopilot:clearPersonal')
    Notify('Veicolo personale resettato.')
end)
