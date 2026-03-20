-- module_currently.lua — Simple UI
-- Currently Reading module: cover + title + author + progress bar + percentage.

local Device  = require("device")
local Screen  = Device.screen
local _       = require("gettext")
local logger  = require("logger")

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")

local Config       = require("sui_config")
local UI           = require("sui_core")
local PAD          = UI.PAD
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

-- Shared helpers — lazy-loaded.
local _SH = nil
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok and m then _SH = m
        else logger.warn("simpleui: module_currently: cannot load module_books_shared: " .. tostring(m)) end
    end
    return _SH
end

-- Internal spacing — base values at 100% scale; scaled at render time.
local _BASE_COVER_GAP  = Screen:scaleBySize(12)
local _BASE_TITLE_GAP  = Screen:scaleBySize(4)
local _BASE_AUTHOR_GAP = Screen:scaleBySize(8)
local _BASE_BAR_H      = Screen:scaleBySize(7)
local _BASE_BAR_GAP    = Screen:scaleBySize(6)
local _BASE_PCT_GAP    = Screen:scaleBySize(3)
local _BASE_TITLE_FS   = Screen:scaleBySize(12)
local _BASE_AUTHOR_FS  = Screen:scaleBySize(11)
local _BASE_PCT_FS     = Screen:scaleBySize(11)
local _BASE_TL_FS      = Screen:scaleBySize(9)
local _BASE_HL_FS      = Screen:scaleBySize(10)
local _BASE_HL_GAP     = Screen:scaleBySize(8)
local MAX_HL_LINES     = 3   -- max lines per highlight before it is skipped

local _CLR_DARK = Blitbuffer.COLOR_BLACK

local TITLE_MAX_LEN = 60

local function truncateTitle(title)
    if not title then return title end
    if #title > TITLE_MAX_LEN then
        return title:sub(1, TITLE_MAX_LEN) .. "…"
    end
    return title
end


-- ---------------------------------------------------------------------------
-- getRecentHighlights: reads the most recent highlighted-text annotations
-- from a book's doc settings.  Returns up to `limit` entries whose displayed
-- text fits within MAX_HL_LINES lines (longer ones are skipped).
-- ---------------------------------------------------------------------------
local function getRecentHighlights(filepath, limit)
    limit = limit or 3
    local results = {}
    local DS = nil
    local ok_ds, ds_mod = pcall(require, "docsettings")
    if not ok_ds then return results end
    DS = ds_mod
    local lfs_ok, lfs_m = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs_m and lfs_m.attributes(filepath, "mode") ~= "file" then return results end
    local ok2, ds = pcall(DS.open, DS, filepath)
    if not ok2 or not ds then return results end
    local annotations = ds:readSetting("annotations") or {}
    pcall(function() ds:close() end)
    -- Collect only highlighted-text entries in reverse order (most recent first).
    local hl_list = {}
    for _, ann in ipairs(annotations) do
        if ann.highlighted and ann.text and ann.text ~= "" then
            hl_list[#hl_list + 1] = ann.text
        end
    end
    -- Iterate from most recent (end of list).
    for i = #hl_list, 1, -1 do
        if #results >= limit then break end
        results[#results + 1] = hl_list[i]
    end
    return results
end


-- ---------------------------------------------------------------------------
-- Visibility helpers — each element can be toggled independently.
-- Keys stored in G_reader_settings under pfx .. "currently_show_<elem>".
-- Default: all visible (nilOrTrue).
-- ---------------------------------------------------------------------------
local function _showElem(pfx, key)
    return G_reader_settings:nilOrTrue(pfx .. "currently_show_" .. key)
end
local function _toggleElem(pfx, key)
    local cur = G_reader_settings:nilOrTrue(pfx .. "currently_show_" .. key)
    G_reader_settings:saveSetting(pfx .. "currently_show_" .. key, not cur)
end

local M = {}

M.id          = "currently"
M.name        = _("Currently Reading")
M.label       = _("Currently Reading")
M.enabled_key = "currently"
M.default_on  = true

function M.build(w, ctx)
    if not ctx.current_fp then return nil end

    local SH = getSH()
    if not SH then return nil end

    local scale       = Config.getModuleScale("currently", ctx.pfx)
    local thumb_scale = Config.getThumbScale("currently", ctx.pfx)
    local lbl_scale   = Config.getItemLabelScale("currently", ctx.pfx)
    local D           = SH.getDims(scale, thumb_scale)

    -- Scale internal spacing proportionally.
    local cover_gap  = math.max(1, math.floor(_BASE_COVER_GAP  * scale))
    local title_gap  = math.max(1, math.floor(_BASE_TITLE_GAP  * scale))
    local author_gap = math.max(1, math.floor(_BASE_AUTHOR_GAP * scale))
    local bar_h      = math.max(1, math.floor(_BASE_BAR_H      * scale))
    local bar_gap    = math.max(1, math.floor(_BASE_BAR_GAP    * scale))
    local pct_gap    = math.max(1, math.floor(_BASE_PCT_GAP    * scale))
    -- Text sizes apply both module scale and independent text scale.
    local title_fs   = math.max(8, math.floor(_BASE_TITLE_FS   * scale * lbl_scale))
    local author_fs  = math.max(8, math.floor(_BASE_AUTHOR_FS  * scale * lbl_scale))
    local pct_fs     = math.max(8, math.floor(_BASE_PCT_FS     * scale * lbl_scale))
    local tl_fs      = math.max(7, math.floor(_BASE_TL_FS      * scale * lbl_scale))
    local hl_fs      = math.max(7, math.floor(_BASE_HL_FS      * scale * lbl_scale))
    local hl_gap     = math.max(2, math.floor(_BASE_HL_GAP     * scale))

    local bd    = SH.getBookData(ctx.current_fp, ctx.prefetched and ctx.prefetched[ctx.current_fp], ctx.db_conn)
    local cover = SH.getBookCover(ctx.current_fp, D.COVER_W, D.COVER_H)
                  or SH.coverPlaceholder(bd.title, D.COVER_W, D.COVER_H)

    -- Text column width: total minus both side PADs, cover width, and cover gap.
    local tw = w - PAD - D.COVER_W - cover_gap - PAD

    local pfx = ctx.pfx
    local meta = VerticalGroup:new{ align = "left" }

    if _showElem(pfx, "title") then
        meta[#meta+1] = TextBoxWidget:new{
            text       = truncateTitle(bd.title) or "?",
            face       = Font:getFace("smallinfofont", title_fs),
            bold       = true,
            width      = tw,
            max_lines  = 2,
        }
        meta[#meta+1] = VerticalSpan:new{ width = title_gap }
    end

    if _showElem(pfx, "author") and bd.authors and bd.authors ~= "" then
        meta[#meta+1] = TextWidget:new{
            text    = bd.authors,
            face    = Font:getFace("smallinfofont", author_fs),
            fgcolor = CLR_TEXT_SUB,
            width   = tw,
        }
        meta[#meta+1] = VerticalSpan:new{ width = author_gap }
    end

    if _showElem(pfx, "progress") then
        meta[#meta+1] = SH.progressBar(tw, bd.percent, bar_h)
        meta[#meta+1] = VerticalSpan:new{ width = bar_gap }
    end

    if _showElem(pfx, "percent") then
        meta[#meta+1] = TextWidget:new{
            text    = string.format(_("%d%% Read"), math.floor((bd.percent or 0) * 100)),
            face    = Font:getFace("smallinfofont", pct_fs),
            bold    = true,
            fgcolor = _CLR_DARK,
            width   = tw,
        }
    end

    local tl = SH.formatTimeLeft(bd.percent, bd.pages, bd.avg_time)
    if tl then
        meta[#meta+1] = VerticalSpan:new{ width = pct_gap }
        meta[#meta+1] = TextWidget:new{
            text    = string.format(_("%s TO GO"), tl:upper()),
            face    = Font:getFace("smallinfofont", tl_fs),
            fgcolor = CLR_TEXT_SUB,
            width   = tw,
        }
    end

    -- Recent highlights: show up to 3, skip any that need more than MAX_HL_LINES lines.
    local highlights = getRecentHighlights(ctx.current_fp, 3)
    if #highlights > 0 then
        local CLR_HL_BG = Blitbuffer.gray(0.92)
        for _, hl_text in ipairs(highlights) do
            -- Count lines by splitting on newlines and estimating wraps.
            -- We build the widget with max_lines = MAX_HL_LINES; if the text
            -- fits it renders fully, otherwise it is truncated. We detect
            -- overflow by checking charcount vs a rough chars-per-line estimate
            -- so we can skip highlights that are too long.
            local hl_widget = TextBoxWidget:new{
                text      = hl_text,
                face      = Font:getFace("smallinfofont", hl_fs),
                fgcolor   = CLR_TEXT_SUB,
                width     = tw,
                max_lines = MAX_HL_LINES,
            }
            -- getLineCount() is available in modern KOReader TextBoxWidget.
            local line_count = 1
            if type(hl_widget.getLineCount) == "function" then
                line_count = hl_widget:getLineCount()
            elseif hl_widget.lines then
                line_count = #hl_widget.lines
            end
            if line_count <= MAX_HL_LINES then
                local hl_frame = FrameContainer:new{
                    bordersize  = 1,
                    color       = Blitbuffer.gray(0.80),
                    background  = CLR_HL_BG,
                    padding     = math.max(2, math.floor(4 * scale)),
                    padding_top = math.max(2, math.floor(3 * scale)),
                    hl_widget,
                }
                meta[#meta+1] = VerticalSpan:new{ width = hl_gap }
                meta[#meta+1] = hl_frame
            end
        end
    end

    -- HorizontalGroup centres the meta column vertically against the cover.
    local row = HorizontalGroup:new{
        align = "center",
        FrameContainer:new{
            bordersize    = 0, padding = 0,
            padding_right = cover_gap,
            cover,
        },
        meta,
    }

    -- Outer container: horizontal padding only, no vertical padding.
    -- Height is pinned to exactly COVER_H so getHeight() is deterministic.
    local tappable = InputContainer:new{
        dimen    = Geom:new{ w = w, h = D.COVER_H },
        _fp      = ctx.current_fp,
        _open_fn = ctx.open_fn,
        [1] = FrameContainer:new{
            bordersize    = 0,
            padding       = 0,
            padding_left  = PAD,
            padding_right = PAD,
            dimen         = Geom:new{ w = w, h = D.COVER_H },
            row,
        },
    }
    tappable.ges_events = {
        TapBook = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    function tappable:onTapBook()
        if self._open_fn then self._open_fn(self._fp) end
        return true
    end

    return tappable
end

function M.getHeight(_ctx)
    local SH = getSH()
    if not SH then return require("sui_config").getScaledLabelH() end
    local D = SH.getDims(Config.getModuleScale("currently", _ctx and _ctx.pfx),
                         Config.getThumbScale("currently", _ctx and _ctx.pfx))
    return require("sui_config").getScaledLabelH() + D.COVER_H
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("currently", pfx) end,
        set          = function(v) Config.setModuleScale(v, "currently", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end

local function _makeThumbScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Cover size") end,
        separator = true,
        title     = _lc("Cover size"),
        info      = _lc("Scale for the cover thumbnail only.\n100% is the default size."),
        get       = function() return Config.getThumbScalePct("currently", pfx) end,
        set       = function(v) Config.setThumbScale(v, "currently", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

local function _makeTextScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func = function() return _lc("Text Size") end,
        title     = _lc("Text Size"),
        info      = _lc("Scale for all text elements (title, author, progress, time).\n100% is the default size."),
        get       = function() return Config.getItemLabelScalePct("currently", pfx) end,
        set       = function(v) Config.setItemLabelScale(v, "currently", pfx) end,
        refresh   = ctx_menu.refresh,
    })
end

function M.getMenuItems(ctx_menu)
    local pfx     = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._

    local function toggle_item(label, key)
        return {
            text_func    = function() return _lc(label) end,
            checked_func = function() return _showElem(pfx, key) end,
            keep_menu_open = true,
            callback     = function()
                _toggleElem(pfx, key)
                refresh()
            end,
        }
    end

    -- Scale items (no separator between them), then separator before visibility toggles.
    local thumb = _makeThumbScaleItem(ctx_menu)
    thumb.separator = true

    return {
        _makeScaleItem(ctx_menu),
        _makeTextScaleItem(ctx_menu),
        thumb,
        toggle_item("Title",           "title"),
        toggle_item("Author",          "author"),
        toggle_item("Progress bar",    "progress"),
        toggle_item("Percentage read", "percent"),
    }
end

return M