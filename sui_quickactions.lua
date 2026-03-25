-- sui_quickactions.lua — Simple UI
-- Single source of truth for Quick Actions:
--   • Storage: custom QA CRUD, default-action label/icon overrides
--   • Resolution: getEntry(id) — used by both bottombar and module_quick_actions
--   • Menus: icon picker, rename dialog, create/edit/delete flows

local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")
local _         = require("gettext")

local Config    = require("sui_config")

local QA = {}

-- ---------------------------------------------------------------------------
-- Icon directory
-- ---------------------------------------------------------------------------

local _qa_plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
QA.ICONS_DIR = _qa_plugin_dir .. "icons/custom"

-- ---------------------------------------------------------------------------
-- Default-action label / icon overrides
-- ---------------------------------------------------------------------------

local function _defaultLabelKey(id) return "navbar_action_" .. id .. "_label" end
local function _defaultIconKey(id)  return "navbar_action_" .. id .. "_icon"  end

function QA.getDefaultActionLabel(id)
    return G_reader_settings:readSetting(_defaultLabelKey(id))
end

function QA.getDefaultActionIcon(id)
    return G_reader_settings:readSetting(_defaultIconKey(id))
end

function QA.setDefaultActionLabel(id, label)
    if label and label ~= "" then
        G_reader_settings:saveSetting(_defaultLabelKey(id), label)
    else
        G_reader_settings:delSetting(_defaultLabelKey(id))
    end
end

function QA.setDefaultActionIcon(id, icon)
    if icon then
        G_reader_settings:saveSetting(_defaultIconKey(id), icon)
    else
        G_reader_settings:delSetting(_defaultIconKey(id))
    end
end

-- ---------------------------------------------------------------------------
-- getEntry(id) — canonical resolver
-- ---------------------------------------------------------------------------

local _wifi_entry = { icon = "", label = "" }

function QA.getEntry(id)
    if id and id:match("^custom_qa_%d+$") then
        local cfg = G_reader_settings:readSetting("navbar_cqa_" .. id) or {}
        local default_icon
        if cfg.dispatcher_action and cfg.dispatcher_action ~= "" then
            default_icon = Config.CUSTOM_DISPATCHER_ICON
        elseif cfg.plugin_key and cfg.plugin_key ~= "" then
            default_icon = Config.CUSTOM_PLUGIN_ICON
        else
            default_icon = Config.CUSTOM_ICON
        end
        return {
            icon  = cfg.icon or default_icon,
            label = cfg.label or id,
        }
    end

    local a = Config.ACTION_BY_ID[id]
    if not a then
        logger.warn("simpleui: QA.getEntry: unknown id " .. tostring(id))
        return { icon = Config.ICON.library, label = tostring(id) }
    end

    if id == "wifi_toggle" then
        _wifi_entry.icon  = QA.getDefaultActionIcon(id) or Config.wifiIcon()
        _wifi_entry.label = QA.getDefaultActionLabel(id) or a.label
        return _wifi_entry
    end

    local lbl_ov  = QA.getDefaultActionLabel(id)
    local icon_ov = QA.getDefaultActionIcon(id)
    if not lbl_ov and not icon_ov then
        return a
    end
    return {
        icon  = icon_ov  or a.icon,
        label = lbl_ov   or a.label,
    }
end

-- ---------------------------------------------------------------------------
-- Custom QA validity cache
-- ---------------------------------------------------------------------------

local _cqa_valid_cache = nil

function QA.getCustomQAValid()
    if not _cqa_valid_cache then
        local list = Config.getCustomQAList()
        local s = {}
        for _i, id in ipairs(list) do s[id] = true end
        _cqa_valid_cache = s
    end
    return _cqa_valid_cache
end

function QA.invalidateCustomQACache()
    _cqa_valid_cache = nil
end

-- ---------------------------------------------------------------------------
-- Icon picker
-- ---------------------------------------------------------------------------

local function _loadCustomIconList()
    local icons = {}
    local attr  = lfs.attributes(QA.ICONS_DIR)
    if not attr or attr.mode ~= "directory" then return icons end
    for fname in lfs.dir(QA.ICONS_DIR) do
        if fname:match("%.[Ss][Vv][Gg]$") or fname:match("%.[Pp][Nn][Gg]$") then
            local path  = QA.ICONS_DIR .. "/" .. fname
            local label = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
            icons[#icons + 1] = { path = path, label = label }
        end
    end
    table.sort(icons, function(a, b) return a.label:lower() < b.label:lower() end)
    return icons
end

function QA.showIconPicker(current_icon, on_select, default_label, _picker_handle, picker_key)
    _picker_handle = _picker_handle or QA
    picker_key     = picker_key     or "_icon_picker"

    local ButtonDialog = require("ui/widget/buttondialog")
    local icons   = _loadCustomIconList()
    local buttons = {}
    local default_marker = (not current_icon) and "  ✓" or ""
    buttons[#buttons + 1] = {{
        text     = (default_label or _("Default")) .. default_marker,
        callback = function()
            UIManager:close(_picker_handle[picker_key])
            on_select(nil)
        end,
    }}
    if #icons == 0 then
        buttons[#buttons + 1] = {{
            text    = _("No icons found in:") .. "\n" .. QA.ICONS_DIR,
            enabled = false,
        }}
    else
        for _i, icon in ipairs(icons) do
            local p = icon
            buttons[#buttons + 1] = {{
                text     = p.label .. ((current_icon == p.path) and "  ✓" or ""),
                callback = function()
                    UIManager:close(_picker_handle[picker_key])
                    on_select(p.path)
                end,
            }}
        end
    end
    buttons[#buttons + 1] = {{
        text     = _("Cancel"),
        callback = function() UIManager:close(_picker_handle[picker_key]) end,
    }}
    _picker_handle[picker_key] = ButtonDialog:new{ buttons = buttons }
    UIManager:show(_picker_handle[picker_key])
end

-- ---------------------------------------------------------------------------
-- Plugin scanner
--
-- KOReader's plugin loader stores each plugin on the FileManager (and
-- ReaderUI) instance under the plugin's `name` field from _meta.lua.
-- For example: _meta.lua { name = "calibre" } → fm.calibre = instance
--
-- We scan the live FM instance first (most reliable), then supplement with
-- disk-discovered plugins from _meta.lua for anything not yet active.
--
-- IMPORTANT: use fm[key] (normal access), NOT rawget — KOReader may use
-- __index metamethods, and this matches what sui_bottombar.lua does at
-- execution time:  fm and fm.menu_items and fm[cfg.plugin_key]
-- ---------------------------------------------------------------------------

-- Keys to skip — infrastructure or SimpleUI-handled.
local _SKIP_KEYS = {
    simpleui         = true,
    gestures         = true,
    backgroundrunner = true,
    timesync         = true,
    autowarmth       = true,
}

-- Debug flag — enable by uncommenting or setting via plugin menu
local _DEBUG = true

-- Debug logging helper
local function _debug(...)
    if _DEBUG then
        logger.warn("[simpleui:plugin-debug]", ...)
    end
end

-- Dump a table (recursive) for debugging
local function _dumpTable(t, indent, seen)
    if type(t) ~= "table" then return tostring(t) end
    seen = seen or {}
    if seen[t] then return "<circular>" end
    seen[t] = true
    indent = indent or 0
    local lines = {}
    for k, v in pairs(t) do
        local kstr = type(k) == "string" and k or "[" .. tostring(k) .. "]"
        if type(v) == "table" then
            table.insert(lines, string.rep("  ", indent) .. kstr .. " = {")
            table.insert(lines, _dumpTable(v, indent + 1, seen))
            table.insert(lines, string.rep("  ", indent) .. "}")
        else
            table.insert(lines, string.rep("  ", indent) .. kstr .. " = " .. tostring(v))
        end
    end
    return table.concat(lines, "\n")
end

-- Ordered probe list — first match wins.
-- Uses the shared constant from Config to match execution.
local _PROBE_METHODS = Config.PLUGIN_ENTRY_METHODS

local function _probeMethod(inst)
    if type(inst) ~= "table" then return nil end
    for _i, m in ipairs(_PROBE_METHODS) do
        if type(inst[m]) == "function" then return m end
    end
    -- Generic sweep for any remaining onShow*/onOpen*/onLaunch*.
    for k, v in pairs(inst) do
        if type(k) == "string" and type(v) == "function" then
            if k:match("^onShow") or k:match("^onOpen") or k:match("^onLaunch") then
                return k
            end
        end
    end
    return nil
end

-- Read name/fullname from a plugin's _meta.lua.
local function _readPluginMeta(plugin_dir)
    local f = io.open(plugin_dir .. "_meta.lua", "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local function extract(field)
        return content:match(field .. '%s*=%s*"([^"]+)"')
            or content:match('%["' .. field .. '"%]%s*=%s*"([^"]+)"')
    end
    local name = extract("name")
    if not name then return nil end
    return { name = name, fullname = extract("fullname") }
end

-- Sanitize plugin key: remove non-printable characters (fixes garbage bytes in some _meta.lua files)
local function sanitizePluginKey(key)
    if not key then return nil end
    -- Remove all non-printable and space characters
    return key:gsub('[^%w_%-]', ''):gsub(' ', '')
end

-- Locate KOReader's plugins/ directory.
-- This file: <root>/plugins/simpleui.koplugin/sui_quickactions.lua
local function _findPluginsDir()
    -- Walk up from our own path: strip plugin dir to get <root>/plugins/
    local root = _qa_plugin_dir:match("^(.*/)plugins/[^/]+/$")
    if root then return root .. "plugins/" end
    -- DataStorage fallback (works on Android).
    local ok_ds, ds = pcall(require, "datastorage")
    if ok_ds and ds and type(ds.getDataDir) == "function" then
        local d = ds.getDataDir():gsub("/$", "") .. "/plugins/"
        if lfs.attributes(d, "mode") == "directory" then return d end
    end
    return nil
end

local _plugins_dir = nil
local _disk_cache  = nil  -- list of { name, title }

local function _getDiskPlugins()
    if _disk_cache then return _disk_cache end
    if not _plugins_dir then _plugins_dir = _findPluginsDir() end
    local result = {}
    if not _plugins_dir or lfs.attributes(_plugins_dir, "mode") ~= "directory" then
        logger.warn("simpleui: QA: plugins/ dir not found: " .. tostring(_plugins_dir))
        _disk_cache = result
        return result
    end
    for entry in lfs.dir(_plugins_dir) do
        if entry ~= "." and entry ~= ".." and entry ~= "simpleui.koplugin"
                and entry:match("%.koplugin$") then
            local meta = _readPluginMeta(_plugins_dir .. entry .. "/")
            local dirname = entry:gsub("%.koplugin$", "")
            if dirname and not _SKIP_KEYS[dirname] then
                result[#result + 1] = {
                    name  = dirname,
                    title = (meta and meta.fullname) or dirname,
                }
            end
        end
    end
    table.sort(result, function(a, b) return a.title:lower() < b.title:lower() end)
    _disk_cache = result
    return result
end

function QA.invalidatePluginCache()
    _disk_cache   = nil
    _plugins_dir  = nil
end

-- Plugin scanner using KORea
local _debug = logger and function(...) end or function() end

-- Cache for PluginLoader results
local _plugin_cache = nil

-- Methods to probe on plugin instances (ordered by likelihood)
local _PROBE_METHODS = Config.PLUGIN_ENTRY_METHODS

-- Probe an instance for a callable method
local function _probeMethod(inst)
    if type(inst) ~= "table" then return nil end
    for _, m in ipairs(_PROBE_METHODS) do
        if type(inst[m]) == "function" then return m end
    end
    return nil
end

-- Main scanner using PluginLoader
-- Proper plugin scanning using PluginLoader
-- NEW SCANNER - Proper instance-based probing
function _scanAllPlugins()
    local _debug = logger and function(...) end or function() end
    
    _debug("_scanAllPlugins: Starting")
    local results = {}
    local seen = {}

    -- Get properly instantiated plugins from PluginLoader
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if ok_pl and PluginLoader then
        local enabled_plugins = PluginLoader:loadPlugins()
        _debug("_scanAllPlugins: Got", #(enabled_plugins or {}), "enabled plugins")
        
        for _, plug in ipairs(enabled_plugins or {}) do
            -- Get actual instance - this is the key fix!
            local instance = PluginLoader:getPluginInstance(plug.name)
            _debug("_scanAllPlugins: Checking", plug.name, "instance:", instance and "yes" or "no")
            if instance and type(instance) == "table" then
                local method = _probeMethod(instance)
                if method and not seen[plug.name] then
                    seen[plug.name] = true
                    results[#results + 1] = {
                        fm_key = plug.name,
                        fm_method = method,
                        title = plug.fullname or plug.name,
                    }
                    _debug("_scanAllPlugins: Added", plug.name, "via", method)
                end
            end
        end
    end

    -- Also scan FM directly for any missed plugins
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FM and FM.instance then
        local fm = FM.instance
        for key, val in pairs(fm) do
            if type(key) == "string" and type(val) == "table"
                    and not _SKIP_KEYS[key] then
                local inst_name = type(val.name) == "string" and val.name or nil
                if inst_name and not seen[inst_name] then
                    local method = _probeMethod(val)
                    if method then
                        seen[inst_name] = true
                        results[#results + 1] = {
                            fm_key = inst_name,
                            fm_method = method,
                            title = type(val.fullname) == "string" and val.fullname or inst_name,
                        }
                        _debug("_scanAllPlugins: FM direct", key, "->", inst_name, "via", method)
                    end
                end
            end
        end
    end

    table.sort(results, function(a, b) return a.title:lower() < b.title:lower() end)
    _debug("_scanAllPlugins: Returning", #results, "plugins")
    return results
end
