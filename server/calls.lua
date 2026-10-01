local config = require 'server.config'
local identity = require 'server.identity'
local chats = require 'server.chats'

local handlers = {}

local function fail(code) return { ok = false, error = code } end
local function ok(data) return { ok = true, data = data } end

local function serialize(row, phone)
    local outgoing = row.caller == phone
    return {
        id = row.id,
        phone = outgoing and row.callee or row.caller,
        direction = outgoing and 'out' or 'in',
        video = row.video == 1 or row.video == true,
        createdAt = row.created_at,
    }
end

---Logs a call placed from the app; the call itself is the phone's (sd-phone dialler).
handlers.callLog = function(_, phone, payload)
    local other = identity.digits(payload.phone)
    if other == '' or other == phone then return fail('invalidNumber') end
    if not identity.inService(other) then return fail('notInService') end
    if chats.isBlocked(phone, other) then return fail('youBlocked') end
    local id = MySQL.insert.await(
        'INSERT INTO `mri_whatsapp_calls` (`caller`, `callee`, `video`, `created_at`) VALUES (?, ?, ?, ?)',
        { phone, other, payload.video and 1 or 0, identity.now() }
    )
    local row = MySQL.single.await('SELECT * FROM `mri_whatsapp_calls` WHERE `id` = ?', { id })
    if not chats.isBlocked(other, phone) then
        identity.push(other, 'call:new', serialize(row, other))
    end
    return ok(serialize(row, phone))
end

handlers.callList = function(_, phone)
    local rows = MySQL.query.await(
        'SELECT * FROM `mri_whatsapp_calls` WHERE (`caller` = ? AND `caller_hidden` = 0) OR (`callee` = ? AND `callee_hidden` = 0) ORDER BY `id` DESC LIMIT ?',
        { phone, phone, config.callLogLimit }
    ) or {}
    local out = {}
    for i = 1, #rows do out[i] = serialize(rows[i], phone) end
    return ok(out)
end

handlers.callClear = function(_, phone)
    MySQL.update.await('UPDATE `mri_whatsapp_calls` SET `caller_hidden` = 1 WHERE `caller` = ?', { phone })
    MySQL.update.await('UPDATE `mri_whatsapp_calls` SET `callee_hidden` = 1 WHERE `callee` = ?', { phone })
    return ok(true)
end

return { handlers = handlers }
