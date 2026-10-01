local DEFAULTS = {
    maxMessageLength = 2000,
    pageSize = 40,
    maxGroupMembers = 64,
    maxForward = 5,
    statusHours = 24,
    editWindowMinutes = 15,
    revokeWindowMinutes = 60,
    callLogLimit = 60,
}

local config = {}
for key, value in pairs(DEFAULTS) do config[key] = value end

local raw = LoadResourceFile(cache.resource, 'data/config.json')
if raw and raw ~= '' then
    local ok, saved = pcall(json.decode, raw)
    if ok and type(saved) == 'table' then
        for key, value in pairs(saved) do
            if type(DEFAULTS[key]) == type(value) then config[key] = value end
        end
    else
        lib.print.warn('data/config.json invalido, usando os padroes')
    end
end

return config
