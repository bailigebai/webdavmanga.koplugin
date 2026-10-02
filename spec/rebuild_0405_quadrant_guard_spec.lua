local fixture = dofile("spec/helpers/reader_quadrant_host.lua")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local gesture = {pos={x=500,y=100}}

-- Removing model/session validation would replace error/settings UI with the
-- retained page/top_right; the production Shell callback must have no effects.
for _, mode in ipairs({ "error", "controls", "loading", "empty", "closed",
    "stale state", "stale model", "foreign buffer", "stale shell", "closed reader" }) do
    for _, zoomed in ipairs({false, true}) do
        local r, o, context = fixture(false)
        if zoomed then expect(r.shell.widget:onTwoFingerTap(nil, gesture), "establish zoom") end
        local callback_shell = r.shell
        if mode == "error" then r.shell:show_error{message="failed",on_retry=function() end}
        elseif mode == "controls" then r.shell:show_controls{title="Settings",actions={}}
        elseif mode == "loading" then r.shell:show_loading("Loading")
        elseif mode == "empty" then r.shell.current_model = nil
        elseif mode == "closed" then r.shell:close_now()
        elseif mode == "stale state" then r.state:begin_chapter({})
        elseif mode == "stale model" then r.shell.current_model.reader_generation = r.generation - 1
        elseif mode == "foreign buffer" then r.shell.current_model.buffer = {}
        elseif mode == "stale shell" then
            expect(r:open(context), "reopen creates a new shell")
            o.requests[2].callbacks.on_ready("/cache/1.jpg", false, {width=600,height=800})
        elseif mode == "closed reader" then r:force_close("plugin_teardown") end
        local shell, source, viewport = r.shell or callback_shell, r.page_buffer, r.page_viewport
        local reader_shell, model, tree = r.shell, shell.current_model, shell.widget[1]
        local zoom, serial, saves, requests, decodes, dirty, views = r.quadrant_zoom, r.request_serial,
            o.saves, #o.requests, o.decodes, o.dirty, #o.views
        local frees = source and source.frees
        local accepted = callback_shell.widget:onTwoFingerTap(nil, gesture)
        expect(accepted == false and r.shell == reader_shell and shell.current_model == model
            and shell.widget[1] == tree and r.page_viewport == viewport and r.quadrant_zoom == zoom
            and r.request_serial == serial and o.saves == saves and #o.requests == requests
            and o.decodes == decodes and o.dirty == dirty and #o.views == views
            and r.page_buffer == source and (not source or source.frees == frees),
            mode .. " must preserve model/content/state/ownership; got "
                .. tostring(shell.current_model and shell.current_model.kind) .. "/" .. tostring(r.quadrant_zoom))
    end
end
print(("rebuild_0405_quadrant_guard_spec: %d checks passed"):format(checks))
