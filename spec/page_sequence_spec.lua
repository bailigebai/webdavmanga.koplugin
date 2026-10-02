local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Sequence = require("webdavmanga.page_sequence")

local function reader(overrides)
    local values = {
        split_enabled = false,
        split_min_ratio = 1.20,
        split_max_ratio = 2.20,
        split_cut_percent = 50,
        direction = "normal",
    }
    for key, value in pairs(overrides or {}) do values[key] = value end
    return values
end

local function join(values)
    return table.concat(values, ",")
end

local disabled = reader()
expect(join(Sequence.segments(1600, 1000, disabled)) == "whole",
    "split pages should remain disabled by default")

local normal = reader{ split_enabled = true, direction = "normal" }
expect(join(Sequence.segments(1200, 1000, normal)) == "left,right",
    "the minimum wide-page ratio should be inclusive")
expect(join(Sequence.segments(1199, 1000, normal)) == "whole",
    "pages below the minimum ratio should remain whole")
expect(join(Sequence.segments(2200, 1000, normal)) == "left,right",
    "the maximum wide-page ratio should be inclusive")
expect(join(Sequence.segments(2201, 1000, normal)) == "whole",
    "pages above the maximum ratio should remain whole")

local manga = reader{ split_enabled = true, direction = "manga" }
expect(join(Sequence.segments(1600, 1000, manga)) == "right,left",
    "manga direction should read the right segment first")

local first = Sequence.segments(1600, 1000, normal)
local second = Sequence.segments(1600, 1000, normal)
first[1] = "changed"
expect(join(second) == "left,right", "segment arrays must be fresh values")

local left = Sequence.viewport(1000, 800, "left", 40)
local right = Sequence.viewport(1000, 800, "right", 40)
local whole = Sequence.viewport(1000, 800, "whole", 40)
expect(left.x == 0 and left.y == 0 and left.w == 400 and left.h == 800,
    "left viewport should end at the exact cut")
expect(right.x == 400 and right.y == 0 and right.w == 600 and right.h == 800,
    "right viewport should begin at the exact cut")
expect(whole.x == 0 and whole.y == 0 and whole.w == 1000 and whole.h == 800,
    "whole viewport should cover the complete image")

local position = { index = 2, segment = "left" }
local next_position = Sequence.next(position, { "left", "right" }, 3)
expect(next_position.index == 2 and next_position.segment == "right",
    "next should advance between split segments before changing physical page")
expect(position.index == 2 and position.segment == "left",
    "next must not mutate its input position")
next_position = Sequence.next(next_position, { "left", "right" }, 3)
expect(next_position.index == 3 and next_position.segment == "whole",
    "next should advance to a whole physical page after the final segment")
expect(Sequence.next({ index = 3, segment = "whole" }, { "whole" }, 3) == nil,
    "next should stop at the final physical page")

position = { index = 2, segment = "right" }
local previous_position = Sequence.previous(position, { "left", "right" }, 3)
expect(previous_position.index == 2 and previous_position.segment == "left",
    "previous should reverse within a split physical page")
expect(position.index == 2 and position.segment == "right",
    "previous must not mutate its input position")
previous_position = Sequence.previous(previous_position, { "left", "right" }, 3)
expect(previous_position.index == 1 and previous_position.segment == "whole",
    "previous should return to the prior whole physical page")
expect(Sequence.previous({ index = 1, segment = "whole" }, { "whole" }, 3) == nil,
    "previous should stop at the first physical page")

local manga_next = Sequence.next({ index = 1, segment = "right" },
    { "right", "left" }, 2)
expect(manga_next.index == 1 and manga_next.segment == "left",
    "navigation should follow the supplied manga segment order")
local normal_after_direction_change = Sequence.next(
    { index = 1, segment = "left" }, { "left", "right" }, 2)
expect(normal_after_direction_change.index == 1
    and normal_after_direction_change.segment == "right",
    "navigation should follow a changed normal segment order")

print(("page_sequence_spec: %d checks"):format(checks))
