-- Runs plex-auth.lua against a stubbed cliamp API: no cliamp, no network, and
-- no config file touched. From the repo root:
--
--   lua test/plex_auth_test.lua
--
-- The stub follows cliamp's plugin API as of commit 02309c9: cliamp.http
-- returns body, status; cliamp.fs.write raises for a refused path; [plex] holds
-- url, token and libraries.

local PLUGIN = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/../plex-auth.lua"
local API = "https://plex.tv/api/v2"

-- The same lookup the plugin does. Only the string matters: the stub never
-- touches the disk, so this cannot read or write a real config.
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

local failed, passed = 0, 0

local function check(name, got, want)
    if got == want then
        passed = passed + 1
        print("ok   " .. name)
        return
    end
    failed = failed + 1
    print("FAIL " .. name)
    print("     got:  " .. tostring(got))
    print("     want: " .. tostring(want))
end

local function check_true(name, got)
    check(name, got and true or false, true)
end

local function config_for(url, token)
    local lines = {
        "# my cliamp config",
        'provider = "plex"',
        "",
        "[plex]",
        '  url = "' .. url .. '"   # my note',
    }
    if token then
        lines[#lines + 1] = '  token = "' .. token .. '"'
    end
    for _, line in ipairs({
        '  libraries = ["Music"]',
        "",
        "[plugins.plex-auth]",
        'profile = "blaine"',
        "",
    }) do
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

local function resources_for(remote)
    return { {
        name = "sol", provides = "server", owned = true, accessToken = "SERVER_TOKEN",
        connections = {
            { uri = "https://10-0-0-5.abc.plex.direct:32400", ["local"] = true },
            { uri = remote or "https://99-99-99-99.abc.plex.direct:32400" },
        },
    } }
end

-- Builds a stub environment and loads the plugin into it.
local function load_plugin(opts)
    opts = opts or {}
    local cfg = config_path()
    local staged = cfg .. ".new"
    local env = {
        cfg = cfg,
        staged = staged,
        files = {},
        messages = {},
        logs = {},
        writes = 0,
        notified = 0,
        store = opts.account_token == nil and { account_token = "ACCOUNT" } or {},
        handlers = {},
        commands = {},
    }
    env.files[cfg] = opts.config or config_for(opts.url or "https://old.example.com:32400")

    local responses = {
        ["/user"] = { status = 200, data = {} },
        ["/home/users"] = {
            status = 200,
            data = { users = {
                { title = "renderorange", admin = true, uuid = "uuid-owner" },
                { title = "blaine", restricted = true, uuid = "uuid-blaine" },
            } },
        },
        ["/home/users/uuid-blaine/switch"] = {
            status = 201,
            data = { authToken = "PROFILE_TOKEN" },
        },
        ["/resources?includeHttps=1&includeRelay=1"] = {
            status = 200,
            data = opts.resources or resources_for(),
        },
        ["/pins"] = {
            status = 201,
            data = opts.pin or { id = 123456, code = "ABCD", expiresIn = 900 },
        },
    }
    env.responses = responses

    local function record(list)
        return function(msg) list[#list + 1] = tostring(msg) end
    end

    cliamp = {
        fs = {
            read = function(path)
                if opts.read_fails and path == cfg then
                    return nil, "permission denied"
                end
                if env.files[path] == nil then
                    return nil, "no such file or directory"
                end
                return env.files[path]
            end,
            exists = function(path) return env.files[path] ~= nil end,
            write = function(path, text)
                -- cliamp raises, rather than returning, for a path it refuses.
                if opts.deny and path == cfg then
                    error("write not allowed to this path")
                end
                env.writes = env.writes + 1
                env.files[path] = text
                return true
            end,
        },
        json = { decode = function(body)
            local response = responses[body]
            if not response then
                return nil, "not json"
            end
            return response.data
        end },
        http = {
            get = function(url)
                local path = url:sub(#API + 1)
                local response = responses[path]
                return response and path or nil, response and response.status or "connection refused"
            end,
            post = function(url)
                local path = url:sub(#API + 1)
                local response = responses[path]
                return response and path or nil, response and response.status or "connection refused"
            end,
        },
        timer = {
            after = function(_, fn) fn(); return 1 end,
            every = function() return 2 end,
            cancel = function() end,
        },
        crypto = { sha256 = function() return string.rep("ab", 32) end },
        store = {
            get = function(key) return env.store[key] end,
            set = function(key, value) env.store[key] = value; return true end,
        },
        message = function(text) env.messages[#env.messages + 1] = text end,
        notify = function(title, body)
            env.notified = env.notified + 1
            env.messages[#env.messages + 1] = "notify " .. title .. ": " .. body
        end,
        log = {
            info = record(env.logs), warn = record(env.logs),
            error = record(env.logs), debug = record(env.logs),
        },
    }

    plugin = {
        register = function()
            return {
                on = function(_, event, fn) env.handlers[event] = fn end,
                command = function(_, name, fn) env.commands[name] = fn end,
                config = function(_, key) return (opts.settings or { profile = "blaine" })[key] end,
            }
        end,
    }

    assert(loadfile(PLUGIN))()
    return env
end

local function start(env)
    env.handlers["app.start"]()
    return env
end

local function last_message(env)
    for i = #env.messages, 1, -1 do
        if not env.messages[i]:match("^notify ") then
            return env.messages[i]
        end
    end
end

local function any_log(env, pattern)
    for _, line in ipairs(env.logs) do
        if line:find(pattern) then
            return true
        end
    end
    return false
end

-- A cliamp that refuses the config.toml write, as v2.3.1 and later do.
local env = start(load_plugin({ deny = true }))
check("refused write leaves config.toml alone", env.files[env.cfg]:find("old%.example") ~= nil, true)
check_true("refused write stages config.toml.new", env.files[env.staged] ~= nil)
check_true("staged file holds the new url", env.files[env.staged]:find("99%-99%-99%-99", 1, false) ~= nil)
check_true("staged file keeps the rest of the config", env.files[env.staged]:find('libraries = %["Music"%]') ~= nil)
check("staged file drops the comment on the url line", env.files[env.staged]:find("my note") == nil, true)
check("status line names the mv", last_message(env):match("Run: mv ") ~= nil, true)
check("one notification for a new staged file", env.notified, 1)

-- The next start must not rewrite the file or notify again.
local writes, notified, messages = env.writes, env.notified, #env.messages
start(env)
check("second start does not rewrite", env.writes, writes)
check("second start does not notify", env.notified, notified)
check("second start still shows the mv", #env.messages > messages, true)

-- A cliamp that allows the write, as v2.3.0 and earlier do.
env = start(load_plugin({ deny = false }))
check_true("allowed write updates config.toml", env.files[env.cfg]:find("99%-99%-99%-99", 1, false) ~= nil)
check("allowed write leaves no staged file", env.files[env.staged], nil)
check("allowed write keeps the token out of the status line",
    last_message(env):find("SERVER_TOKEN") == nil, true)
check("allowed write says to restart", last_message(env):match("Restart cliamp") ~= nil, true)

-- A read that fails must not be treated as an empty file.
env = start(load_plugin({ deny = false, read_fails = true }))
check("failed read writes nothing", env.writes, 0)
check("failed read stages nothing", env.files[env.staged], nil)
check_true("failed read is logged", any_log(env, "could not read"))

-- A config that already holds the values needs no work.
env = start(load_plugin({
    deny = true,
    config = config_for("https://99-99-99-99.abc.plex.direct:32400", "SERVER_TOKEN"),
}))
check("up to date config stages nothing", env.files[env.staged], nil)
check("up to date config says nothing", #env.messages, 0)

-- A trailing slash in [plex] still matches the server's address.
env = start(load_plugin({
    deny = true,
    config = config_for("https://99-99-99-99.abc.plex.direct:32400/", "SERVER_TOKEN"),
}))
check("trailing slash still matches", env.files[env.staged], nil)

-- A server setting that matches nothing should name the ones that exist.
env = start(load_plugin({ deny = false, settings = { server = "nope" } }))
check_true("unknown server names the known ones",
    (last_message(env) or ""):find('servers: sol') ~= nil)

-- A value with a line break cannot go in a one-line TOML string.
env = start(load_plugin({ deny = false, resources = resources_for("https://bad\naddress:32400") }))
check("line break in the url is refused", env.writes, 0)
check_true("line break is logged", any_log(env, "line break"))

-- A value with a quote or a backslash is written escaped, and reads back the
-- same, so the next start sees nothing to change.
env = start(load_plugin({ deny = true, resources = resources_for('https://weird"quote:32400') }))
check_true("quote in the url is escaped", env.files[env.staged]:find('\\"', 1, true) ~= nil)
env.files[env.cfg] = env.files[env.staged]
start(env)
check("escaped url reads back unchanged", env.files[env.staged], env.files[env.cfg])

env = start(load_plugin({ deny = true, resources = resources_for("https://weird\\slash:32400") }))
check_true("backslash in the url is escaped", env.files[env.staged]:find("\\\\", 1, true) ~= nil)

-- A failed request for a new code must not cancel the code already in flight.
env = load_plugin({})
check_true("signin asks for a code", env.commands["signin"]():find("enter ABCD") ~= nil)
env.responses["/pins"] = nil
check_true("a failed signin says why", env.commands["signin"]():find("connection refused") ~= nil)
check_true("a failed signin keeps the old code",
    env.commands["status"]():find("enter ABCD") ~= nil)

-- The read side must match cliamp's own parsing of a value.
local cases = {
    { 'url = "https://a.plex.direct:32400"   # home', "https://a.plex.direct:32400" },
    { "url = 'https://single:32400'", "https://single:32400" },
    { 'url = "https://hash#inside:32400"', "https://hash#inside:32400" },
    { 'url = "https://closed:32400"#tight', "https://closed:32400" },
    { 'url = "unclosed:32400', "unclosed:32400" },
    { 'url = "https://esc\\\\aped:32400"', "https://esc\\aped:32400" },
    { 'url = "https://plain:32400" # kept', "https://plain:32400" },
}
for _, case in ipairs(cases) do
    env = load_plugin({
        config = '[plex]\n' .. case[1] .. '\ntoken = "T"\n',
    })
    local out = env.commands["status"]()
    check("reads " .. case[1], out:match("Server address: (.*)"), case[2])
end

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
