--[[--
TaskNotes - an offline, page based task / note manager for KOreader.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Font = require("ui/font")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------

local function deepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = deepCopy(v)
    end
    return copy
end

local function newCategory()
    return { name = "", lines = {}, start_idx = 1 }
end

local function newPage()
    return {
        active_category = nil,
        categories = { newCategory(), newCategory(), newCategory() },
    }
end

local function newData()
    return {
        current_page = 1,
        pages = { newPage() },
    }
end

local function cmToPx(cm)
    local dpi = (Screen.getDPI and Screen:getDPI()) or 167
    return math.floor(cm * dpi / 2.54)
end

local function place(x, y, widget)
    return VerticalGroup:new{
        VerticalSpan:new{ width = y },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = x },
            widget,
        },
    }
end

local TapArea = InputContainer:extend{}

function TapArea:init()
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
    }
end

function TapArea:onTap()
    if self.callback then self.callback() end
    return true
end

-- ---------------------------------------------------------------------
-- The full screen widget
-- ---------------------------------------------------------------------

local TaskNotesView = InputContainer:extend{
    name = "tasknotes_view",
}

local SIZE = {
    title = 24,
    tab = 15,
    side_btn = 18,
    heading_line = 20,
    normal_line = 16,
    small_btn = 16,
}

function TaskNotesView:init()
    self.dimen = Screen:getSize()
    self.covers_fullscreen = true

    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/tasknotes.lua")

    self.data = self.settings:readSetting("data")
    if not self.data or not self.data.pages or #self.data.pages == 0 then
        self.data = newData()
    end

    local start_page = self.data.pages[self.data.current_page]
    if start_page then
        start_page.active_category = nil
    end

    self.selected_style = nil
    self.delete_mode = false
    self.edit_mode = false
    self.move_mode = false
    self.move_source = nil
    self.undo_snapshot = nil
    self.redo_snapshot = nil

    self.has_more_lines_below = false

    self.key_events = {
        Close = { { Device.input.group.Back } },
    }

    self.ges_events = {}
    self:render()
end

function TaskNotesView:saveData()
    self.settings:saveSetting("data", self.data)
    self.settings:flush()
end

function TaskNotesView:getPage()
    return self.data.pages[self.data.current_page]
end

function TaskNotesView:getActiveCategory()
    local page = self:getPage()
    if not page.active_category then return nil end
    return page.categories[page.active_category]
end

function TaskNotesView:insertLine(cat, new_line)
    local insert_idx = #cat.lines + 1
    for i, line in ipairs(cat.lines) do
        if line.style == "T" and line.done then
            insert_idx = i
            break
        end
    end
    table.insert(cat.lines, insert_idx, new_line)
end

function TaskNotesView:pushUndo()
    self.undo_snapshot = deepCopy(self.data)
    self.redo_snapshot = nil
end

function TaskNotesView:doUndo()
    if not self.undo_snapshot then
        UIManager:show(InfoMessage:new{ text = _("Nothing to undo"), timeout = 1 })
        return
    end
    self.redo_snapshot = deepCopy(self.data)
    self.data = self.undo_snapshot
    self.undo_snapshot = nil
    self:saveData()
    self:render(true)
end

function TaskNotesView:doRedo()
    if not self.redo_snapshot then
        UIManager:show(InfoMessage:new{ text = _("Nothing to redo"), timeout = 1 })
        return
    end
    self.undo_snapshot = deepCopy(self.data)
    self.data = self.redo_snapshot
    self.redo_snapshot = nil
    self:saveData()
    self:render(true)
end

function TaskNotesView:swipeZone()
    return {
        id = "tasknotes_swipe",
        ges = "swipe",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        handler = function(ges) return self:onGlobalSwipe(ges) end,
    }
end

function TaskNotesView:onGlobalSwipe(ges)
    if ges.direction == "west" then
        self:goToPage(self.data.current_page + 1)
        return true
    elseif ges.direction == "east" then
        self:goToPage(self.data.current_page - 1)
        return true
    end
    return false
end

function TaskNotesView:scrollLines(direction, step)
    local cat = self:getActiveCategory()
    if not cat then return end
    cat.start_idx = cat.start_idx or 1
    step = step or math.max(self.last_page_line_count or 1, 1)

    if direction > 0 and self.has_more_lines_below then
        cat.start_idx = cat.start_idx + step
        self:render(true)
    elseif direction < 0 and cat.start_idx > 1 then
        cat.start_idx = math.max(cat.start_idx - step, 1)
        self:render(true)
    end
end

function TaskNotesView:resetModes()
    self.selected_style = nil
    self.delete_mode = false
    self.edit_mode = false
    self.move_mode = false
    self.move_source = nil
end

function TaskNotesView:goToPage(idx)
    if idx < 1 or idx > #self.data.pages then return end
    self.data.current_page = idx
    self:resetModes()
    self:saveData()
    self:render(true)
end

function TaskNotesView:onClose()
    self:saveData()
    UIManager:close(self)
    UIManager:setDirty("all", "full")
    return true
end

function TaskNotesView:onCloseOrDeletePage()
    if self.delete_mode then
        self:deleteCurrentPage()
    else
        self:onClose()
    end
end

function TaskNotesView:deleteCurrentPage()
    if #self.data.pages <= 1 then
        UIManager:show(InfoMessage:new{ text = _("Can't delete the only page"), timeout = 1.5 })
        self.delete_mode = false
        self:render()
        return
    end
    self:pushUndo()
    table.remove(self.data.pages, self.data.current_page)
    if self.data.current_page > #self.data.pages then
        self.data.current_page = #self.data.pages
    end
    self:resetModes()
    self:saveData()
    self:render(true)
end

function TaskNotesView:showHelp()
    local help_text = _(
        "TaskNotes -- how it works\n\n" ..
        "PAGES\n" ..
        "Swipe left/right to move between pages. Tap + to create a new page with 3 empty categories.\n\n" ..
        "CATEGORIES (bottom row)\n" ..
        "Tap an empty tab to name it. Tap a named tab to open it. Tap the open tab again to close it.\n\n" ..
        "ADDING A LINE\n" ..
        "Pick H (heading), T (to-do) or N (note), then tap the blank area to type. New lines go to the top; finished to-dos sink to the bottom.\n\n" ..
        "TO-DO LINES\n" ..
        "Tap the circle to check it off -- it turns into a checkmark, goes gray, and moves to the bottom.\n\n" ..
        "D -- delete mode: tap a line or a tab to delete it.\n" ..
        "E -- edit mode: tap a line or a tab to change its text/name.\n" ..
        "M -- move mode: tap a line to pick it up, tap another spot to drop it there.\n" ..
        "<- / -> -- undo / redo (one step).\n\n" ..
        "Up/down arrows appear next to the list when there are more lines than fit on screen."
    )
    UIManager:show(InfoMessage:new{ text = help_text })
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function TaskNotesView:render(full_refresh)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(10)
    local edge_gap = cmToPx(0.5)
    local text_gap = cmToPx(0.4)
    local right_col_w = Screen:scaleBySize(70)
    local right_btn_h = Screen:scaleBySize(58)
    local top_h = Screen:scaleBySize(50)
    local bottom_btn_h = Screen:scaleBySize(52)
    local close_w = Screen:scaleBySize(40)

    local page = self:getPage()
    local cat = self:getActiveCategory()

    local zones = {}

    local top_margin = cmToPx(0.5)
    local left_margin = cmToPx(0.5)

    local close_btn = Button:new{
        text = "x",
        bordersize = Size.border.button,
        radius = 0,
        margin = 0,
        text_font_size = SIZE.small_btn,
        width = close_w,
        callback = function() self:onCloseOrDeletePage() end,
    }

    local help_btn = Button:new{
        text = "?",
        bordersize = Size.border.button,
        radius = 0,
        margin = 0,
        text_font_size = SIZE.small_btn,
        width = close_w,
        callback = function() self:showHelp() end,
    }

    local has_cat = cat and cat.name ~= ""
    local title_text = has_cat and cat.name or _("Pick a category to start")
    local title_widget = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = top_h },
        TextWidget:new{
            text = title_text,
            face = Font:getFace("tfont", has_cat and SIZE.title or SIZE.heading_line),
            bold = true,
        },
    }

    local function styleButton(label, style_key)
        local active = (self.selected_style == style_key)
        return Button:new{
            text = label,
            bordersize = Size.border.button,
            radius = 0,
            margin = Screen:scaleBySize(3),
            text_font_size = SIZE.side_btn,
            text_font_bold = true,
            width = right_col_w - pad,
            height = right_btn_h,
            inverse = active,
            callback = function() self:onPickStyle(style_key) end,
        }
    end

    local right_col = VerticalGroup:new{
        styleButton("H", "H"),
        styleButton("T", "T"),
        styleButton("N", "N"),
        Button:new{
            text = "D", bordersize = Size.border.button, radius = 0, margin = Screen:scaleBySize(3),
            text_font_size = SIZE.side_btn, text_font_bold = true, width = right_col_w - pad, height = right_btn_h,
            inverse = self.delete_mode, callback = function() self:onToggleDelete() end,
        },
        Button:new{
            text = "E", bordersize = Size.border.button, radius = 0, margin = Screen:scaleBySize(3),
            text_font_size = SIZE.side_btn, text_font_bold = true, width = right_col_w - pad, height = right_btn_h,
            inverse = self.edit_mode, callback = function() self:onToggleEdit() end,
        },
        Button:new{
            text = "M", bordersize = Size.border.button, radius = 0, margin = Screen:scaleBySize(3),
            text_font_size = SIZE.side_btn, text_font_bold = true, width = right_col_w - pad, height = right_btn_h,
            inverse = self.move_mode, callback = function() self:onToggleMove() end,
        },
        Button:new{
            text = "\u{2190}", bordersize = Size.border.button, radius = 0, margin = Screen:scaleBySize(3),
            text_font_size = SIZE.side_btn, width = right_col_w - pad, height = right_btn_h,
            callback = function() self:doUndo() end,
        },
        Button:new{
            text = "\u{2192}", bordersize = Size.border.button, radius = 0, margin = Screen:scaleBySize(3),
            text_font_size = SIZE.side_btn, width = right_col_w - pad, height = right_btn_h,
            callback = function() self:doRedo() end,
        },
    }

    local right_col_x = screen_w - right_col_w - cmToPx(0.3)
    local right_col_y = top_margin + top_h + pad
    local bottom_row_y = screen_h - bottom_btn_h - edge_gap
    local content_x = left_margin
    local content_top_y = top_margin + top_h + pad
    local content_w = right_col_x - content_x - pad
    local content_h = bottom_row_y - pad - content_top_y

    local lines_group = VerticalGroup:new{}
    local y_cursor = text_gap
    self.has_more_lines_below = false
    self.last_page_line_count = 0

    if cat then
        cat.start_idx = cat.start_idx or 1
        if #cat.lines == 0 then
            cat.start_idx = 1
        elseif cat.start_idx > #cat.lines then
            cat.start_idx = #cat.lines
        end

        for i = cat.start_idx, #cat.lines do
            local line = cat.lines[i]
            local face_size = (line.style == "H") and SIZE.heading_line or SIZE.normal_line
            local prefix_w = Screen:scaleBySize(25)
            local max_text_w = content_w - prefix_w - (text_gap * 2)

            local item_row_items = {}

            -- Fixed prefix box on the left so the checkbox is NEVER on top of the text
            if line.style == "T" then
                local mark = line.done and "\u{2713}" or "\u{25CB}"
                table.insert(item_row_items, CenterContainer:new{
                    dimen = Geom:new{ w = prefix_w, h = face_size + Screen:scaleBySize(4) },
                    TextWidget:new{
                        text = mark,
                        face = Font:getFace("cfont", face_size),
                        fgcolor = line.done and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK,
                    }
                })
            else
                table.insert(item_row_items, HorizontalSpan:new{ width = prefix_w })
            end

            local text_widget
            if self.move_mode and self.move_source and self.move_source.kind == "line" and self.move_source.idx == i then
                text_widget = TextWidget:new{
                    text = "----------------------------------------",
                    face = Font:getFace("cfont", face_size),
                    fgcolor = Blitbuffer.COLOR_GRAY,
                }
            else
                text_widget = TextBoxWidget:new{
                    text = line.text,
                    face = Font:getFace("cfont", face_size),
                    bold = (line.style == "H"),
                    fgcolor = (line.style == "T" and line.done) and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK,
                    width = max_text_w,
                }
            end

            table.insert(item_row_items, text_widget)
            local line_item = HorizontalGroup:new(item_row_items)
            local tsize = line_item:getSize()
            
            -- Dynamic line gap logic (0.1 - 0.2mm gap scaled)
            local item_gap = Screen:scaleBySize(10)
            local zone_h = tsize.h + item_gap

            if y_cursor + zone_h > content_h then
                self.has_more_lines_below = true
                break
            end

            local line_index = i
            table.insert(lines_group, TapArea:new{
                dimen = Geom:new{ w = content_w, h = zone_h },
                callback = function() self:onTapLine(line_index) end,
                line_item,
            })

            y_cursor = y_cursor + zone_h
            self.last_page_line_count = self.last_page_line_count + 1
        end
    end

    -- The blank "tap to add a line" area, and swipe-to-scroll, are both
    -- registered as absolute-screen-coordinate zones (the same reliable
    -- mechanism the page-turn swipe already uses) rather than as a nested
    -- widget inside the VerticalGroup stack -- nested tap areas were only
    -- reliably clickable near where they visually started, not across
    -- their whole declared rectangle.
    if y_cursor < content_h then
        local add_y = content_top_y + y_cursor
        local add_h = content_h - y_cursor
        table.insert(zones, {
            id = "add_line_area",
            ges = "tap",
            screen_zone = {
                ratio_x = content_x / screen_w,
                ratio_y = add_y / screen_h,
                ratio_w = content_w / screen_w,
                ratio_h = add_h / screen_h,
            },
            handler = function() self:onTapAddArea(); return true end,
        })
    end

    -- swipe up/down anywhere in the content rectangle scrolls continuously,
    -- a few lines at a time, instead of needing to tap the arrow buttons
    table.insert(zones, {
        id = "content_scroll",
        ges = "swipe",
        screen_zone = {
            ratio_x = content_x / screen_w,
            ratio_y = content_top_y / screen_h,
            ratio_w = content_w / screen_w,
            ratio_h = content_h / screen_h,
        },
        handler = function(ges)
            if ges.direction == "north" then
                self:scrollLines(1, 3)
                return true
            elseif ges.direction == "south" then
                self:scrollLines(-1, 3)
                return true
            end
            return false
        end,
    })

    -- reliable scroll buttons -- only shown when there's actually more to
    -- see in that direction; these replace the earlier swipe-based scrolling,
    -- which could feel inconsistent since it shared gestures with page-swipe
    local can_scroll_up = cat and cat.start_idx and cat.start_idx > 1
    local scroll_btn_w = Screen:scaleBySize(40)
    local scroll_up_btn, scroll_down_btn
    if can_scroll_up then
        scroll_up_btn = Button:new{
            text = "\u{2191}",
            bordersize = Size.border.button,
            radius = 0,
            margin = Screen:scaleBySize(2),
            text_font_size = SIZE.small_btn,
            width = scroll_btn_w,
            callback = function() self:scrollLines(-1) end,
        }
    end
    if self.has_more_lines_below then
        scroll_down_btn = Button:new{
            text = "\u{2193}",
            bordersize = Size.border.button,
            radius = 0,
            margin = Screen:scaleBySize(2),
            text_font_size = SIZE.small_btn,
            width = scroll_btn_w,
            callback = function() self:scrollLines(1) end,
        }
    end

    local plus_w = right_col_w - pad
    local plus_x = right_col_x
    local tabs_area_w = plus_x - pad - content_x
    local tab_gap = Screen:scaleBySize(4)
    local tab_w = (tabs_area_w - tab_gap * 2) / 3
    local tab_buttons = {}

    for i = 1, 3 do
        local c = page.categories[i]
        local label = (c.name ~= "") and c.name or _("Tap to type")
        tab_buttons[i] = Button:new{
            text = label, bordersize = Size.border.button, radius = 0, margin = Screen:scaleBySize(2),
            text_font_size = SIZE.tab, width = tab_w, height = bottom_btn_h, inverse = (page.active_category == i),
            callback = function() self:onTapTab(i) end,
        }
    end

    local tabs_row = HorizontalGroup:new{ tab_buttons[1], tab_buttons[2], tab_buttons[3] }
    local tabs_row_x = content_x + (tabs_area_w - tabs_row:getSize().w) / 2

    local plus_btn = Button:new{
        text = "+", bordersize = Size.border.button, radius = 0, margin = Screen:scaleBySize(2),
        text_font_size = SIZE.title, text_font_bold = true, width = plus_w, height = bottom_btn_h,
        callback = function() self:onTapPlus() end,
    }

    local empty_bg_widget = nil
    if not has_cat then
        empty_bg_widget = CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            TextWidget:new{
                text = "TaskNotes",
                face = Font:getFace("tfont", 55),
                bold = true,
                fgcolor = Blitbuffer.COLOR_GRAY,
            },
        }
    end

    local full_group_items = {
        dimen = Geom:new{ w = screen_w, h = screen_h },
    }
    
    if empty_bg_widget then
        table.insert(full_group_items, place(0, 0, empty_bg_widget))
    end

    table.insert(full_group_items, place(left_margin, top_margin, close_btn))
    table.insert(full_group_items, place(screen_w - close_w - left_margin, top_margin, help_btn))
    table.insert(full_group_items, place(0, top_margin, title_widget))
    table.insert(full_group_items, place(right_col_x, right_col_y, right_col))
    table.insert(full_group_items, place(content_x, content_top_y, lines_group))
    table.insert(full_group_items, place(tabs_row_x, bottom_row_y, tabs_row))
    table.insert(full_group_items, place(plus_x, bottom_row_y, plus_btn))
    if scroll_up_btn then
        table.insert(full_group_items, place(screen_w - scroll_btn_w * 2 - Screen:scaleBySize(8), top_margin, scroll_up_btn))
    end
    if scroll_down_btn then
        table.insert(full_group_items, place(screen_w - scroll_btn_w - Screen:scaleBySize(4), top_margin, scroll_down_btn))
    end

    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h, background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0,
        OverlapGroup:new(full_group_items),
    }
    
    table.insert(zones, self:swipeZone())
    self:registerTouchZones(zones)
    UIManager:setDirty(self, full_refresh and "full" or "ui")
end

-- ---------------------------------------------------------------------
-- Event handlers
-- ---------------------------------------------------------------------

function TaskNotesView:onPickStyle(style_key)
    self.delete_mode = false
    self.edit_mode = false
    self.move_mode = false
    self.move_source = nil
    if self.selected_style == style_key then
        self.selected_style = nil
    else
        self.selected_style = style_key
    end
    self:render()
end

function TaskNotesView:onToggleDelete()
    local turning_on = not self.delete_mode
    self:resetModes()
    self.delete_mode = turning_on
    self:render()
end

function TaskNotesView:onToggleEdit()
    local turning_on = not self.edit_mode
    self:resetModes()
    self.edit_mode = turning_on
    self:render()
end

function TaskNotesView:onToggleMove()
    local turning_on = not self.move_mode
    self:resetModes()
    self.move_mode = turning_on
    self:render()
end

function TaskNotesView:onTapTab(idx)
    local page = self:getPage()
    local c = page.categories[idx]

    if self.delete_mode then
        self:pushUndo()
        page.categories[idx] = newCategory()
        if page.active_category == idx then page.active_category = nil end
        self.delete_mode = false
        self:saveData()
        self:render()
        return
    end

    if self.edit_mode then
        self.edit_mode = false
        self:promptCategoryName(idx, c.name)
        return
    end

    if self.move_mode then
        if self.move_source and self.move_source.kind == "cat" then
            local from_idx = self.move_source.idx
            self.move_source = nil
            self.move_mode = false
            if from_idx ~= idx then
                self:pushUndo()
                page.categories[from_idx], page.categories[idx] = page.categories[idx], page.categories[from_idx]
                if page.active_category == from_idx then
                    page.active_category = idx
                elseif page.active_category == idx then
                    page.active_category = from_idx
                end
                self:saveData()
            end
            self:render()
        else
            self.move_source = { kind = "cat", idx = idx }
            UIManager:show(InfoMessage:new{ text = _("Category picked. Tap another tab to swap."), timeout = 1.5 })
            self:render()
        end
        return
    end

    if c.name == "" then
        self:promptCategoryName(idx)
    elseif page.active_category == idx then
        page.active_category = nil
        self.selected_style = nil
        self:saveData()
        self:render()
    else
        page.active_category = idx
        self.selected_style = nil
        if page.categories[idx].start_idx then
            page.categories[idx].start_idx = 1
        end
        self:saveData()
        self:render()
    end
end

function TaskNotesView:promptCategoryName(idx, prefill)
    local dialog
    dialog = InputDialog:new{
        title = _("Category name"),
        input = prefill or "",
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    if name and name ~= "" then
                        self:pushUndo()
                        local page = self:getPage()
                        page.categories[idx].name = name
                        page.active_category = idx
                        self:saveData()
                        self:render()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function TaskNotesView:onTapPlus()
    self:pushUndo()
    table.insert(self.data.pages, newPage())
    self.data.current_page = #self.data.pages
    self:resetModes()
    self:saveData()
    self:render(true)
end

function TaskNotesView:onTapAddArea()
    local cat = self:getActiveCategory()
    if not cat then return end
    if not self.selected_style then
        UIManager:show(InfoMessage:new{ text = _("Pick H, T or N first"), timeout = 1.5 })
        return
    end

    local style = self.selected_style
    local dialog
    dialog = InputDialog:new{
        title = _("New line"),
        input = "",
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Add"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    if text and text ~= "" then
                        self:pushUndo()
                        self:insertLine(cat, { text = text, style = style, done = false })
                        self:saveData()
                        self:render()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function TaskNotesView:onTapLine(idx)
    local cat = self:getActiveCategory()
    if not cat then return end
    local line = cat.lines[idx]
    if not line then return end

    if self.delete_mode then
        self:pushUndo()
        table.remove(cat.lines, idx)
        self.delete_mode = false
        self:saveData()
        self:render()
        return
    end

    if self.edit_mode then
        self.edit_mode = false
        self:promptLineText(cat, idx, line.text)
        return
    end

    if self.move_mode then
        if self.move_source and self.move_source.kind == "line" then
            local from_idx = self.move_source.idx
            self.move_source = nil
            self.move_mode = false
            if from_idx ~= idx then
                self:pushUndo()
                local moved = table.remove(cat.lines, from_idx)
                local target = idx
                if from_idx < target then target = target - 1 end
                table.insert(cat.lines, target, moved)
                self:saveData()
            end
            self:render()
        else
            self.move_source = { kind = "line", idx = idx }
            self:render()
        end
        return
    end

    if line.style == "T" then
        self:pushUndo()
        line.done = not line.done
        local toggled_line = table.remove(cat.lines, idx)
        
        if toggled_line.done then
            table.insert(cat.lines, toggled_line)
        else
            self:insertLine(cat, toggled_line)
        end
        self:saveData()
        self:render()
    end
end

function TaskNotesView:promptLineText(cat, idx, prefill)
    local dialog
    dialog = InputDialog:new{
        title = _("Edit line"),
        input = prefill or "",
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    if text and text ~= "" then
                        self:pushUndo()
                        cat.lines[idx].text = text
                        self:saveData()
                        self:render()
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------------
-- Plugin registration
-- ---------------------------------------------------------------------

local TaskNotes = WidgetContainer:extend{
    name = "tasknotes",
}

function TaskNotes:init()
    self.ui.menu:registerToMainMenu(self)
end

function TaskNotes:addToMainMenu(menu_items)
    menu_items.tasknotes = {
        text = "TaskNotes",
        sorting_hint = "tools",
        callback = function()
            UIManager:show(TaskNotesView:new{})
        end,
    }
end

return TaskNotes
