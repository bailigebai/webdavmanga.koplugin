-- Historical version/bundle contract superseded by 0.4.16. Its functional
-- bookshelf, cache and reader suites remain selected by --all.
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local root=assert(TEST_PLUGIN_ROOT)
local function read(path) local f=assert(io.open(root.."/"..path,"rb"));local b=f:read("*a");f:close();return b end
package.preload.gettext=function() return function(s) return s end end
local meta=assert(loadfile(root.."/_meta.lua"))()
expect(meta.version=="0.4.15","bookshelf cover release must identify 0.4.15")
expect(read("main.lua"):match('local%s+VERSION%s*=%s*"([^"]+)"')==meta.version,"runtime metadata agrees")
for _,name in ipairs({"bookshelf","bookshelf_store","bookshelf_catalog","bookshelf_loader","bookshelf_toolbar","ui_bookshelf_cache"}) do
    expect(#read("webdavmanga/"..name..".lua")>0,"dedicated shelf module installed: "..name)
end
local help=read("webdavmanga/reader_help.lua")
for _,marker in ipairs({"漫画书架封面缓存","直属图片","下一层","200MB","150MB","100MB","10分钟","长按","列表"}) do
    expect(help:find(marker,1,true),"comic instructions explain "..marker)
end
local readme=read("README.md")
for _,marker in ipairs({"版本：0.4.15","漫画书架封面缓存","下一页继续检测","只刷新文字区域","完整目录"}) do
    expect(readme:find(marker,1,true),"release documents retain old reading behavior and new shelf: "..marker)
end
expect(read("NOTICE"):find("version 0.4.15",1,true),"notice version agrees")
print(("rebuild_0415_release_spec: %d checks"):format(checks))
