-- Server side for Autopilot rewrite
-- Keeps track of each player's registered personal vehicle.

local personal = {}

RegisterNetEvent('autopilot:registerPersonal', function(netId, plate)
    personal[source] = { netId = netId, plate = plate }
    TriggerClientEvent('autopilot:notify', source, ('Veicolo personale registrato (%s).'):format(plate))
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
