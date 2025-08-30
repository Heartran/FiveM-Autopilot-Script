-- Autopilot rewrite: register personal vehicle and summon it to follow the player.
-- The script is intentionally simple to maximise reliability.

-- =========================
-- CONFIGURATION
-- =========================
local KEY_DEFAULT = 'F6'
local DRIVE_SPEED = 28.0 -- m/s (~100km/h)
local DRIVING_STYLE = 786603 -- road/normal
local FOLLOW_DISTANCE = 8.0

-- =========================
-- STATE
-- =========================
local personal = nil -- { netId, plate }
local driverPed = nil
local summoning = false
local following = false

-- =========================
-- UTILS
-- =========================
local function notify(msg)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, false)
end

RegisterNetEvent('autopilot:notify', function(msg)
    notify(msg)
end)

local function EnumerateEntities(init, move, finish)
    return coroutine.wrap(function()
        local iter, id = init()
        if id == 0 then
            finish(iter)
            return
        end
        local enum = {handle = iter, destructor = finish}
        setmetatable(enum, {__gc = function(e)
            if e.handle then e.destructor(e.handle) end
        end})
        local next = true
        repeat
            coroutine.yield(id)
            next, id = move(iter)
        until not next
        enum.destructor(iter)
    end)
end

local function EnumerateVehicles()
    return EnumerateEntities(FindFirstVehicle, FindNextVehicle, EndFindVehicle)
end

local function takeControl(entity, retries)
    retries = retries or 30
    local tries = 0
    while not NetworkHasControlOfEntity(entity) and tries < retries do
        NetworkRequestControlOfEntity(entity)
        Wait(0)
        tries = tries + 1
    end
    return NetworkHasControlOfEntity(entity)
end

local function ensureModel(hash)
    RequestModel(hash)
    while not HasModelLoaded(hash) do
        Wait(0)
    end
end

local function spawnDriver(veh)
        local model = joaat('s_m_m_scientist_01')
    ensureModel(model)
    local ped = CreatePed(26, model, 0.0, 0.0, 0.0, 0.0, true, true)
    SetEntityAsMissionEntity(ped, true, true)
    SetPedIntoVehicle(ped, veh, -1)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false, false)
    return ped
end

-- =========================
-- SYNC WITH SERVER
-- =========================
RegisterNetEvent('autopilot:cbPersonal', function(data)
    personal = data
end)

local function pullPersonal()
    TriggerServerEvent('autopilot:getPersonal')
end

-- =========================
-- VEHICLE HELPERS
-- =========================
local function getPlateTrimmed(veh)
    return (GetVehicleNumberPlateText(veh) or ''):gsub('%s+', ''):upper()
end

local function findVehicle()
    if not personal then return nil end
    local veh = NetworkGetEntityFromNetworkId(personal.netId or -1)
    if veh ~= 0 and DoesEntityExist(veh) then
        return veh
    end
    local plate = (personal.plate or ''):gsub('%s+', ''):upper()
    for vehIt in EnumerateVehicles() do
        if getPlateTrimmed(vehIt) == plate then
            return vehIt
        end
    end
    return nil
end

local function stopAutopilot()
    local veh = findVehicle()
    if driverPed and DoesEntityExist(driverPed) then
        ClearPedTasks(driverPed)
        if veh and DoesEntityExist(veh) then
            TaskLeaveVehicle(driverPed, veh, 0)
        end
        Wait(500)
        DeletePed(driverPed)
    end
    driverPed = nil
    summoning = false
    following = false
end

-- =========================
-- MAIN AUTOPILOT LOGIC
-- =========================
local function summonVehicle()
    if summoning or following then
        notify('Autopilota già attivo.')
        return
    end
    pullPersonal()
    Wait(200)
    if not personal then
        notify('Nessun veicolo personale registrato.')
        return
    end
    local veh = findVehicle()
    if not veh then
        notify('Veicolo non trovato.')
        return
    end
    if not takeControl(veh) then
        notify('Impossibile ottenere il controllo del veicolo.')
        return
    end
    driverPed = spawnDriver(veh)
    if not driverPed then
        notify('Impossibile creare il driver.')
        return
    end
    summoning = true
    notify('Il veicolo sta arrivando...')

    CreateThread(function()
        while summoning do
            local pcoords = GetEntityCoords(PlayerPedId())
            TaskVehicleDriveToCoordLongrange(driverPed, veh, pcoords.x, pcoords.y, pcoords.z, DRIVE_SPEED, DRIVING_STYLE, 20.0)
            if #(pcoords - GetEntityCoords(veh)) <= FOLLOW_DISTANCE then
                summoning = false
                following = true
                notify('Ti sto seguendo.')
            end
            Wait(2000)
        end
        while following do
            local ped = PlayerPedId()
            if IsPedInVehicle(ped, veh, false) then
                notify('Autopilota disattivato.')
                stopAutopilot()
                break
            end
            TaskVehicleFollow(driverPed, veh, ped, DRIVE_SPEED, DRIVING_STYLE, FOLLOW_DISTANCE)
            Wait(2000)
        end
    end)
end

local function registerVehicle()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) or GetPedInVehicleSeat(GetVehiclePedIsIn(ped, false), -1) ~= ped then
        notify('Siediti al posto di guida per registrare il veicolo.')
        return
    end
    local veh = GetVehiclePedIsIn(ped, false)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local plate = GetVehicleNumberPlateText(veh) or 'N/A'
    TriggerServerEvent('autopilot:registerPersonal', netId, plate)
    personal = { netId = netId, plate = plate }
    notify(('Veicolo %s registrato.'):format(plate))
end

RegisterCommand('autopilot', function()
    pullPersonal()
    Wait(200)
    if personal then
        summonVehicle()
    else
        registerVehicle()
    end
end, false)

RegisterKeyMapping('autopilot', 'Autopilota personale', 'keyboard', KEY_DEFAULT)

RegisterCommand('autopilot_stop', function()
    stopAutopilot()
    notify('Autopilota fermato.')
end, false)

RegisterCommand('autopilot_clear', function()
    stopAutopilot()
    personal = nil
    TriggerServerEvent('autopilot:clearPersonal')
    notify('Veicolo personale resettato.')
end, false)
