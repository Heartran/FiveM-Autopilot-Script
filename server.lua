local personal = {} -- [source] = { netId = number, plate = string }

-- Lista di nodi di parcheggio predefiniti che il server può restituire al client.
-- Personalizzala con coordinate reali della tua mappa/server.
local parkNodes = {
    { x = 215.76, y = -810.12, z = 29.73, heading = 90.0 }, -- esempio: vicino a police station
    { x = -47.01, y = -1115.14, z = 26.43, heading = 180.0 },
    { x = -273.68, y = -911.35, z = 31.22, heading = 45.0 },
}

RegisterNetEvent('autopilot:registerPersonal', function(netId, plate)
    local src = source
    -- sanitizzazione minimale
    local nid = tonumber(netId) or netId
    local p = tostring(plate or ''):gsub('%s+', '')
    personal[src] = { netId = nid, plate = p }
    TriggerClientEvent('autopilot:notify', src, ('Veicolo personale registrato (%s).'):format(p))
end)

RegisterNetEvent('autopilot:clearPersonal', function()
    local p = personal[source]
    if p and p.plate then
        vehicleState[p.plate] = nil
    end
    personal[source] = nil
end)

RegisterNetEvent('autopilot:getPersonal', function()
    local src = source
    local data = personal[src]
    TriggerClientEvent('autopilot:cbPersonal', src, data)
end)


-- Server-side: restituisce al client il nodo di parcheggio più vicino alle coordinate fornite
RegisterNetEvent('autopilot:requestParkNode', function(px, py, pz)
    local src = source
    if not px or not py or not pz then
        TriggerClientEvent('autopilot:cbParkNode', src, nil)
        return
    end
    local best = nil
    local bestDist = nil
    for _, node in ipairs(parkNodes) do
        local dx = node.x - px
        local dy = node.y - py
        local dz = node.z - pz
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
        if not bestDist or dist < bestDist then
            bestDist = dist
            best = node
        end
    end
    TriggerClientEvent('autopilot:cbParkNode', src, best)
end)

AddEventHandler('playerDropped', function()
    local p = personal[source]
    if p and p.plate then
        vehicleState[p.plate] = nil
    end
    personal[source] = nil
end)
