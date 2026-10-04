local config = require 'server.config'
local identity = require 'server.identity'
local chats = require 'server.chats'
local status = require 'server.status'
local calls = require 'server.calls'

local ready = false

local function fail(code) return { ok = false, error = code } end
local function ok(data) return { ok = true, data = data } end

local handlers = {}
for _, group in ipairs({ chats.handlers, status.handlers, calls.handlers }) do
    for name, fn in pairs(group) do handlers[name] = fn end
end

handlers.bootstrap = function(source, phone)
    local account = identity.ensureAccount(source, phone)
    local list = handlers.bootstrapChats(source, phone)
    return ok({
        me = identity.serializeAccount(account),
        chats = list.data,
        contacts = identity.contacts(source),
        blocked = chats.blockedList(phone),
        limits = {
            maxMessageLength = config.maxMessageLength,
            maxGroupMembers = config.maxGroupMembers,
            maxForward = config.maxForward,
            editWindowMinutes = config.editWindowMinutes,
            revokeWindowMinutes = config.revokeWindowMinutes,
        },
    })
end

handlers.contacts = function(source)
    return ok(identity.contacts(source))
end

---Profile names and photos for numbers the UI has to draw (contacts with no chat yet, viewers).
handlers.profiles = function(_, _, payload)
    local phones = {}
    if type(payload.phones) == 'table' then
        for i = 1, math.min(#payload.phones, 200) do
            local number = identity.digits(payload.phones[i])
            if number ~= '' then phones[#phones + 1] = number end
        end
    end
    local out = {}
    for number, row in pairs(identity.accounts(phones)) do
        out[number] = { name = row.name, avatar = row.avatar, about = row.about }
    end
    return ok(out)
end

handlers.updateProfile = function(_, phone, payload)
    local sets, params = {}, {}
    if payload.name ~= nil then
        local name = identity.trim(payload.name):sub(1, 40)
        if name == '' then return fail('nameRequired') end
        sets[#sets + 1] = '`name` = ?'
        params[#params + 1] = name
    end
    if payload.about ~= nil then
        sets[#sets + 1] = '`about` = ?'
        params[#params + 1] = identity.trim(payload.about):sub(1, 140)
    end
    if payload.avatar ~= nil then
        local avatar = payload.avatar
        if avatar ~= false and (type(avatar) ~= 'string' or #avatar > 512 or not avatar:match('^https?://')) then return fail('invalid') end
        sets[#sets + 1] = '`avatar` = ?'
        params[#params + 1] = avatar or nil
    end
    if payload.privacyLastSeen ~= nil then
        sets[#sets + 1] = '`privacy_last_seen` = ?'
        params[#params + 1] = payload.privacyLastSeen and 1 or 0
    end
    if payload.privacyReceipts ~= nil then
        sets[#sets + 1] = '`privacy_receipts` = ?'
        params[#params + 1] = payload.privacyReceipts and 1 or 0
    end
    if #sets == 0 then return fail('invalid') end
    params[#params + 1] = phone
    MySQL.update.await(('UPDATE `mri_whatzapp_accounts` SET %s WHERE `phone` = ?'):format(table.concat(sets, ', ')), params)
    return ok(identity.serializeAccount(identity.account(phone)))
end

handlers.presenceWatch = function(source, phone, payload)
    local target = payload.phone and identity.digits(payload.phone) or ''
    if target == '' then
        identity.watch(source, nil)
        return ok(nil)
    end
    identity.watch(source, target)
    if chats.isBlocked(target, phone) then return ok({ phone = target, online = false, lastSeen = 0 }) end
    return ok(identity.presence(target, phone))
end

handlers.foreground = function(source, phone, payload)
    identity.setForeground(source, phone, payload.open == true)
    return ok(true)
end

for name, fn in pairs(handlers) do
    lib.callback.register('mri_Qwhatzapp:' .. name, function(source, payload)
        if not ready then return fail('notReady') end
        local phone = identity.phone(source)
        if not phone then return fail('noPhone') end
        local success, result = pcall(fn, source, phone, type(payload) == 'table' and payload or {})
        if not success then
            lib.print.error(('%s: %s'):format(name, result))
            return fail('server')
        end
        return result
    end)
end

CreateThread(function()
    require 'server.schema' ()
    ready = true
end)
