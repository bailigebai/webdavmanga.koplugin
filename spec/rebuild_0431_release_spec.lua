package.loaded.gettext=function(s)return s end
local root=TEST_PLUGIN_ROOT
local function read(p)local f=assert(io.open(root..'/'..p,'rb'));local s=f:read('*a');f:close();return s end
local meta=assert(loadfile(root..'/_meta.lua'))()
assert(meta.version=='0.4.31','current release version')
assert(read('main.lua'):match('local%s+VERSION%s*=%s*"([^"]+)"')==meta.version,'runtime version')
assert(read('README.md'):find('版本：0.4.31',1,true),'readme version')
assert(read('NOTICE'):find('version 0.4.31',1,true),'notice version')
local help=read('webdavmanga/reader_help.lua')
for _,marker in ipairs({'Web 分格','返回上一级','高级动态面板识别','自动匹配强度','0°','270°','原生 /'})do
    assert(help:find(marker,1,true),'help: '..marker)
end
assert(not help:find('当前视图截图',1,true),'screenshot removed')
for _,name in ipairs({'panel_modes','panel_detection_profile','web_panel_zoom','web_panel_analysis','web_panel_components'})do
    assert(loadfile(root..'/webdavmanga/'..name..'.lua'),'packaged module '..name)
end
print('rebuild_0431_release_spec: 17 checks')
