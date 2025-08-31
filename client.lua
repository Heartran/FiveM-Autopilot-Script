-- Predict vehicle position based on last known state and elapsed time (dead-reckoning)
local function predictFromState(state, now)
    if not state then return nil end
    local dt = math.max(0.0, (now - (state.lastSeen or now)) / 1000.0)
    local px = (state.x or 0.0) + (state.vx or 0.0) * dt
    local py = (state.y or 0.0) + (state.vy or 0.0) * dt
    local pz = (state.z or 0.0) + (state.vz or 0.0) * dt
    return { x = px, y = py, z = pz, heading = state.heading or 0.0 }
end

-- Receive last known vehicle state from server
RegisterNetEvent('autopilot:cbVehState', function(state)
    if state then
        state.receivedAt = GetGameTimer()
    end
    lastState = state
end)

-- Autopilot rewrite: register personal vehicle and summon it to follow the player.
-- The script is intentionally simple to maximise reliability.

-- =========================
-- =========================
local MENU_KEY = 'F4'
local DEFAULT_DRIVE_SPEED = 28.0 -- m/s (~100km/h) fallback
local DRIVING_STYLE = 786603 -- road/normal
local FOLLOW_DISTANCE = 5.0

-- =========================
-- STATE
-- =========================
local personal = nil -- { netId, plate }
local driverPed = nil
local summoning = false
local following = false
local vehicleBlip = nil
local lastState = nil -- { x,y,z, heading, vx,vy,vz, lastSeen, receivedAt }

-- =========================
-- UTILS
-- =========================
local function notify(msg)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandThefeedPostTicker(false, false)
end

-- =========================
-- DRIVING HELPERS (ADAPTIVE + AVOIDANCE)
-- =========================
local function calcDriveSpeed(veh)
    -- Determine speed based on road type, weather and vehicle condition
    local speed = DEFAULT_DRIVE_SPEED
    if veh and DoesEntityExist(veh) then
        local coords = GetEntityCoords(veh)
        local streetHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
        local street = GetStreetNameFromHashKey(streetHash)
        if street then
            street = street:upper()
            if street:find('FWY') or street:find('HWY') or street:find('FREEWAY') then
                speed = 33.0 -- ~120km/h on highways
            elseif street:find('BLVD') or street:find('AVE') or street:find('RD') then
                speed = 22.0 -- ~80km/h on larger roads
            else
                speed = 14.0 -- ~50km/h on smaller streets
            end
        else
            speed = DEFAULT_DRIVE_SPEED
        end
        local weather = GetPrevWeatherTypeHashName()
        if weather == GetHashKey('RAIN') or weather == GetHashKey('THUNDER') or weather == GetHashKey('BLIZZARD') then
            speed = speed * 0.8 -- slow down in bad weather
        end
        local health = GetVehicleBodyHealth(veh)
        if health < 800.0 then
            speed = speed * 0.7 -- cautious if damaged
        end
    end
    return speed
end

local function adaptiveSpeed(veh, dist)
    -- Return a cautious speed based on distance to target (meters)
    local base = calcDriveSpeed(veh)
    if dist > 40.0 then return base end
    if dist > 25.0 then return math.min(base, 20.0) end
    if dist > 12.0 then return math.min(base, 14.0) end
    if dist > 6.0 then return math.min(base, 8.0) end
    return 1.0
end

local function vehicleAhead(veh)
    if not (veh and DoesEntityExist(veh)) then return false end
    local from = GetOffsetFromEntityInWorldCoords(veh, 0.0, 1.5, 0.5)
    local to = GetOffsetFromEntityInWorldCoords(veh, 0.0, 18.0, 0.5)
    local ray = StartShapeTestCapsule(from.x, from.y, from.z, to.x, to.y, to.z, 2.0, 10, veh, 7)
    local _, hit, _, _, entityHit = GetShapeTestResult(ray)
    return (hit == 1) and DoesEntityExist(entityHit) and IsEntityAVehicle(entityHit) and entityHit ~= veh
end

local function obstacleAhead(veh)
    if not (veh and DoesEntityExist(veh)) then return false end
    local from = GetOffsetFromEntityInWorldCoords(veh, 0.0, 1.5, 0.5)
    local to = GetOffsetFromEntityInWorldCoords(veh, 0.0, 14.0, 0.5)
    local ray = StartShapeTestCapsule(from.x, from.y, from.z, to.x, to.y, to.z, 2.0, 12, veh, 7)
    local _, hit, _, _, entityHit = GetShapeTestResult(ray)
    if hit ~= 1 or not DoesEntityExist(entityHit) then return false end
    return IsEntityAVehicle(entityHit) or IsPedAPlayer(entityHit) or IsEntityAPed(entityHit)
end

RegisterNetEvent('autopilot:notify', function(msg)
    notify(msg)
end)

-- Add chat suggestions for commands (requires default chat resource)
CreateThread(function()
    -- Delay to allow chat resource to initialize
    Wait(1000)
    TriggerEvent('chat:addSuggestion', '/autopilot', 'Richiama il veicolo personale o registra quello attuale')
    TriggerEvent('chat:addSuggestion', '/autopilot_menu', 'Apri il menu autopilota')
    TriggerEvent('chat:addSuggestion', '/autopilot_stop', 'Ferma l\'autopilota e parcheggia')
    TriggerEvent('chat:addSuggestion', '/autopilot_park', 'Parcheggia il veicolo a bordo strada')
    TriggerEvent('chat:addSuggestion', '/autopilot_clear', 'Resetta il veicolo personale')
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
    -- Safer driving profile
    SetDriverAbility(ped, 0.6)
    SetDriverAggressiveness(ped, 0.0)
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

local function parkVehicle()
    local veh = findVehicle()
    if not veh then return end

    if not driverPed or not DoesEntityExist(driverPed) then
        driverPed = spawnDriver(veh)
    end

    summoning = false
    following = false

    -- Compute a roadside parking spot: slightly ahead and to the right of the lane
    local function calcParkSpotNear(v)
        local vpos = GetEntityCoords(v)
        local found, nx, ny, nz, nheading = GetClosestVehicleNodeWithHeading(vpos.x, vpos.y, vpos.z, 1, 3.0, 0)
        if not found then
            return vpos.x, vpos.y, vpos.z, GetEntityHeading(v)
        end
        local headRad = math.rad(nheading)
        local ahead = 8.0
        local side = 2.2
        local function spot(offSide)
            local tx = nx + math.cos(headRad) * ahead + math.cos(headRad + math.pi / 2) * offSide
            local ty = ny + math.sin(headRad) * ahead + math.sin(headRad + math.pi / 2) * offSide
            local tz = nz
            return tx, ty, tz
        end
        local tx, ty, tz = spot(side) -- try right side (right-hand traffic)
        if not IsPointOnRoad(tx, ty, tz, v) then
            tx, ty, tz = spot(-side)   -- try left side
        end
        if not IsPointOnRoad(tx, ty, tz, v) then
            -- fallback: center of lane ahead
            tx = nx + math.cos(headRad) * ahead
            ty = ny + math.sin(headRad) * ahead
            tz = nz
        end
        return tx, ty, tz, nheading
    end

    local tx, ty, tz, thead = calcParkSpotNear(veh)
    if tx and ty and tz then
        -- mode 1 = park forward; radius 3.0; engine off after parking
        TaskVehiclePark(driverPed, veh, tx, ty, tz, thead, 1, 3.0, false)
    else
        TaskVehicleTempAction(driverPed, veh, 27, 6000)
    end

    local timeout = GetGameTimer() + 20000
    while GetGameTimer() < timeout do
        local vpos = GetEntityCoords(veh)
        local dist = #(vpos - vector3(tx or vpos.x, ty or vpos.y, tz or vpos.z))
        if IsVehicleStopped(veh) and dist <= 3.5 then
            break
        end
        Wait(400)
    end
    -- Ensure parked: brake and engine off
    TaskVehicleTempAction(driverPed, veh, 27, 1200)
    SetVehicleEngineOn(veh, false, true, true)
end

local function stopAutopilot(parkFirst)
    local veh = findVehicle()
    if parkFirst then
        parkVehicle()
    end
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
            -- Drive towards the closest road node near the player to stay on roads
            local found, nx, ny, nz, nheading = GetClosestVehicleNodeWithHeading(pcoords.x, pcoords.y, pcoords.z, 1, 3.0, 0)
            if found then
                TaskVehicleDriveToCoordLongrange(driverPed, veh, nx, ny, nz, calcDriveSpeed(veh), DRIVING_STYLE, 5.0)
            else
                -- Fallback to player coords if no node found
                TaskVehicleDriveToCoordLongrange(driverPed, veh, pcoords.x, pcoords.y, pcoords.z, calcDriveSpeed(veh), DRIVING_STYLE, 5.0)
            end
            -- Adaptive cruise and obstacle avoidance
            local dist = #(pcoords - GetEntityCoords(veh))
            local spd = adaptiveSpeed(veh, dist)
            SetDriveTaskCruiseSpeed(driverPed, spd)
            if vehicleAhead(veh) or obstacleAhead(veh) then
                -- Strong early brake if obstacle detected ahead
                SetDriveTaskCruiseSpeed(driverPed, 3.0)
                TaskVehicleTempAction(driverPed, veh, 27, 1200) -- brake stronger/longer
            end
            -- Hard stop if too close
            if dist <= 0.5 then
                TaskVehicleTempAction(driverPed, veh, 27, 1500)
            end
            if #(pcoords - GetEntityCoords(veh)) <= FOLLOW_DISTANCE then
                summoning = false
                following = true
                notify('Ti sto seguendo.')
            end
            Wait(600)
        end
        while following do
            local ped = PlayerPedId()
            if IsPedInVehicle(ped, veh, false) then
                notify('Autopilota disattivato.')
                stopAutopilot()
                break
            end
            local pcoords = GetEntityCoords(ped)
            local found, nx, ny, nz, nheading = GetClosestVehicleNodeWithHeading(pcoords.x, pcoords.y, pcoords.z, 1, 3.0, 0)
            if found then
                TaskVehicleDriveToCoordLongrange(driverPed, veh, nx, ny, nz, calcDriveSpeed(veh), DRIVING_STYLE, 5.0)
            else
                TaskVehicleDriveToCoordLongrange(driverPed, veh, pcoords.x, pcoords.y, pcoords.z, calcDriveSpeed(veh), DRIVING_STYLE, 5.0)
            end
            -- If close enough, keep speed minimal
            local dist = #(pcoords - GetEntityCoords(veh))
            if dist <= FOLLOW_DISTANCE then
                TaskVehicleTempAction(driverPed, veh, 27, 1200) -- brake
            end
            -- Adaptive cruise and obstacle avoidance
            local spd = adaptiveSpeed(veh, dist)
            -- Cap speed during following for safety
            local spdCap = math.min(spd, 12.0)
            SetDriveTaskCruiseSpeed(driverPed, spdCap)
            if vehicleAhead(veh) or obstacleAhead(veh) then
                SetDriveTaskCruiseSpeed(driverPed, 3.0)
                TaskVehicleTempAction(driverPed, veh, 27, 1200)
            end
            if dist <= 0.5 then
                TaskVehicleTempAction(driverPed, veh, 27, 1500)
            end
            Wait(600)
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

RegisterCommand('autopilot', function(source, args, raw)
    pullPersonal()
    Wait(200)
    if personal then
        summonVehicle()
    else
        registerVehicle()
    end
end, false)

-- Open ESX default menu instead of custom NUI
local function openMenu()
    -- Define menu items mapped to existing commands
    local elements = {
        { label = 'Summon', value = 'autopilot' },
        { label = 'Stop & Park', value = 'autopilot_stop' },
        { label = 'Park', value = 'autopilot_park' },
        { label = 'Clear', value = 'autopilot_clear' },
    }

    if ESX and ESX.UI and ESX.UI.Menu then
        ESX.UI.Menu.CloseAll()
        ESX.UI.Menu.Open('default', GetCurrentResourceName(), 'autopilot_menu', {
            title = 'Autopilota',
            align = 'top-left',
            elements = elements,
        }, function(data, menu)
            local cmd = data.current and data.current.value
            if cmd then
                ExecuteCommand(cmd)
            end
        end, function(data, menu)
            menu.close()
        end)
    else
        -- Fallback: execute the primary action if ESX menu is unavailable
        ExecuteCommand('autopilot')
        notify('ESX menu non disponibile, eseguo Summon come fallback.')
    end
end

RegisterCommand('autopilot_menu', function(source, args, raw)
    openMenu()
end, false)

RegisterKeyMapping('autopilot_menu', 'Menu Autopilota', 'keyboard', MENU_KEY)

RegisterCommand('autopilot_stop', function(source, args, raw)
    stopAutopilot(true)
    notify('Autopilota fermato e veicolo parcheggiato.')
end, false)

RegisterCommand('autopilot_park', function(source, args, raw)
    parkVehicle()
    stopAutopilot()
    notify('Veicolo parcheggiato.')
end, false)

RegisterCommand('autopilot_clear', function(source, args, raw)
    stopAutopilot()
    personal = nil
    TriggerServerEvent('autopilot:clearPersonal')
    if vehicleBlip and DoesBlipExist(vehicleBlip) then
        RemoveBlip(vehicleBlip)
        vehicleBlip = nil
    end
    notify('Veicolo personale resettato.')
end, false)

-- Removed custom NUI callbacks; using ESX default menu

-- Maintain a blip on the personal vehicle if it exists (persistent)
CreateThread(function()
    local lastSeen = 0
    local lastCoords = nil
    local vanishTimeout = 15000 -- kept for reference; we no longer use it to remove the blip
    local lastReq = 0
    while true do
        local now = GetGameTimer()
        local veh = personal and findVehicle() or 0

        if veh ~= 0 and DoesEntityExist(veh) then
            -- Ensure blip exists and is attached to entity
            if not vehicleBlip or not DoesBlipExist(vehicleBlip) then
                vehicleBlip = AddBlipForEntity(veh)
                SetBlipSprite(vehicleBlip, 225) -- car
                SetBlipAsFriendly(vehicleBlip, true)
                SetBlipScale(vehicleBlip, 0.8)
                SetBlipHighDetail(vehicleBlip, true)
                SetBlipDisplay(vehicleBlip, 6)
                SetBlipPriority(vehicleBlip, 10)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName('Veicolo')
                EndTextCommandSetBlipName(vehicleBlip)
            end
            -- Update coordinates and last seen
            local vcoords = GetEntityCoords(veh)
            lastCoords = vcoords
            lastSeen = now
            if vehicleBlip and DoesBlipExist(vehicleBlip) then
                SetBlipCoords(vehicleBlip, vcoords.x, vcoords.y, vcoords.z)
            end
            -- Update lastState for smoother predictions if needed
            local vx, vy, vz = table.unpack(GetEntityVelocity(veh))
            local heading = GetEntityHeading(veh)
            lastState = {
                x = vcoords.x, y = vcoords.y, z = vcoords.z,
                heading = heading,
                vx = vx, vy = vy, vz = vz,
                lastSeen = now,
                receivedAt = now,
            }
        else
            -- Vehicle momentarily not found (streaming/despawn). Keep blip for a bit.
            local recentlySeen = (now - lastSeen) <= vanishTimeout
            -- Periodically request server state to keep simulation fresh
            if now - lastReq > 2000 then
                TriggerServerEvent('autopilot:getVehState')
                lastReq = now
            end
            if lastState then
                local pred = predictFromState(lastState, now)
                if pred then
                    lastCoords = vector3(pred.x, pred.y, pred.z)
                    lastSeen = now -- we simulate continuously
                end
            end
            -- Make blip persistent: if we have any coords (recent or predicted), keep showing
            if ((recentlySeen or lastState) and lastCoords) or lastCoords then
                if not vehicleBlip or not DoesBlipExist(vehicleBlip) then
                    -- Recreate a free blip at last known coords
                    vehicleBlip = AddBlipForCoord(lastCoords.x, lastCoords.y, lastCoords.z)
                    SetBlipSprite(vehicleBlip, 225)
                    SetBlipAsFriendly(vehicleBlip, true)
                    SetBlipScale(vehicleBlip, 0.8)
                    SetBlipHighDetail(vehicleBlip, true)
                    SetBlipDisplay(vehicleBlip, 6)
                    SetBlipPriority(vehicleBlip, 10)
                    BeginTextCommandSetBlipName('STRING')
                    AddTextComponentSubstringPlayerName('Veicolo')
                    EndTextCommandSetBlipName(vehicleBlip)
                else
                    SetBlipCoords(vehicleBlip, lastCoords.x, lastCoords.y, lastCoords.z)
                end
            else
                -- If no data available yet, keep trying without removing existing blip
                -- Only remove blip if personal entry is cleared elsewhere
            end
        end

        Wait(300)
    end
end)

-- On resource start, pull personal and last server state so the blip can appear immediately
CreateThread(function()
    Wait(1000)
    pullPersonal()
    Wait(200)
    TriggerServerEvent('autopilot:getVehState')
end)

-- Periodically push vehicle state to server for persistence/simulation
CreateThread(function()
    while true do
        if personal then
            local veh = findVehicle()
            if veh ~= 0 and DoesEntityExist(veh) then
                local vcoords = GetEntityCoords(veh)
                local heading = GetEntityHeading(veh)
                local vx, vy, vz = table.unpack(GetEntityVelocity(veh))
                local plate = personal and personal.plate or nil
                if plate and plate ~= '' then
                    TriggerServerEvent('autopilot:updateVehState', plate, vcoords.x, vcoords.y, vcoords.z, heading, vx, vy, vz, GetGameTimer())
                end
            end
        end
        Wait(500)
    end
end)
