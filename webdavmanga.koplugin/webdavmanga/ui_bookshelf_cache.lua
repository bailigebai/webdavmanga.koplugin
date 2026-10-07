local Registry=require("webdavmanga.ui_registry")
local Keyboard=require("webdavmanga.dialog_keyboard")
local SafeCallback=require("webdavmanga.safe_callback")
local MB=1024*1024
local Ui={};Ui.__index=Ui

local function default_ui()
    local Manager=require("ui/uimanager")
    local Buttons=require("ui/widget/buttondialog")
    local Input=require("ui/widget/multiinputdialog")
    local Confirm=require("ui/widget/confirmbox")
    local Info=require("ui/widget/infomessage")
    local registry=Registry:new(Manager)
    local adapter={}
    function adapter:show_info(text) registry:show(Info:new{text=text,timeout=4}) end
    function adapter:confirm(model) registry:show(Confirm:new{text=model.text,ok_callback=model.on_confirm}) end
    function adapter:close_all() registry:close_all() end
    function adapter:show(model)
        self:close_all()
        local dialog
        local function close() registry:close(dialog) end
        local function edit()
            close()
            local input
            local fields={};for _,field in ipairs({
                {"total_mb","最大容量（MB）"},{"trigger_mb","清理触发线（MB）"},
                {"retain_mb","清理后保留量（MB）"},{"interval_minutes","检查间隔（分钟）"},
            }) do fields[#fields+1]={text=tostring(model.policy[field[1]]),hint=field[2],description=field[2],input_type="number"} end
            input=Input:new{title="漫画书架封面缓存策略",fields=fields,buttons={{
                {text="取消",callback=function() registry:close(input);model.on_return() end},
                {text="保存",callback=function()
                    local values=input:getFields()
                    if model.on_save{total_mb=values[1],trigger_mb=values[2],retain_mb=values[3],interval_minutes=values[4]} then
                        registry:close(input);model.on_return()
                    end
                end},
            }}}
            registry:show(input);Keyboard.show(input)
        end
        dialog=Buttons:new{title=("%s\n总占用 %.2f MB；封面 %d 张（%.2f MB）\n目录与选图索引 %.2f MB；使用中 %.2f MB\n上限 %.0f / 触发 %.0f / 保留 %.0f MB；每 %.0f 分钟检查\n超过触发线，按最久未浏览顺序清理到保留量。\n仅保存书架封面与索引，不代表整本漫画已离线。")
            :format(model.title,model.used_bytes/MB,model.cover_count,model.cover_bytes/MB,
                model.index_bytes/MB,model.protected_bytes/MB,model.policy.total_mb,
                model.policy.trigger_mb,model.policy.retain_mb,model.policy.interval_minutes),
            buttons={
                {{text="修改容量与清理策略",callback=edit}},
                {{text="按规则清理旧封面",callback=function() close();model.on_cleanup() end}},
                {{text="清空漫画书架封面缓存",callback=function() close();model.on_clear() end}},
                {{text="关闭",callback=close}},
            }}
        registry:show(dialog)
    end
    return adapter
end

function Ui:new(options)
    return setmetatable({settings=assert(options.settings),cache=assert(options.cache),
        ui=options.ui,on_changed=options.on_changed,
        error_reporter=options.error_reporter},self)
end
function Ui:_callback(label,callback) return SafeCallback.wrap(self.error_reporter or self.ui,label,callback,false) end
function Ui:show()
    if not self.ui then self.ui=default_ui() end
    local cache=self.cache
    local policy=self.settings:get_bookshelf_cache()
    self.ui:show{
        title="漫画书架封面缓存",policy=policy,used_bytes=cache:total_size(),
        cover_bytes=cache:kind_size("cover"),cover_count=cache:kind_count("cover"),
        index_bytes=cache:kind_size("manifest")+cache.store:cache_index_size(cache.entries),
        protected_bytes=cache:protected_size(),
        on_return=self:_callback("reopen bookshelf cache",function() self:show() end),
        on_save=self:_callback("save bookshelf cache policy",function(values)
            local old=self.settings:get_bookshelf_cache()
            if not self.settings:set_bookshelf_cache(values) then
                self.ui:show_info("请填写有效数字：0 ≤ 保留量 < 触发线 ≤ 最大容量；检查间隔为1–1440分钟。")
                return false
            end
            local next_policy=self.settings:get_bookshelf_cache()
            if not cache:set_browse_policy{total_bytes=next_policy.total_mb*MB,
                trigger_bytes=next_policy.trigger_mb*MB,retain_bytes=next_policy.retain_mb*MB,
                check_interval_seconds=next_policy.interval_minutes*60} then
                self.settings:set_bookshelf_cache(old);return false
            end
            self.settings:flush()
            cache:cleanup_browse(true)
            if self.on_changed then self.on_changed() end
            return true
        end),
        on_cleanup=self:_callback("clean old bookshelf cache",function()
            local freed=cache:cleanup_browse(true)
            self:show()
            self.ui:show_info(("已释放 %.2f MB；当前保留 %.2f MB。使用中的封面和目录会保留。")
                :format((tonumber(freed) or 0)/MB,cache:total_size()/MB))
        end),
        on_clear=self:_callback("confirm bookshelf cache clear",function()
            self.ui:confirm{text="只清理漫画书架生成的封面和目录索引；原漫画、阅读历史和正文缓存不会删除。使用中的文件会保留。",
                on_confirm=self:_callback("clear bookshelf cache",function()
                    local ok,retained=cache:clear()
                    self:show()
                    self.ui:show_info((ok and "书架缓存已清理，使用中保留 %.2f MB。" or "部分书架缓存清理失败，使用中保留 %.2f MB。")
                        :format((tonumber(retained) or 0)/MB))
                end)}
        end),
    }
end
function Ui:close_all() if self.ui and self.ui.close_all then self.ui:close_all() end end
return Ui
