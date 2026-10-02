"""Strict file and sensitive-content contract for the current plugin."""
import re
from pathlib import PurePosixPath

FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
PERMISSIONS = 0o100644 << 16
MODULES = """
archive_pages archive_stream async auto_crop book_index cache chapter_index client cover
denoise dialog_keyboard directory_store document_bridge error_reporter errors format_diagnostics
gray_enhance image_formats image_probe keyboard_compat library license license_config license_crypto license_device
license_rsa license_store license_transport lighting loader local_archive local_client manga_identity manifest
manifest_posix meguru_association meguru_document meguru_pointer memory_pages memory_transfer
mobi_compat mobi_pages mupdf_pages native_image_filter natural_sort nodeshare offline_cache
offline_manager opds_catalog opds_chapter_index opds_client opds_cover opds_driver
opds_drivers/kavita opds_drivers/komga opds_drivers/suwayomi opds_pages opds_parser opds_progress
opds_resume opds_url page_processor page_sequence panel_detector panel_session panel_source path
pinyin_initials premium_access prepared_pages progress quadrant_zoom remote_stream safe_callback
series_navigation settings state strict_integer tone_adjust transport ui_browser ui_cover_grid
ui_library ui_opds ui_reader ui_reader_shell ui_registry ui_settings webdav_xml
""".split()
SAMPLES = """baseline.jpg grayscale.png lossless.WEBP lossy.webp manifest.lua progressive.jpeg
rgba.PNG sample.tif sample.TIFF static.gif vector.svg""".split()
REQUIRED = {"_meta.lua", "main.lua", "README.md", "NOTICE"} | {
    f"webdavmanga/{name}.lua" for name in MODULES
} | {f"resources/format_samples/{name}" for name in SAMPLES}


def validate_content(name: str, body: bytes) -> None:
    path = PurePosixPath(name)
    if (name not in REQUIRED or path.is_absolute() or ".." in path.parts or "\\" in name
            or any(part.startswith(".") for part in path.parts)
            or re.search(r"(?:^|[/._-])(?:part|spool|building|wrangler|credentials|private|tests?)(?:$|[/._-])", name, re.I)):
        raise ValueError("unexpected or sensitive package member: " + name)
    # Only the published UI input placeholder is exempt from the issued-key shape.
    scanned = body.replace("授权密钥（XXXX-XXXX-XXXX）".encode(), b"license input placeholder")
    alphabet = rb"[23456789ABCDEFGHJKMNPQRSTUVWXYZ]"
    patterns = (
        rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----",
        rb"(?<![A-Za-z0-9_])(?:" + alphabet + rb"{4}-){2}" + alphabet + rb"{4}(?![A-Za-z0-9_])",
        rb"[\"']" + alphabet + rb"{12}[\"']",
        rb"^\s*" + alphabet + rb"{12}\s*$",
        rb"(?:LICENSE_PRIVATE_KEY|WRANGLER_API_TOKEN|CLOUDFLARE_API_TOKEN)[\"']?\s*[=:]\s*[\"'][^\"']+",
        rb"\b(?:password|api_key|apikey|access_token|secret)\s*[=:]\s*[\"'][^\"'{}\s][^\"']*[\"']",
        rb"https?://[^\s/\"']+:[^\s/@\"']+@",
        rb"(?:[A-Za-z]:[/\\](?:Users|Documents and Settings)[/\\]|/(?:home|Users)/)[^\s\"']+",
        rb"INSERT\s+(?:OR\s+\w+\s+)?INTO\s+license_keys",
    )
    if any(re.search(pattern, scanned, re.I | re.M) for pattern in patterns):
        raise ValueError("sensitive content in package member: " + name)
