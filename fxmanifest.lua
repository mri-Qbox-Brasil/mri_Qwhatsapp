fx_version 'cerulean'
lua54 'yes'
game 'gta5'

name 'mri_Qwhatsapp'
author 'MRI Qbox Brasil'
version '1.0.1'
description 'Whatzap: mensageiro para o sd-phone e o sd-tablet: conversas, grupos, status, mídia, áudio e ligações'

ox_lib 'locale'

shared_scripts {
    '@ox_lib/init.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

files {
    'locales/*.json',
    'web/build/index.html',
    'web/build/**',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'sd-phone',
}
