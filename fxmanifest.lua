fx_version 'cerulean'
game 'gta5'

name 'autopilot'
author 'Heartran'
description 'Autopilota: registra veicolo personale e richiamalo ovunque'
version '1.0.0'
lua54 'yes'

client_scripts {
    '@es_extended/imports.lua',
    'client.lua'
}

server_scripts {
    'server.lua'
}

dependencies {
    'es_extended',
    'esx_menu_default'
}
