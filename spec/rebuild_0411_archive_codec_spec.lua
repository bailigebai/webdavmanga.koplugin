local Stream=require('webdavmanga.archive_stream')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
package.loaded.device={isKindle=function() return true end}
local function run(arch,softfp,core_codec,load_error,bundle_codec,kind)
    local core={archive_version_details=function() return core_codec and 'libarchive liblzma/5.8.3' or 'libarchive zlib' end}
    local bundled={archive_version_details=function() return bundle_codec and 'libarchive liblzma/5.8.3' or 'libarchive zlib' end}
    local loads=0
    local ffi={arch=arch,os='Linux',abi=function(name) assert(name=='softfp');return softfp end,
        cdef=function() end,string=function(value) return value end,
        load=function(path)
            loads=loads+1
            expect(path:match('/lib/kindlehf/libarchive%.so%.13$'),'only the plugin-owned packaged library may load')
            if load_error then error('missing library') end
            return bundled
        end}
    local stream=Stream:new{ffi=ffi,libarchive=core}
    expect(type(stream._library_for_format)=='function','archive reader must select a format-specific compatible codec')
    local selected=stream:_library_for_format(kind or '7z')
    return selected,core,bundled,loads,stream
end
local lib,core,bundle,loads,stream=run('arm',false,false,false,true)
expect(lib==bundle and loads==1,'KindleHF 7Z gets the packaged LZMA-capable codec')
expect(stream:_library_for_format('cb7')==bundle,'CB7 shares the verified codec')
expect(stream:_library_for_format('rar')==core,'RAR retains the installed core library')
for _,case in ipairs({{'x64',false,false,false,true}, {'arm',true,false,false,true},
    {'arm',false,true,false,true},{'arm',false,false,true,true},{'arm',false,false,false,false},
    {'arm',false,false,false,true,'zip'}}) do
    local selected,original,_,count=run(unpack(case))
    expect(selected==original,'unsupported platforms, missing bundles and capable core preserve existing library')
end
print(('rebuild_0411_archive_codec_spec: %d checks'):format(checks))
