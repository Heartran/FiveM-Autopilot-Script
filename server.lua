-- Server side for Autopilot rewrite
-- Keeps track of each player's registered personal vehicle.

local personal = {}
local vehicleState = {} -- keyed by plate: { x, y, z, heading, vx, vy, vz, lastSeen }

RegisterNetEvent('autopilot:registerPersonal', function(netId, plate)
    personal[source] = { netId = netId, plate = plate }
    TriggerClientEvent('autopilot:notify', source, ('Veicolo personale registrato (%s).'):format(plate))
end)

RegisterNetEvent('autopilot:clearPersonal', function()
    local p = personal[source]
    if p and p.plate then
        vehicleState[p.plate] = nil
    end
    personal[source] = nil
end)

RegisterNetEvent('autopilot:getPersonal', function()
    TriggerClientEvent('autopilot:cbPersonal', source, personal[source])
end)

-- Save last known vehicle transform/velocity (from client)
RegisterNetEvent('autopilot:updateVehState', function(plate, x, y, z, heading, vx, vy, vz, lastSeen)
    if type(plate) ~= 'string' or plate == '' then return end
    vehicleState[plate] = {
        x = x, y = y, z = z,
        heading = heading,
        vx = vx, vy = vy, vz = vz,
        lastSeen = lastSeen or GetGameTimer()
    }
end)

-- Provide saved vehicle state to client
RegisterNetEvent('autopilot:getVehState', function()
    local src = source
    local p = personal[src]
    local state = nil
    if p and p.plate then
        state = vehicleState[p.plate]
    end
    TriggerClientEvent('autopilot:cbVehState', src, state)
end)

AddEventHandler('playerDropped', function()
    local p = personal[source]
    if p and p.plate then
        vehicleState[p.plate] = nil
    end
    personal[source] = nil
end)
