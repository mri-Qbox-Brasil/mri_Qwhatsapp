local config = require 'server.config'
local identity = require 'server.identity'
local chats = require 'server.chats'

local handlers = {}
local trim = identity.trim

local function fail(code) return { ok = false, error = code } end
local function ok(data) return { ok = true, data = data } end

local COLORS = { ['#25D366'] = true, ['#128C7E'] = true, ['#7E57C2'] = true, ['#EF5350'] = true, ['#FFA726'] = true, ['#26A69A'] = true, ['#5C6BC0'] = true, ['#EC407A'] = true, ['#8D6E63'] = true, ['#263238'] = true }

local function serialize(row, viewed)
    return {
        id = row.id,
        phone = row.phone,
        kind = row.kind,
        body = row.body,
        media = row.media,
        color = row.color,
        createdAt = row.created_at,
        expiresAt = row.expires_at,
        viewed = viewed == true,
    }
end

---Everyone whose status the player may see: their sd-phone contacts plus direct-chat partners.
local function audienceOf(source, phone)
    local phones, seen = {}, { [phone] = true }
    for _, contact in ipairs(identity.contacts(source)) do
        if not seen[contact.phone] then
            seen[contact.phone] = true
            phones[#phones + 1] = contact.phone
        end
    end
    local partners = MySQL.query.await([[SELECT b.`phone` FROM `mri_qwhatzapp_members` a
        JOIN `mri_qwhatzapp_chats` c ON c.`id` = a.`chat_id` AND c.`kind` = 'direct'
        JOIN `mri_qwhatzapp_members` b ON b.`chat_id` = a.`chat_id` AND b.`phone` <> a.`phone`
        WHERE a.`phone` = ?]], { phone }) or {}
    for i = 1, #partners do
        local other = partners[i].phone
        if not seen[other] then
            seen[other] = true
            phones[#phones + 1] = other
        end
    end
    return phones
end

handlers.statusList = function(source, phone)
    local t = identity.now()
    local mine = {}
    for _, row in ipairs(MySQL.query.await('SELECT * FROM `mri_qwhatzapp_statuses` WHERE `phone` = ? AND `expires_at` > ? ORDER BY `id` ASC', { phone, t }) or {}) do
        local item = serialize(row, true)
        item.views = MySQL.scalar.await('SELECT COUNT(*) FROM `mri_qwhatzapp_status_views` WHERE `status_id` = ?', { row.id }) or 0
        mine[#mine + 1] = item
    end

    local audience = audienceOf(source, phone)
    local others = {}
    if #audience > 0 then
        local rows = MySQL.query.await([[SELECT s.*, v.`viewed_at` FROM `mri_qwhatzapp_statuses` s
            LEFT JOIN `mri_qwhatzapp_status_views` v ON v.`status_id` = s.`id` AND v.`phone` = ?
            WHERE s.`phone` IN (?) AND s.`expires_at` > ?
            AND NOT EXISTS (SELECT 1 FROM `mri_qwhatzapp_blocks` b WHERE (b.`phone` = ? AND b.`blocked` = s.`phone`) OR (b.`phone` = s.`phone` AND b.`blocked` = ?))
            ORDER BY s.`id` ASC]], { phone, audience, t, phone, phone }) or {}
        local byPhone, order = {}, {}
        for i = 1, #rows do
            local row = rows[i]
            if not byPhone[row.phone] then
                byPhone[row.phone] = { phone = row.phone, items = {} }
                order[#order + 1] = row.phone
            end
            local list = byPhone[row.phone].items
            list[#list + 1] = serialize(row, row.viewed_at ~= nil)
        end
        local accounts = identity.accounts(order)
        for i = 1, #order do
            local entry = byPhone[order[i]]
            local account = accounts[entry.phone]
            entry.name = account and account.name or nil
            entry.avatar = account and account.avatar or nil
            others[#others + 1] = entry
        end
    end
    return ok({ mine = mine, others = others })
end

handlers.statusPost = function(_, phone, payload)
    local kind = payload.kind == 'image' and 'image' or 'text'
    local body = type(payload.body) == 'string' and trim(payload.body):sub(1, 700) or ''
    local media
    if kind == 'image' then
        media = payload.media
        if type(media) ~= 'string' or #media > 512 or not media:match('^https?://') then return fail('invalid') end
    elseif body == '' then
        return fail('empty')
    end
    local color = COLORS[payload.color] and payload.color or '#128C7E'
    local t = identity.now()
    local id = MySQL.insert.await(
        'INSERT INTO `mri_qwhatzapp_statuses` (`phone`, `kind`, `body`, `media`, `color`, `created_at`, `expires_at`) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { phone, kind, body ~= '' and body or nil, media, color, t, t + config.statusHours * 3600 }
    )
    return ok({ id = id })
end

handlers.statusView = function(source, phone, payload)
    local id = tonumber(payload.id)
    local row = id and MySQL.single.await('SELECT `phone` FROM `mri_qwhatzapp_statuses` WHERE `id` = ?', { id })
    if not row or row.phone == phone then return ok(true) end
    if chats.isBlocked(row.phone, phone) or chats.isBlocked(phone, row.phone) then return fail('invalid') end
    local visible = false
    for _, other in ipairs(audienceOf(source, phone)) do
        if other == row.phone then visible = true break end
    end
    if not visible then return fail('invalid') end
    MySQL.insert.await('INSERT IGNORE INTO `mri_qwhatzapp_status_views` (`status_id`, `phone`, `viewed_at`) VALUES (?, ?, ?)', { id, phone, identity.now() })
    return ok(true)
end

handlers.statusViewers = function(_, phone, payload)
    local id = tonumber(payload.id)
    local row = id and MySQL.single.await('SELECT `phone` FROM `mri_qwhatzapp_statuses` WHERE `id` = ?', { id })
    if not row or row.phone ~= phone then return fail('invalid') end
    local views = MySQL.query.await('SELECT `phone`, `viewed_at` FROM `mri_qwhatzapp_status_views` WHERE `status_id` = ? ORDER BY `viewed_at` DESC', { id }) or {}
    local phones = {}
    for i = 1, #views do phones[i] = views[i].phone end
    local accounts = identity.accounts(phones)
    local out = {}
    for i = 1, #views do
        local account = accounts[views[i].phone]
        out[i] = { phone = views[i].phone, viewedAt = views[i].viewed_at, name = account and account.name or nil, avatar = account and account.avatar or nil }
    end
    return ok(out)
end

handlers.statusDelete = function(_, phone, payload)
    local id = tonumber(payload.id)
    if not id then return fail('invalid') end
    MySQL.update.await('DELETE FROM `mri_qwhatzapp_statuses` WHERE `id` = ? AND `phone` = ?', { id, phone })
    MySQL.update.await('DELETE FROM `mri_qwhatzapp_status_views` WHERE `status_id` = ?', { id })
    return ok(true)
end

CreateThread(function()
    while true do
        Wait(10 * 60000)
        local t = identity.now()
        MySQL.update.await('DELETE v FROM `mri_qwhatzapp_status_views` v JOIN `mri_qwhatzapp_statuses` s ON s.`id` = v.`status_id` WHERE s.`expires_at` <= ?', { t })
        MySQL.update.await('DELETE FROM `mri_qwhatzapp_statuses` WHERE `expires_at` <= ?', { t })
    end
end)

return { handlers = handlers }
