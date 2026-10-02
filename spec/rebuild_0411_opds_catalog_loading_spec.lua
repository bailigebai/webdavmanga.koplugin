local Ui = require("webdavmanga.ui_opds")
local Client = require("webdavmanga.opds_client")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local source = { id = "fixture", name = "Suwayomi", server_kind = "suwayomi",
    url = "https://fixture.invalid/api/opds/v1.2" }
local function controller(network, async)
    local shown, logs, fetched = {}, {}, 0
    local catalog = { active = function() return source end,
        fetch = function()
            fetched = fetched + 1
            return { is_atom_feed = true, title = "Catalog", entries = {} }
        end }
    local instance = Ui:new{ catalog = catalog, reader = {}, network_manager = network,
        async = async or { run = function(work, done)
            done(true, work()); return { cancel = function() end }
        end },
        logger = { warn = function(...)
            local values = {...}
            logs[#logs + 1] = table.concat(values, " ")
        end },
        ui = { show_menu = function(_, model) shown[#shown + 1] = model end,
            show_info = function() end, close_menu = function() end } }
    return instance, shown, logs, function() return fetched end
end

do
    local resume
    local instance, shown, _, fetched = controller({
        willRerunWhenConnected = function(_, callback)
            resume = callback
            return true
        end,
    })
    instance:show_home()
    expect(fetched() == 0 and type(resume) == "function",
        "catalog fetch must wait for KOReader connectivity before starting the worker")
    resume()
    expect(fetched() == 1 and instance.current.feed.title == "Catalog",
        "the connected callback starts the original catalog request once")
    resume()
    expect(fetched() == 1, "duplicate network callbacks must not fetch twice")
end

do
    local callbacks = {}
    local instance, shown, _, fetched = controller({
        willRerunWhenConnected = function(_, callback)
            callbacks[#callbacks + 1] = callback; return true
        end,
    })
    instance:show_home()
    instance:open_url(source, source.url .. "/new", "New")
    callbacks[1]()
    expect(fetched() == 0, "a stale network callback must not launch a catalog worker")
    instance:cancel()
    local count = #shown
    callbacks[2]()
    expect(fetched() == 0 and #shown == count,
        "closing the browser also retires requests waiting for Wi-Fi")
end

local categories = {
    { "background subprocess unavailable", "worker_unavailable", "后台" },
    { "async timeout", "request_timeout", "超时" },
    { "malformed subprocess output", "worker_output_invalid", "后台" },
    { "subprocess status failed", "worker_status_failed", "后台" },
    { "UI scheduler unavailable", "scheduler_unavailable", "后台" },
    { "subprocess payload exceeds 8388608 bytes", "catalog_too_large", "过大" },
    { "fixture password=must-not-log https://private.invalid/token", "worker_exception", "后台" },
}
for _, case in ipairs(categories) do
    local instance, shown, logs = controller(nil, { run = function(_, done)
        done(false, nil, case[1]); return { cancel = function() end }
    end })
    instance:show_home()
    local model = shown[#shown]
    expect(model.title == "OPDS 加载失败" and model.subtitle:find(case[3], 1, true),
        "the catalog must show the actual asynchronous failure category: " .. case[2])
    expect(#logs == 1 and logs[1]:find("reason=" .. case[2], 1, true),
        "catalog diagnostics must retain a fixed failure reason")
    expect(not logs[1]:find("private", 1, true) and not logs[1]:find("password", 1, true)
        and not model.subtitle:find("private", 1, true), "private worker errors must not reach logs or UI")
end

for _, case in ipairs({
    { "TLS certificate hostname mismatch secret", "tls", "tls", "证书" },
    { "timeout", "transport", "request_timeout", "超时" },
    { "response exceeds maximum image size", "decode", "catalog_too_large", "过大" },
    { "connection refused private-server", "transport", "server_unavailable", "启动" },
}) do
    local client = Client:new{ transport = { get_bytes = function() return nil, nil, case[1] end } }
    local feed, err = client:fetch(source.url, {})
    expect(not feed and err.code == case[2] and err.reason == case[3],
        "the OPDS client must classify transport failures without exposing their text")
    expect(not tostring(err.detail):find("secret", 1, true)
        and not tostring(err.detail):find("private", 1, true), "client errors must use fixed details")
    local instance, shown, logs = controller(nil, { run = function(_, done)
        done(true, { error = err }); return { cancel = function() end }
    end })
    instance:show_home()
    expect(shown[#shown].subtitle:find(case[4], 1, true)
        and logs[1]:find("reason=" .. case[3], 1, true), "transport categories must reach the menu")
end

do
    local jobs, logs = {}, {}
    local instance = Ui:new{ catalog = { active = function() return source end }, reader = {},
        logger = { warn = function(value) logs[#logs + 1] = value end },
        ui = { show_menu = function() end, close_menu = function() end },
        async = { run = function(_, done)
            jobs[#jobs + 1] = done; return { cancel = function() end }
        end } }
    instance:show_home(); instance:cancel()
    jobs[1](false, nil, "async timeout")
    expect(#logs == 0, "stale or cancelled worker errors must not log as current failures")
end

print("rebuild_0411_opds_catalog_loading_spec: " .. checks .. " checks passed")
