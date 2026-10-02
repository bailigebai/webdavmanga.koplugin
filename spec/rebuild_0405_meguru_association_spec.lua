local ok, Association = pcall(require, "webdavmanga.meguru_association")
assert(ok, "Meguru interception must exist")
local checks = 0
local function expect(value, message) checks=checks+1; assert(value, message) end
local providers, native, opens, history, messages = {}, {}, {}, {}, {}
local registry = { addProvider=function(_, ext, mime, provider, weight)
    providers[#providers+1] = { ext=ext, mime=mime, provider=provider, weight=weight }
end }
local reader_ui = { showReader=function(...)
    native[#native+1] = { n=select("#", ...), ... }; return "native", "preserved"
end }
local outcome, reason = true, nil
local options = { document_registry=registry, reader_ui=reader_ui,
    read_history={addItem=function(_, path) history[#history+1] = path end},
    open_pointer=function(path, on_first_page)
        opens[#opens+1] = path
        if outcome then on_first_page() end
        return outcome, reason
    end,
    show_error=function(message) messages[#messages+1] = message end,
}
expect(Association.install(options), "install")
local wrapper = reader_ui.showReader
expect(Association.install(options) and reader_ui.showReader == wrapper and #providers == 1, "register and wrap once")
expect(providers[1].ext == "meguru" and providers[1].weight < 100 and providers[1].provider.provider == "webdavmanga-meguru", "low weight pointer-only sentinel")
expect(providers[1].provider:new{file="/book.meguru"} == nil, "sentinel never constructs another Reader")
local a,b = reader_ui.showReader("/book.cbz", nil, 42)
expect(a == "native" and b == "preserved" and native[1].n == 3 and native[1][3] == 42, "dot calls preserve all arguments and return values")
reader_ui:showReader("/book.epub", false)
expect(native[2][1] == reader_ui and native[2][2] == "/book.epub" and native[2][3] == false, "colon native calls unchanged")
expect(reader_ui.showReader("/book.meguru"), "pointer handoff succeeds")
expect(#native == 2 and opens[1] == "/book.meguru" and history[1] == "/book.meguru" and #history == 1, "intercept before native construction and add history once")
expect(reader_ui:showReader("/second.MEGURU") and opens[2] == "/second.MEGURU" and #history == 2, "colon and uppercase pointer paths supported")
outcome, reason = nil, "missing_source"
expect(not reader_ui.showReader("/offline.meguru") and #history == 2 and #native == 2 and #messages == 1, "failed pointer leaves native UI untouched, shows error, no History")
options.open_pointer = function() error("https://secret:password@srv") end
Association.install(options)
expect(not reader_ui.showReader("/throw.meguru") and #history == 2 and #messages == 2, "callback exception remains controlled failure")
expect(not messages[2]:find("secret", 1, true), "raw callback exceptions never leak credentials")
reader_ui.showReader("/book.meguru.cbz")
expect(#native == 3, "only terminal meguru extension intercepted")
for _, mode in ipairs({"throw", "false", "nil"}) do
    local additions, handoffs, warnings = 0, 0, {}
    options.open_pointer = function(_, on_first_page)
        handoffs = handoffs + 1; on_first_page(); return true
    end
    options.read_history = {addItem=function(_, path)
        additions = additions + 1
        expect(path == "/history.meguru", "history receives the intercepted path")
        if mode == "throw" then error("https://secret:password@srv") end
        if mode == "false" then return false end
        return nil -- KOReader's normal addItem does not promise a return value.
    end}
    options.show_error = function(message, reason) warnings[#warnings+1] = {message, reason} end
    Association.install(options)
    local returned, success = pcall(reader_ui.showReader, "/history.meguru")
    expect(returned and success == true, "history " .. mode .. " preserves successful reader handoff")
    expect(additions == 1 and handoffs == 1 and #native == 3, "history result never retries or falls back to native")
    if mode == "nil" then
        expect(#warnings == 0, "normal nil history return is success without warning")
    else
        expect(#warnings == 1 and warnings[1][2] == "history_write_failed"
            and not warnings[1][1]:find("secret", 1, true)
            and not warnings[1][1]:find("password", 1, true), "history failure shows one fixed credential-safe warning")
    end
end
local boot
local install = Association.install
local Pointer = require("webdavmanga.meguru_pointer")
local SettingsUi = require("webdavmanga.ui_settings")
local pointer_new, settings_new = Pointer.new, SettingsUi.new
local startup_pointer, settings_options
Pointer.new = function(self, options) startup_pointer = pointer_new(self, options); return startup_pointer end
SettingsUi.new = function(self, options) settings_options = options; return settings_new(self, options) end
Association.install = function(options)
    boot = options
    settings_options.on_reader_saved{opds_pointer_root="/new-pointer-root", opds_pointer_per_server=false}
    return true
end
dofile("spec/rebuild_0355_main_wiring_spec.lua")
Association.install = install
Pointer.new, SettingsUi.new = pointer_new, settings_new
expect(startup_pointer.root == "/new-pointer-root" and startup_pointer.per_server == false, "saved settings update future pointer location without moving files")
expect(boot and type(boot.open_pointer) == "function", "plugin startup installs the pointer callback")
local Plugin = require("main")
local descriptor = { source_id="source-1", chapter_id="chapter-2" }
local source = { id="source-1", kind="opds", password="private" }
local handoff
local plugin = setmetatable({
    settings={get_source=function(_, id) expect(id == "source-1", "lookup by source id"); return source end},
    meguru_pointer={load=function(_, path) expect(path == "/book.meguru", "load requested pointer"); return descriptor end},
    opds_ui={open_descriptor=function(_, desc, connection, options)
        handoff = {desc, connection, options}; return true
    end},
}, {__index=Plugin})
expect(plugin:open_pointer("/book.meguru") and handoff[1] == descriptor and handoff[2] == source
    and handoff[3].pointer_path == "/book.meguru", "loaded data hands off to existing OPDS UI")
source = nil
local opened, why = plugin:open_pointer("/book.meguru")
expect(not opened and why == "missing_source", "removed source is classified, never request placeholder")
source = {id="source-1", kind="webdav"}
opened, why = plugin:open_pointer("/book.meguru")
expect(not opened and why == "missing_source", "wrong source kind cannot authenticate an OPDS pointer")
source.kind = "opds"
plugin.opds_ui = {}
opened, why = plugin:open_pointer("/book.meguru")
expect(not opened and why == "reader_unavailable", "not-yet-wired descriptor entry fails closed")
print("rebuild_0405_meguru_association_spec: " .. checks .. " checks")
