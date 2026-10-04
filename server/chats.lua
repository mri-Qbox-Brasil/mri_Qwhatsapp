local config = require 'server.config'
local identity = require 'server.identity'

local chats = {}
local handlers = {}
chats.handlers = handlers

local digits, now, trim = identity.digits, identity.now, identity.trim

local MESSAGE_KINDS = { text = true, image = true, gif = true, audio = true, location = true, contact = true }

local function fail(code) return { ok = false, error = code } end
local function ok(data) return { ok = true, data = data } end

local function isTrue(value) return value == 1 or value == true end

local function isUrl(value)
    return type(value) == 'string' and #value <= 512 and value:match('^https?://') ~= nil
end

local function cleanText(value, limit)
    if type(value) ~= 'string' then return nil end
    local text = trim(value)
    if text == '' then return nil end
    return text:sub(1, limit)
end

local function decodeMeta(raw)
    if not raw or raw == '' then return {} end
    local okDecode, value = pcall(json.decode, raw)
    return okDecode and type(value) == 'table' and value or {}
end

-------------------------------------------------------------------- membership

local function member(chatId, phone)
    return MySQL.single.await('SELECT * FROM `mri_whatsapp_members` WHERE `chat_id` = ? AND `phone` = ?', { chatId, phone })
end

local function memberRows(chatId)
    return MySQL.query.await('SELECT * FROM `mri_whatsapp_members` WHERE `chat_id` = ?', { chatId }) or {}
end

local function chatRow(chatId)
    return MySQL.single.await('SELECT * FROM `mri_whatsapp_chats` WHERE `id` = ?', { chatId })
end

local function isBlocked(owner, other)
    return MySQL.scalar.await('SELECT 1 FROM `mri_whatsapp_blocks` WHERE `phone` = ? AND `blocked` = ?', { owner, other }) ~= nil
end
chats.isBlocked = isBlocked

local function latestId(chatId)
    -- COALESCE comes back as DECIMAL, which oxmysql hands over as a string.
    return tonumber(MySQL.scalar.await('SELECT COALESCE(MAX(`id`), 0) FROM `mri_whatsapp_messages` WHERE `chat_id` = ?', { chatId })) or 0
end

-------------------------------------------------------------------- serialization

---Reactions, stars and quoted messages for a page of rows, as seen by `viewer`.
local function extras(rows, viewer)
    local ids, replyIds = {}, {}
    for i = 1, #rows do
        ids[#ids + 1] = rows[i].id
        if rows[i].reply_to then replyIds[#replyIds + 1] = rows[i].reply_to end
    end

    local reactions, starred, replies = {}, {}, {}
    if #ids == 0 then return reactions, starred, replies end

    for _, row in ipairs(MySQL.query.await('SELECT * FROM `mri_whatsapp_reactions` WHERE `message_id` IN (?)', { ids }) or {}) do
        reactions[row.message_id] = reactions[row.message_id] or {}
        local list = reactions[row.message_id]
        list[#list + 1] = { phone = row.phone, emoji = row.emoji }
    end
    for _, row in ipairs(MySQL.query.await('SELECT `message_id` FROM `mri_whatsapp_starred` WHERE `phone` = ? AND `message_id` IN (?)', { viewer, ids }) or {}) do
        starred[row.message_id] = true
    end
    if #replyIds > 0 then
        for _, row in ipairs(MySQL.query.await('SELECT * FROM `mri_whatsapp_messages` WHERE `id` IN (?)', { replyIds }) or {}) do
            local revoked = isTrue(row.revoked)
            replies[row.id] = {
                id = row.id,
                sender = row.sender,
                kind = row.kind,
                body = not revoked and row.body and row.body:sub(1, 160) or nil,
                media = not revoked and row.media or nil,
                revoked = revoked,
            }
        end
    end
    return reactions, starred, replies
end

local function serialize(row, reactions, starred, replies)
    local revoked = isTrue(row.revoked)
    return {
        id = row.id,
        chatId = row.chat_id,
        sender = row.sender,
        kind = row.kind,
        body = not revoked and row.body or nil,
        media = not revoked and row.media or nil,
        meta = revoked and {} or decodeMeta(row.meta),
        replyTo = row.reply_to and replies[row.reply_to] or nil,
        edited = isTrue(row.edited),
        revoked = revoked,
        createdAt = row.created_at,
        reactions = reactions[row.id] or {},
        starred = starred[row.id] == true,
    }
end

local function serializeRows(rows, viewer)
    local reactions, starred, replies = extras(rows, viewer)
    local out = {}
    for i = 1, #rows do out[i] = serialize(rows[i], reactions, starred, replies) end
    return out
end

local function serializeOne(row, viewer)
    return serializeRows({ row }, viewer)[1]
end

local function messageRow(id)
    return MySQL.single.await('SELECT * FROM `mri_whatsapp_messages` WHERE `id` = ?', { id })
end

-------------------------------------------------------------------- receipts

---Member receipts as `viewer` may see them. Direct chats honour both sides' read-receipt privacy.
local function receiptsFor(chat, rows, accounts, viewer)
    local viewerAccount = accounts[viewer]
    local viewerShares = not viewerAccount or isTrue(viewerAccount.privacy_receipts)
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        local account = accounts[row.phone]
        local read = row.last_read
        if chat.kind == 'direct' and row.phone ~= viewer then
            local shares = not account or isTrue(account.privacy_receipts)
            if not (shares and viewerShares) then read = 0 end
        end
        out[#out + 1] = {
            phone = row.phone,
            role = row.role,
            joinedAt = row.joined_at,
            read = read,
            delivered = math.max(row.last_delivered, read),
            name = account and account.name or nil,
            avatar = account and account.avatar or nil,
            about = account and account.about or nil,
        }
    end
    return out
end

---Tells every online member the chat's current receipts, each from their own point of view.
local function broadcastReceipts(chatId)
    local chat = chatRow(chatId)
    if not chat then return end
    local rows = memberRows(chatId)
    local phones = {}
    for i = 1, #rows do phones[i] = rows[i].phone end
    local accounts = identity.accounts(phones)
    for i = 1, #rows do
        local src = identity.source(rows[i].phone)
        if src then
            identity.pushSource(src, 'receipts', { chatId = chatId, members = receiptsFor(chat, rows, accounts, rows[i].phone) })
        end
    end
end

-------------------------------------------------------------------- chat list

local CHAT_LIST_SQL = [[
SELECT c.*, m.`role`, m.`last_read`, m.`cleared_before`, m.`pinned`, m.`archived`, m.`muted`, m.`joined_at`,
    (SELECT MAX(x.`id`) FROM `mri_whatsapp_messages` x
        WHERE x.`chat_id` = c.`id` AND x.`id` > m.`cleared_before`
        AND NOT EXISTS (SELECT 1 FROM `mri_whatsapp_hidden` h WHERE h.`message_id` = x.`id` AND h.`phone` = m.`phone`)) AS `last_id`,
    (SELECT COUNT(*) FROM `mri_whatsapp_messages` x
        WHERE x.`chat_id` = c.`id` AND x.`id` > GREATEST(m.`last_read`, m.`cleared_before`)
        AND x.`sender` <> m.`phone` AND x.`kind` <> 'system'
        AND NOT EXISTS (SELECT 1 FROM `mri_whatsapp_hidden` h WHERE h.`message_id` = x.`id` AND h.`phone` = m.`phone`)) AS `unread`
FROM `mri_whatsapp_members` m
JOIN `mri_whatsapp_chats` c ON c.`id` = m.`chat_id`
WHERE m.`phone` = ?]]

local function listChats(phone, onlyChatId)
    local rows
    if onlyChatId then
        rows = MySQL.query.await(CHAT_LIST_SQL .. ' AND m.`chat_id` = ?', { phone, onlyChatId })
    else
        rows = MySQL.query.await(CHAT_LIST_SQL, { phone })
    end
    rows = rows or {}
    if #rows == 0 then return {} end

    local chatIds, lastIds = {}, {}
    for i = 1, #rows do
        chatIds[#chatIds + 1] = rows[i].id
        if rows[i].last_id then lastIds[#lastIds + 1] = rows[i].last_id end
    end

    local membersByChat, phones, seen = {}, {}, {}
    for _, row in ipairs(MySQL.query.await('SELECT * FROM `mri_whatsapp_members` WHERE `chat_id` IN (?)', { chatIds }) or {}) do
        membersByChat[row.chat_id] = membersByChat[row.chat_id] or {}
        local list = membersByChat[row.chat_id]
        list[#list + 1] = row
        if not seen[row.phone] then
            seen[row.phone] = true
            phones[#phones + 1] = row.phone
        end
    end
    local accounts = identity.accounts(phones)

    local lastById = {}
    if #lastIds > 0 then
        local lastRows = MySQL.query.await('SELECT * FROM `mri_whatsapp_messages` WHERE `id` IN (?)', { lastIds }) or {}
        for _, message in ipairs(serializeRows(lastRows, phone)) do lastById[message.id] = message end
    end

    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        if row.kind == 'group' or row.last_id or onlyChatId then
            local members = receiptsFor(row, membersByChat[row.id] or {}, accounts, phone)
            local peer
            if row.kind == 'direct' then
                for j = 1, #members do
                    if members[j].phone ~= phone then peer = members[j].phone end
                end
            end
            out[#out + 1] = {
                id = row.id,
                kind = row.kind,
                name = row.name,
                avatar = row.avatar,
                description = row.description,
                onlyAdmins = isTrue(row.only_admins),
                createdBy = row.created_by,
                createdAt = row.created_at,
                role = row.role,
                pinned = isTrue(row.pinned),
                archived = isTrue(row.archived),
                muted = isTrue(row.muted),
                unread = tonumber(row.unread) or 0,
                peer = peer or (row.kind == 'direct' and phone or nil),
                members = members,
                last = row.last_id and lastById[row.last_id] or nil,
            }
        end
    end
    return out
end
chats.list = listChats

local function chatFor(phone, chatId)
    return listChats(phone, chatId)[1]
end

local function pushChat(chatId)
    for _, row in ipairs(memberRows(chatId)) do
        local src = identity.source(row.phone)
        if src then identity.pushSource(src, 'chat:update', chatFor(row.phone, chatId)) end
    end
end

-------------------------------------------------------------------- sending

local function preview(row)
    local kind = row.kind
    if kind == 'text' then return row.body or '' end
    local label = locale('preview_' .. kind)
    if row.body and row.body ~= '' then return ('%s %s'):format(label, row.body) end
    return label
end

local function insertMessage(chatId, sender, kind, body, media, meta, replyTo)
    local createdAt = now()
    local id = MySQL.insert.await(
        'INSERT INTO `mri_whatsapp_messages` (`chat_id`, `sender`, `kind`, `body`, `media`, `meta`, `reply_to`, `created_at`) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { chatId, sender, kind, body, media, meta and next(meta) and json.encode(meta) or nil, replyTo, createdAt }
    )
    return messageRow(id)
end

---Fans a new message out: live push to online members, delivered receipts, and banners.
local function deliver(chat, row, senderPhone)
    local rows = memberRows(chat.id)
    local hidden = {}
    for _, h in ipairs(MySQL.query.await('SELECT `phone` FROM `mri_whatsapp_hidden` WHERE `message_id` = ?', { row.id }) or {}) do
        hidden[h.phone] = true
    end

    local delivered = {}
    local senderAccount = identity.account(senderPhone)
    for i = 1, #rows do
        local target = rows[i]
        local src = not hidden[target.phone] and identity.source(target.phone) or nil
        if src then
            identity.pushSource(src, 'message:new', { chatId = chat.id, message = serializeOne(row, target.phone) })
            if target.phone ~= senderPhone then
                delivered[#delivered + 1] = target.phone
                if row.kind ~= 'system' and not isTrue(target.muted) then
                    local senderName = identity.displayName(src, senderPhone, senderAccount and senderAccount.name)
                    local title = chat.kind == 'group' and (chat.name or 'Whatzap') or senderName
                    local body = preview(row)
                    if chat.kind == 'group' then body = ('%s: %s'):format(senderName, body) end
                    -- The message is already stored; a failed banner must not fail the send.
                    local banner = {
                        app = 'Whatzap',
                        appId = 'mri_whatsapp',
                        title = title,
                        body = body:sub(1, 140),
                        image = chat.kind == 'group' and chat.avatar or (senderAccount and senderAccount.avatar) or nil,
                        quietInApp = true,
                    }
                    local notified, err = pcall(function() return exports['sd-phone']:notify(src, banner) end)
                    if not notified then lib.print.warn(('notify: %s'):format(err)) end
                end
            end
        end
    end

    if #delivered > 0 then
        MySQL.update.await(
            'UPDATE `mri_whatsapp_members` SET `last_delivered` = GREATEST(`last_delivered`, ?) WHERE `chat_id` = ? AND `phone` IN (?)',
            { row.id, chat.id, delivered }
        )
    end
    MySQL.update.await(
        'UPDATE `mri_whatsapp_members` SET `last_read` = GREATEST(`last_read`, ?), `last_delivered` = GREATEST(`last_delivered`, ?) WHERE `chat_id` = ? AND `phone` = ?',
        { row.id, row.id, chat.id, senderPhone }
    )
    broadcastReceipts(chat.id)
end

local function systemMessage(chat, actor, code, target, value)
    local row = insertMessage(chat.id, actor, 'system', code, nil, { target = target, value = value }, nil)
    deliver(chat, row, actor)
    return row
end

---@type table<number, number[]> source -> recent send timestamps
local sendLog = {}
AddEventHandler('playerDropped', function() sendLog[source] = nil end)

local function throttled(source)
    local list = sendLog[source] or {}
    local t = GetGameTimer()
    local fresh = {}
    for i = 1, #list do
        if t - list[i] < 5000 then fresh[#fresh + 1] = list[i] end
    end
    if #fresh >= 10 then
        sendLog[source] = fresh
        return true
    end
    fresh[#fresh + 1] = t
    sendLog[source] = fresh
    return false
end

---Validates an outgoing payload into the columns stored for it, or nil plus an error code.
local function readContent(payload)
    local kind = payload.kind
    if not MESSAGE_KINDS[kind] then return nil, 'invalid' end
    local meta = {}
    local body = cleanText(payload.body, config.maxMessageLength)
    local media

    if kind == 'text' then
        if not body then return nil, 'empty' end
    elseif kind == 'image' or kind == 'gif' then
        if not isUrl(payload.media) then return nil, 'invalid' end
        media = payload.media
    elseif kind == 'audio' then
        if not isUrl(payload.media) then return nil, 'invalid' end
        media = payload.media
        body = nil
        local duration = tonumber(type(payload.meta) == 'table' and payload.meta.duration)
        meta.duration = math.max(0, math.min(900, math.floor(duration or 0)))
    elseif kind == 'location' then
        local source = type(payload.meta) == 'table' and payload.meta or {}
        local x, y = tonumber(source.x), tonumber(source.y)
        if not x or not y then return nil, 'invalid' end
        meta.x = math.floor(x * 100) / 100
        meta.y = math.floor(y * 100) / 100
        meta.label = cleanText(source.label, 80)
        body = nil
    elseif kind == 'contact' then
        local source = type(payload.meta) == 'table' and payload.meta or {}
        local number = digits(source.phone)
        if number == '' then return nil, 'invalid' end
        meta.phone = number:sub(1, 20)
        meta.name = cleanText(source.name, 40) or number
        body = nil
    end
    return { kind = kind, body = body, media = media, meta = meta }
end

---Whether `phone` may post in `chat`; direct chats also check both block lists.
local function canPost(chat, membership, phone)
    if chat.kind == 'group' then
        if isTrue(chat.only_admins) and membership.role ~= 'admin' then return false, 'onlyAdmins' end
        return true
    end
    for _, row in ipairs(memberRows(chat.id)) do
        if row.phone ~= phone and isBlocked(phone, row.phone) then return false, 'youBlocked' end
    end
    return true
end

local function hideFromBlockers(chat, row, phone)
    if chat.kind ~= 'direct' then return end
    for _, other in ipairs(memberRows(chat.id)) do
        if other.phone ~= phone and isBlocked(other.phone, phone) then
            MySQL.insert.await('INSERT IGNORE INTO `mri_whatsapp_hidden` (`message_id`, `phone`) VALUES (?, ?)', { row.id, other.phone })
        end
    end
end

local function post(phone, chat, content, replyTo, forwarded)
    local meta = content.meta or {}
    if forwarded then meta.forwarded = true end
    local row = insertMessage(chat.id, phone, content.kind, content.body, content.media, meta, replyTo)
    hideFromBlockers(chat, row, phone)
    deliver(chat, row, phone)
    return row
end

handlers.send = function(source, phone, payload)
    if throttled(source) then return fail('slowDown') end
    local chatId = tonumber(payload.chatId)
    local membership = chatId and member(chatId, phone)
    if not membership then return fail('notMember') end
    local chat = chatRow(chatId)
    local allowed, reason = canPost(chat, membership, phone)
    if not allowed then return fail(reason) end

    local content, err = readContent(payload)
    if not content then return fail(err) end

    local replyTo = tonumber(payload.replyTo)
    if replyTo then
        local quoted = messageRow(replyTo)
        if not quoted or quoted.chat_id ~= chatId then replyTo = nil end
    end

    local row = post(phone, chat, content, replyTo, false)
    return ok(serializeOne(row, phone))
end

handlers.forward = function(source, phone, payload)
    if throttled(source) then return fail('slowDown') end
    local row = messageRow(tonumber(payload.messageId) or 0)
    if not row or isTrue(row.revoked) or row.kind == 'system' or not member(row.chat_id, phone) then return fail('invalid') end
    if type(payload.chatIds) ~= 'table' then return fail('invalid') end

    local content = { kind = row.kind, body = row.body, media = row.media, meta = decodeMeta(row.meta) }
    content.meta.forwarded = nil
    local sent = 0
    for i = 1, math.min(#payload.chatIds, config.maxForward) do
        local chatId = tonumber(payload.chatIds[i])
        local membership = chatId and member(chatId, phone)
        if membership then
            local chat = chatRow(chatId)
            if canPost(chat, membership, phone) then
                post(phone, chat, { kind = content.kind, body = content.body, media = content.media, meta = lib.table.deepclone(content.meta) }, nil, true)
                sent = sent + 1
            end
        end
    end
    return ok({ sent = sent })
end

-------------------------------------------------------------------- reading

handlers.bootstrapChats = function(_, phone)
    -- Opening the app is when an offline recipient finally "receives" what was waiting.
    local pending = MySQL.query.await([[
        SELECT m.`chat_id`, MAX(x.`id`) AS `latest` FROM `mri_whatsapp_members` m
        JOIN `mri_whatsapp_messages` x ON x.`chat_id` = m.`chat_id` AND x.`id` > m.`last_delivered`
        WHERE m.`phone` = ? GROUP BY m.`chat_id`]], { phone }) or {}
    for i = 1, #pending do
        MySQL.update.await('UPDATE `mri_whatsapp_members` SET `last_delivered` = ? WHERE `chat_id` = ? AND `phone` = ?', { pending[i].latest, pending[i].chat_id, phone })
        broadcastReceipts(pending[i].chat_id)
    end
    return ok(listChats(phone))
end

handlers.messages = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local membership = chatId and member(chatId, phone)
    if not membership then return fail('notMember') end

    local size = config.pageSize
    local base = [[SELECT * FROM `mri_whatsapp_messages` x WHERE x.`chat_id` = ? AND x.`id` > ?
        AND NOT EXISTS (SELECT 1 FROM `mri_whatsapp_hidden` h WHERE h.`message_id` = x.`id` AND h.`phone` = ?)]]
    local params = { chatId, membership.cleared_before, phone }
    local before, after, around = tonumber(payload.before), tonumber(payload.after), tonumber(payload.around)

    local older, newer = {}, {}
    local hasOlder, hasNewer = false, false
    if around then
        local half = math.floor(size / 2)
        older = MySQL.query.await(base .. ' AND x.`id` <= ? ORDER BY x.`id` DESC LIMIT ?', { chatId, membership.cleared_before, phone, around, half + 1 }) or {}
        newer = MySQL.query.await(base .. ' AND x.`id` > ? ORDER BY x.`id` ASC LIMIT ?', { chatId, membership.cleared_before, phone, around, half + 1 }) or {}
        hasOlder = #older > half
        hasNewer = #newer > half
        if hasOlder then table.remove(older) end
        if hasNewer then table.remove(newer) end
    elseif after then
        newer = MySQL.query.await(base .. ' AND x.`id` > ? ORDER BY x.`id` ASC LIMIT ?', { chatId, membership.cleared_before, phone, after, size + 1 }) or {}
        hasNewer = #newer > size
        if hasNewer then table.remove(newer) end
    else
        local sql = base .. (before and ' AND x.`id` < ?' or '') .. ' ORDER BY x.`id` DESC LIMIT ?'
        if before then params[#params + 1] = before end
        params[#params + 1] = size + 1
        older = MySQL.query.await(sql, params) or {}
        hasOlder = #older > size
        if hasOlder then table.remove(older) end
    end

    local rows = {}
    for i = #older, 1, -1 do rows[#rows + 1] = older[i] end
    for i = 1, #newer do rows[#rows + 1] = newer[i] end
    return ok({ messages = serializeRows(rows, phone), hasOlder = hasOlder, hasNewer = hasNewer })
end

handlers.markRead = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local membership = chatId and member(chatId, phone)
    if not membership then return fail('notMember') end
    local latest = latestId(chatId)
    if latest > membership.last_read then
        MySQL.update.await(
            'UPDATE `mri_whatsapp_members` SET `last_read` = ?, `last_delivered` = GREATEST(`last_delivered`, ?) WHERE `chat_id` = ? AND `phone` = ?',
            { latest, latest, chatId, phone }
        )
        broadcastReceipts(chatId)
    end
    return ok(true)
end

handlers.typing = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    if not chatId or not member(chatId, phone) then return fail('notMember') end
    local state = payload.state == 'recording' and 'recording' or (payload.state and 'typing' or false)
    for _, row in ipairs(memberRows(chatId)) do
        if row.phone ~= phone and not isBlocked(row.phone, phone) then
            identity.push(row.phone, 'typing', { chatId = chatId, phone = phone, state = state })
        end
    end
    return ok(true)
end

handlers.search = function(_, phone, payload)
    local query = cleanText(payload.query, 60)
    if not query or #query < 2 then return ok({}) end
    local pattern = '%' .. query:gsub('[%%_\\]', '\\%0') .. '%'
    local params = { phone, pattern }
    local sql = [[SELECT x.* FROM `mri_whatsapp_messages` x
        JOIN `mri_whatsapp_members` m ON m.`chat_id` = x.`chat_id` AND m.`phone` = ?
        WHERE x.`id` > m.`cleared_before` AND x.`revoked` = 0 AND x.`kind` IN ('text', 'image', 'gif') AND x.`body` LIKE ?
        AND NOT EXISTS (SELECT 1 FROM `mri_whatsapp_hidden` h WHERE h.`message_id` = x.`id` AND h.`phone` = m.`phone`)]]
    local chatId = tonumber(payload.chatId)
    if chatId then
        sql = sql .. ' AND x.`chat_id` = ?'
        params[#params + 1] = chatId
    end
    sql = sql .. ' ORDER BY x.`id` DESC LIMIT 40'
    return ok(serializeRows(MySQL.query.await(sql, params) or {}, phone))
end

-------------------------------------------------------------------- message actions

local function ownMessage(phone, id)
    local row = messageRow(tonumber(id) or 0)
    if not row or not member(row.chat_id, phone) then return nil end
    return row
end

local function pushMessageUpdate(row)
    for _, target in ipairs(memberRows(row.chat_id)) do
        local src = identity.source(target.phone)
        if src then identity.pushSource(src, 'message:update', { chatId = row.chat_id, message = serializeOne(row, target.phone) }) end
    end
end

handlers.react = function(_, phone, payload)
    local row = ownMessage(phone, payload.messageId)
    if not row or isTrue(row.revoked) or row.kind == 'system' then return fail('invalid') end
    local emoji = type(payload.emoji) == 'string' and payload.emoji:sub(1, 16) or nil
    local current = MySQL.scalar.await('SELECT `emoji` FROM `mri_whatsapp_reactions` WHERE `message_id` = ? AND `phone` = ?', { row.id, phone })
    if not emoji or emoji == '' or current == emoji then
        MySQL.update.await('DELETE FROM `mri_whatsapp_reactions` WHERE `message_id` = ? AND `phone` = ?', { row.id, phone })
    else
        MySQL.insert.await('REPLACE INTO `mri_whatsapp_reactions` (`message_id`, `phone`, `emoji`) VALUES (?, ?, ?)', { row.id, phone, emoji })
    end
    pushMessageUpdate(row)
    return ok(true)
end

handlers.edit = function(_, phone, payload)
    local row = ownMessage(phone, payload.messageId)
    if not row or row.sender ~= phone or row.kind ~= 'text' or isTrue(row.revoked) then return fail('invalid') end
    if now() - row.created_at > config.editWindowMinutes * 60 then return fail('tooLate') end
    local body = cleanText(payload.body, config.maxMessageLength)
    if not body then return fail('empty') end
    MySQL.update.await('UPDATE `mri_whatsapp_messages` SET `body` = ?, `edited` = 1 WHERE `id` = ?', { body, row.id })
    row = messageRow(row.id)
    pushMessageUpdate(row)
    return ok(serializeOne(row, phone))
end

handlers.delete = function(_, phone, payload)
    local row = ownMessage(phone, payload.messageId)
    if not row then return fail('invalid') end
    if payload.scope == 'all' then
        if row.sender ~= phone or isTrue(row.revoked) or row.kind == 'system' then return fail('invalid') end
        if now() - row.created_at > config.revokeWindowMinutes * 60 then return fail('tooLate') end
        MySQL.update.await('UPDATE `mri_whatsapp_messages` SET `revoked` = 1, `body` = NULL, `media` = NULL, `meta` = NULL WHERE `id` = ?', { row.id })
        MySQL.update.await('DELETE FROM `mri_whatsapp_reactions` WHERE `message_id` = ?', { row.id })
        row = messageRow(row.id)
        pushMessageUpdate(row)
        return ok(serializeOne(row, phone))
    end
    MySQL.insert.await('INSERT IGNORE INTO `mri_whatsapp_hidden` (`message_id`, `phone`) VALUES (?, ?)', { row.id, phone })
    return ok(true)
end

handlers.star = function(_, phone, payload)
    local row = ownMessage(phone, payload.messageId)
    if not row then return fail('invalid') end
    if payload.on then
        MySQL.insert.await('INSERT IGNORE INTO `mri_whatsapp_starred` (`message_id`, `phone`) VALUES (?, ?)', { row.id, phone })
    else
        MySQL.update.await('DELETE FROM `mri_whatsapp_starred` WHERE `message_id` = ? AND `phone` = ?', { row.id, phone })
    end
    return ok(true)
end

handlers.starred = function(_, phone)
    local rows = MySQL.query.await([[SELECT x.* FROM `mri_whatsapp_starred` s
        JOIN `mri_whatsapp_messages` x ON x.`id` = s.`message_id`
        JOIN `mri_whatsapp_members` m ON m.`chat_id` = x.`chat_id` AND m.`phone` = s.`phone`
        WHERE s.`phone` = ? AND x.`revoked` = 0 ORDER BY x.`id` DESC LIMIT 100]], { phone }) or {}
    return ok(serializeRows(rows, phone))
end

handlers.media = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local membership = chatId and member(chatId, phone)
    if not membership then return fail('notMember') end
    local rows = MySQL.query.await([[SELECT x.* FROM `mri_whatsapp_messages` x WHERE x.`chat_id` = ? AND x.`id` > ?
        AND x.`revoked` = 0 AND x.`kind` IN ('image', 'gif')
        AND NOT EXISTS (SELECT 1 FROM `mri_whatsapp_hidden` h WHERE h.`message_id` = x.`id` AND h.`phone` = ?)
        ORDER BY x.`id` DESC LIMIT 90]], { chatId, membership.cleared_before, phone }) or {}
    return ok(serializeRows(rows, phone))
end

-------------------------------------------------------------------- chat actions

handlers.openDirect = function(source, phone, payload)
    local other = digits(payload.phone)
    if other == '' or other == phone then return fail('invalidNumber') end
    if not identity.inService(other) then return fail('notInService') end

    local key = phone < other and (phone .. ':' .. other) or (other .. ':' .. phone)
    local chatId = MySQL.scalar.await('SELECT `id` FROM `mri_whatsapp_chats` WHERE `direct_key` = ?', { key })
    if not chatId then
        local t = now()
        chatId = MySQL.insert.await(
            'INSERT IGNORE INTO `mri_whatsapp_chats` (`kind`, `direct_key`, `created_by`, `created_at`) VALUES (?, ?, ?, ?)',
            { 'direct', key, phone, t }
        )
        if not chatId or chatId == 0 then
            chatId = MySQL.scalar.await('SELECT `id` FROM `mri_whatsapp_chats` WHERE `direct_key` = ?', { key })
        end
        MySQL.insert.await(
            'INSERT IGNORE INTO `mri_whatsapp_members` (`chat_id`, `phone`, `role`, `joined_at`) VALUES (?, ?, ?, ?), (?, ?, ?, ?)',
            { chatId, phone, 'member', t, chatId, other, 'member', t }
        )
    end
    return ok(chatFor(phone, chatId))
end

handlers.chatSettings = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    if not chatId or not member(chatId, phone) then return fail('notMember') end
    local sets, params = {}, {}
    for field, column in pairs({ pinned = 'pinned', archived = 'archived', muted = 'muted' }) do
        if payload[field] ~= nil then
            sets[#sets + 1] = ('`%s` = ?'):format(column)
            params[#params + 1] = payload[field] and 1 or 0
        end
    end
    if #sets == 0 then return fail('invalid') end
    params[#params + 1] = chatId
    params[#params + 1] = phone
    MySQL.update.await(('UPDATE `mri_whatsapp_members` SET %s WHERE `chat_id` = ? AND `phone` = ?'):format(table.concat(sets, ', ')), params)
    return ok(chatFor(phone, chatId))
end

handlers.clearChat = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    if not chatId or not member(chatId, phone) then return fail('notMember') end
    local latest = latestId(chatId)
    MySQL.update.await(
        'UPDATE `mri_whatsapp_members` SET `cleared_before` = ?, `last_read` = GREATEST(`last_read`, ?) WHERE `chat_id` = ? AND `phone` = ?',
        { latest, latest, chatId, phone }
    )
    return ok(true)
end

handlers.deleteChat = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local chat = chatId and chatRow(chatId)
    if not chat or not member(chatId, phone) then return fail('notMember') end
    if chat.kind == 'group' then return fail('leaveFirst') end
    local latest = latestId(chatId)
    MySQL.update.await(
        'UPDATE `mri_whatsapp_members` SET `cleared_before` = ?, `last_read` = GREATEST(`last_read`, ?), `pinned` = 0, `archived` = 0 WHERE `chat_id` = ? AND `phone` = ?',
        { latest, latest, chatId, phone }
    )
    return ok(true)
end

handlers.chatInfo = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local chat = chatId and chatRow(chatId)
    if not chat or not member(chatId, phone) then return fail('notMember') end
    local info = { chat = chatFor(phone, chatId), commonGroups = {} }
    if chat.kind == 'direct' then
        local other = info.chat.peer
        info.presence = identity.presence(other, phone)
        info.blocked = isBlocked(phone, other)
        local groups = MySQL.query.await([[SELECT c.`id`, c.`name`, c.`avatar` FROM `mri_whatsapp_chats` c
            JOIN `mri_whatsapp_members` a ON a.`chat_id` = c.`id` AND a.`phone` = ?
            JOIN `mri_whatsapp_members` b ON b.`chat_id` = c.`id` AND b.`phone` = ?
            WHERE c.`kind` = 'group' LIMIT 20]], { phone, other }) or {}
        info.commonGroups = groups
    end
    return ok(info)
end

-------------------------------------------------------------------- groups

local function readMembers(list, phone)
    local out, seen = {}, { [phone] = true }
    if type(list) ~= 'table' then return out end
    for i = 1, #list do
        local number = digits(list[i])
        if number ~= '' and not seen[number] and identity.inService(number) then
            seen[number] = true
            out[#out + 1] = number
        end
    end
    return out
end

local function requireAdmin(phone, chatId)
    local chat = chatId and chatRow(chatId)
    local membership = chat and chat.kind == 'group' and member(chatId, phone)
    if not membership then return nil, fail('notMember') end
    if membership.role ~= 'admin' then return nil, fail('notAdmin') end
    return chat
end

handlers.createGroup = function(_, phone, payload)
    local name = cleanText(payload.name, 40)
    if not name then return fail('nameRequired') end
    local members = readMembers(payload.members, phone)
    if #members == 0 then return fail('membersRequired') end
    if #members + 1 > config.maxGroupMembers then return fail('tooManyMembers') end

    local t = now()
    local chatId = MySQL.insert.await(
        'INSERT INTO `mri_whatsapp_chats` (`kind`, `name`, `avatar`, `created_by`, `created_at`) VALUES (?, ?, ?, ?, ?)',
        { 'group', name, isUrl(payload.avatar) and payload.avatar or nil, phone, t }
    )
    MySQL.insert.await('INSERT INTO `mri_whatsapp_members` (`chat_id`, `phone`, `role`, `joined_at`) VALUES (?, ?, ?, ?)', { chatId, phone, 'admin', t })
    for i = 1, #members do
        MySQL.insert.await('INSERT INTO `mri_whatsapp_members` (`chat_id`, `phone`, `role`, `joined_at`) VALUES (?, ?, ?, ?)', { chatId, members[i], 'member', t })
    end
    local chat = chatRow(chatId)
    systemMessage(chat, phone, 'created', nil, name)
    pushChat(chatId)
    return ok(chatFor(phone, chatId))
end

handlers.updateGroup = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local chat, err = requireAdmin(phone, chatId)
    if not chat then return err end

    if payload.name ~= nil then
        local name = cleanText(payload.name, 40)
        if not name then return fail('nameRequired') end
        if name ~= chat.name then
            MySQL.update.await('UPDATE `mri_whatsapp_chats` SET `name` = ? WHERE `id` = ?', { name, chatId })
            systemMessage(chat, phone, 'renamed', nil, name)
        end
    end
    if payload.description ~= nil then
        local description = type(payload.description) == 'string' and trim(payload.description):sub(1, 300) or ''
        MySQL.update.await('UPDATE `mri_whatsapp_chats` SET `description` = ? WHERE `id` = ?', { description ~= '' and description or nil, chatId })
        systemMessage(chat, phone, 'description')
    end
    if payload.avatar ~= nil then
        local avatar = isUrl(payload.avatar) and payload.avatar or nil
        MySQL.update.await('UPDATE `mri_whatsapp_chats` SET `avatar` = ? WHERE `id` = ?', { avatar, chatId })
        systemMessage(chat, phone, 'avatar', nil, avatar and 'set' or 'removed')
    end
    if payload.onlyAdmins ~= nil then
        MySQL.update.await('UPDATE `mri_whatsapp_chats` SET `only_admins` = ? WHERE `id` = ?', { payload.onlyAdmins and 1 or 0, chatId })
        systemMessage(chat, phone, 'onlyAdmins', nil, payload.onlyAdmins and 'on' or 'off')
    end
    pushChat(chatId)
    return ok(chatFor(phone, chatId))
end

handlers.addMembers = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local chat, err = requireAdmin(phone, chatId)
    if not chat then return err end

    local current = memberRows(chatId)
    local existing = {}
    for i = 1, #current do existing[current[i].phone] = true end
    local added = {}
    for _, number in ipairs(readMembers(payload.members, phone)) do
        if not existing[number] then added[#added + 1] = number end
    end
    if #added == 0 then return fail('membersRequired') end
    if #current + #added > config.maxGroupMembers then return fail('tooManyMembers') end

    local latest, t = latestId(chatId), now()
    for i = 1, #added do
        MySQL.insert.await(
            'INSERT INTO `mri_whatsapp_members` (`chat_id`, `phone`, `role`, `joined_at`, `cleared_before`, `last_read`, `last_delivered`) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { chatId, added[i], 'member', t, latest, latest, latest }
        )
        systemMessage(chat, phone, 'added', added[i])
    end
    pushChat(chatId)
    return ok(chatFor(phone, chatId))
end

local function promoteSuccessor(chatId)
    local admins = MySQL.scalar.await('SELECT COUNT(*) FROM `mri_whatsapp_members` WHERE `chat_id` = ? AND `role` = ?', { chatId, 'admin' })
    if (admins or 0) > 0 then return end
    local successor = MySQL.scalar.await('SELECT `phone` FROM `mri_whatsapp_members` WHERE `chat_id` = ? ORDER BY `joined_at` ASC LIMIT 1', { chatId })
    if successor then
        MySQL.update.await('UPDATE `mri_whatsapp_members` SET `role` = ? WHERE `chat_id` = ? AND `phone` = ?', { 'admin', chatId, successor })
    end
end

handlers.removeMember = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local chat, err = requireAdmin(phone, chatId)
    if not chat then return err end
    local target = digits(payload.phone)
    if target == phone or not member(chatId, target) then return fail('invalid') end
    systemMessage(chat, phone, 'removed', target)
    MySQL.update.await('DELETE FROM `mri_whatsapp_members` WHERE `chat_id` = ? AND `phone` = ?', { chatId, target })
    identity.push(target, 'chat:removed', { chatId = chatId })
    pushChat(chatId)
    return ok(chatFor(phone, chatId))
end

handlers.setRole = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local chat, err = requireAdmin(phone, chatId)
    if not chat then return err end
    local target = digits(payload.phone)
    local membership = member(chatId, target)
    if target == phone or not membership then return fail('invalid') end
    local role = payload.role == 'admin' and 'admin' or 'member'
    if membership.role == role then return ok(chatFor(phone, chatId)) end
    MySQL.update.await('UPDATE `mri_whatsapp_members` SET `role` = ? WHERE `chat_id` = ? AND `phone` = ?', { role, chatId, target })
    systemMessage(chat, phone, role == 'admin' and 'promoted' or 'demoted', target)
    pushChat(chatId)
    return ok(chatFor(phone, chatId))
end

handlers.leaveGroup = function(_, phone, payload)
    local chatId = tonumber(payload.chatId)
    local chat = chatId and chatRow(chatId)
    if not chat or chat.kind ~= 'group' or not member(chatId, phone) then return fail('notMember') end
    systemMessage(chat, phone, 'left')
    MySQL.update.await('DELETE FROM `mri_whatsapp_members` WHERE `chat_id` = ? AND `phone` = ?', { chatId, phone })
    local remaining = MySQL.scalar.await('SELECT COUNT(*) FROM `mri_whatsapp_members` WHERE `chat_id` = ?', { chatId }) or 0
    if remaining == 0 then
        for _, tbl in ipairs({ 'mri_whatsapp_reactions', 'mri_whatsapp_hidden', 'mri_whatsapp_starred' }) do
            MySQL.update.await(('DELETE t FROM `%s` t JOIN `mri_whatsapp_messages` x ON x.`id` = t.`message_id` WHERE x.`chat_id` = ?'):format(tbl), { chatId })
        end
        MySQL.update.await('DELETE FROM `mri_whatsapp_messages` WHERE `chat_id` = ?', { chatId })
        MySQL.update.await('DELETE FROM `mri_whatsapp_chats` WHERE `id` = ?', { chatId })
    else
        promoteSuccessor(chatId)
        pushChat(chatId)
    end
    return ok(true)
end

-------------------------------------------------------------------- blocking

handlers.block = function(_, phone, payload)
    local other = digits(payload.phone)
    if other == '' or other == phone then return fail('invalidNumber') end
    if payload.on then
        MySQL.insert.await('INSERT IGNORE INTO `mri_whatsapp_blocks` (`phone`, `blocked`) VALUES (?, ?)', { phone, other })
    else
        MySQL.update.await('DELETE FROM `mri_whatsapp_blocks` WHERE `phone` = ? AND `blocked` = ?', { phone, other })
    end
    return ok(chats.blockedList(phone))
end

function chats.blockedList(phone)
    local out = {}
    for _, row in ipairs(MySQL.query.await('SELECT `blocked` FROM `mri_whatsapp_blocks` WHERE `phone` = ?', { phone }) or {}) do
        out[#out + 1] = row.blocked
    end
    return out
end

return chats
