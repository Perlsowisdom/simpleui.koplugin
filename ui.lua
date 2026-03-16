-- ui.lua — Simple UI
-- Shared layout infrastructure: side margin, content dimensions,
-- OverlapGroup composition (wrapWithNavbar), topbar replacement
-- and access to the UIManager window stack.

local FrameContainer = require("ui/widget/container/framecontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local LineWidget     = require("ui/widget/linewidget")
local Geom           = require("ui/geometry")
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Screen         = Device.screen
local logger         = require("logger")

local M   = {}
local _dim = {}

-- ---------------------------------------------------------------------------
-- Shared layout constants — single source of truth for all desktop modules.
--
-- Every module_*.lua and homescreen.lua reads these instead of declaring
-- their own identical local copies. Values are computed once at load time
-- via scaleBySize and stored as plain numbers — zero overhead at render time.
--
-- LABEL_PAD_TOP    : space above a section label text              (= PAD2)
-- LABEL_PAD_BOT    : space below a section label text, above content
-- LABEL_TEXT_H     : estimated height of the section label TextWidget
-- LABEL_H          : total vertical space consumed by a section label
--                    (LABEL_PAD_TOP + LABEL_PAD_BOT + LABEL_TEXT_H)
-- MOD_GAP          : vertical gap inserted by _buildContent after each module
-- PAD              : standard horizontal/vertical padding inside modules
-- PAD2             : smaller padding (half of PAD)
-- SIDE_PAD         : left/right inset of the homescreen content area
-- ---------------------------------------------------------------------------

M.PAD           = Screen:scaleBySize(14)
M.PAD2          = Screen:scaleBySize(8)
M.MOD_GAP       = Screen:scaleBySize(23)   -- includes former LABEL_PAD_TOP (8px)
M.SIDE_PAD      = Screen:scaleBySize(14)
M.LABEL_PAD_TOP = 0                         -- absorbed into MOD_GAP
M.LABEL_PAD_BOT = M.PAD2                    -- padding_bottom of sectionLabel (was 4px, now 8px)
M.LABEL_TEXT_H  = Screen:scaleBySize(16)    -- TextWidget height at SECTION_LABEL_SIZE
M.LABEL_H       = M.LABEL_PAD_TOP + M.LABEL_PAD_BOT + M.LABEL_TEXT_H

-- ---------------------------------------------------------------------------
-- Shared menu-item resolver
-- Converts KOReader-style menu item tables (with checked_func / enabled_func /
-- sub_item_table_func) into flat, statically-resolved tables suitable for use
-- in our custom Menu widgets (P2 — eliminates duplication in bottombar/topbar).
-- ---------------------------------------------------------------------------

function M.resolveMenuItems(items)
    local out = {}
    for _, item in ipairs(items) do
        local r = {}
        for k, v in pairs(item) do r[k] = v end
        if type(item.sub_item_table_func) == "function" then
            -- Resolve the sub-table and recurse into its items (C1).
            r.sub_item_table      = M.resolveMenuItems(item.sub_item_table_func())
            r.sub_item_table_func = nil
        elseif type(item.sub_item_table) == "table" then
            -- Resolve any funcs inside existing sub-tables too (C1).
            r.sub_item_table = M.resolveMenuItems(item.sub_item_table)
        end
        if type(item.checked_func) == "function" then
            local cf = item.checked_func
            r.mandatory_func = function() return cf() and "\u{2713}" or "" end
            r.checked_func   = nil
        end
        if type(item.enabled_func) == "function" then
            r.dim        = not item.enabled_func()
            r.enabled_func = nil
        end
        out[#out + 1] = r
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Side margin shared by topbar and bottombar
-- ---------------------------------------------------------------------------

local function _cached(key, fn)
    if not _dim[key] then _dim[key] = fn() end
    return _dim[key]
end

function M.SIDE_M()
    return _cached("side_m", function() return Screen:scaleBySize(24) end)
end

-- ---------------------------------------------------------------------------
-- Invalidates all dimension caches across bottombar and topbar
-- ---------------------------------------------------------------------------

function M.invalidateDimCache()
    _dim = {}
    local bb = package.loaded["bottombar"]
    if bb and bb.invalidateDimCache then bb.invalidateDimCache() end
    local tb = package.loaded["topbar"]
    if tb and tb.invalidateDimCache then tb.invalidateDimCache() end
    -- Clear VerticalSpan pools so stale px values (computed before resize)
    -- are not reused after scaleBySize produces different numbers.
    local hs = package.loaded["homescreen"]
    if hs and hs._instance and hs._instance._vspan_pool then
        hs._instance._vspan_pool = {}
    end
    -- Clear the section-label widget cache: labels embed inner_w in their key
    -- and must be rebuilt after a screen rotation changes inner_w (fix #6).
    if hs and hs.invalidateLabelCache then hs.invalidateLabelCache() end
end

-- ---------------------------------------------------------------------------
-- Content area dimensions
-- ---------------------------------------------------------------------------

function M.getContentHeight()
    local Bottombar = require("bottombar")
    local Topbar    = require("topbar")
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    return Screen:getHeight() - Bottombar.TOTAL_H() - (topbar_on and Topbar.TOTAL_TOP_H() or 0)
end

function M.getContentTop()
    local Topbar    = require("topbar")
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    return topbar_on and Topbar.TOTAL_TOP_H() or 0
end

-- ---------------------------------------------------------------------------
-- Topbar replacement inside OverlapGroup
-- ---------------------------------------------------------------------------

function M.replaceTopbar(widget, new_topbar)
    local container = widget._navbar_container
    if not container then return end
    if not widget._navbar_topbar then return end
    local idx = widget._navbar_topbar_idx
    if idx and container[idx] == widget._navbar_topbar then
        new_topbar.overlap_offset = container[idx].overlap_offset or { 0, 0 }
        container[idx]        = new_topbar
        widget._navbar_topbar = new_topbar
        return
    end
    for i, child in ipairs(container) do
        if child == widget._navbar_topbar then
            new_topbar.overlap_offset = child.overlap_offset or { 0, 0 }
            container[i]              = new_topbar
            widget._navbar_topbar     = new_topbar
            widget._navbar_topbar_idx = i
            return
        end
    end
    logger.warn("simpleui: replaceTopbar could not find topbar in container — skipping")
end

-- ---------------------------------------------------------------------------
-- Wraps an inner widget with the navbar layout (topbar + content + bottombar)
-- ---------------------------------------------------------------------------

function M.wrapWithNavbar(inner_widget, active_action_id, tabs)
    local Topbar    = require("topbar")
    local Bottombar = require("bottombar")
    local screen_w  = Screen:getWidth()
    local screen_h  = Screen:getHeight()
    -- Read both settings once — used multiple times below.
    local topbar_on = G_reader_settings:nilOrTrue("navbar_topbar_enabled")
    local navbar_on = G_reader_settings:nilOrTrue("navbar_enabled")
    local topbar_top = topbar_on and Topbar.TOTAL_TOP_H() or 0
    local navbar_h   = Bottombar.TOTAL_H()
    local content_h  = screen_h - topbar_top - navbar_h

    local bar    = navbar_on and Bottombar.buildBarWidget(active_action_id, tabs) or nil
    -- Build topbar only once — wrapWithNavbar is the single point of construction.
    -- Callers must NOT call buildTopbarWidget() again after wrapWithNavbar returns.
    local topbar = topbar_on and Topbar.buildTopbarWidget() or nil

    inner_widget.overlap_offset = { 0, topbar_top }
    if inner_widget.dimen then
        inner_widget.dimen.h = content_h
        inner_widget.dimen.w = screen_w
    else
        inner_widget.dimen = Geom:new{ w = screen_w, h = content_h }
    end

    local bar_idx      = navbar_on and 3 or nil
    local overlap_items = {
        dimen = Geom:new{ w = screen_w, h = screen_h },
        inner_widget,
    }

    if navbar_on then
        local bar_y = screen_h - navbar_h
        local bot_y = screen_h - Bottombar.BOT_SP()

        local sep_line = LineWidget:new{
            dimen      = Geom:new{ w = screen_w, h = Bottombar.TOP_SP() },
            background = Blitbuffer.COLOR_WHITE,
        }
        local bot_pad = LineWidget:new{
            dimen      = Geom:new{ w = screen_w, h = Bottombar.BOT_SP() },
            background = Blitbuffer.COLOR_WHITE,
        }
        sep_line.overlap_offset = { 0, bar_y }
        bar.overlap_offset      = { 0, bar_y + Bottombar.TOP_SP() }
        bot_pad.overlap_offset  = { 0, bot_y }

        overlap_items[2] = sep_line
        overlap_items[3] = bar
        overlap_items[4] = bot_pad
    end

    if topbar_on then
        topbar.overlap_offset = { 0, 0 }
        overlap_items[#overlap_items + 1] = topbar
    end

    local topbar_idx       = topbar_on and #overlap_items or nil
    local navbar_container = OverlapGroup:new(overlap_items)

    return navbar_container,
           FrameContainer:new{
               bordersize = 0, padding = 0, margin = 0,
               background = Blitbuffer.COLOR_WHITE,
               navbar_container,
           },
           bar, topbar, bar_idx, topbar_on, topbar_idx
end

-- ---------------------------------------------------------------------------
-- Applies all navbar state fields to a widget in one call (RF2).
-- Eliminates the repeated 9-field block scattered across patches/bottombar.
-- ---------------------------------------------------------------------------

function M.applyNavbarState(widget, container, bar, topbar, bar_idx, topbar_on, topbar_idx, tabs)
    local Topbar = require("topbar")
    widget._navbar_container         = container
    widget._navbar_bar               = bar
    widget._navbar_topbar            = topbar
    widget._navbar_topbar_idx        = topbar_idx
    widget._navbar_tabs              = tabs
    widget._navbar_bar_idx           = bar_idx
    widget._navbar_bar_idx_topbar_on = topbar_on
    widget._navbar_content_h         = M.getContentHeight()
    widget._navbar_topbar_h          = topbar_on and Topbar.TOTAL_TOP_H() or 0
end

-- ---------------------------------------------------------------------------
-- Safe access to the UIManager window stack
-- ---------------------------------------------------------------------------

function M.getWindowStack()
    local UIManager = require("ui/uimanager")
    if type(UIManager._window_stack) ~= "table" then
        logger.warn("simpleui: UIManager._window_stack not available — internal API changed?")
        return {}
    end
    return UIManager._window_stack
end

-- ---------------------------------------------------------------------------
-- Shared settings menu (#4)
-- Eliminates the near-identical showSettingsMenu closures in bottombar.lua and
-- topbar.lua. Both now delegate here.
--
-- title         : menu title string
-- item_table_fn : zero-arg function returning the raw item table
-- top_offset    : pixels to push the menu down (topbar height, or 0)
-- screen_h      : Screen:getHeight() — passed in to avoid re-querying
-- bottombar_h   : Bottombar.TOTAL_H() — passed in to avoid circular require
-- ---------------------------------------------------------------------------

function M.showSettingsMenu(title, item_table_fn, top_offset, screen_h, bottombar_h)
    if not item_table_fn then return end
    top_offset = top_offset or 0
    local Menu      = require("ui/widget/menu")
    local UIManager = require("ui/uimanager")
    local menu_h    = screen_h - bottombar_h - top_offset

    -- Tracks whether any item callback ran while the menu was open.
    -- Used by onCloseWidget to trigger an immediate HS refresh on close,
    -- bypassing the 0.15s debounce that would otherwise fire after the paint.
    local _had_changes = false

    local menu
    menu = Menu:new{
        title      = title,
        item_table = M.resolveMenuItems(item_table_fn()),
        height     = menu_h,
        width      = Screen:getWidth(),
        onMenuSelect = function(self_menu, item)
            if item.sub_item_table then
                self_menu.item_table.title = self_menu.title
                table.insert(self_menu.item_table_stack, self_menu.item_table)
                self_menu:switchItemTable(item.text, M.resolveMenuItems(item.sub_item_table))
            elseif item.callback then
                item.callback()
                _had_changes = true
                if item.keep_menu_open then
                    -- Stay open: just redraw the item list to reflect the change.
                    self_menu:updateItems()
                else
                    -- Close the menu; onCloseWidget will fire the HS refresh.
                    UIManager:close(self_menu)
                end
            end
            return true
        end,
        -- When the menu closes (by any means — back button, item without
        -- keep_menu_open, or tapping outside), immediately refresh the
        -- Homescreen if it is open and any item callback ran.
        -- This fires synchronously in the same UIManager cycle as the close,
        -- so the HS is rebuilt before the next paint — eliminating the
        -- stale-state flash that occurred when the 0.15s debounce timer
        -- fired after the menu had already closed and the HS been painted.
        onCloseWidget = function()
            if not _had_changes then return end
            _had_changes = false
            -- Call _refreshImmediate directly (synchronous, no scheduleIn).
            -- scheduleIn(0) was tried but the UIManager processes pending repaints
            -- before executing scheduled callbacks — so the HS was painted with
            -- the stale tree before the rebuild ran. The synchronous call ensures
            -- the widget tree is replaced before any paint is flushed.
            local ok, HS = pcall(require, "homescreen")
            if not (ok and HS and HS._instance) then return end
            HS._instance:_refreshImmediate(false)
        end,
    }
    if top_offset > 0 then
        local orig_paintTo = menu.paintTo
        menu.paintTo = function(self_m, bb, x, y)
            orig_paintTo(self_m, bb, x, y + top_offset)
        end
        menu.dimen.y = top_offset
    end
    UIManager:show(menu)
end

return M
