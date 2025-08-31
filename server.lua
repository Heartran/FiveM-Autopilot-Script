local personal = {} -- [source] = { netId = number, plate = string }

RegisterNetEvent('autopilot:registerPersonal', function(netId, plate)
    local src = source
    personal[src] = { netId = netId, plate = plate }
    TriggerClientEvent('autopilot:notify', src, ('Veicolo personale registrato (%s).'):format(plate))
end)

RegisterNetEvent('autopilot:clearPersonal', function()
    local src = source
    personal[src] = nil
end)

lib = lib or {} -- no-op, in caso di future estensioni

RegisterNetEvent('autopilot:getPersonal', function()
    local src = source
    local data = personal[src]
    TriggerClientEvent('autopilot:cbPersonal', src, data)
end)

AddEventHandler('playerDropped', function()
    local src = source
    personal[src] = nil
end)

-- Handler ibrido: risponde con uno spot di parcheggio semplice
RegisterNetEvent('autopilot:requestParkSpot', function(netId, vx, vy, vz, vheading)
    local src = source
    -- Validazione minima: se non riceviamo coordinate, ignoriamo
    if not netId or not vx or not vy or not vz then
        TriggerClientEvent('__autopilot:parkSpotResp', src, nil)
        return
    end

    -- Per ora: fallback semplice che ritorna le stesse coordinate (server può implementare logica avanzata)
    local resp = { x = vx, y = vy, z = vz, heading = vheading, meta = { source = 'server-echo' } }
    TriggerClientEvent('__autopilot:parkSpotResp', src, resp)
end)
