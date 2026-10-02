local Crypto = {}

local PRODUCT = "webdavmanga-premium"
local ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
local ALPHABET_SET = {}
for index = 1, #ALPHABET do ALPHABET_SET[ALPHABET:sub(index, index)] = true end

local function trim_ascii(value)
    value = tostring(value or "")
    return (value:match("^[ \t\r\n]*(.-)[ \t\r\n]*$") or "")
end

local function ascii_upper(value)
    return value:gsub("%l", string.upper)
end

local function valid_hex(value)
    return type(value) == "string" and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

local function default_sha256(value)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or type(sha2) ~= "table" or type(sha2.sha256) ~= "function" then
        return nil, "hash_unavailable"
    end
    local called, digest = pcall(sha2.sha256, value)
    if not called or type(digest) ~= "string" then return nil, "hash_failed" end
    digest = digest:lower()
    if not valid_hex(digest) then return nil, "hash_failed" end
    return digest
end

function Crypto.normalize_key(raw)
    if type(raw) ~= "string" then return nil, "invalid_key_format" end
    local value = trim_ascii(raw)
    if value == "" then return nil, "invalid_key_format" end
    local compact
    if #value == 14 then
        if not value:match("^[%w][%w][%w][%w]%-[%w][%w][%w][%w]%-[%w][%w][%w][%w]$") then
            return nil, "invalid_key_format"
        end
        compact = value:gsub("-", "")
    elseif #value == 12 then
        if value:find("-", 1, true) then return nil, "invalid_key_format" end
        compact = value
    else
        return nil, "invalid_key_format"
    end
    compact = ascii_upper(compact)
    if #compact ~= 12 then return nil, "invalid_key_format" end
    for index = 1, #compact do
        if not ALPHABET_SET[compact:sub(index, index)] then
            return nil, "invalid_key_character"
        end
    end
    return compact:sub(1, 4) .. "-" .. compact:sub(5, 8) .. "-" .. compact:sub(9, 12)
end

function Crypto.key_hash(normalized_key)
    if type(normalized_key) ~= "string" then return nil, "invalid_key_format" end
    local canonical = Crypto.normalize_key(normalized_key)
    if not canonical then return nil, "invalid_key_format" end
    return default_sha256(canonical)
end

function Crypto.receipt_payload(receipt)
    if type(receipt) ~= "table" then return nil, "invalid_receipt" end
    return table.concat({
        "PRODUCT-LICENSE-1",
        tostring(receipt.device_id or ""),
        tostring(receipt.key_id or ""),
        tostring(receipt.issued_at or ""),
    }, "\n")
end

local function validate_receipt(receipt)
    if type(receipt) ~= "table" then return false, "invalid_receipt" end
    if receipt.version ~= 1 then return false, "invalid_version" end
    if receipt.product ~= PRODUCT then return false, "invalid_product" end
    if not valid_hex(receipt.device_id) then return false, "invalid_device_id" end
    if not valid_hex(receipt.key_id) then return false, "invalid_key_id" end
    if type(receipt.issued_at) ~= "number" or receipt.issued_at < 1
        or receipt.issued_at ~= math.floor(receipt.issued_at) then
        return false, "invalid_issued_at"
    end
    local signature = receipt.signature
    if type(signature) ~= "string" or #signature == 0 then
        return false, "invalid_signature"
    end
    local padding = signature:match("(=*)$") or ""
    local body = signature:sub(1, #signature - #padding)
    if #padding > 2 or body:find("[^A-Za-z0-9+/]", 1) then
        return false, "invalid_signature"
    end
    return true
end

function Crypto.verify_receipt(receipt, public_key)
    local valid, error_code = validate_receipt(receipt)
    if not valid then return false, error_code end
    if type(public_key) ~= "table" or type(public_key.verifier) ~= "table"
        or type(public_key.verifier.verify) ~= "function" then
        return false, "missing_verifier"
    end
    local payload = Crypto.receipt_payload(receipt)
    local ok, verified = pcall(public_key.verifier.verify, public_key.verifier,
        payload, receipt.signature, public_key.value or public_key.key)
    if not ok or verified ~= true then return false, "invalid_signature" end
    return true
end

Crypto.PRODUCT = PRODUCT
Crypto.ALPHABET = ALPHABET
Crypto.valid_hex = valid_hex
return Crypto
