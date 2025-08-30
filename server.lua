-- Server side for Autopilot rewrite
-- Keeps track of each player's registered personal vehicle.

local personal = {}

RegisterNetEvent('autopilot:registerPersonal', function(netId, plate)
    local src = source
    local ent = NetworkGetEntityFromNetworkId(netId or -1)
    local ok = false
    if ent ~= 0 and DoesEntityExist(ent) and IsEntityAVehicle(ent) then
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and veh == ent and GetPedInVehicleSeat(veh, -1) == ped then
                ok = true
            end
        end
    end

    -- sanitize plate (server-side)
    plate = tostring(plate or ''):gsub('%s+', '')
    if #plate > 12 then plate = plate:sub(1, 12) end

    if ok then
        personal[src] = { netId = netId, plate = plate }
        TriggerClientEvent('autopilot:notify', src, ('Veicolo personale registrato (%s).'):format(plate))
    else
        TriggerClientEvent('autopilot:notify', src, 'Registrazione veicolo non valida. Siediti al posto di guida e riprova.')
    end
end)

RegisterNetEvent('autopilot:clearPersonal', function()
    personal[source] = nil
end)

RegisterNetEvent('autopilot:getPersonal', function()
    TriggerClientEvent('autopilot:cbPersonal', source, personal[source])
end)

AddEventHandler('playerDropped', function()
    personal[source] = nil
end)
