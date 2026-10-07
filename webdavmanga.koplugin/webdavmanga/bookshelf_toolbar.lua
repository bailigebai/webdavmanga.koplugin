local Toolbar={}
function Toolbar.new(model,width)
    local Screen=require("device").screen
    local TitleBar=require("ui/widget/titlebar")
    local Group=require("ui/widget/horizontalgroup")
    local IconButton=require("ui/widget/iconbutton")
    local Size=require("ui/size")
    local icon_size,padding=Screen:scaleBySize(28),Screen:scaleBySize(8)
    local function help(text)
        return function()
            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{text=text,timeout=3})
            return true
        end
    end
    local buttons={
        IconButton:new{icon="appbar.menu",width=icon_size,height=icon_size,padding=padding,
            callback=model.on_switch_connection,hold_callback=help("切换连接"),allow_flash=false},
        IconButton:new{icon=model.view_mode=="covers" and "appbar.filebrowser" or "book.opened",
            width=icon_size,height=icon_size,padding=padding,callback=model.on_toggle_view,
            hold_callback=help(model.view_mode=="covers" and "切换为文件夹列表" or "切换为漫画封面"),allow_flash=false},
    }
    local bar=TitleBar:new{title=model.title,subtitle=model.subtitle,width=width or Screen:getWidth(),
        subtitle_fullwidth=true,title_h_padding=2*(icon_size+2*padding)+Size.padding.large,
        with_bottom_line=true,close_callback=model.on_close}
    -- Stock TitleBar enlarges the single left icon's tap zone. Separate
    -- buttons keep that zone from overlapping the adjacent view toggle.
    bar[#bar+1]=Group:new{overlap_align="left",buttons[1],buttons[2]}
    bar.bookshelf_buttons=buttons
    function bar:generateHorizontalLayout()
        local row={buttons[1],buttons[2]};if self.right_button then row[#row+1]=self.right_button end
        return {row}
    end
    function bar:generateVerticalLayout()
        local rows={{buttons[1]},{buttons[2]}};if self.right_button then rows[#rows+1]={self.right_button} end
        return rows
    end
    return bar
end
return Toolbar
