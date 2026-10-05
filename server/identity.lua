local identity = {}

---@type table<number, string> source -> phone seen on its last request, used to settle presence on drop
local sourcePhone = {}
---@type table<string, true> phones with the app in the foreground
local foreground = {}
---@type table<string, table<number, true>> watched phone -> sources showing its presence
local watchers = {}

function identity.digits(value)
    local digits = tostring(value or ''):gsub('%D', '')
    return digits
end

function identity.now()
    return os.time()
end

---The acting character's number; sd-phone owns numbers (and SIMs), so it is asked every time.
function identity.phone(source)
    local ok, number = pcall(function() return exports['sd-phone']:getPhoneNumber(source) end)
    if not ok or not number then return nil end
    number = identity.digits(number)
    if number == '' then return nil end
    sourcePhone[source] = number
    return number
end

function identity.source(phone)
    local ok, src = pcall(function() return exports['sd-phone']:getSourceByNumber(phone) end)
    if ok and src then return src end
    return nil
end

function identity.inService(phone)
    local ok, result = pcall(function() return exports['sd-phone']:isNumberInService(phone) end)
    return ok and result == true
end

local function trim(value)
    local out = tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
    return out
end
identity.trim = trim

local function characterName(source)
    if GetResourceState('qbx_core') == 'started' then
        local player = exports.qbx_core:GetPlayer(source)
        local info = player and player.PlayerData and player.PlayerData.charinfo
        if info then
            local name = trim(('%s %s'):format(info.firstname or '', info.lastname or ''))
            if name ~= '' then return name:sub(1, 40) end
        end
    end
    return (GetPlayerName(source) or 'Whatzapp'):sub(1, 40)
end

local function serializeAccount(row)
    if not row then return nil end
    return {
        phone = row.phone,
        name = row.name,
        about = row.about,
        avatar = row.avatar,
        privacyLastSeen = row.privacy_last_seen == 1 or row.privacy_last_seen == true,
        privacyReceipts = row.privacy_receipts == 1 or row.privacy_receipts == true,
    }
end
identity.serializeAccount = serializeAccount

function identity.account(phone)
    return MySQL.single.await('SELECT * FROM `mri_qwhatzapp_accounts` WHERE `phone` = ?', { phone })
end

function identity.ensureAccount(source, phone)
    local row = identity.account(phone)
    if row then return row end
    MySQL.insert.await(
        'INSERT IGNORE INTO `mri_qwhatzapp_accounts` (`phone`, `name`, `about`, `created_at`) VALUES (?, ?, ?, ?)',
        { phone, characterName(source), locale('default_about'), identity.now() }
    )
    return identity.account(phone)
end

function identity.accounts(phones)
    local map = {}
    if #phones == 0 then return map end
    local rows = MySQL.query.await('SELECT * FROM `mri_qwhatzapp_accounts` WHERE `phone` IN (?)', { phones })
    for i = 1, #(rows or {}) do map[rows[i].phone] = rows[i] end
    return map
end

---Pushes a live event into the player's app, wherever it is drawn (phone or tablet).
function identity.pushSource(source, action, data)
    TriggerClientEvent('mri_Qwhatzapp:client:push', source, action, data)
end

function identity.push(phone, action, data)
    local src = identity.source(phone)
    if src then identity.pushSource(src, action, data) end
    return src
end

---Whether `viewer` may see `phone`'s presence: both must share last seen (mutual, like the real app).
local function presenceOf(phone, viewerAccount)
    local account = identity.account(phone)
    if not account then return { phone = phone, online = false, lastSeen = 0 } end
    local shares = account.privacy_last_seen == 1 and (not viewerAccount or viewerAccount.privacy_last_seen == 1)
    return {
        phone = phone,
        online = foreground[phone] == true and identity.source(phone) ~= nil,
        lastSeen = shares and account.last_seen or 0,
    }
end

function identity.presence(phone, viewerPhone)
    return presenceOf(phone, viewerPhone and identity.account(viewerPhone) or nil)
end

local function broadcastPresence(phone)
    local list = watchers[phone]
    if not list then return end
    for src in pairs(list) do
        local viewer = sourcePhone[src]
        if viewer and GetPlayerName(src) then
            identity.pushSource(src, 'presence', identity.presence(phone, viewer))
        else
            list[src] = nil
        end
    end
end

function identity.watch(source, phone)
    for watched, list in pairs(watchers) do
        list[source] = nil
        if next(list) == nil then watchers[watched] = nil end
    end
    if not phone then return end
    watchers[phone] = watchers[phone] or {}
    watchers[phone][source] = true
end

function identity.setForeground(source, phone, open)
    if open then
        foreground[phone] = true
    else
        foreground[phone] = nil
        MySQL.update.await('UPDATE `mri_qwhatzapp_accounts` SET `last_seen` = ? WHERE `phone` = ?', { identity.now(), phone })
    end
    broadcastPresence(phone)
end

AddEventHandler('playerDropped', function()
    local src = source
    local phone = sourcePhone[src]
    sourcePhone[src] = nil
    identity.watch(src, nil)
    if phone and foreground[phone] then
        foreground[phone] = nil
        MySQL.update('UPDATE `mri_qwhatzapp_accounts` SET `last_seen` = ? WHERE `phone` = ?', { identity.now(), phone })
        broadcastPresence(phone)
    end
end)

---The player's sd-phone contacts as { phone, name, avatar }.
function identity.contacts(source)
    local ok, list = pcall(function() return exports['sd-phone']:getContacts(source) end)
    local out = {}
    if not ok or type(list) ~= 'table' then return out end
    for i = 1, #list do
        local entry = list[i]
        local number = identity.digits(entry.phone)
        if number ~= '' then
            out[#out + 1] = { phone = number, name = entry.name, avatar = entry.avatar }
        end
    end
    return out
end

---How `phone` appears to the player at `viewerSource`: their contact name, else the profile name.
function identity.displayName(viewerSource, phone, fallback)
    local ok, contact = pcall(function() return exports['sd-phone']:getContactByNumber(viewerSource, phone) end)
    if ok and type(contact) == 'table' and contact.name and contact.name ~= '' then return contact.name end
    if fallback and fallback ~= '' then return fallback end
    local account = identity.account(phone)
    return account and account.name or phone
end

return identity
