package.preload["ffi/sha2"] = function()
    return { sha256 = function(value)
        return string.rep(string.byte(tostring(value), 1, 1) == 0 and "0" or "a", 64)
    end }
end

local Crypto = require("webdavmanga.license_crypto")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

expect(Crypto.normalize_key(" \n23456789abcd\r\n") == "2345-6789-ABCD",
    "ASCII outer whitespace and lowercase should normalize")
expect(Crypto.normalize_key("2345-6789-ABCD") == "2345-6789-ABCD",
    "canonical key should remain unchanged")
expect(Crypto.normalize_key("23456789ABCD") == "2345-6789-ABCD",
    "unhyphenated key should normalize")
expect(Crypto.normalize_key(" abcd-efgh-ijkl ") == nil,
    "characters outside the short-key alphabet must be rejected")
expect(Crypto.normalize_key("２３４５-6789-ABCD") == nil,
    "Unicode lookalikes must be rejected")
expect(Crypto.normalize_key("2345 6789-ABCD") == nil,
    "internal spaces must be rejected")
expect(Crypto.normalize_key("2345--6789-ABCD") == nil,
    "misplaced hyphens must be rejected")
local normalized = assert(Crypto.normalize_key("2345-6789-abcd"))
expect(Crypto.key_hash(normalized) == string.rep("a", 64),
    "key hash must be lower-case SHA-256 output")

local receipt = {
    version = 1,
    product = "webdavmanga-premium",
    device_id = string.rep("a", 64),
    key_id = string.rep("b", 64),
    issued_at = 1700000000,
    signature = "c2ln",
}
local payload = Crypto.receipt_payload(receipt)
expect(payload == "PRODUCT-LICENSE-1\n" .. string.rep("a", 64) .. "\n"
    .. string.rep("b", 64) .. "\n1700000000",
    "receipt payload must match the production Worker's fixed canonical form")
expect(payload:sub(-1) ~= "\n", "receipt payload must not end in LF")
local verifier = { verify = function(_, value, signature, public_key)
    return value == payload and signature == "c2ln" and public_key == "pub"
end }
local verified, verify_error = Crypto.verify_receipt(receipt, {
    value = "pub", verifier = verifier,
})
expect(verified == true and verify_error == nil, "injected verifier should validate receipt")
local bad = {}
for key, value in pairs(receipt) do bad[key] = value end
bad.product = "other"
local rejected, rejected_error = Crypto.verify_receipt(bad, {
    value = "pub", verifier = verifier,
})
expect(rejected == false and rejected_error == "invalid_product",
    "tampered product must be rejected before signature verification")
for _, item in ipairs({
    { "key_id", string.rep("c", 64) },
    { "issued_at", 1700000001 },
    { "signature", "!!!!" },
}) do
    local altered = {}
    for key, value in pairs(receipt) do altered[key] = value end
    altered[item[1]] = item[2]
    local altered_ok = Crypto.verify_receipt(altered, {
        value = "pub", verifier = verifier,
    })
    expect(altered_ok == false, "tampered " .. item[1] .. " must be rejected")
end
local closed = Crypto.verify_receipt(receipt, "raw-public-key")
expect(closed == false, "missing injected RSA verifier must fail closed")

print(("license_crypto_spec: %d checks"):format(checks))
