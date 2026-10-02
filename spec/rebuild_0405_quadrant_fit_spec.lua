local fixture = dofile("spec/helpers/reader_quadrant_host.lua")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local points = { {x=100,y=100}, {x=500,y=100}, {x=100,y=700}, {x=500,y=700} }

-- Fixed 2x clips split/long pages. Stretching or fitting against full source
-- instead of the selected quadrant also breaks these hand-checked rectangles.
for _, case in ipairs({
    { name="normal", w=600, h=800, boxes={{0,0,300,400},{300,0,300,400},{0,400,300,400},{300,400,300,400}},
        sizes={{600,800},{600,800},{600,800},{600,800}} },
    { name="split", w=1200, h=800, split=true,
        boxes={{0,0,600,400},{600,0,600,400},{0,400,600,400},{600,400,600,400}},
        sizes={{600,400},{600,400},{600,400},{600,400}} },
    { name="fit-width", w=600, h=2400, fit_mode="width",
        boxes={{0,0,300,1200},{300,0,300,1200},{0,1200,300,1200},{300,1200,300,1200}},
        sizes={{200,800},{200,800},{200,800},{200,800}} },
    { name="cropped odd", w=640, h=880, crop={x=11,y=17,w=601,h=803},
        boxes={{0,0,300,401},{300,0,301,401},{0,401,300,402},{300,401,301,402}},
        sizes={{598,800},{600,799},{597,800},{599,800}} },
}) do
    local r, o = fixture(true, case)
    r.page_crop = case.crop
    expect(r:_display_segment(r.position.segment, false), case.name .. " ordinary display")
    local source, ordinary = r.page_buffer, r.page_viewport
    local saves, requests, decodes = o.saves, #o.requests, o.decodes
    for i, point in ipairs(points) do
        expect(r.shell.widget:onTwoFingerTap(nil, { pos=point }), case.name .. " accepts quadrant")
        local view, box, image, size = r.page_viewport, case.boxes[i], o.image, case.sizes[i]
        expect(view.x == box[1] and view.y == box[2] and view.w == box[3] and view.h == box[4],
            case.name .. " selects complete quadrant " .. i)
        expect(case.crop and view.parent.parent == source or not case.crop and view.parent == source,
            "crop must precede one quadrant over the existing allocation")
        image:getSize() -- Runs KOReader's real _render and best-fit positioning.
        expect(image:getCurrentWidth() == size[1] and image:getCurrentHeight() == size[2],
            case.name .. " complete quadrant must fit reading area; got "
                .. image:getCurrentWidth() .. "x" .. image:getCurrentHeight())
        expect(math.abs(image:getCurrentWidth() - view.w * image:getScaleFactor()) < 1.001
            and math.abs(image:getCurrentHeight() - view.h * image:getScaleFactor()) < 1.001,
            "both axes use the same scale, with only integer-pixel rounding")
        local painted = false
        image:paintTo({ blitFrom = function(_, rendered, x, y, sx, sy, w, h)
            painted = true
            -- Negative offsets are letterboxing. The requested source interval
            -- must contain the entire scaled image; positive offsets lose pixels.
            expect(sx <= 0 and sy <= 0 and sx + w >= rendered.w and sy + h >= rendered.h,
                case.name .. " paint rectangle must represent every selected source pixel")
            expect(x - sx >= 0 and y - sy >= 0 and x - sx + rendered.w <= 600
                and y - sy + rendered.h <= 800, "painted image stays inside reading area")
            expect(math.abs((600-rendered.w)/2 + sx) <= 1
                and math.abs((800-rendered.h)/2 + sy) <= 1, "letterbox is centered")
        end }, 0, 0)
        expect(painted and image.image == view and image.image_disposable == false
            and source.frees == 0 and r.page_buffer == source, "fit borrows the original quadrant")
        expect(r.shell.widget:onTwoFingerTap(nil, {pos=point}), "second tap collapses")
        expect(o.image.scale_factor == 1 and r.quadrant_zoom == nil
            and r.page_viewport.w == ordinary.w and r.page_viewport.h == ordinary.h,
            "collapse restores ordinary scale and viewport")
    end
    expect(o.saves == saves and #o.requests == requests and o.decodes == decodes,
        "zoom and collapse perform no history, Loader or decode work")
    r.shell.widget:onTwoFingerTap(nil, {pos=points[2]})
    expect(r:enter_panel_mode() and r.quadrant_zoom == nil and o.image.scale_factor == 1
        and r.panel_entry.viewport.w == ordinary.w and r.panel_entry.viewport.h == ordinary.h,
        "panel entry restores the ordinary snapshot and scale")
    r:_show_panel(source, {}, 1, 2)
    expect(o.image.scale_factor == 1, "panel publication uses ordinary scale")
    r:exit_panel_mode()
    expect(o.image.scale_factor == 1, "panel exit uses ordinary scale")
    r.fit_mode = "page"
    r.shell.widget:onTwoFingerTap(nil, {pos=points[2]})
    r:request_page(2)
    o.requests[2].callbacks.on_ready("/cache/2.jpg", false, {width=case.w,height=case.h})
    expect(r.quadrant_zoom == nil and o.image.scale_factor == 1, "page change restores ordinary scale")
    local shell = r.shell
    r:force_close("plugin_teardown")
    expect(r.quadrant_zoom == nil and shell.current_model == nil, "close clears zoom and model")
end
print(("rebuild_0405_quadrant_fit_spec: %d checks passed (real KOReader ImageWidget)"):format(checks))
