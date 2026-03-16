-- module_collections.lua — Simple UI
-- Módulo: Collections.
-- Substitui collectionswidget.lua — contém todo o código de widget.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")
local Config          = require("config")

local UI      = require("ui")
local PAD     = UI.PAD
local PAD2    = UI.PAD2
local MOD_GAP = UI.MOD_GAP

local COLL_W  = Screen:scaleBySize(75)
local COLL_H  = Screen:scaleBySize(112)
local ACCENT_H = Screen:scaleBySize(4)
local CELL_W   = COLL_W
local CELL_H   = COLL_H + ACCENT_H

local LABEL_LINE_H = Screen:scaleBySize(14)
local COLL_CELL_H  = CELL_H + Screen:scaleBySize(4) + LABEL_LINE_H
local BADGE_SZ     = Screen:scaleBySize(18)
local BADGE_MARGIN = Screen:scaleBySize(3)

local LABEL_H = UI.LABEL_H

local _CLR_COVER_BORDER = Blitbuffer.gray(0.45)  -- matches section label text colour
local _CLR_COVER_BG     = Blitbuffer.gray(0.88)
local _CLR_LABEL_TEXT   = Blitbuffer.gray(0.45)

-- ---------------------------------------------------------------------------
-- Settings keys
-- ---------------------------------------------------------------------------
local SETTINGS_KEY       = "navbar_collections_list"
local COVER_OVERRIDE_KEY = "navbar_collections_covers"

local function getSelectedCollections()
    return G_reader_settings:readSetting(SETTINGS_KEY) or {}
end
local function saveSelectedCollections(list)
    G_reader_settings:saveSetting(SETTINGS_KEY, list)
end
local function getCoverOverrides()
    return G_reader_settings:readSetting(COVER_OVERRIDE_KEY) or {}
end
local function saveCoverOverrides(t)
    G_reader_settings:saveSetting(COVER_OVERRIDE_KEY, t)
end

-- ---------------------------------------------------------------------------
-- ReadCollection helpers
-- ---------------------------------------------------------------------------
local function getCollectionFilesFromRC(rc, coll_name)
    local coll = rc.coll and rc.coll[coll_name]
    if not coll then return {} end
    local entries = {}
    local i = 1
    for fp, info in pairs(coll) do
        entries[i] = { filepath = fp, order = (type(info) == "table" and info.order) or 9999 }
        i = i + 1
    end
    table.sort(entries, function(a, b) return a.order < b.order end)
    local files = {}
    for j = 1, #entries do files[j] = entries[j].filepath end
    return files
end

-- ---------------------------------------------------------------------------
-- Cover loading
-- ---------------------------------------------------------------------------
local function getBookCover(filepath, w, h)
    local bb = Config.getCoverBB(filepath, w, h)
    if not bb then return nil end
    local ok, img = pcall(function()
        return ImageWidget:new{
            image        = bb,
            width        = w,
            height       = h,
            scale_factor = 1,
        }
    end)
    return ok and img or nil
end

-- ---------------------------------------------------------------------------
-- Cover cell
-- ---------------------------------------------------------------------------
local function buildCoverCell(files, cover_override, coll_name, count)
    local front_fp = cover_override
    if front_fp and lfs.attributes(front_fp, "mode") ~= "file" then front_fp = nil end
    if not front_fp and #files > 0 then front_fp = files[1] end

    local cover
    if front_fp and lfs.attributes(front_fp, "mode") == "file" then
        local raw = getBookCover(front_fp, COLL_W, COLL_H)
        if raw then
            cover = FrameContainer:new{
                bordersize = 1, color = _CLR_COVER_BORDER,
                padding    = 0, margin = 0,
                dimen      = Geom:new{ w = COLL_W, h = COLL_H },
                raw,
            }
        end
    end
    if not cover then
        cover = FrameContainer:new{
            bordersize = 1, color = _CLR_COVER_BORDER,
            background = _CLR_COVER_BG, padding = 0,
            dimen      = Geom:new{ w = COLL_W, h = COLL_H },
            CenterContainer:new{
                dimen = Geom:new{ w = COLL_W, h = COLL_H },
                TextWidget:new{
                    text = (coll_name or "?"):sub(1, 2):upper(),
                    face = Font:getFace("smallinfofont", Screen:scaleBySize(12)),
                },
            },
        }
    end

    local accent = FrameContainer:new{
        bordersize = 0, padding = 0,
        background = Blitbuffer.COLOR_BLACK,
        dimen      = Geom:new{ w = COLL_W, h = ACCENT_H },
        VerticalSpan:new{ width = 0 },
    }
    local base = VerticalGroup:new{ align = "left", cover, accent }

    local badge_inner = CenterContainer:new{
        dimen = Geom:new{ w = BADGE_SZ, h = BADGE_SZ },
        TextWidget:new{
            text    = tostring(math.min(count, 99)),
            face    = Font:getFace("cfont", Screen:scaleBySize(9)),
            fgcolor = Blitbuffer.COLOR_WHITE,
            bold    = true,
        },
    }
    local badge = FrameContainer:new{
        bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        radius     = math.floor(BADGE_SZ / 2),
        padding    = 0,
        dimen      = Geom:new{ w = BADGE_SZ, h = BADGE_SZ },
        badge_inner,
    }
    badge.overlap_offset = { BADGE_MARGIN, COLL_H - BADGE_SZ - BADGE_MARGIN }

    return OverlapGroup:new{
        dimen = Geom:new{ w = CELL_W, h = CELL_H },
        base, badge,
    }
end

-- ---------------------------------------------------------------------------
-- openCollection
-- ---------------------------------------------------------------------------
local function openCollection(coll_name)
    -- patchUIManagerShow (patches.lua) automatically closes any homescreen widget
    -- when a covers_fullscreen widget is shown — so we must NOT call close_fn here.
    -- Calling it would produce a double-close and run onCloseWidget twice.
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FM or not FM.instance then return end
    local fm = FM.instance
    if fm.collections and type(fm.collections.onShowColl) == "function" then
        pcall(function() fm.collections:onShowColl(coll_name) end)
    elseif fm.collections and type(fm.collections.onShowCollList) == "function" then
        pcall(function() fm.collections:onShowCollList() end)
    end
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------
local M = {}

M.id          = "collections"
M.name        = _("Collections")
M.label       = _("Collections")
M.enabled_key = "collections"
M.default_on  = true

function M.setEnabled(pfx, on)
    G_reader_settings:saveSetting(pfx .. "collections", on)
end

local MAX_COLL = 5

function M.getCountLabel(_pfx)
    local n   = #M.getSelected()
    local rem = MAX_COLL - n
    if n == 0   then return nil end
    if rem <= 0 then return string.format("(%d/%d — at limit)", n, MAX_COLL) end
    return string.format("(%d/%d — %d left)", n, MAX_COLL, rem)
end

local _EMPTY_H = Screen:scaleBySize(36)

function M.build(w, ctx)
    local selected = getSelectedCollections()
    if #selected == 0 then
        local CenterContainer = require("ui/widget/container/centercontainer")
        local _lc = require("gettext")
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = _EMPTY_H },
            require("ui/widget/textwidget"):new{
                text    = _lc("No collections selected"),
                face    = Font:getFace("cfont", Screen:scaleBySize(10)),
                fgcolor = Blitbuffer.gray(0.55),
                width   = w - PAD * 2,
            },
        }
    end

    local inner_w   = w - PAD * 2
    local cols      = math.min(#selected, 5)
    local overrides = getCoverOverrides()

    local rc
    local ok_rc, rc_or_err = pcall(require, "readcollection")
    if ok_rc and rc_or_err then
        rc = rc_or_err
        if rc._read then pcall(function() rc:_read() end) end
    end

    local gap = math.floor((inner_w - 5 * CELL_W) / 4)
    local row = HorizontalGroup:new{ align = "top" }

    for i = 1, cols do
        local coll_name = selected[i]
        local files     = rc and getCollectionFilesFromRC(rc, coll_name) or {}
        local count     = #files
        local thumb     = buildCoverCell(files, overrides[coll_name], coll_name, count)

        local label_w = TextWidget:new{
            text      = coll_name,
            face      = Font:getFace("cfont", Screen:scaleBySize(8)),
            fgcolor   = _CLR_LABEL_TEXT,
            width     = CELL_W,
            alignment = "center",
        }

        local cell_vg = VerticalGroup:new{
            align = "center",
            thumb,
            VerticalSpan:new{ width = Screen:scaleBySize(4) },
            label_w,
        }

        local tappable = InputContainer:new{
            dimen      = Geom:new{ w = CELL_W, h = COLL_CELL_H },
            [1]        = cell_vg,
            _coll_name = coll_name,
        }
        tappable.ges_events = {
            TapColl = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapColl()
            openCollection(self._coll_name)
            return true
        end

        row[#row + 1] = FrameContainer:new{
            bordersize   = 0, padding = 0,
            padding_left = (i > 1) and gap or 0,
            tappable,
        }
    end

    return FrameContainer:new{
        bordersize = 0, padding = PAD, padding_top = 0, padding_bottom = 0,
        row,
    }
end

function M.getHeight(_ctx)
    if #getSelectedCollections() == 0 then
        return LABEL_H + _EMPTY_H
    end
    return LABEL_H + COLL_CELL_H
end

-- Settings API (usados por getMenuItems e externamente pelo menu.lua legado)
function M.getSelected()       return getSelectedCollections() end
function M.saveSelected(list)  saveSelectedCollections(list) end
function M.getCoverOverrides() return getCoverOverrides() end
function M.saveCoverOverrides(t) saveCoverOverrides(t) end
function M.saveCoverOverride(coll_name, filepath)
    local t = getCoverOverrides(); t[coll_name] = filepath; saveCoverOverrides(t)
end
function M.clearCoverOverride(coll_name)
    local t = getCoverOverrides(); t[coll_name] = nil; saveCoverOverrides(t)
end

function M.getMenuItems(ctx_menu)
    local _UIManager  = ctx_menu.UIManager
    local InfoMessage = ctx_menu.InfoMessage
    local SortWidget  = ctx_menu.SortWidget
    local refresh     = ctx_menu.refresh
    local _lc         = ctx_menu._

    local ok_rc, rc  = pcall(require, "readcollection")
    local all_colls  = {}
    if ok_rc and rc then
        if rc._read then pcall(function() rc:_read() end) end
        local fav = rc.default_collection_name or "favorites"
        if rc.coll then
            if rc.coll[fav] then
                all_colls[#all_colls + 1] = fav
            end
            local others = {}
            for name in pairs(rc.coll) do
                if name ~= fav then others[#others + 1] = name end
            end
            table.sort(others, function(a, b) return a:lower() < b:lower() end)
            for _, n in ipairs(others) do all_colls[#all_colls + 1] = n end
        end
    end

    local function openCoverPicker(coll_name)
        if not ok_rc then return end
        if rc._read then pcall(function() rc:_read() end) end
        local coll = rc.coll and rc.coll[coll_name]
        if not coll then
            _UIManager:show(InfoMessage:new{ text = _lc("Collection is empty."), timeout = 2 }); return
        end
        local fps = {}
        for fp in pairs(coll) do fps[#fps + 1] = fp end
        table.sort(fps)
        if #fps == 0 then
            _UIManager:show(InfoMessage:new{ text = _lc("Collection is empty."), timeout = 2 }); return
        end
        local overrides     = M.getCoverOverrides()
        local ButtonDialog  = require("ui/widget/buttondialog")
        local cover_buttons = {}
        local _n            = coll_name
        cover_buttons[#cover_buttons + 1] = {{
            text     = (not overrides[_n] and "✓ " or "  ") .. _lc("Auto (first book)"),
            callback = function()
                _UIManager:close(ctx_menu._cover_picker)
                M.clearCoverOverride(_n); refresh()
            end,
        }}
        for _loop_, fp in ipairs(fps) do
            local _fp   = fp
            local fname = fp:match("([^/]+)%.[^%.]+$") or fp
            local title = fname
            local ok_ds, ds = pcall(function()
                return require("docsettings"):open(_fp)
            end)
            if ok_ds and ds then
                local meta = ds:readSetting("doc_props") or {}
                title = meta.title or fname
            end
            cover_buttons[#cover_buttons + 1] = {{
                text     = ((overrides[_n] == _fp) and "✓ " or "  ") .. title,
                callback = function()
                    _UIManager:close(ctx_menu._cover_picker)
                    M.saveCoverOverride(_n, _fp); refresh()
                end,
            }}
        end
        cover_buttons[#cover_buttons + 1] = {{
            text     = _lc("Cancel"),
            callback = function() _UIManager:close(ctx_menu._cover_picker) end,
        }}
        ctx_menu._cover_picker = require("ui/widget/buttondialog"):new{
            title   = string.format(_lc("Cover for \"%s\""), _n),
            buttons = cover_buttons,
        }
        _UIManager:show(ctx_menu._cover_picker)
    end

    local items = {}
    items[#items + 1] = {
        text = _lc("Arrange Collections"), keep_menu_open = true, separator = true,
        callback = function()
            local cur_sel = M.getSelected()
            if #cur_sel < 2 then
                _UIManager:show(InfoMessage:new{
                    text = _lc("Select at least 2 collections to arrange."), timeout = 2 })
                return
            end
            local sort_items = {}
            for _loop_, n in ipairs(cur_sel) do
                sort_items[#sort_items + 1] = { text = n, orig_item = n }
            end
            _UIManager:show(SortWidget:new{
                title             = _lc("Arrange Collections"),
                item_table        = sort_items,
                covers_fullscreen = true,
                callback          = function()
                    local new_order = {}
                    for _loop_, item in ipairs(sort_items) do
                        new_order[#new_order + 1] = item.orig_item
                    end
                    M.saveSelected(new_order); refresh()
                end,
            })
        end,
    }

    if #all_colls == 0 then
        items[#items + 1] = { text = _lc("No collections found."), enabled = false }
    else
        for _loop_, coll_name in ipairs(all_colls) do
            local _n = coll_name
            items[#items + 1] = {
                text_func = function()
                    local cur = M.getSelected()
                    for _loop_, n in ipairs(cur) do if n == _n then return _n end end
                    local rem = 4 - #cur
                    if rem <= 0 then return _n .. "  (0 left)" end
                    if rem <= 2 then return _n .. "  (" .. rem .. " left)" end
                    return _n
                end,
                checked_func = function()
                    for _loop_, n in ipairs(M.getSelected()) do
                        if n == _n then return true end
                    end
                    return false
                end,
                keep_menu_open = true,
                callback       = function()
                    local cur     = M.getSelected()
                    local new_sel = {}
                    local found   = false
                    for _loop_, s in ipairs(cur) do
                        if s == _n then found = true else new_sel[#new_sel + 1] = s end
                    end
                    if not found then
                        if #cur >= 5 then
                            _UIManager:show(InfoMessage:new{
                                text = _lc("Maximum 5 collections. Remove one first."), timeout = 2 })
                            return
                        end
                        new_sel[#new_sel + 1] = _n
                    end
                    M.saveSelected(new_sel); refresh()
                end,
                hold_callback = function() openCoverPicker(_n) end,
            }
        end
    end
    return items
end

return M