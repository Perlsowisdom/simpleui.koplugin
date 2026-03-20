-- module_quick_actions.lua — Simple UI
-- Módulo: Quick Actions (3 slots independentes).
-- Substitui quickactionswidget.lua — contém todo o código de widget.
-- Expõe sub_modules = { slot1, slot2, slot3 } para o registry.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local UIManager       = require("ui/uimanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")
local Config          = require("sui_config")
local QA              = require("sui_quickactions")

local UI  = require("sui_core")
local PAD = UI.PAD
local LABEL_H = UI.LABEL_H

local _CLR_BAR_FG = Blitbuffer.gray(0.75)

local _BASE_ICON_SZ   = Screen:scaleBySize(52)
local _BASE_FRAME_PAD = Screen:scaleBySize(18)
local _BASE_CORNER_R  = Screen:scaleBySize(22)
local _BASE_LBL_SP    = Screen:scaleBySize(7)
local _BASE_LBL_H     = Screen:scaleBySize(20)
local _BASE_LBL_FS    = Screen:scaleBySize(9)

local function _getQADims(scale)
    scale = scale or 1.0
    local icon_sz   = math.max(16, math.floor(_BASE_ICON_SZ   * scale))
    local frame_pad = math.max(4,  math.floor(_BASE_FRAME_PAD * scale))
    local lbl_sp    = math.max(1,  math.floor(_BASE_LBL_SP    * scale))
    local lbl_h     = math.max(8,  math.floor(_BASE_LBL_H     * scale))
    return {
        icon_sz   = icon_sz,
        frame_pad = frame_pad,
        frame_sz  = icon_sz + frame_pad * 2,
        corner_r  = math.max(4, math.floor(_BASE_CORNER_R * scale)),
        lbl_sp    = lbl_sp,
        lbl_h     = lbl_h,
        lbl_fs    = math.max(6, math.floor(_BASE_LBL_FS * scale)),
    }
end

-- ---------------------------------------------------------------------------
-- Action entry resolution and QA validity cache
-- Delegated to sui_quickactions (single source of truth).
-- ---------------------------------------------------------------------------

local function getEntry(action_id)
    return QA.getEntry(action_id)
end

local function getCustomQAValid()
    return QA.getCustomQAValid()
end

local function invalidateCustomQACache()
    QA.invalidateCustomQACache()
end

-- ---------------------------------------------------------------------------
-- Core widget builder (shared by all slots)
-- ---------------------------------------------------------------------------
local function buildQAWidget(w, action_ids, show_labels, on_tap_fn, d)
    if not action_ids or #action_ids == 0 then return nil end

    local valid_ids = {}
    local cqa_valid = getCustomQAValid()
    for _, aid in ipairs(action_ids) do
        if aid:match("^custom_qa_%d+$") then
            if cqa_valid[aid] then valid_ids[#valid_ids + 1] = aid end
        else
            valid_ids[#valid_ids + 1] = aid
        end
    end
    if #valid_ids == 0 then return nil end

    local n        = math.min(#valid_ids, 4)
    local inner_w  = w - PAD * 2
    local lbl_h    = show_labels and d.lbl_h or 0
    local lbl_sp   = show_labels and d.lbl_sp or 0
    local gap      = n <= 1 and 0 or math.floor((inner_w - n * d.frame_sz) / (n - 1))
    local left_off = n == 1 and math.floor((inner_w - d.frame_sz) / 2) or 0

    local row = HorizontalGroup:new{ align = "top" }

    for i = 1, n do
        local aid   = valid_ids[i]
        local entry = getEntry(aid)

        local icon_frame = FrameContainer:new{
            bordersize = 1,
            color      = _CLR_BAR_FG,
            background = Blitbuffer.COLOR_WHITE,
            radius     = d.corner_r,
            padding    = d.frame_pad,
            ImageWidget:new{
                file    = entry.icon,
                width   = d.icon_sz,
                height  = d.icon_sz,
                is_icon = true,
                alpha   = true,
            },
        }

        local col = VerticalGroup:new{ align = "center" }
        col[#col + 1] = icon_frame
        if show_labels then
            col[#col + 1] = VerticalSpan:new{ width = lbl_sp }
            col[#col + 1] = CenterContainer:new{
                dimen = Geom:new{ w = d.frame_sz, h = lbl_h },
                TextWidget:new{
                    text    = entry.label,
                    face    = Font:getFace("cfont", d.lbl_fs),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    width   = d.frame_sz,
                },
            }
        end

        local col_h    = d.frame_sz + lbl_sp + lbl_h
        local tappable = InputContainer:new{
            dimen      = Geom:new{ w = d.frame_sz, h = col_h },
            [1]        = col,
            _on_tap_fn = on_tap_fn,
            _action_id = aid,
        }
        tappable.ges_events = {
            TapQA = {
                GestureRange:new{
                    ges   = "tap",
                    range = function() return tappable.dimen end,
                },
            },
        }
        function tappable:onTapQA()
            if self._on_tap_fn then self._on_tap_fn(self._action_id) end
            return true
        end

        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end
        row[#row + 1] = tappable
    end

    return FrameContainer:new{
        bordersize   = 0, padding = 0,
        padding_top  = Config.getScaledLabelH(),
        padding_left = PAD + left_off,
        row,
    }
end

-- ---------------------------------------------------------------------------
-- Slot factory — creates one module descriptor per slot
-- ---------------------------------------------------------------------------
local function makeSlot(slot)
    -- Keys built at call-time using ctx.pfx — works for any page prefix.
    local slot_suffix = "quick_actions_" .. slot

    local S = {}
    S.id         = "quick_actions_" .. slot
    S.name       = string.format(_("Quick Actions %d"), slot)
    S.label      = nil
    S.default_on = false

    function S.isEnabled(pfx)
        return G_reader_settings:readSetting(pfx .. slot_suffix .. "_enabled") == true
    end

    function S.setEnabled(pfx, on)
        G_reader_settings:saveSetting(pfx .. slot_suffix .. "_enabled", on)
    end

    local MAX_QA = 4
    function S.getCountLabel(pfx)
        local n   = #(G_reader_settings:readSetting(pfx .. slot_suffix .. "_items") or {})
        local rem = MAX_QA - n
        if n == 0   then return nil end
        if rem <= 0 then return string.format("(%d/%d — at limit)", n, MAX_QA) end
        return string.format("(%d/%d — %d left)", n, MAX_QA, rem)
    end

    function S.build(w, ctx)
        if not S.isEnabled(ctx.pfx) then return nil end
        local items_key   = ctx.pfx .. slot_suffix .. "_items"
        local labels_key  = ctx.pfx .. slot_suffix .. "_labels"
        local qa_ids      = G_reader_settings:readSetting(items_key) or {}
        local show_labels = G_reader_settings:nilOrTrue(labels_key)
        local d           = _getQADims(Config.getModuleScale(S.id, ctx.pfx))
        -- Apply independent label text scale.
        local lbl_scale = Config.getItemLabelScale(S.id, ctx.pfx)
        d.lbl_fs = math.max(6, math.floor(d.lbl_fs * lbl_scale))
        return buildQAWidget(w, qa_ids, show_labels, ctx.on_qa_tap, d)
    end

    function S.getHeight(ctx)
        local labels_key  = ctx.pfx .. slot_suffix .. "_labels"
        local show_labels = G_reader_settings:nilOrTrue(labels_key)
        local d           = _getQADims(Config.getModuleScale(S.id, ctx.pfx))
        return Config.getScaledLabelH() + (show_labels and (d.frame_sz + d.lbl_sp + d.lbl_h) or d.frame_sz)
    end

    function S.getMenuItems(ctx_menu)
        local pfx     = ctx_menu.pfx
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._
        local items = {}
        -- Scale first, with separator before the QA action items.
        items[#items + 1] = Config.makeScaleItem({
            text_func    = function() return _lc("Scale") end,
            enabled_func = function() return not Config.isScaleLinked() end,
            title        = _lc("Scale"),
            info         = _lc("Scale for this module.\n100% is the default size."),
            get          = function() return Config.getModuleScalePct(S.id, pfx) end,
            set          = function(v) Config.setModuleScale(v, S.id, pfx) end,
            refresh      = refresh,
        })
        items[#items + 1] = Config.makeScaleItem({
            text_func = function() return _lc("Text Size") end,
            separator = true,
            title     = _lc("Text Size"),
            info      = _lc("Scale for the button label text.\n100% is the default size."),
            get       = function() return Config.getItemLabelScalePct(S.id, pfx) end,
            set       = function(v) Config.setItemLabelScale(v, S.id, pfx) end,
            refresh   = refresh,
        })
        if type(ctx_menu.makeQAMenu) == "function" then
            local qa = ctx_menu.makeQAMenu(ctx_menu, slot) or {}
            for _, v in ipairs(qa) do items[#items + 1] = v end
        end
        return items
    end

    return S
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
local M = {}
M.sub_modules = { makeSlot(1), makeSlot(2), makeSlot(3) }

-- Expose base frame size for menu.lua (MAX_QA_ITEMS referenced there).
-- Returns the 100%-scale value; callers that need the current scaled value
-- should call _getQADims(Config.getModuleScale(...)).frame_sz directly.
M.FRAME_SZ             = _BASE_ICON_SZ + _BASE_FRAME_PAD * 2
M.invalidateCustomQACache = QA.invalidateCustomQACache

return M