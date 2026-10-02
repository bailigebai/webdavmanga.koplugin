local Errors = require("webdavmanga.errors")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end

local range = Errors.stream("epub", "range_probe", "content_range_mismatch")
expect(range.code == "document" and range.stage == "stream", "stream errors use document boundary")
expect(range.format == "epub" and range.stream_stage == "range_probe"
    and range.reason == "content_range_mismatch", "safe stage and reason survive")
expect(range.detail == "epub:content_range_mismatch", "legacy detail stays compatible")
expect(Errors.message(range):find("HTTP Range", 1, true), "Range failure is explicit")

local directory = Errors.stream("epub", "zip_directory", "zip_directory_invalid")
expect(Errors.message(directory):find("ZIP", 1, true), "ZIP directory failure is explicit")
local opf = Errors.stream("epub", "epub_spine", "epub_not_image_book")
expect(Errors.message(opf):find("EPUB", 1, true), "EPUB structure failure is explicit")
local pdf = Errors.stream("pdf", "pdf_index", "pdf_xref_invalid")
expect(Errors.message(pdf):find("PDF", 1, true), "PDF structure failure is explicit")

expect(Errors.stream_stage("epub", "content_range_missing") == "range_probe", "Range reasons keep probe stage")
expect(Errors.stream_stage("pdf", "pdf_xref_invalid") == "pdf_index", "PDF reasons keep index stage")
expect(Errors.stream_stage("epub", "zip_directory_invalid") == "zip_directory", "ZIP reasons keep directory stage")
expect(Errors.stream_stage("epub", "epub_container_missing") == "epub_container", "container reason stays distinct")
expect(Errors.stream_stage("epub", "epub_not_image_book") == "epub_spine", "EPUB reasons keep spine stage")
expect(Errors.stream_stage("epub", "unknown_image_signature") == "first_page", "image reasons keep first-page stage")
expect(Errors.stream_stage("epub", "stream_failed") == "fallback", "unknown stage has safe fallback")

local unsafe = Errors.stream("secret-name", "remote/path", "password=secret")
expect(unsafe.format == "document" and unsafe.stream_stage == "fallback"
    and unsafe.reason == "stream_failed", "untrusted values collapse to safe allowlists")
expect(unsafe.detail == "document:stream_failed", "legacy detail is sanitized")
expect(not Errors.message(unsafe):find("secret", 1, true), "user text cannot cross the boundary")

print(("rebuild_0408_stream_error_spec: %d checks"):format(checks))
