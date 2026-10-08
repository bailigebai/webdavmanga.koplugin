-- Replaces the 0.4.15 version/bundle contract; all functional suites still run.
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local root=assert(TEST_PLUGIN_ROOT)
local function read(path) local f=assert(io.open(root.."/"..path,"rb"));local b=f:read("*a");f:close();return b end
package.preload.gettext=function() return function(s) return s end end
local meta=assert(loadfile(root.."/_meta.lua"))()
expect(meta.version=="0.4.16","shared image-session release identifies 0.4.16")
expect(read("main.lua"):match('local%s+VERSION%s*=%s*"([^"]+)"')==meta.version,"runtime metadata agrees")
for _,name in ipairs({"bookshelf","bookshelf_store","bookshelf_catalog","bookshelf_loader","bookshelf_toolbar",
    "ui_bookshelf_cache","graydither_bridge"}) do
    expect(#read("webdavmanga/"..name..".lua")>0,"runtime module installed: "..name)
end
local help=read("webdavmanga/reader_help.lua")
for _,marker in ipairs({"漫画书架封面缓存","直属图片","下一层","200MB","150MB","100MB","10分钟","长按","列表",
    "灰度抖动与墨水屏刷新","默认关闭","GrayDither 0.3.0","16 级"}) do
    expect(help:find(marker,1,true),"comic instructions explain "..marker)
end
local readme=read("README.md")
for _,marker in ipairs({"版本：0.4.16","漫画书架封面缓存","下一页继续检测","只刷新文字区域","完整目录",
    "GrayDither 0.3.0","两个开关独立保存","默认关闭","硬件 256 级"}) do
    expect(readme:find(marker,1,true),"release documentation explains "..marker)
end
expect(read("NOTICE"):find("version 0.4.16",1,true),"notice version agrees")
print(("rebuild_0416_release_spec: %d checks"):format(checks))
