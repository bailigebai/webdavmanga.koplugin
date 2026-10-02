local M = {}

function M.normalize_remote(value)
    local path = tostring(value or ""):gsub("\\", "/")
    path = path:gsub("/+", "/")
    local segments = {}
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then
            if #segments > 0 then table.remove(segments) end
        elseif segment ~= "." then
            segments[#segments + 1] = segment
        end
    end
    if #segments == 0 then return "" end
    return "/" .. table.concat(segments, "/")
end

function M.join_remote(base, child)
    return M.normalize_remote(tostring(base or "") .. "/" .. tostring(child or ""))
end

function M.is_within_remote(path, root)
    local normalized_path = M.normalize_remote(path)
    local normalized_root = M.normalize_remote(root)
    if normalized_root == "" then return true end
    return normalized_path == normalized_root
        or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

function M.webdav_request_path(value)
    -- ZSpace exposes volume roots as "SATA11-account" in PROPFIND hrefs,
    -- while requests below that root are accepted only with a lowercase
    -- "sata" prefix (the root itself accepts either spelling).
    local path = M.normalize_remote(value)
    return path:gsub("^/SATA(%d+%-[^/]+)", "/sata%1", 1)
end

function M.build_url(address, remote_path, encode_segment)
    local base = tostring(address or ""):gsub("/+$", "")
    local path = M.webdav_request_path(remote_path)
    if path == "" then return base .. "/" end
    local encoded = {}
    for segment in path:gmatch("[^/]+") do
        encoded[#encoded + 1] = encode_segment(segment)
    end
    return base .. "/" .. table.concat(encoded, "/")
end

return M
