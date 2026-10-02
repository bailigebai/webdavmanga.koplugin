local Stream = require("webdavmanga.archive_stream")
local Errors = require("webdavmanga.errors")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local cases = {
    { -25, "Passphrase required for /private/account/secret.jpg", "archive_encrypted", "加密" },
    { -30, "Encrypted 7-Zip file https://account:secret@server/book.7z", "archive_encrypted", "加密" },
    { -30, "Unsupported compression method for /private/secret.jpg", "archive_codec_unsupported", "不支持", "compression_method" },
    { -25, "LZMA codec is not supported /private/secret.jpg", "archive_codec_unsupported", "不支持", "lzma" },
    { -30, "Truncated 7-Zip file /private/secret.jpg", "archive_truncated", "损坏" },
    { -25, "Unexpected end of archive /private/secret.jpg", "archive_truncated", "损坏" },
    { -30, "Unknown failure /private/secret.jpg", "archive_header_failed", "失败" },
}
for _, case in ipairs(cases) do
    local logs = {}
    local stream = Stream:new{logger = {warn = function(...)
        local fields = {}; for _, value in ipairs({...}) do fields[#fields+1] = tostring(value) end
        logs[#logs+1] = table.concat(fields, " ")
    end}}
    local reader = {archive = {}, entry = {}, consumed = true,
        ffi = {string = function(value) return value end},
        libarchive = {archive_read_next_header2 = function() return case[1] end,
            archive_error_string = function() return case[2] end}}
    local entry, reason = stream:next(reader)
    expect(not entry and reason == case[3], "hard native status keeps category: " .. case[3])
    expect(reader.last_status == case[1] and reader.native_reason == case[3],
        "reader diagnostics retain numeric status and allowlisted category")
    local log = table.concat(logs, " ")
    expect(log:find(tostring(case[1]), 1, true) and log:find(case[3], 1, true),
        "diagnostic contains native status and category")
    if case[5] then
        expect(reader.native_detail == case[5] and log:find(case[5], 1, true),
            "unsupported codec logs a fixed, non-sensitive subtype")
    end
    expect(not log:find("private", 1, true) and not log:find("secret", 1, true)
        and not log:find("https:", 1, true), "native paths and URLs never reach logs")
    local err = Errors.stream("7z", "fallback", reason)
    expect(err.reason == case[3] and Errors.message(err):find(case[4], 1, true),
        "specific native failure reaches safe user prompt")
end
for _, status in ipairs({0, -20}) do
    local reader = {archive = {}, entry = {}, consumed = true,
        ffi = {string = function(value) return value end},
        libarchive = {archive_read_next_header2 = function() return status end,
            archive_entry_pathname = function() return "001.jpg" end,
            archive_entry_size = function() return 12 end,
            archive_entry_filetype = function() return 32768 end}}
    expect(Stream:new():next(reader) ~= nil and reader.last_status == status,
        "OK/WARN preserve usable header and status")
end
expect(Errors.stream_reason("archive_seek_unavailable") == "archive_seek_unavailable",
    "seek capability reason is allowlisted")
expect(Errors.stream_stage("7z", "archive_range_read_failed") == "range_probe",
    "Range failure is distinct from native codec failures")
do
    local path=os.tmpname()
    local reader={archive={},current={mode="file",size=12,name="001.jpg"},consumed=false,
        ffi={new=function() return {} end,string=function() return "short" end},
        libarchive={archive_read_data=function(handle)
            if handle.read then return 0 end;handle.read=true;return 5
        end}}
    local metadata,reason=Stream:new():extract_current(reader,path)
    expect(not metadata and reason=="archive_truncated" and reader.native_reason==reason,
        "native EOF before declared entry size rejects truncated image")
    local remaining=io.open(path,"rb")
    expect(not remaining,"truncated output is removed")
    if remaining then remaining:close() end
    os.remove(path)
end
for _,case in ipairs(cases) do
    local path=os.tmpname()
    local reader={archive={},current={mode="file",size=12,name="001.jpg"},consumed=false,
        ffi={new=function() return {} end,string=function(value) return value end},
        libarchive={archive_read_data=function() return case[1] end,
            archive_error_string=function() return case[2] end}}
    local _,reason=Stream:new():extract_current(reader,path)
    expect(reason==(case[3]=="archive_header_failed" and "archive_read_failed" or case[3])
        and reader.last_status==case[1],"data failure retains native category and status")
    os.remove(path)
end
do
    local previous, logs = package.loaded.logger, {}
    package.loaded.logger = {warn=function(_,status,reason) logs[#logs+1]={status,reason} end}
    local reader={archive={},entry={},consumed=true,ffi={string=function(value) return value end},
        libarchive={archive_read_next_header2=function() return -30 end,
            archive_error_string=function() return "Truncated archive /private/secret.jpg" end}}
    Stream:new():next(reader)
    expect(logs[1] and logs[1][1]==-30 and logs[1][2]=="archive_truncated",
        "default device logger receives sanitized native diagnostics")
    package.loaded.logger=previous
end
print(("rebuild_0411_stream_errors_spec: %d checks"):format(checks))
