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
local function _scanAllPlugins()
    -- Get live FM instance
    local fm = nil
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FM then fm = FM.instance end

    if not fm then
        _debug("_scanAllPlugins: FM not available")
        return {}
    end

    _debug("_scanAllPlugins: FM found, scanning for plugins")

    local results = {}
    local seen = {}

    -- Scan FM instance for plugin-like objects
    -- Plugins extend WidgetContainer and have a `name` property
    for key, val in pairs(fm) do
        if type(key) == "string" and type(val) == "table" then
            local pname = val.name
            if pname and type(pname) == "string" and not _SKIP_KEYS[pname] and not seen[pname] then
                local method = _probeMethod(val)
                if method then
                    seen[pname] = true
                    results[#results + 1] = {
                        fm_key = key,
                        fm_method = method,
                        title = val.fullname or pname,
                    }
                    _debug("_scanAllPlugins: FM instance found:", pname, "key:", key, "method:", method)
                end
            end
        end
    end

    table.sort(results, function(a, b) return a.title:lower() < b.title:lower() end)
    _debug("_scanAllPlugins: Returning", #results, "plugins")

    return results
end


local function _scanDispatcherActions()
    local ok_d, Dispatcher = pcall(require, "dispatcher")
    if not ok_d or not Dispatcher then return {} end
    pcall(function() Dispatcher:init() end)

    local settingsList, dispatcher_menu_order

    if type(Dispatcher.registerAction) == "function" then
        pcall(function()
            local i = 1
            while true do
                local name, val = debug.getupvalue(Dispatcher.registerAction, i)
                if not name then break end
                if name == "settingsList"          then settingsList          = val end
                if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
                i = i + 1
            end
        end)
    end

    if type(settingsList) ~= "table" then
        settingsList = rawget(Dispatcher, "settingsList")
                   or rawget(Dispatcher, "settings_list")
    end
    if type(settingsList) ~= "table" then return {} end

    local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
        or (function()
            local t = {}
            for k in pairs(settingsList) do t[#t+1] = k end
            table.sort(t)
            return t
        end)()

    local results = {}
    for _i, action_id in ipairs(order) do
        local def = settingsList[action_id]
        if type(def) == "table" and def.title and def.category == "none"
                and (def.condition == nil or def.condition == true) then
            results[#results + 1] = { id = action_id, title = tostring(def.title) }
        end
    end
    table.sort(results, function(a, b) return a.title:lower() < b.title:lower() end)
    return results
end

-- ---------------------------------------------------------------------------
-- Create / Edit dialog
-- ---------------------------------------------------------------------------

function QA.showQuickActionDialog(plugin, qa_id, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local PathChooser      = require("ui/widget/pathchooser")
    local InfoMessage      = require("ui/widget/infomessage")
    local ButtonDialog     = require("ui/widget/buttondialog")

    local getNonFavColl = Config.getNonFavoritesCollections
    local collections   = getNonFavColl and getNonFavColl() or {}
    table.sort(collections, function(a, b) return a:lower() < b:lower() end)

    local cfg         = qa_id and Config.getCustomQAConfig(qa_id) or {}
    local start_path  = cfg.path or G_reader_settings:readSetting("home_dir") or "/"
    local chosen_icon = cfg.icon
    local dlg_title   = qa_id and _("Edit Quick Action") or _("New Quick Action")
    local TOTAL_H     = require("sui_bottombar").TOTAL_H

    local function iconButtonLabel(default_lbl)
        if not chosen_icon then return default_lbl or _("Icon: Default") end
        local fname = chosen_icon:match("([^/]+)$") or chosen_icon
        local stem  = (fname:match("^(.+)%.[^%.]+$") or fname):gsub("_", " ")
        return _("Icon") .. ": " .. stem
    end

    local function commitQA(final_label, path, coll, default_icon, fm_key, fm_method, dispatcher_action)
        local final_id = qa_id or Config.nextCustomQAId()
        if not qa_id then
            local list = Config.getCustomQAList()
            list[#list + 1] = final_id
            Config.saveCustomQAList(list)
        end
        Config.saveCustomQAConfig(final_id, final_label, path, coll,
            chosen_icon or default_icon, fm_key, fm_method, dispatcher_action)
        QA.invalidateCustomQACache()
        plugin:_rebuildAllNavbars()
        if on_done then on_done() end
    end

    local active_dialog = nil

    local function _buildSaveDialog(spec)
        if active_dialog then UIManager:close(active_dialog); active_dialog = nil end

        local function openIconPicker()
            if active_dialog then UIManager:close(active_dialog); active_dialog = nil end
            QA.showIconPicker(chosen_icon, function(new_icon)
                chosen_icon = new_icon
                _buildSaveDialog(spec)
            end, spec.icon_default_label, plugin, "_qa_icon_picker")
        end

        local fields = {}
        for _i, f in ipairs(spec.fields) do
            fields[#fields + 1] = { description = f.description, text = f.text or "", hint = f.hint }
        end

        active_dialog = MultiInputDialog:new{
            title  = dlg_title,
            fields = fields,
            buttons = {
                { { text = iconButtonLabel(spec.icon_default_label),
                    callback = function() openIconPicker() end } },
                { { text = _("Cancel"),
                    callback = function() UIManager:close(active_dialog); active_dialog = nil end },
                  { text = _("Save"), is_enter_default = true,
                    callback = function()
                        local inputs = active_dialog:getFields()
                        if spec.validate then
                            local err = spec.validate(inputs)
                            if err then
                                UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
                                return
                            end
                        end
                        UIManager:close(active_dialog); active_dialog = nil
                        spec.on_save(inputs)
                    end } },
            },
        }
        UIManager:show(active_dialog)
        pcall(function() active_dialog:onShowKeyboard() end)
    end

    local sanitize = Config.sanitizeLabel

    local function openPathChooser()
        UIManager:show(PathChooser:new{
            select_directory = true, select_file = false, show_files = false,
            path = start_path, covers_fullscreen = true,
            height = Screen:getHeight() - TOTAL_H(),
            onConfirm = function(chosen_path)
                _buildSaveDialog({
                    fields = {
                        { description = _("Name"),
                          text = cfg.label or (chosen_path:match("([^/]+)$") or ""),
                          hint = _("e.g. Books…") },
                        { description = _("Folder"), text = chosen_path, hint = "/path/to/folder" },
                    },
                    icon_default_label = _("Default (Folder)"),
                    validate = function(inputs)
                        local p = inputs[2] ~= "" and inputs[2] or chosen_path
                        local attr = lfs.attributes(p)
                        if not attr then return string.format(_("Folder not found:\n%s"), p) end
                        if attr.mode ~= "directory" then return string.format(_("Path is not a folder:\n%s"), p) end
                    end,
                    on_save = function(inputs)
                        local new_path = inputs[2] ~= "" and inputs[2] or chosen_path
                        commitQA(sanitize(inputs[1]) or (new_path:match("([^/]+)$") or "?"),
                            new_path, nil, Config.CUSTOM_ICON)
                    end,
                })
            end,
        })
    end

    local function openCollectionPicker()
        local buttons = {}
        for _i, coll_name in ipairs(collections) do
            local name = coll_name
            buttons[#buttons + 1] = {{ text = name, callback = function()
                UIManager:close(plugin._qa_coll_picker)
                _buildSaveDialog({
                    fields = { { description = _("Name"), text = cfg.label or name, hint = _("e.g. Sci-Fi…") } },
                    icon_default_label = _("Default (Folder)"),
                    on_save = function(inputs)
                        commitQA(sanitize(inputs[1]) or name, nil, name, Config.CUSTOM_ICON)
                    end,
                })
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_coll_picker) end }}
        plugin._qa_coll_picker = ButtonDialog:new{ buttons = buttons }
        UIManager:show(plugin._qa_coll_picker)
    end

    local function openPluginPicker()
        local plugin_actions = _scanAllPlugins()
        if #plugin_actions == 0 then
            UIManager:show(InfoMessage:new{ text = _("No plugins found."), timeout = 3 })
            return
        end
        local buttons = {}
        for _i, a in ipairs(plugin_actions) do
            local _a = a
            local label = _a._inactive
                and (_a.title .. "  (" .. _("restart required") .. ")")
                or  _a.title
            buttons[#buttons + 1] = {{ text = label, callback = function()
                UIManager:close(plugin._qa_plugin_picker)
                _buildSaveDialog({
                    fields = { { description = _("Name"), text = cfg.label or _a.title, hint = _("e.g. Rakuyomi…") } },
                    icon_default_label = _("Default (Plugin)"),
                    on_save = function(inputs)
                        commitQA(sanitize(inputs[1]) or _a.title,
                            nil, nil, Config.CUSTOM_PLUGIN_ICON, _a.fm_key, _a.fm_method, nil)
                    end,
                })
            end }}
        end
        buttons[#buttons + 1] = {{
            text     = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_plugin_picker) end,
        }}
        plugin._qa_plugin_picker = ButtonDialog:new{ buttons = buttons }
        UIManager:show(plugin._qa_plugin_picker)
    end

    local function openDispatcherPicker()
        local actions = _scanDispatcherActions()
        if #actions == 0 then
            UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 })
            return
        end
        local buttons = {}
        for _i, a in ipairs(actions) do
            local _a = a
            buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                UIManager:close(plugin._qa_dispatcher_picker)
                _buildSaveDialog({
                    fields = { { description = _("Name"), text = cfg.label or _a.title, hint = _("e.g. Sleep, Refresh…") } },
                    icon_default_label = _("Default (System)"),
                    on_save = function(inputs)
                        commitQA(sanitize(inputs[1]) or _a.title,
                            nil, nil, Config.CUSTOM_DISPATCHER_ICON, nil, nil, _a.id)
                    end,
                })
            end }}
        end
        buttons[#buttons + 1] = {{ text = _("Cancel"),
            callback = function() UIManager:close(plugin._qa_dispatcher_picker) end }}
        plugin._qa_dispatcher_picker = ButtonDialog:new{ buttons = buttons }
        UIManager:show(plugin._qa_dispatcher_picker)
    end

    local choice_dialog
    choice_dialog = ButtonDialog:new{ buttons = {
        {{ text = _("Collection"), enabled = #collections > 0,
           callback = function() UIManager:close(choice_dialog); openCollectionPicker() end }},
        {{ text = _("Folder"),
           callback = function() UIManager:close(choice_dialog); openPathChooser() end }},
        {{ text = _("Plugin"),
           callback = function() UIManager:close(choice_dialog); openPluginPicker() end }},
        {{ text = _("System Actions"),
           callback = function() UIManager:close(choice_dialog); openDispatcherPicker() end }},
        {{ text = _("Cancel"),
           callback = function() UIManager:close(choice_dialog) end }},
    }}
    UIManager:show(choice_dialog)
end

-- ---------------------------------------------------------------------------
-- makeMenuItems(plugin) — returns the items table for the Quick Actions menu
-- ---------------------------------------------------------------------------

function QA.makeMenuItems(plugin)
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox  = require("ui/widget/confirmbox")
    local InputDialog = require("ui/widget/inputdialog")

    local MAX_CUSTOM_QA = Config.MAX_CUSTOM_QA

    local function allActions()
        local pool = {}
        for _i, a in ipairs(Config.ALL_ACTIONS) do
            pool[#pool + 1] = { id = a.id, is_default = true }
        end
        for _i, qa_id in ipairs(Config.getCustomQAList()) do
            pool[#pool + 1] = { id = qa_id, is_default = false }
        end
        table.sort(pool, function(a, b)
            return QA.getEntry(a.id).label:lower() < QA.getEntry(b.id).label:lower()
        end)
        return pool
    end

    local function makeChangeIconsMenu()
        local items = {}
        for _i, entry in ipairs(allActions()) do
            local _id         = entry.id
            local _is_default = entry.is_default
            items[#items + 1] = {
                text_func = function()
                    local lbl        = QA.getEntry(_id).label
                    local has_custom = _is_default
                        and QA.getDefaultActionIcon(_id) ~= nil
                        or (not _is_default and (function()
                                local c = Config.getCustomQAConfig(_id)
                                return c.icon ~= nil
                                    and c.icon ~= Config.CUSTOM_ICON
                                    and c.icon ~= Config.CUSTOM_PLUGIN_ICON
                                    and c.icon ~= Config.CUSTOM_DISPATCHER_ICON
                            end)())
                    return lbl .. (has_custom and "  ✎" or "")
                end,
                callback = function()
                    local current_icon
                    if _is_default then
                        current_icon = QA.getDefaultActionIcon(_id)
                    else
                        current_icon = Config.getCustomQAConfig(_id).icon
                    end
                    local default_label = QA.getEntry(_id).label .. " (" .. _("default") .. ")"
                    QA.showIconPicker(current_icon, function(new_icon)
                        if _is_default then
                            QA.setDefaultActionIcon(_id, new_icon)
                        else
                            local c = Config.getCustomQAConfig(_id)
                            local type_default
                            if c.dispatcher_action and c.dispatcher_action ~= "" then
                                type_default = Config.CUSTOM_DISPATCHER_ICON
                            elseif c.plugin_key and c.plugin_key ~= "" then
                                type_default = Config.CUSTOM_PLUGIN_ICON
                            else
                                type_default = Config.CUSTOM_ICON
                            end
                            Config.saveCustomQAConfig(_id, c.label, c.path, c.collection,
                                new_icon or type_default,
                                c.plugin_key, c.plugin_method, c.dispatcher_action)
                        end
                        QA.invalidateCustomQACache()
                        plugin:_rebuildAllNavbars()
                    end, default_label, plugin, "_qa_icon_picker")
                end,
            }
        end
        return items
    end

    local function makeRenameMenu()
        local items = {}
        for _i, entry in ipairs(allActions()) do
            local _id         = entry.id
            local _is_default = entry.is_default
            items[#items + 1] = {
                text_func = function()
                    local lbl        = QA.getEntry(_id).label
                    local has_custom = _is_default and QA.getDefaultActionLabel(_id) ~= nil
                    return lbl .. (has_custom and "  ✎" or "")
                end,
                callback = function()
                    local current_label = QA.getEntry(_id).label
                    local dlg
                    dlg = InputDialog:new{
                        title      = _("Rename"),
                        input      = current_label,
                        input_hint = _("New name…"),
                        buttons = {{
                            { text = _("Cancel"),
                              callback = function() UIManager:close(dlg) end },
                            { text         = _("Reset"),
                              enabled_func = function()
                                  return _is_default and QA.getDefaultActionLabel(_id) ~= nil
                              end,
                              callback = function()
                                  UIManager:close(dlg)
                                  QA.setDefaultActionLabel(_id, nil)
                                  plugin:_rebuildAllNavbars()
                              end },
                            { text             = _("Save"),
                              is_enter_default = true,
                              callback = function()
                                  local new_name = Config.sanitizeLabel(dlg:getInputText())
                                  UIManager:close(dlg)
                                  if not new_name then return end
                                  if _is_default then
                                      QA.setDefaultActionLabel(_id, new_name)
                                  else
                                      local c = Config.getCustomQAConfig(_id)
                                      Config.saveCustomQAConfig(_id, new_name,
                                          c.path, c.collection, c.icon,
                                          c.plugin_key, c.plugin_method, c.dispatcher_action)
                                      Config.invalidateTabsCache()
                                  end
                                  QA.invalidateCustomQACache()
                                  plugin:_rebuildAllNavbars()
                              end },
                        }},
                    }
                    UIManager:show(dlg)
                    pcall(function() dlg:onShowKeyboard() end)
                end,
            }
        end
        return items
    end

    local items = {}
    items[#items + 1] = {
        text               = _("Change Icons"),
        sub_item_table_func = makeChangeIconsMenu,
    }
    items[#items + 1] = {
        text               = _("Rename"),
        sub_item_table_func = makeRenameMenu,
        separator          = true,
    }
    items[#items + 1] = {
        text         = _("Create Quick Action"),
        enabled_func = function() return #Config.getCustomQAList() < MAX_CUSTOM_QA end,
        callback     = function()
            if #Config.getCustomQAList() >= MAX_CUSTOM_QA then
                UIManager:show(InfoMessage:new{
                    text    = string.format(_("Maximum %d quick actions reached. Delete one first."), MAX_CUSTOM_QA),
                    timeout = 2,
                })
                return
            end
            QA.showQuickActionDialog(plugin, nil, nil)
        end,
    }

    local qa_list = Config.getCustomQAList()
    if #qa_list == 0 then return items end
    items[#items].separator = true

    local sorted_qa = {}
    for _i, qa_id in ipairs(qa_list) do
        local cfg = Config.getCustomQAConfig(qa_id)
        sorted_qa[#sorted_qa + 1] = { id = qa_id, label = cfg.label or qa_id }
    end
    table.sort(sorted_qa, function(a, b) return a.label:lower() < b.label:lower() end)

    for _i, entry in ipairs(sorted_qa) do
        local _id = entry.id
        items[#items + 1] = {
            text_func = function()
                local c = Config.getCustomQAConfig(_id)
                local desc
                if c.dispatcher_action and c.dispatcher_action ~= "" then
                    desc = "⊕ " .. c.dispatcher_action
                elseif c.plugin_key and c.plugin_key ~= "" then
                    desc = "⬡ " .. c.plugin_key
                elseif c.collection and c.collection ~= "" then
                    desc = "⊞ " .. c.collection
                else
                    desc = c.path or _("not configured")
                    if #desc > 34 then desc = "…" .. desc:sub(-31) end
                end
                return c.label .. "  |  " .. desc
            end,
            sub_item_table_func = function()
                local sub = {}
                sub[#sub + 1] = {
                    text_func = function()
                        local c = Config.getCustomQAConfig(_id)
                        local desc
                        if c.plugin_key and c.plugin_key ~= "" then
                            desc = "⬡ " .. c.plugin_key
                        elseif c.collection and c.collection ~= "" then
                            desc = "⊞ " .. c.collection
                        else
                            desc = c.path or _("not configured")
                            if #desc > 38 then desc = "…" .. desc:sub(-35) end
                        end
                        return c.label .. "  |  " .. desc
                    end,
                    enabled = false,
                }
                sub[#sub + 1] = {
                    text     = _("Edit"),
                    callback = function() QA.showQuickActionDialog(plugin, _id, nil) end,
                }
                sub[#sub + 1] = {
                    text     = _("Delete"),
                    callback = function()
                        local c = Config.getCustomQAConfig(_id)
                        local confirm_box = ConfirmBox:new{
                            text        = string.format(_("Delete quick action \"%s\"?"), c.label),
                            ok_text     = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                UIManager:close(confirm_box)
                                Config.deleteCustomQA(_id)
                                Config.invalidateTabsCache()
                                QA.invalidateCustomQACache()
                                plugin:_rebuildAllNavbars()
                            end,
                        }
                        UIManager:show(confirm_box)
                    end,
                }
                return sub
            end,
        }
    end

    return items
end

-- ---------------------------------------------------------------------------
-- Tab-position helpers
-- ---------------------------------------------------------------------------

function QA.quickAddPluginToTab(plugin, pos, fm_key, fm_method, title)
    local label = Config.sanitizeLabel(title) or "Plugin"
    local qa_id = Config.nextCustomQAId()
    local list  = Config.getCustomQAList()
    list[#list + 1] = qa_id
    Config.saveCustomQAList(list)
    Config.saveCustomQAConfig(qa_id, label, nil, nil,
        Config.CUSTOM_PLUGIN_ICON, fm_key, fm_method, nil)
    local tabs = Config.loadTabConfig()
    if pos >= 1 and pos <= #tabs then
        tabs[pos] = qa_id
        Config.saveTabConfig(tabs)
    end
    QA.invalidateCustomQACache()
    plugin:_rebuildAllNavbars()
end

function QA.quickAddDispatcherToTab(plugin, pos, action_id, title)
    local label = Config.sanitizeLabel(title) or "Action"
    local qa_id = Config.nextCustomQAId()
    local list  = Config.getCustomQAList()
    list[#list + 1] = qa_id
    Config.saveCustomQAList(list)
    Config.saveCustomQAConfig(qa_id, label, nil, nil,
        Config.CUSTOM_DISPATCHER_ICON, nil, nil, action_id)
    local tabs = Config.loadTabConfig()
    if pos >= 1 and pos <= #tabs then
        tabs[pos] = qa_id
        Config.saveTabConfig(tabs)
    end
    QA.invalidateCustomQACache()
    plugin:_rebuildAllNavbars()
end

function QA.showPluginPickerForTab(plugin, pos)
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")
    local plugin_actions = _scanAllPlugins()
    if #plugin_actions == 0 then
        UIManager:show(InfoMessage:new{ text = _("No plugins found."), timeout = 3 })
        return
    end
    local buttons = {}
    for _i, a in ipairs(plugin_actions) do
        local _a = a
        local label = _a._inactive
            and (_a.title .. "  (" .. _("restart required") .. ")")
            or  _a.title
        buttons[#buttons + 1] = {{ text = label, callback = function()
            UIManager:close(plugin._qa_tab_plugin_picker)
            QA.quickAddPluginToTab(plugin, pos, _a.fm_key, _a.fm_method, _a.title)
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"),
        callback = function() UIManager:close(plugin._qa_tab_plugin_picker) end }}
    plugin._qa_tab_plugin_picker = ButtonDialog:new{ buttons = buttons }
    UIManager:show(plugin._qa_tab_plugin_picker)
end

function QA.showDispatcherPickerForTab(plugin, pos)
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage  = require("ui/widget/infomessage")
    local actions = _scanDispatcherActions()
    if #actions == 0 then
        UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 })
        return
    end
    local buttons = {}
    for _i, a in ipairs(actions) do
        local _a = a
        buttons[#buttons + 1] = {{ text = _a.title, callback = function()
            UIManager:close(plugin._qa_tab_dispatcher_picker)
            QA.quickAddDispatcherToTab(plugin, pos, _a.id, _a.title)
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"),
        callback = function() UIManager:close(plugin._qa_tab_dispatcher_picker) end }}
    plugin._qa_tab_dispatcher_picker = ButtonDialog:new{ buttons = buttons }
    UIManager:show(plugin._qa_tab_dispatcher_picker)
end

return QA
