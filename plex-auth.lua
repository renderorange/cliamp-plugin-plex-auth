-- plex-auth.lua — keeps the [plex] url and token in cliamp's config.toml working.
--
-- You sign in once, the way a TV does: a 4-character code you enter at
-- plex.tv/link. The plugin keeps that account token in its own store. On every
-- start it checks the account token with plex.tv and works out what [plex]
-- should hold:
--
--   token  the token your server expects. With profile = "<name>" set under
--          [plugins.plex-auth], that is the Plex Home profile's token for the
--          server, so cliamp plays as that profile.
--   url    a plex.direct address for the server, which matches the server's
--          certificate. An address you already use is kept if it is one of
--          the server's addresses.
--
-- cliamp builds its Plex connection once, at startup, before plugins run, so
-- when the plugin changes [plex], restart cliamp to use the new values.
--
-- cliamp refuses to let a plugin write config.toml itself after v2.3.0, so when
-- that write is refused the plugin leaves the finished file at config.toml.new
-- and asks for one mv.
--
-- Commands (cliamp must be running):
--   cliamp plugins call plex-auth status     check the account token and [plex]
--   cliamp plugins call plex-auth signin     sign in again with a new code
--   cliamp plugins call plex-auth profiles   list the Plex Home profiles

local VERSION = "1.2.0"

local p = plugin.register({
    name        = "plex-auth",
    type        = "hook",
    version     = VERSION,
    description = "Sign in to Plex with a plex.tv/link code and keep the [plex] url and token current",
})

local API = "https://plex.tv/api/v2"
local PRODUCT = "cliamp"
local POLL_SECONDS = 3
-- cliamp.message caps a status-bar message at 60 seconds, so the code is shown
-- again a little before it would disappear.
local RESHOW_SECONDS = 50

-- Same lookup order as cliamp's own config directory.
local function config_path()
    local dir = os.getenv("CLIAMP_CONFIG_DIR")
    if not dir or dir == "" then
        local xdg = os.getenv("XDG_CONFIG_HOME")
        if xdg and xdg ~= "" then
            dir = xdg .. "/cliamp"
        else
            dir = (os.getenv("HOME") or "") .. "/.config/cliamp"
        end
    end
    return dir .. "/config.toml"
end

local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

-- Mirrors cliamp's own unquote (config/config.go), so the plugin and cliamp read
-- the same value from a line. One pair of matching quotes goes, a # comment
-- after the closing quote goes, and inside double quotes \\ and \" are decoded.
-- A value that does not start with a quote comes back as it is, # included,
-- because cliamp keeps that # too.
local function unquote(s)
    local q = s:sub(1, 1)
    if #s < 2 or (q ~= '"' and q ~= "'") then
        return s
    end
    local out = {}
    local closed = false
    local i = 2
    while i <= #s do
        local c = s:sub(i, i)
        if q == '"' and c == "\\" and i < #s then
            local next_char = s:sub(i + 1, i + 1)
            if next_char == "\\" or next_char == '"' then
                out[#out + 1] = next_char
                i = i + 2
            else
                out[#out + 1] = c
                i = i + 1
            end
        elseif c == q then
            local rest = s:sub(i + 1):gsub("^[ \t]*", "")
            if rest == "" or rest:sub(1, 1) == "#" then
                return table.concat(out)
            end
            -- Text follows this quote, so it is part of the value.
            closed = true
            break
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    if not closed then
        return (s:sub(2):gsub("[\"']+$", ""))
    end
    if s:sub(-1) == q then
        return s:sub(2, -2)
    end
    return s
end

-- Mirrors cliamp's QuoteString, so a value written into config.toml comes back
-- out of it unchanged. It escapes only \ and "; cliamp reads no other escape.
-- The value must be a single line; write_plex checks that first.
local function quote(s)
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- A setting from [plugins.plex-auth], or nil when it is missing or empty.
local function setting(key)
    local v = p:config(key)
    if v == nil then
        return nil
    end
    v = unquote(trim(tostring(v)))
    return v ~= "" and v or nil
end

-- Splits on "\n" the way cliamp's config saver does, so joining the lines back
-- with "\n" gives the same file.
local function split_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

-- The name inside a [name] header, exactly as written. cliamp's own reader is
-- case-sensitive, so [Plex] is not [plex] and the plugin must not treat it as
-- one.
local function section_name(trimmed)
    return trimmed:match("^%[(.+)%]$")
end

-- Every timer callback gets its own 5-second limit, so each plex.tv request
-- runs in one. cliamp drops errors from timer callbacks, so log them here.
local function later(fn, secs)
    cliamp.timer.after(secs or 0.05, function()
        local ok, err = pcall(fn)
        if not ok then
            cliamp.log.error(tostring(err))
        end
    end)
end

-- Plex lists every client identifier as a separate device under
-- Settings > Authorized Devices, so make one once and reuse it.
local function client_id()
    local cid = cliamp.store.get("client_id")
    if type(cid) == "string" and cid ~= "" then
        return cid
    end
    local h = cliamp.crypto.sha256(os.time() .. os.clock() .. tostring({}) .. math.random())
    cid = h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
    cliamp.store.set("client_id", cid)
    return cid
end

local device_name_cache

local function device_name()
    if not device_name_cache then
        local name = cliamp.fs.read("/etc/hostname")
        name = name and trim(name) or ""
        device_name_cache = name ~= "" and name or "cliamp"
    end
    return device_name_cache
end

local function plex_headers(token)
    local h = {
        Accept = "application/json",
        ["X-Plex-Product"] = PRODUCT,
        ["X-Plex-Version"] = VERSION,
        ["X-Plex-Device-Name"] = device_name(),
        ["X-Plex-Client-Identifier"] = client_id(),
    }
    if token then
        h["X-Plex-Token"] = token
    end
    return h
end

local function decode(body)
    local ok, data = pcall(cliamp.json.decode, body)
    if ok and type(data) == "table" then
        return data
    end
end

-- Why a cliamp.http call failed: an HTTP status, or the error text it returned
-- in place of the status.
local function failure(body, status)
    if body then
        return "HTTP " .. tostring(status)
    end
    return status ~= nil and tostring(status) or "no response"
end

local function plex_get(path, token)
    local body, status = cliamp.http.get(API .. path, { headers = plex_headers(token) })
    local data = body and status == 200 and decode(body)
    if not data then
        return nil, failure(body, status)
    end
    return data
end

-- The url and token from [plex]. Like cliamp, a token of $NAME or ${NAME} is
-- read from that environment variable.
local function read_plex()
    local values = {}
    local text = cliamp.fs.read(config_path())
    if not text then
        return values
    end
    local section
    for _, line in ipairs(split_lines(text)) do
        local trimmed = trim(line)
        local name = section_name(trimmed)
        if name then
            section = name
        elseif section == "plex" then
            local key, value = trimmed:match("^([%w_]+)%s*=%s*(.-)$")
            if key == "url" or key == "token" then
                value = unquote(value)
                local env = key == "token"
                    and (value:match("^%${([%a_][%w_]*)}$") or value:match("^%$([%a_][%w_]*)$"))
                if env then
                    value = os.getenv(env) or ""
                end
                values[key] = value ~= "" and value or nil
            end
        end
    end
    return values
end

-- Sets url and token in [plex]. An existing line keeps its spacing and only
-- gets a new value; a missing one goes under the [plex] header; with no [plex]
-- section, one is added at the end. Every other line stays as it was.
local function plex_config_text(values, text)
    local lines = split_lines(text)
    local pending = {}
    for key, value in pairs(values) do
        pending[key] = value
    end
    local section, header_at
    for i, line in ipairs(lines) do
        local trimmed = trim(line)
        local name = section_name(trimmed)
        if name then
            section = name
            if name == "plex" then
                header_at = i
            end
        elseif section == "plex" then
            local lead, key = line:match("^(%s*([%w_]+)%s*=%s*)")
            if key and pending[key] then
                lines[i] = lead .. quote(pending[key])
                pending[key] = nil
            end
        end
    end

    local missing = {}
    for _, key in ipairs({ "url", "token" }) do
        if pending[key] then
            missing[#missing + 1] = key .. " = " .. quote(pending[key])
        end
    end
    if header_at then
        for j = #missing, 1, -1 do
            table.insert(lines, header_at + 1, missing[j])
        end
    elseif #missing > 0 then
        if lines[#lines] == "" then
            lines[#lines] = nil
        end
        if #lines > 0 then
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = "[plex]"
        for _, line in ipairs(missing) do
            lines[#lines + 1] = line
        end
        lines[#lines + 1] = ""
    end

    return table.concat(lines, "\n")
end

-- cliamp.fs.write returns true, or nil and a reason. It raises a Lua error for
-- a path it refuses to write, which is how cliamp guards config.toml from the
-- release after v2.3.0.
local function save(path, text)
    local ok, result, why = pcall(cliamp.fs.write, path, text)
    if not ok then
        return false, tostring(result)
    end
    if result ~= true then
        return false, tostring(why)
    end
    return true
end

-- Puts values in [plex]. Returns "written" when config.toml holds them,
-- "staged", the path of config.toml.new and whether that file is new when
-- cliamp refuses the direct write, or nil and a reason.
local function write_plex(values)
    for key, value in pairs(values) do
        if value:find("[\r\n]") then
            return nil, "the " .. key .. " has a line break, so it cannot go in config.toml"
        end
    end
    local path = config_path()
    local text = ""
    if cliamp.fs.exists(path) then
        local why
        text, why = cliamp.fs.read(path)
        if not text then
            return nil, "could not read " .. path .. ": " .. tostring(why)
        end
    end
    local content = plex_config_text(values, text)

    local written, why = save(path, content)
    if written then
        local saved = read_plex()
        for key, value in pairs(values) do
            if saved[key] ~= value then
                return nil, "the " .. key .. " did not read back from " .. path
            end
        end
        return "written"
    end

    -- cliamp refuses to write config.toml itself after v2.3.0, so leave the
    -- finished file beside it for one mv. A file that already holds the same
    -- text is left alone, so the notification stays a one-off.
    local staged = path .. ".new"
    local fresh = cliamp.fs.read(staged) ~= content
    if fresh then
        local staged_ok, staged_why = save(staged, content)
        if not staged_ok then
            return nil, "could not save [plex] to " .. path .. " (" .. why .. ") or to "
                .. staged .. " (" .. staged_why .. ")"
        end
        if cliamp.fs.read(staged) ~= content then
            return nil, staged .. " did not read back"
        end
    end
    return "staged", staged, fresh
end

-- Returns "valid" or "invalid" for the account token. Returns nil and a reason
-- when plex.tv can't give an answer, for example with no network, so a working
-- token is never replaced just because the laptop is offline.
local function check_account(token)
    local body, status = cliamp.http.get(API .. "/user", { headers = plex_headers(token) })
    if not body then
        return nil, status
    end
    if status == 200 then
        return "valid"
    end
    if status == 401 then
        return "invalid"
    end
    return nil, "plex.tv answered HTTP " .. status
end

local function names(list, field)
    local out = {}
    for _, item in ipairs(list) do
        if item[field] ~= nil then
            out[#out + 1] = tostring(item[field])
        end
    end
    return table.concat(out, ", ")
end

-- Direct internet addresses work at home and away, so they come first. Plex's
-- relay is slow and capped, so it comes last.
local function address_rank(c)
    if c.relay then
        return 3
    end
    if c["local"] then
        return 2
    end
    return 1
end

-- A trailing slash on a server address means nothing to Plex, so addresses are
-- compared without one.
local function normalize_url(url)
    return (url or ""):gsub("/+$", "")
end

-- Picks the server and the address to use from a plex.tv resources list.
-- Returns the server and url, or nil and a reason.
local function pick_server(resources)
    local wanted = setting("server")
    local servers, available = {}, {}
    for _, r in ipairs(resources) do
        if type(r) == "table" and tostring(r.provides or ""):find("server") then
            available[#available + 1] = r
            if not wanted or tostring(r.name):lower() == wanted:lower() then
                servers[#servers + 1] = r
            end
        end
    end

    -- The address already in [plex] wins when it belongs to one of the servers.
    local current = normalize_url(read_plex().url)
    if current ~= "" then
        for _, server in ipairs(servers) do
            for _, c in ipairs(server.connections or {}) do
                if normalize_url(c.uri) == current then
                    return server, c.uri
                end
            end
        end
    end

    if #servers == 0 then
        if wanted then
            return nil, 'no Plex server named "' .. wanted .. '" (servers: '
                .. names(available, "name") .. ")"
        end
        return nil, "this account can't see any Plex servers"
    end
    -- Servers friends share with you show up too. Your own server is the
    -- likely one, so use it when there is exactly one.
    if #servers > 1 then
        local owned = {}
        for _, server in ipairs(servers) do
            if server.owned then
                owned[#owned + 1] = server
            end
        end
        if #owned == 1 then
            servers = owned
        end
    end
    if #servers > 1 then
        return nil, 'more than one Plex server; set server = "<name>" under [plugins.plex-auth] ('
            .. names(servers, "name") .. ")"
    end

    local server, best = servers[1], nil
    for _, c in ipairs(server.connections or {}) do
        if type(c.uri) == "string" and c.uri:match("^https://")
            and (not best or address_rank(c) < address_rank(best)) then
            best = c
        end
    end
    if not best then
        return nil, 'Plex server "' .. tostring(server.name) .. '" has no https address'
    end
    return server, best.uri
end

-- Works out what [plex] should hold for the account token, then calls
-- done(values, who) or done(nil, reason). Each plex.tv request runs in its own
-- timer callback.
local function resolve(account, done)
    local profile = setting("profile")

    local function find_server(token, who)
        later(function()
            local resources, why = plex_get("/resources?includeHttps=1&includeRelay=1", token)
            if not resources then
                return done(nil, "could not list Plex servers: " .. why)
            end
            local server, url = pick_server(resources)
            if not server then
                return done(nil, url)
            end
            done({ url = url, token = server.accessToken or token }, who)
        end)
    end

    if not profile then
        return find_server(account, "the account owner")
    end
    later(function()
        local home, why = plex_get("/home/users", account)
        if not home then
            return done(nil, "could not list Plex profiles: " .. why)
        end
        local users = home.users or {}
        local user
        for _, u in ipairs(users) do
            if tostring(u.title):lower() == profile:lower()
                or (type(u.username) == "string" and u.username:lower() == profile:lower()) then
                user = u
            end
        end
        if not user then
            return done(nil, 'no Plex profile named "' .. profile .. '" (profiles: ' .. names(users, "title") .. ")")
        end
        if user.protected then
            return done(nil, 'Plex profile "' .. profile .. '" has a PIN, and this plugin can\'t enter one')
        end
        later(function()
            local body, status = cliamp.http.post(API .. "/home/users/" .. user.uuid .. "/switch", {
                headers = plex_headers(account),
                body = "",
            })
            local data = body and status < 300 and decode(body)
            if not data or type(data.authToken) ~= "string" then
                return done(nil, 'could not switch to Plex profile "' .. profile .. '": ' .. failure(body, status))
            end
            find_server(data.authToken, tostring(user.title))
        end)
    end)
end

-- Puts what resolve found in [plex] when it differs from what is there, either
-- in config.toml or, when cliamp refuses that write, in config.toml.new.
local function sync(account, signed_in)
    resolve(account, function(values, who)
        if not values then
            cliamp.log.error(who)
            cliamp.message("Plex: " .. who, 60)
            return
        end
        local current = read_plex()
        if normalize_url(current.url) == normalize_url(values.url)
            and current.token == values.token then
            cliamp.log.debug("[plex] already has the url and token for " .. who)
            if signed_in then
                cliamp.message("Plex: signed in. Nothing in [plex] needed to change.", 30)
            end
            return
        end
        local mode, detail, fresh = write_plex(values)
        if not mode then
            cliamp.log.error("could not save [plex]: " .. tostring(detail))
            cliamp.message("Plex: could not save the server address and token. See plugins.log", 60)
            return
        end
        if mode == "staged" then
            -- Say it every start, because [plex] is still stale, but notify once
            -- for each new file.
            local text = "Plex: set up for " .. who .. ". Run: mv " .. detail .. " " .. config_path()
            if fresh then
                cliamp.log.info("wrote " .. detail .. " for " .. who .. "; run mv to put it in place")
                cliamp.notify("Plex", text)
            else
                cliamp.log.debug(detail .. " is still waiting for its mv")
            end
            cliamp.message(text, 60)
            return
        end
        cliamp.log.info("saved url " .. values.url .. " and the token for " .. who .. " to " .. config_path())
        local text = "Plex: set up for " .. who .. ". Restart cliamp to load your Plex library."
        cliamp.message(text, 60)
        cliamp.notify("Plex", text)
    end)
end

-- The sign-in in progress: {id, code, expires_at, shown_at, timer}, or nil.
local pin

local function show_code()
    cliamp.message("Plex sign-in: go to plex.tv/link and enter " .. pin.code, 60)
    pin.shown_at = os.time()
end

local function stop_signin()
    if pin and pin.timer then
        cliamp.timer.cancel(pin.timer)
    end
    pin = nil
end

local function finish_signin(account)
    stop_signin()
    cliamp.store.set("account_token", account)
    cliamp.log.info("signed in")
    sync(account, true)
end

local function poll()
    if not pin then
        return
    end
    if os.time() >= pin.expires_at then
        stop_signin()
        cliamp.log.warn("the plex.tv/link code expired before sign-in finished")
        cliamp.message("Plex: the code expired. Run: cliamp plugins call plex-auth signin", 60)
        return
    end

    local body, status = cliamp.http.get(API .. "/pins/" .. pin.id, { headers = plex_headers() })
    if body and status == 404 then
        -- plex.tv drops a PIN once it expires. Give it three polls first, so a
        -- proxy or CDN that answers 404 once does not end a working sign-in.
        pin.missing = (pin.missing or 0) + 1
        if pin.missing < 3 then
            return
        end
        pin.expires_at = 0
        return
    end
    pin.missing = 0
    local data = body and status == 200 and decode(body)
    if data and type(data.authToken) == "string" and data.authToken ~= "" then
        finish_signin(data.authToken)
        return
    end
    -- Not approved yet, or a network error that the next poll may not have.
    if os.time() - pin.shown_at >= RESHOW_SECONDS then
        show_code()
    end
end

-- Asks plex.tv for a 4-character code and starts polling for the token.
-- Returns the text to show the person.
local function start_signin()
    local headers = plex_headers()
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    local body, status = cliamp.http.post(API .. "/pins", { headers = headers, body = "strong=false" })
    local data = body and status < 300 and decode(body)
    local id = data and tonumber(data.id)
    if not id or not data.code then
        local why = failure(body, status)
        cliamp.log.error("could not get a sign-in code from plex.tv: " .. why)
        cliamp.message("Plex: could not get a sign-in code from plex.tv (" .. why .. ")", 30)
        return "Could not get a sign-in code from plex.tv: " .. why
    end

    -- Only now that plex.tv has given a new code: until this point the old code
    -- is still the only one the person can use.
    stop_signin()
    pin = {
        id = string.format("%.0f", id),
        code = data.code,
        expires_at = os.time() + (tonumber(data.expiresIn) or 900),
    }
    pin.timer = cliamp.timer.every(POLL_SECONDS, function()
        local ok, err = pcall(poll)
        if not ok then
            cliamp.log.error(tostring(err))
        end
    end)
    show_code()
    cliamp.notify("Plex sign-in", "Go to plex.tv/link and enter " .. pin.code)
    cliamp.log.info("waiting for sign-in, code " .. pin.code)
    return "Go to plex.tv/link and enter " .. pin.code
end

-- The saved account token. Before version 1.1 the plugin kept it only in
-- [plex], so fall back to that; a server token found there fails the plex.tv
-- check and leads to a new sign-in.
local function account_token()
    local account = cliamp.store.get("account_token")
    if type(account) == "string" and account ~= "" then
        return account
    end
    return read_plex().token
end

p:on("app.start", function()
    local account = account_token()
    if not account then
        cliamp.log.info("not signed in yet, starting sign-in")
        start_signin()
        return
    end
    local result, why = check_account(account)
    if result == "invalid" then
        cliamp.log.warn("plex.tv rejected the account token, starting sign-in")
        start_signin()
    elseif result == "valid" then
        -- The fallback in account_token() can be a [plex] token, so save the
        -- confirmed one, but only when the store does not already hold it.
        if cliamp.store.get("account_token") ~= account then
            cliamp.store.set("account_token", account)
        end
        sync(account, false)
    else
        cliamp.log.warn("could not reach plex.tv, leaving [plex] as is: " .. tostring(why))
    end
end)

p:command("signin", function()
    return start_signin()
end)

p:command("status", function()
    if pin then
        return "Waiting for sign-in: go to plex.tv/link and enter " .. pin.code
    end
    local account = account_token()
    if not account then
        return "Not signed in. Run: cliamp plugins call plex-auth signin"
    end
    local result, why = check_account(account)
    local lines = {}
    if result == "valid" then
        lines[1] = "Signed in to plex.tv."
    elseif result == "invalid" then
        lines[1] = "plex.tv rejected the account token. Run: cliamp plugins call plex-auth signin"
    else
        lines[1] = "Could not reach plex.tv: " .. tostring(why)
    end
    lines[#lines + 1] = "Profile: " .. (setting("profile") or "the account owner")
    lines[#lines + 1] = "Server address: " .. (read_plex().url or "none")
    local staged = config_path() .. ".new"
    if cliamp.fs.exists(staged) then
        lines[#lines + 1] = "Ready to apply: mv " .. staged .. " " .. config_path()
    end
    return table.concat(lines, "\n")
end)

p:command("profiles", function()
    local account = account_token()
    if not account then
        return "Not signed in. Run: cliamp plugins call plex-auth signin"
    end
    local home, why = plex_get("/home/users", account)
    if not home then
        return "Could not list Plex profiles: " .. why
    end
    local lines = {}
    for _, u in ipairs(home.users or {}) do
        local notes = {}
        if u.admin then
            notes[#notes + 1] = "account owner"
        end
        if u.restricted then
            notes[#notes + 1] = "managed"
        end
        if u.protected then
            notes[#notes + 1] = "has a PIN"
        end
        local suffix = #notes > 0 and (" (" .. table.concat(notes, ", ") .. ")") or ""
        lines[#lines + 1] = tostring(u.title) .. suffix
    end
    return table.concat(lines, "\n")
end)
