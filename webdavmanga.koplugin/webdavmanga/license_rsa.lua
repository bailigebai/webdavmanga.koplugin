local Rsa = {}

function Rsa.valid_signature(value)
    return type(value) == "string" and #value == 344
        and value:sub(-2) == "=="
        and value:sub(1, 342):find("[^A-Za-z0-9+/]") == nil
        and value:sub(342, 342):match("[AQgw]") ~= nil
end

local ffi
local crypto
local function backend()
    if crypto then return true end
    local ok = pcall(function()
        ffi = require("ffi")
        ffi.cdef[[
            typedef struct bio_st WDM_BIO;
            typedef struct evp_pkey_st WDM_PKEY;
            typedef struct evp_md_st WDM_MD;
            typedef struct evp_md_ctx_st WDM_MD_CTX;
            typedef struct evp_pkey_ctx_st WDM_PKEY_CTX;
            typedef struct rsa_st WDM_RSA;
            WDM_BIO *BIO_new_mem_buf(const void *, int);
            int BIO_free(WDM_BIO *);
            WDM_PKEY *PEM_read_bio_PUBKEY(WDM_BIO *, WDM_PKEY **, void *, void *);
            void EVP_PKEY_free(WDM_PKEY *);
            WDM_RSA *EVP_PKEY_get1_RSA(WDM_PKEY *);
            int RSA_size(const WDM_RSA *);
            void RSA_free(WDM_RSA *);
            WDM_MD_CTX *EVP_MD_CTX_new(void);
            void EVP_MD_CTX_free(WDM_MD_CTX *);
            const WDM_MD *EVP_sha256(void);
            int EVP_DigestVerifyInit(WDM_MD_CTX *, WDM_PKEY_CTX **,
                const WDM_MD *, void *, WDM_PKEY *);
            int EVP_PKEY_CTX_ctrl_str(WDM_PKEY_CTX *, const char *, const char *);
            int EVP_DigestUpdate(WDM_MD_CTX *, const void *, size_t);
            int EVP_DigestVerifyFinal(WDM_MD_CTX *, const unsigned char *, size_t);
            int EVP_DecodeBlock(unsigned char *, const unsigned char *, int);
        ]]
        crypto = ffi.loadlib("crypto", "57")
    end)
    return ok and crypto ~= nil
end

function Rsa.verify(self_or_message, message_or_signature, signature_or_pem, maybe_pem)
    local message, signature, pem
    if type(self_or_message) == "table" then
        message, signature, pem = message_or_signature, signature_or_pem, maybe_pem
    else
        message, signature, pem = self_or_message, message_or_signature, signature_or_pem
    end
    if type(message) ~= "string" or #message > 256
        or not Rsa.valid_signature(signature) then
        return false
    end
    if not backend() then return nil, "crypto_unavailable" end
    if type(pem) ~= "string" or #pem > 8192
        or pem:find("BEGIN PUBLIC KEY", 1, true) == nil
        or pem:find("PRIVATE KEY", 1, true) ~= nil then
        return nil, "public_key_unavailable"
    end

    local bio, key, rsa, context
    local called, valid = pcall(function()
        bio = crypto.BIO_new_mem_buf(pem, #pem)
        if bio == nil then return false end
        key = crypto.PEM_read_bio_PUBKEY(bio, nil, nil, nil)
        if key == nil then return false end
        rsa = crypto.EVP_PKEY_get1_RSA(key)
        if rsa == nil or crypto.RSA_size(rsa) ~= 256 then return false end
        local decoded = ffi.new("unsigned char[258]")
        if crypto.EVP_DecodeBlock(decoded, signature, #signature) ~= 258 then
            return false
        end
        context = crypto.EVP_MD_CTX_new()
        if context == nil then return false end
        local key_context = ffi.new("WDM_PKEY_CTX *[1]")
        return crypto.EVP_DigestVerifyInit(context, key_context,
                crypto.EVP_sha256(), nil, key) == 1
            and crypto.EVP_PKEY_CTX_ctrl_str(key_context[0],
                "rsa_padding_mode", "pkcs1") == 1
            and crypto.EVP_DigestUpdate(context, message, #message) == 1
            and crypto.EVP_DigestVerifyFinal(context, decoded, 256) == 1
    end)
    if context ~= nil then crypto.EVP_MD_CTX_free(context) end
    if rsa ~= nil then crypto.RSA_free(rsa) end
    if key ~= nil then crypto.EVP_PKEY_free(key) end
    if bio ~= nil then crypto.BIO_free(bio) end
    return called and valid == true
end

return Rsa
