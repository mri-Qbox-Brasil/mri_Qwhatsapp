local APP_ID = 'mri_whatsapp'
local PHONE = 'sd-phone'

local ACTIONS = {}
for _, name in ipairs({
    'bootstrap', 'contacts', 'profiles', 'updateProfile', 'presenceWatch',
    'send', 'forward', 'messages', 'markRead', 'typing', 'search',
    'react', 'edit', 'delete', 'star', 'starred', 'media',
    'openDirect', 'chatSettings', 'clearChat', 'deleteChat', 'chatInfo',
    'createGroup', 'updateGroup', 'addMembers', 'removeMember', 'setRole', 'leaveGroup',
    'block', 'statusList', 'statusPost', 'statusView', 'statusViewers', 'statusDelete',
    'callLog', 'callList', 'callClear',
}) do ACTIONS[name] = true end

local function foreground(open)
    lib.callback('mri_Qwhatsapp:foreground', false, function() end, { open = open })
end

---Icon URL tagged with a hash of the file, so the NUI cache drops it whenever the icon changes.
local function iconUrl()
    local svg = LoadResourceFile(cache.resource, 'web/build/icon.svg') or ''
    local hash = 0
    for i = 1, #svg do hash = (hash * 31 + svg:byte(i)) % 2147483647 end
    return ('https://cfx-nui-%s/web/build/icon.svg?v=%d'):format(cache.resource, hash)
end

local function register()
    local ok, err = exports[PHONE]:addCustomApp({
        identifier = APP_ID,
        name = 'Whatzap',
        description = locale('app_description'),
        developer = 'MRI Qbox',
        defaultApp = true,
        size = 48000,
        icon = iconUrl(),
        ui = ('%s/web/build/index.html'):format(cache.resource),
        images = {},
        onOpen = function() foreground(true) end,
        onClose = function() foreground(false) end,
    })
    if not ok then lib.print.error(('addCustomApp: %s'):format(err)) end
end

CreateThread(register)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == PHONE then register() end
end)

RegisterNetEvent('mri_Qwhatsapp:client:push', function(action, data)
    exports[PHONE]:sendCustomAppMessage(APP_ID, { action = action, data = data })
end)

RegisterNUICallback('rpc', function(data, cb)
    local action = type(data) == 'table' and data.action or nil
    if not ACTIONS[action] then return cb({ ok = false, error = 'invalid' }) end
    local result = lib.callback.await('mri_Qwhatsapp:' .. action, false, data.payload)
    cb(result or { ok = false, error = 'server' })
end)

---The tablet has no cellular radio, so the UI hides calling while it is the one drawing the app.
RegisterNUICallback('device', function(_, cb)
    local tablet = GetResourceState('sd-tablet') == 'started' and exports['sd-tablet']:isOpen() == true
    cb({ tablet = tablet })
end)

RegisterNUICallback('location', function(_, cb)
    local coords = GetEntityCoords(cache.ped)
    local streetHash, crossingHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local street = GetStreetNameFromHashKey(streetHash)
    local crossing = crossingHash ~= 0 and GetStreetNameFromHashKey(crossingHash) or nil
    local zone = GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z))
    local label = crossing and crossing ~= '' and ('%s / %s'):format(street, crossing) or street
    if zone and zone ~= '' and zone ~= 'NULL' then label = ('%s, %s'):format(label, zone) end
    cb({ x = coords.x, y = coords.y, label = label })
end)

RegisterNUICallback('waypoint', function(data, cb)
    local x, y = tonumber(data and data.x), tonumber(data and data.y)
    if x and y then
        SetNewWaypoint(x, y)
        lib.notify({ description = locale('waypoint_set'), type = 'success' })
    end
    cb(true)
end)
