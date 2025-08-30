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
