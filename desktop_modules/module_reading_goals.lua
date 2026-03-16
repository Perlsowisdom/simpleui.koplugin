-- module_reading_goals.lua — Simple UI
-- Reading Goals module: annual and daily progress bars with tap-to-set dialogs.
--
-- Compact inline layout (one row per goal):
--   Label  ████████░░░░  XX%  • detail text

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local _               = require("gettext")
local Config          = require("config")

local UI      = require("ui")
local PAD     = UI.PAD
local PAD2    = UI.PAD2
local LABEL_H = UI.LABEL_H

local _CLR_BAR_BG   = Blitbuffer.gray(0.15)
local _CLR_BAR_FG   = Blitbuffer.gray(0.75)
local _CLR_TEXT_LBL = Blitbuffer.COLOR_BLACK
local _CLR_TEXT_PCT = Blitbuffer.COLOR_BLACK
local _CLR_TEXT_SUB = Blitbuffer.gray(0.50)

-- All pixel constants computed once at load time.
local ROW_FS      = Screen:scaleBySize(11)    -- label / pct font size
local SUB_FS      = Screen:scaleBySize(10)    -- detail text font size
local ROW_H       = Screen:scaleBySize(20)    -- height of one compact row
local ROW_GAP     = Screen:scaleBySize(8)     -- gap between annual and daily rows
local BAR_H       = Screen:scaleBySize(7)     -- progress bar thickness
local LBL_W       = Screen:scaleBySize(44)    -- fixed width reserved for the label column
local COL_GAP     = Screen:scaleBySize(8)     -- base gap unit

-- Total module height: LABEL_H already added by _buildContent above each module.
-- This is the height of the rows themselves.
local function _rowsHeight(n)
    return n * ROW_H + (n == 2 and ROW_GAP or 0)
end

-- Year string cached for the session.
local _YEAR_STR = os.date("%Y")

-- Settings keys.
local SHOW_ANNUAL = "navbar_reading_goals_show_annual"
local SHOW_DAILY  = "navbar_reading_goals_show_daily"

local function showAnnual() return G_reader_settings:readSetting(SHOW_ANNUAL) ~= false end
local function showDaily()  return G_reader_settings:readSetting(SHOW_DAILY)  ~= false end

local function getAnnualGoal()     return G_reader_settings:readSetting("navbar_reading_goal") or 0 end
local function getAnnualPhysical() return G_reader_settings:readSetting("navbar_reading_goal_physical") or 0 end
local function getDailyGoalSecs()  return G_reader_settings:readSetting("navbar_daily_reading_goal_secs") or 0 end

local function formatDuration(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0m" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- Stats cache — keyed by calendar date.
local _stats_cache     = nil
local _stats_cache_day = nil

local function invalidateStatsCache()
    _stats_cache     = nil
    _stats_cache_day = nil
end

local function getGoalStats(shared_conn)
    local today_key = os.date("%Y-%m-%d")
    if _stats_cache and _stats_cache_day == today_key then
        return _stats_cache[1], _stats_cache[2], _stats_cache[3]
    end

    local books_read, year_secs, today_secs = 0, 0, 0
    local conn     = shared_conn or Config.openStatsDB()
    if not conn then return books_read, year_secs, today_secs end
    local own_conn = not shared_conn

    pcall(function()
        local t           = os.date("*t")
        local year_start  = os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
        local today_start = os.time() - (t.hour * 3600 + t.min * 60 + t.sec)

        local ry = conn:rowexec(string.format([[
            SELECT sum(s) FROM (
                SELECT sum(duration) AS s FROM page_stat
                WHERE start_time >= %d GROUP BY id_book, page);]], year_start))
        year_secs = tonumber(ry) or 0

        local rt = conn:rowexec(string.format([[
            SELECT sum(s) FROM (
                SELECT sum(duration) AS s FROM page_stat
                WHERE start_time >= %d GROUP BY id_book, page);]], today_start))
        today_secs = tonumber(rt) or 0

        local tb = conn:rowexec([[
            SELECT count(*) FROM book
            WHERE pages > 0
              AND total_read_pages > 0
              AND CAST(total_read_pages AS REAL) / pages >= 0.99]])
        books_read = tonumber(tb) or 0
    end)

    if own_conn then pcall(function() conn:close() end) end

    _stats_cache     = { books_read, year_secs, today_secs }
    _stats_cache_day = today_key
    return books_read, year_secs, today_secs
end

-- ---------------------------------------------------------------------------
-- Compact inline progress bar
-- ---------------------------------------------------------------------------
local function buildProgressBar(w, pct)
    local fw = math.max(0, math.floor(w * math.min(pct, 1.0)))
    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = BAR_H }, background = _CLR_BAR_BG }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = BAR_H },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = BAR_H }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = BAR_H }, background = _CLR_BAR_FG },
    }
end

-- ---------------------------------------------------------------------------
-- Compact single-line goal row
--
--  ┌──────────────────────────────────────────────────────┐
--  │  Label  [═══════════════════░░░░░]  XX%  detail text │
--  └──────────────────────────────────────────────────────┘
--
--  Columns (all vertically centred to ROW_H):
--    1. Label   — fixed LBL_W, bold, left-aligned
--    2. gap     — COL_GAP
--    3. Bar     — fixed BAR_W (~60% of flex)
--    4. gap     — COL_GAP
--    5. Pct     — fixed PCT_W, left-aligned
--    6. gap     — COL_GAP
--    7. Detail  — fills remaining space, left-aligned
-- ---------------------------------------------------------------------------
local function buildGoalRow(inner_w, label_str, pct, pct_str, detail_str, on_tap)
    -- Layout: LBL_W + LBL_BAR_GAP + [bar flex] + BAR_PCT_GAP + PCT_W + PCT_DETAIL_GAP + DETAIL_W
    --
    -- The right block (pct + gap + detail) is sized as a fraction of inner_w
    -- so spacing scales with screen size. The bar fills whatever remains.
    local LBL_BAR_GAP = COL_GAP * 3

    -- Right block: ~28% of inner_w, split as PCT(30%) + gap(15%) + detail(55%).
    local right_w        = math.floor(inner_w * 0.28)
    local PCT_W          = math.floor(right_w * 0.30)
    local PCT_DETAIL_GAP = math.floor(right_w * 0.15)
    local DETAIL_W       = right_w - PCT_W - PCT_DETAIL_GAP

    local BAR_PCT_GAP = COL_GAP
    local bar_w       = math.max(Screen:scaleBySize(40),
                            inner_w - LBL_W - LBL_BAR_GAP - BAR_PCT_GAP - right_w)

    local function vcenter_left(child, col_w)
        local LeftContainer = require("ui/widget/container/leftcontainer")
        return LeftContainer:new{
            dimen = Geom:new{ w = col_w, h = ROW_H },
            child,
        }
    end

    local function vcenter_right(child, col_w)
        local RightContainer = require("ui/widget/container/rightcontainer")
        return RightContainer:new{
            dimen = Geom:new{ w = col_w, h = ROW_H },
            child,
        }
    end

    local lbl_widget = TextWidget:new{
        text    = label_str,
        face    = Font:getFace("smallinfofont", ROW_FS),
        bold    = true,
        fgcolor = _CLR_TEXT_LBL,
        width   = LBL_W,
    }

    local bar_widget = buildProgressBar(bar_w, pct)

    local pct_widget = TextWidget:new{
        text    = pct_str,
        face    = Font:getFace("smallinfofont", ROW_FS),
        bold    = true,
        fgcolor = _CLR_TEXT_PCT,
        width   = PCT_W,
    }

    local detail_widget = TextWidget:new{
        text      = detail_str,
        face      = Font:getFace("cfont", SUB_FS),
        fgcolor   = _CLR_TEXT_SUB,
        width     = DETAIL_W,
        alignment = "right",
    }

    local row = HorizontalGroup:new{
        align = "center",
        vcenter_left(lbl_widget,      LBL_W),
        HorizontalSpan:new{ width = LBL_BAR_GAP },
        vcenter_left(bar_widget,      bar_w),
        HorizontalSpan:new{ width = BAR_PCT_GAP },
        vcenter_left(pct_widget,      PCT_W),
        HorizontalSpan:new{ width = PCT_DETAIL_GAP },
        vcenter_right(detail_widget,  DETAIL_W),
    }

    local frame = FrameContainer:new{
        bordersize = 0, padding = 0,
        dimen      = Geom:new{ w = inner_w, h = ROW_H },
        row,
    }

    if not on_tap then return frame end

    local tappable = InputContainer:new{
        dimen   = Geom:new{ w = inner_w, h = ROW_H },
        [1]     = frame,
        _on_tap = on_tap,
    }
    tappable.ges_events = {
        TapGoal = {
            GestureRange:new{
                ges   = "tap",
                range = function() return tappable.dimen end,
            },
        },
    }
    function tappable:onTapGoal()
        if self._on_tap then self._on_tap() end
        return true
    end
    return tappable
end

-- ---------------------------------------------------------------------------
-- Homescreen refresh helper
-- ---------------------------------------------------------------------------
local function _refreshHS()
    local HS = package.loaded["homescreen"]
    if HS then HS.refresh(false) end
end

-- ---------------------------------------------------------------------------
-- Goal dialogs (unchanged from original)
-- ---------------------------------------------------------------------------
local function showAnnualGoalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text  = _("Annual Reading Goal"),
        info_text   = string.format(_("Books to read in %s:"), _YEAR_STR),
        value       = (function() local g = getAnnualGoal(); return g > 0 and g or 12 end)(),
        value_min   = 0, value_max = 365, value_step = 1,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("navbar_reading_goal", math.floor(spin.value))
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

local function showAnnualPhysicalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text  = string.format(_("Physical Books — %s"), _YEAR_STR),
        info_text   = _("Physical books read this year:"),
        value       = getAnnualPhysical(), value_min = 0, value_max = 365, value_step = 1,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("navbar_reading_goal_physical", math.floor(spin.value))
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

local function showDailySettingsDialog(on_confirm)
    local SpinWidget  = require("ui/widget/spinwidget")
    local cur_secs    = getDailyGoalSecs()
    local cur_minutes = math.floor(cur_secs / 60)
    UIManager:show(SpinWidget:new{
        title_text  = _("Daily Reading Goal"),
        info_text   = _("Minutes per day:"),
        value       = cur_minutes, value_min = 0, value_max = 720, value_step = 5,
        ok_text     = _("Save"), cancel_text = _("Cancel"),
        callback    = function(spin)
            G_reader_settings:saveSetting("navbar_daily_reading_goal_secs",
                math.floor(spin.value) * 60)
            invalidateStatsCache()
            _refreshHS()
            if on_confirm then on_confirm() end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Module API
-- ---------------------------------------------------------------------------
local M = {}

M.id          = "reading_goals"
M.name        = _("Reading Goals")
M.label       = _("Reading Goals")
M.enabled_key = "reading_goals"
M.default_on  = true

M.showAnnualGoalDialog     = showAnnualGoalDialog
M.showAnnualPhysicalDialog = showAnnualPhysicalDialog
M.showDailySettingsDialog  = showDailySettingsDialog
M.invalidateCache          = invalidateStatsCache

function M.build(w, ctx)
    local show_ann = showAnnual()
    local show_day = showDaily()
    if not show_ann and not show_day then return nil end

    local inner_w                           = w - PAD * 2
    local books_read, year_secs, today_secs = getGoalStats(ctx.db_conn)

    local on_annual_tap = function() showAnnualGoalDialog()    end
    local on_daily_tap  = function() showDailySettingsDialog() end

    local rows = VerticalGroup:new{ align = "left" }

    if show_ann then
        local goal    = getAnnualGoal()
        local read    = books_read + getAnnualPhysical()
        local pct     = (goal > 0) and (read / goal) or 0
        local pct_str = string.format("%d%%", math.floor(pct * 100))
        local detail
        if goal > 0 then
            detail = string.format("%d/%d books", read, goal)
        else
            detail = string.format("%d books", read)
        end
        rows[#rows+1] = buildGoalRow(inner_w, _YEAR_STR, pct, pct_str, detail, on_annual_tap)
    end

    if show_ann and show_day then
        rows[#rows+1] = VerticalSpan:new{ width = ROW_GAP }
    end

    if show_day then
        local goal_secs = getDailyGoalSecs()
        local pct       = (goal_secs > 0) and (today_secs / goal_secs) or 0
        local pct_str   = string.format("%d%%", math.floor(pct * 100))
        local detail
        if goal_secs <= 0 then
            detail = formatDuration(today_secs) .. " read"
        else
            detail = string.format("%s/%s",
                formatDuration(today_secs), formatDuration(goal_secs))
        end
        rows[#rows+1] = buildGoalRow(inner_w, _("Today"), pct, pct_str, detail, on_daily_tap)
    end

    return FrameContainer:new{
        bordersize    = 0, padding = 0,
        padding_left  = PAD, padding_right = PAD,
        rows,
    }
end

function M.getHeight(_ctx)
    local n = (showAnnual() and 1 or 0) + (showDaily() and 1 or 0)
    return LABEL_H + _rowsHeight(n)
end

function M.getMenuItems(ctx_menu)
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    return {
        { text         = _lc("Annual Goal"),
          checked_func = function() return showAnnual() end,
          keep_menu_open = true,
          callback = function()
              G_reader_settings:saveSetting(SHOW_ANNUAL, not showAnnual())
              refresh()
          end },
        { text_func = function()
              local g = getAnnualGoal()
              return g > 0
                  and string.format(_lc("  Set Goal  (%d books in %s)"), g, _YEAR_STR)
                  or  string.format(_lc("  Set Goal  (%s)"), _YEAR_STR)
          end,
          keep_menu_open = true,
          callback = function() showAnnualGoalDialog(refresh) end },
        { text_func = function()
              local p = getAnnualPhysical()
              return string.format(_lc("  Physical Books  (%d in %s)"), p, _YEAR_STR)
          end,
          keep_menu_open = true,
          callback = function() showAnnualPhysicalDialog(refresh) end },
        { text         = _lc("Daily Goal"),
          checked_func = function() return showDaily() end,
          keep_menu_open = true,
          callback = function()
              G_reader_settings:saveSetting(SHOW_DAILY, not showDaily())
              refresh()
          end },
        { text_func = function()
              local secs = getDailyGoalSecs()
              local m    = math.floor(secs / 60)
              if secs <= 0 then return _lc("  Set Goal  (disabled)")
              else              return string.format(_lc("  Set Goal  (%d min/day)"), m) end
          end,
          keep_menu_open = true,
          callback = function() showDailySettingsDialog(refresh) end },
    }
end

return M