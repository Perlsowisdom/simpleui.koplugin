-- module_books_shared.lua — Simple UI
-- Helpers partilhados pelos módulos Currently Reading e Recent Books:
-- cover loading, book data, progress bar, prefetch, formatTimeLeft.
-- Não é um módulo — não tem id nem build(). Apenas utilitários partilhados.

local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local Font        = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom        = require("ui/geometry")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen      = Device.screen
local lfs         = require("libs/libkoreader-lfs")
local Config      = require("config")

local SH = {}

-- ---------------------------------------------------------------------------
-- Dimensions (exposed for height calculations in modules)
-- ---------------------------------------------------------------------------
SH.COVER_W  = Screen:scaleBySize(102)
SH.COVER_H  = Screen:scaleBySize(153)
SH.RECENT_W = Screen:scaleBySize(75)
SH.RECENT_H = Screen:scaleBySize(112)

local _RB_GAP1    = Screen:scaleBySize(4)
local _RB_BAR_H   = Screen:scaleBySize(5)
local _RB_GAP2    = Screen:scaleBySize(3)
local _RB_LABEL_H = Screen:scaleBySize(14)
SH.RECENT_CELL_H  = SH.RECENT_H + _RB_GAP1 + _RB_BAR_H + _RB_GAP2 + _RB_LABEL_H

-- Exposed so module_recent.lua can use them directly without recomputing.
SH.RB_GAP1   = _RB_GAP1
SH.RB_BAR_H  = _RB_BAR_H
SH.RB_GAP2   = _RB_GAP2

local _CLR_COVER_BORDER = Blitbuffer.gray(0.45)  -- matches section label text colour
local _CLR_COVER_BG     = Blitbuffer.gray(0.88)
local _CLR_BAR_BG       = Blitbuffer.gray(0.15)
local _CLR_BAR_FG       = Blitbuffer.gray(0.75)

-- ---------------------------------------------------------------------------
-- vspan pool helper
-- ---------------------------------------------------------------------------
function SH.vspan(px, pool)
    if pool then
        if not pool[px] then pool[px] = VerticalSpan:new{ width = px } end
        return pool[px]
    end
    return VerticalSpan:new{ width = px }
end

-- ---------------------------------------------------------------------------
-- progressBar
-- ---------------------------------------------------------------------------
function SH.progressBar(w, pct, bh)
    bh = bh or Screen:scaleBySize(4)
    local fw = math.max(0, math.floor(w * math.min(pct or 0, 1.0)))
    local LineWidget = require("ui/widget/linewidget")
    if fw <= 0 then
        return LineWidget:new{ dimen = Geom:new{ w = w, h = bh }, background = _CLR_BAR_BG }
    end
    local OverlapGroup = require("ui/widget/overlapgroup")
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = bh },
        LineWidget:new{ dimen = Geom:new{ w = w,  h = bh }, background = _CLR_BAR_BG },
        LineWidget:new{ dimen = Geom:new{ w = fw, h = bh }, background = _CLR_BAR_FG },
    }
end

-- ---------------------------------------------------------------------------
-- coverPlaceholder
-- ---------------------------------------------------------------------------
function SH.coverPlaceholder(title, w, h)
    return FrameContainer:new{
        bordersize = 1, color = _CLR_COVER_BORDER,
        background = _CLR_COVER_BG, padding = 0,
        dimen      = Geom:new{ w = w, h = h },
        require("ui/widget/container/centercontainer"):new{
            dimen = Geom:new{ w = w, h = h },
            require("ui/widget/textwidget"):new{
                text = (title or "?"):sub(1, 2):upper(),
                face = Font:getFace("smallinfofont", Screen:scaleBySize(18)),
                bold = true,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- getBookCover
-- ---------------------------------------------------------------------------
function SH.getBookCover(filepath, w, h)
    local bb = Config.getCoverBB(filepath, w, h)
    if not bb then return nil end
    local ok, img = pcall(function()
        return require("ui/widget/imagewidget"):new{
            image        = bb,
            width        = w,
            height       = h,
            -- bb is already scaled to exactly w×h by getCoverBB.
            scale_factor = 1,
        }
    end)
    if not (ok and img) then return nil end
    return FrameContainer:new{
        bordersize = 1, color = _CLR_COVER_BORDER,
        padding    = 0, margin = 0,
        dimen      = Geom:new{ w = w, h = h },
        img,
    }
end

-- ---------------------------------------------------------------------------
-- formatTimeLeft
-- ---------------------------------------------------------------------------
function SH.formatTimeLeft(pct, pages, avg_time)
    if not avg_time or avg_time <= 0 or not pct or pct <= 0 or not pages then return nil end
    local remaining = math.floor(pages * (1.0 - pct))
    if remaining <= 0 then return nil end
    local secs = math.floor(remaining * avg_time)
    if secs <= 0 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%dh %dm", h, m)
    elseif h > 0        then return string.format("%dh", h)
    else                     return string.format("%dm", m) end
end

-- ---------------------------------------------------------------------------
-- getBookData
-- ---------------------------------------------------------------------------
local _DocSettings = nil
local function getDocSettings()
    if not _DocSettings then
        local ok, ds = pcall(require, "docsettings")
        if ok then _DocSettings = ds end
    end
    return _DocSettings
end

function SH.getBookData(filepath, prefetched, shared_conn)
    local meta = {}
    local percent, pages, md5, stat_pages, stat_total_time = 0, nil, nil, nil, nil

    if prefetched then
        percent         = prefetched.percent or 0
        pages           = prefetched.doc_pages
        md5             = prefetched.partial_md5_checksum
        stat_pages      = prefetched.stat_pages
        stat_total_time = prefetched.stat_total_time
        meta.title      = prefetched.title
        meta.authors    = prefetched.authors
    else
        local DS = getDocSettings()
        if DS and lfs.attributes(filepath, "mode") == "file" then
            local ok2, ds = pcall(DS.open, DS, filepath)
            if ok2 and ds then
                percent         = ds:readSetting("percent_finished") or 0
                pages           = ds:readSetting("doc_pages")
                md5             = ds:readSetting("partial_md5_checksum")
                local rp        = ds:readSetting("doc_props") or {}
                local rs        = ds:readSetting("stats") or {}
                meta.title      = rp.title
                meta.authors    = rp.authors
                stat_pages      = rs.pages
                stat_total_time = rs.total_time_in_sec
            end
        end
    end

    if not meta.title then
        meta.title = filepath:match("([^/]+)%.[^%.]+$") or "?"
    end

    local avg_time
    if md5 and shared_conn then
        pcall(function()
            if not shared_conn._stmt_avg then
                shared_conn._stmt_avg = shared_conn:prepare([[
                    SELECT count(DISTINCT page_stat.page), sum(page_stat.duration)
                    FROM   page_stat
                    JOIN   book ON book.id = page_stat.id_book
                    WHERE  book.md5 = ?;
                ]])
            end
            local r  = shared_conn._stmt_avg:reset():bind(md5):step()
            local rp = tonumber(r and r[1]) or 0
            local tt = tonumber(r and r[2]) or 0
            if rp > 0 and tt > 0 then avg_time = tt / rp end
        end)
    end
    if not avg_time and stat_pages and stat_pages > 0
            and stat_total_time and stat_total_time > 0 then
        avg_time = stat_total_time / stat_pages
    end

    return {
        percent  = percent,
        title    = meta.title,
        authors  = meta.authors or "",
        pages    = pages,
        avg_time = avg_time,
    }
end

-- ---------------------------------------------------------------------------
-- prefetchBooks — reads history, pre-extracts book metadata.
-- Called once per Homescreen render; result cached per open instance.
-- ---------------------------------------------------------------------------
-- NOTE: _cover_extraction_pending was removed from SH.
-- Use Config.cover_extraction_pending (the single source of truth) instead.

function SH.prefetchBooks(show_currently, show_recent)
    local state = { current_fp = nil, recent_fps = {}, prefetched_data = {} }
    if not show_currently and not show_recent then return state end

    local ReadHistory = package.loaded["readhistory"] or require("readhistory")
    if not ReadHistory then return state end
    if not ReadHistory.hist or #ReadHistory.hist == 0 then
        pcall(function() ReadHistory:reload() end)
    end

    local DS = getDocSettings()
    for i, entry in ipairs(ReadHistory.hist or {}) do
        local fp = entry.file
        if fp and lfs.attributes(fp, "mode") == "file" then
            if i == 1 and show_currently then
                state.current_fp = fp
                if DS then
                    local ok2, ds = pcall(DS.open, DS, fp)
                    if ok2 and ds then
                        local rp = ds:readSetting("doc_props") or {}
                        local rs = ds:readSetting("stats") or {}
                        state.prefetched_data[fp] = {
                            percent              = ds:readSetting("percent_finished") or 0,
                            title                = rp.title,
                            authors              = rp.authors,
                            doc_pages            = ds:readSetting("doc_pages"),
                            partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                            stat_pages           = rs.pages,
                            stat_total_time      = rs.total_time_in_sec,
                        }
                        pcall(function() ds:close() end)
                    end
                end
            elseif i > 1 and show_recent and #state.recent_fps < 5 then
                local pct = 0
                if DS then
                    local ok2, ds = pcall(DS.open, DS, fp)
                    if ok2 and ds then
                        pct    = ds:readSetting("percent_finished") or 0
                        local rp = ds:readSetting("doc_props") or {}
                        local rs = ds:readSetting("stats") or {}
                        state.prefetched_data[fp] = {
                            percent              = pct,
                            title                = rp.title,
                            authors              = rp.authors,
                            doc_pages            = ds:readSetting("doc_pages"),
                            partial_md5_checksum = ds:readSetting("partial_md5_checksum"),
                            stat_pages           = rs.pages,
                            stat_total_time      = rs.total_time_in_sec,
                        }
                        pcall(function() ds:close() end)
                    end
                end
                if pct < 1.0 then state.recent_fps[#state.recent_fps + 1] = fp end
            end
        end
        if not show_recent and state.current_fp then break end
        if state.current_fp and #state.recent_fps >= 5 then break end
    end
    return state
end

return SH