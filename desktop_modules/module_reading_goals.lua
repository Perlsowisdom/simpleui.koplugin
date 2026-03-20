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
local HorizontalGroup  = require("ui/widget/horizontalgroup")
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
local logger          = require("logger")
local Config          = require("sui_config")

local UI           = require("sui_core")
local PAD          = UI.PAD
local PAD2         = UI.PAD2
local LABEL_H      = UI.LABEL_H
local CLR_TEXT_SUB = UI.CLR_TEXT_SUB

local _CLR_BAR_BG   = Blitbuffer.gray(0.15)
local _CLR_BAR_FG   = Blitbuffer.gray(0.75)
local _CLR_TEXT_LBL = Blitbuffer.COLOR_BLACK
local _CLR_TEXT_PCT = Blitbuffer.COLOR_BLACK

-- Base pixel constants at 100% scale — multiplied at render time.
local _BASE_ROW_FS  = Screen:scaleBySize(11)
local _BASE_SUB_FS  = Screen:scaleBySize(10)
local _BASE_ROW_H   = Screen:scaleBySize(16)
local _BASE_SUB_H   = Screen:scaleBySize(16)
local _BASE_SUB_GAP = Screen:scaleBySize(2)
local _BASE_ROW_GAP = Screen:scaleBySize(18)
local _BASE_BAR_H   = Screen:scaleBySize(7)
local _BASE_LBL_W   = Screen:scaleBySize(44)
local _BASE_COL_GAP = Screen:scaleBySize(8)
local _BASE_BOT_PAD = Screen:scaleBySize(18)

-- Year string — refreshed each call so it's always correct even across a year
-- boundary in a long-running session. Cheap: os.date is a single C call.
local function _getYearStr() return os.date("%Y") end

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

-- ---------------------------------------------------------------------------
-- Count books the user explicitly marked as read (summary.status == "complete")
-- by scanning the KOReader history sidecar directory.
--
-- Strategy: read each sidecar as raw text and pattern-match the two keys we
-- need. This is much cheaper than dofile() on every sidecar (no Lua parse,
-- no table allocation per file). Sidecar files are small (~2–5 KB) and the
-- LuaSettings serialiser writes keys as `key = "value"`, so the patterns are
-- stable across KOReader versions.
-- ---------------------------------------------------------------------------
local _stats_cache     = nil
local _stats_cache_day = nil

local function invalidateStatsCache()
    _stats_cache     = nil
    _stats_cache_day = nil
end

-- Iterates ReadHistory and checks each book's sidecar for status="complete".
-- year_str: "2026" to restrict to this year, or nil for all-time.
-- Reads only the ["summary"] block from the sidecar — skips annotations,
-- highlights and other large data that appears before it alphabetically.
-- Result is cached per calendar day so this runs at most once per day.
local function _countMarkedRead(year_str)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return 0 end
    local ok_DS, DocSettings = pcall(require, "docsettings")
    if not ok_DS then return 0 end

    local ReadHistory = package.loaded["readhistory"]
    if not ReadHistory or not ReadHistory.hist then return 0 end

    local year_pfx = year_str and ('["modified"] = "' .. year_str) or nil
    local count = 0

    for _, entry in ipairs(ReadHistory.hist) do
        local fp = entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            local sidecar = DocSettings:findSidecarFile(fp)
            if sidecar then
                local f = io.open(sidecar, "r")
                if f then
                    -- Extract only the ["summary"] = { ... } block.
                    -- dump() writes keys in alphabetical order so summary always
                    -- appears after potentially large keys (annotations, highlight).
                    -- We find the block start then read lines until the closing '}'.
                    local in_summary = false
                    local found_status, found_year = false, not year_pfx
                    for line in f:lines() do
                        if not in_summary then
                            if line:find('["summary"]', 1, true) then
                                in_summary = true
                            end
                        else
                            if line:find('"complete"', 1, true)
                               and line:find('"status"', 1, true) then
                                found_status = true
                            end
                            if year_pfx and line:find(year_pfx, 1, true) then
                                found_year = true
                            end
                            -- Summary block ends at the closing brace line
                            if line:find("^%s*},?%s*$") then break end
                        end
                    end
                    f:close()
                    if found_status and found_year then count = count + 1 end
                end
            end
        end
    end
    return count
end

local function getGoalStats(shared_conn)
    local today_key = os.date("%Y-%m-%d")
    if _stats_cache and _stats_cache_day == today_key then
        return _stats_cache[1], _stats_cache[2], _stats_cache[3]
    end

    local year_secs, today_secs = 0, 0
    local conn     = shared_conn or Config.openStatsDB()
    if conn then
        local own_conn = not shared_conn
        local ok, err = pcall(function()
            local t           = os.date("*t")
            local year_start  = os.time{ year = t.year, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
            local today_start = os.time() - (t.hour * 3600 + t.min * 60 + t.sec)

            -- Two independent subqueries in a single SELECT — avoids two round-trips
            -- while keeping start_time accessible inside each WHERE clause.
            -- The CASE approach failed because start_time is not projected by the
            -- inner GROUP BY, making it invisible to the outer CASE expression.
            local stmt = conn:prepare([[
                SELECT
                    (SELECT sum(s) FROM (
                        SELECT sum(duration) AS s FROM page_stat
                        WHERE start_time >= ? GROUP BY id_book, page)),
                    (SELECT sum(s) FROM (
                        SELECT sum(duration) AS s FROM page_stat
                        WHERE start_time >= ? GROUP BY id_book, page));]])
            if stmt then
                local row = stmt:bind(year_start, today_start):step()
                year_secs  = tonumber(row and row[1]) or 0
                today_secs = tonumber(row and row[2]) or 0
                stmt:reset()
            end
        end)
        if not ok then logger.warn("simpleui: reading_goals: getGoalStats failed: " .. tostring(err)) end
        if own_conn then pcall(function() conn:close() end) end
    end

    -- Count books the user explicitly marked as read this year via the sidecar
    -- status field ("complete"). This respects the user's intent instead of
    -- guessing from page coverage in the stats DB.
    local books_read = _countMarkedRead(os.date("%Y"))

    _stats_cache     = { books_read, year_secs, today_secs }
    _stats_cache_day = today_key
    return books_read, year_secs, today_secs
end

-- ---------------------------------------------------------------------------
-- _scaledDims(scale) — all layout metrics for one render pass.
-- Used by both build() and getHeight() so the two never drift apart.
-- Fonts are resolved here once and stored in d.face_row / d.face_sub so
-- buildGoalRow never calls Font:getFace more than once per render.
-- ---------------------------------------------------------------------------
local function _scaledDims(scale)
    scale = scale or 1.0
    local row_h   = math.max(8,  math.floor(_BASE_ROW_H   * scale))
    local sub_h   = math.max(8,  math.floor(_BASE_SUB_H   * scale))
    local sub_gap = math.max(1,  math.floor(_BASE_SUB_GAP * scale))
    local bot_pad = math.max(4,  math.floor(_BASE_BOT_PAD * scale))
    local row_fs  = math.max(7,  math.floor(_BASE_ROW_FS  * scale))
    local sub_fs  = math.max(6,  math.floor(_BASE_SUB_FS  * scale))
    return {
        row_fs     = row_fs,
        sub_fs     = sub_fs,
        face_row   = Font:getFace("smallinfofont", row_fs),
        face_sub   = Font:getFace("cfont",         sub_fs),
        row_h      = row_h,
        sub_h      = sub_h,
        sub_gap    = sub_gap,
        row_gap    = math.max(4,  math.floor(_BASE_ROW_GAP * scale)),
        bar_h      = math.max(1,  math.floor(_BASE_BAR_H   * scale)),
        lbl_w      = math.max(20, math.floor(_BASE_LBL_W   * scale)),
        col_gap    = math.max(2,  math.floor(_BASE_COL_GAP * scale)),
        bot_pad    = bot_pad,
        pct_w      = math.max(16, math.floor(Screen:scaleBySize(32) * scale)),
        min_bar_w  = math.max(20, math.floor(Screen:scaleBySize(40) * scale)),
        goal_row_h = row_h + sub_gap + sub_h + bot_pad,
    }
end
local function buildProgressBar(w, pct, bar_h)
    local fw = math.max(0, math.floor(w * math.min(pct, 1.0)))
    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = bar_h }, background = _CLR_BAR_BG }
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bar_h },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bar_h }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bar_h }, background = _CLR_BAR_FG },
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
local function buildGoalRow(inner_w, label_str, pct, pct_str, detail_str, on_tap, d)
    -- d: scaled dims table computed once per M.build() call.
    -- d.face_row and d.face_sub are pre-resolved by _scaledDims — no Font:getFace here.
    local PCT_W       = d.pct_w
    local BAR_PCT_GAP = d.col_gap
    local bar_w       = math.max(d.min_bar_w,
                            inner_w - d.lbl_w - d.col_gap - BAR_PCT_GAP - PCT_W)

    local lbl_widget = TextWidget:new{
        text    = label_str,
        face    = d.face_row,
        bold    = true,
        fgcolor = _CLR_TEXT_LBL,
        width   = d.lbl_w,
    }

    local bar_widget = buildProgressBar(bar_w, pct, d.bar_h)

    local pct_widget = TextWidget:new{
        text      = pct_str,
        face      = d.face_row,
        bold      = false,
        fgcolor   = _CLR_TEXT_PCT,
        width     = PCT_W,
        alignment = "right",
    }

    local top_row = HorizontalGroup:new{
        align = "center",
        lbl_widget,
        HorizontalSpan:new{ width = d.col_gap },
        bar_widget,
        HorizontalSpan:new{ width = BAR_PCT_GAP },
        pct_widget,
    }

    local detail_widget = TextWidget:new{
        text    = detail_str,
        face    = d.face_sub,
        fgcolor = CLR_TEXT_SUB,
        width   = inner_w,
    }

    local block = VerticalGroup:new{
        align = "left",
        top_row,
        VerticalSpan:new{ width = d.sub_gap },
        detail_widget,
    }

    local frame = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_bottom = d.bot_pad,
        block,
    }

    if not on_tap then return frame end

    local tappable = InputContainer:new{
        dimen   = Geom:new{ w = inner_w, h = d.goal_row_h },
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
    local HS = package.loaded["sui_homescreen"]
    if HS then HS.refresh(false) end
end

-- ---------------------------------------------------------------------------
-- Goal dialogs (unchanged from original)
-- ---------------------------------------------------------------------------
local function showAnnualGoalDialog(on_confirm)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text  = _("Annual Reading Goal"),
        info_text   = string.format(_("Books to read in %s:"), _getYearStr()),
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
        title_text  = string.format(_("Physical Books — %s"), _getYearStr()),
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

-- Called by teardown to drop the per-day stats cache so a hot update or
-- a midnight rollover does not carry stale data into the next session.
function M.reset() invalidateStatsCache() end

function M.build(w, ctx)
    local show_ann = showAnnual()
    local show_day = showDaily()
    if not show_ann and not show_day then return nil end

    local scale   = Config.getModuleScale("reading_goals", ctx.pfx)
    local d       = _scaledDims(scale)
    local inner_w = w - PAD * 2
    local books_read, year_secs, today_secs = getGoalStats(ctx.db_conn)

    local rows = VerticalGroup:new{ align = "left" }

    if show_ann then
        local goal     = getAnnualGoal()
        local read     = books_read + getAnnualPhysical()
        local pct, pct_str
        if goal > 0 then
            pct     = read / goal
            pct_str = string.format("%d%%", math.floor(pct * 100))
        else
            -- No annual goal set: full bar for visual weight, count in detail.
            pct     = 1.0
            pct_str = ""
        end
        logger.dbg("simpleui reading_goals: annual bar — goal=", goal,
            "books_read=", books_read, "physical=", getAnnualPhysical(),
            "read=", read, "pct=", pct, "pct_str=", pct_str)
        local detail
        if goal > 0 then
            detail = string.format(_("%d/%d books"), read, goal)
        else
            detail = string.format(_("%d books"), read)
        end
        local on_tap = function() showAnnualGoalDialog() end
        rows[#rows+1] = buildGoalRow(inner_w, _getYearStr(), pct, pct_str, detail, on_tap, d)
    end

    if show_ann and show_day then
        rows[#rows+1] = VerticalSpan:new{ width = d.row_gap }
    end

    if show_day then
        local goal_secs = getDailyGoalSecs()
        local pct, pct_str
        if goal_secs > 0 then
            -- Normal case: show progress towards the goal.
            pct     = today_secs / goal_secs
            pct_str = string.format("%d%%", math.floor(pct * 100))
        else
            -- No daily goal set: show a full bar so the row has visual weight,
            -- and omit the percentage — the detail line carries the real info.
            pct     = 1.0
            pct_str = ""
        end
        local detail
        if goal_secs <= 0 then
            detail = string.format(_("%s read"), formatDuration(today_secs))
        else
            detail = string.format("%s/%s",
                formatDuration(today_secs), formatDuration(goal_secs))
        end
        -- Closure allocated only when the row is actually shown.
        local on_tap = function() showDailySettingsDialog() end
        rows[#rows+1] = buildGoalRow(inner_w, _("Today"), pct, pct_str, detail, on_tap, d)
    end

    return FrameContainer:new{
        bordersize    = 0, padding = 0,
        padding_left  = PAD, padding_right = PAD,
        rows,
    }
end

function M.getHeight(_ctx)
    local n = (showAnnual() and 1 or 0) + (showDaily() and 1 or 0)
    if n == 0 then return 0 end
    local d = _scaledDims(Config.getModuleScale("reading_goals", _ctx and _ctx.pfx))
    return require("sui_config").getScaledLabelH() + n * d.goal_row_h + (n == 2 and d.row_gap or 0)
end


local function _makeScaleItem(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return Config.makeScaleItem({
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Scale for this module.\n100% is the default size."),
        get          = function() return Config.getModuleScalePct("reading_goals", pfx) end,
        set          = function(v) Config.setModuleScale(v, "reading_goals", pfx) end,
        refresh      = ctx_menu.refresh,
    })
end
function M.getMenuItems(ctx_menu)
    local refresh = ctx_menu.refresh
    local _lc     = ctx_menu._
    local scale_item = _makeScaleItem(ctx_menu)
    scale_item.separator = true
    return {
        scale_item,
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
                  and string.format(_lc("  Set Goal  (%d books in %s)"), g, _getYearStr())
                  or  string.format(_lc("  Set Goal  (%s)"), _getYearStr())
          end,
          keep_menu_open = true,
          callback = function() showAnnualGoalDialog(refresh) end },
        { text_func = function()
              local p = getAnnualPhysical()
              return string.format(_lc("  Physical Books  (%d in %s)"), p, _getYearStr())
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