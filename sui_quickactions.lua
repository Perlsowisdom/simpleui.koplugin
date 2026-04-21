-- sui_quickactions.lua — Simple UI
-- Single source of truth for Quick Actions:
--   • Storage: custom QA CRUD, default-action label/icon overrides
--   • Resolution: getEntry(id) — used by both bottombar and module_quick_actions
--   • Menus: icon picker, rename dialog, create/edit/delete flows
--
-- Both sui_bottombar (buildTabCell) and module_quick_actions (buildQAWidget)
-- call QA.getEntry(id) so every label/icon change propagates everywhere
-- automatically.  sui_menu.lua calls QA.makeMenuItems(plugin) to obtain
-- the Create / Change Icons / Rename sub-menu items.

local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local lfs       = require("libs/libkoreader-lfs")
local logger    = require("logger")
-- PluginLoader not reliable on Kobo, use FM instance directly
local _         = require("gettext")

local Config    = require("sui_config")


local function _pluginDisplayName(raw)
    raw = (raw or "")
        :gsub("%.koplugin$", "")
        :gsub("^filemanager", "")
        :gsub("[_%-]", " ")
        :match("^%s*(.-)%s*$")
    if raw == "" then return "?" end
    return raw
end

local QA = {}

-- ---------------------------------------------------------------------------
-- Icon directory (same as before — single definition now)
-- ---------------------------------------------------------------------------

-- Resolve icons/custom directory using an absolute path derived from this
-- file's location so it works on Android (relative paths fail there).
local _qa_plugin_dir = debug.getinfo(1, "S").source:match("^@(.+/)[^/]+$") or "./"
QA.ICONS_DIR = _qa_plugin_dir .. "icons/custom"
-- Derive the parent plugins/ directory for the filesystem fallback scanner.
-- Works on Kobo (/mnt/onboard/.adds/koreader/plugins/), Kindle, and emulator.
local _plugins_dir = _qa_plugin_dir:match("^(.*plugins/)[^/]+/?$") or ""

-- ---------------------------------------------------------------------------
-- Default-action label / icon overrides
-- Setting keys: navbar_action_<id>_label  /  navbar_action_<id>_icon
-- These are the authoritative get/set functions; sui_config.lua delegates
-- to here for any external callers that still use Config.get/setDefaultAction*.
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
-- getEntry(id) — canonical resolver used by ALL rendering code
--
-- Returns { icon = path, label = string } for any action id.
-- Applies label/icon overrides for default actions.
-- For custom QAs: reads from settings directly (same key as sui_config).
-- Never returns nil.
-- ---------------------------------------------------------------------------

-- Module-level sentinel reused for wifi_toggle to avoid per-call allocation.
local _wifi_entry = { icon = "", label = "" }

function QA.getEntry(id)
    -- Custom QA
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

    -- Default action: look up catalogue
    local a = Config.ACTION_BY_ID[id]
    if not a then
        logger.warn("simpleui: QA.getEntry: unknown id " .. tostring(id))
        return { icon = Config.ICON.library, label = tostring(id) }
    end

    -- wifi_toggle: icon is dynamic (on/off state)
    if id == "wifi_toggle" then
        _wifi_entry.icon  = QA.getDefaultActionIcon(id) or Config.wifiIcon()
        _wifi_entry.label = QA.getDefaultActionLabel(id) or a.label
        return _wifi_entry
    end

    -- All other defaults: apply overrides if present
    local lbl_ov  = QA.getDefaultActionLabel(id)
    local icon_ov = QA.getDefaultActionIcon(id)
    if not lbl_ov and not icon_ov then
        return a  -- fast path: catalogue entry, no allocation
    end
    return {
        icon  = icon_ov  or a.icon,
        label = lbl_ov   or a.label,
    }
end

-- ---------------------------------------------------------------------------
-- Custom QA validity cache
-- Shared between module_quick_actions slots so it is built at most once per
-- render cycle. Invalidate after any create/delete.
-- ---------------------------------------------------------------------------

local _cqa_valid_cache = nil

function QA.getCustomQAValid()
    if not _cqa_valid_cache then
        local list = Config.getCustomQAList()
        local s = {}
        for _, id in ipairs(list) do s[id] = true end
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

-- on_select(path_or_nil) is called with the chosen icon path, or nil for "reset".
-- _picker_handle: table where the open dialog will be stored (e.g. plugin table).
-- picker_key: key on that table (e.g. "_qa_icon_picker").
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
-- Plugin scanner helpers (used by showQuickActionDialog)
-- ---------------------------------------------------------------------------

-- Scans fm.menu.registered_widgets — the same list KOReader's own menu uses.
-- For each widget, calls addToMainMenu() to harvest its menu entries, then
-- uses the callback of the first top-level entry as the plugin action.
-- This is the only approach that reliably discovers every plugin including
-- external ones (BookFusion, FileBrowserPlus, etc.).
--
-- Returns list of { fm_key, title, callback } sorted by title.
-- fm_key is the plugin's key in fm (for saving to config).
-- callback is called directly when the user taps the action.
-- Lazy scan: build plugin list on first use, not at boot time
local _cached_plugin_list = nil

-- FM-internal component keys that must be excluded from plugin scanning.
local _fm_internal_keys = {
    file_chooser   = true,
    collections    = true,
    menu           = true,
    copy_password  = true,
}

-- Returns true for FM-internal keys that are not real KOReader plugins.
local function _isFMInternalKey(k)
    if _fm_internal_keys[k] then return true end
    if k:match("^file_chooser") then return true end
    if k:match("^collection") then return true end
    return false
end

-- Entry-point method priority list (used by _getPluginEntryPoint).
-- Methods that open a fullscreen view/dialog, plus ones used by specific plugins.
-- Order matters: first match wins.
local _ENTRY_METHODS = {
    "onShow", "show", "open", "onOpen", "launch",
    "showBrowser",    -- AppStore
    "onSearchBooks",  -- BookFusion
    "onShowTextEditor",
    "onShowWallabag", "onShowCalendar", "onShowCalibre",
    "onShowDropbox", "onShowEvernote", "onShowZotero",
    "onShowPlugin", "onShowStatistics",
    "onShowStore", "onShowHTTP", "onShowProfiles", "onShowGestures",
}

-- Returns { method_name, callback } for the first matching entry point on inst.
local function _getPluginEntryPoint(inst)
    if type(inst) ~= "table" then return nil, nil end
    for _, m in ipairs(_ENTRY_METHODS) do
        if type(inst[m]) == "function" then return m, inst[m] end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Dispatcher action scanner — shared by showQuickActionDialog and
-- showDispatcherPickerForTab (must be defined before both callers).
-- ---------------------------------------------------------------------------

local function _scanDispatcherActions()
    local ok_d, Dispatcher = pcall(require, "dispatcher")
    if not ok_d or not Dispatcher then return {} end
    pcall(function() Dispatcher:init() end)
    local settingsList, dispatcher_menu_order
    pcall(function()
        local fn_idx = 1
        while true do
            local name, val = debug.getupvalue(Dispatcher.registerAction, fn_idx)
            if not name then break end
            if name == "settingsList" then settingsList = val end
            if name == "dispatcher_menu_order" then dispatcher_menu_order = val end
            fn_idx = fn_idx + 1
        end
    end)
    if type(settingsList) ~= "table" then return {} end
    local order = (type(dispatcher_menu_order) == "table" and dispatcher_menu_order)
        or (function()
            local t = {}
            for k in pairs(settingsList) do t[#t+1] = k end
            table.sort(t)
            return t
        end)()
    local results = {}
    for _, action_id in ipairs(order) do
        local def = settingsList[action_id]
        if type(def) == "table" and def.title and def.category == "none"
                and def.general == true then
            local passes_condition = true
            if def.condition ~= nil then
                local ok_c, cond_val = pcall(def.condition)
                passes_condition = ok_c and cond_val == true
            end
            if passes_condition then
                results[#results + 1] = { id = action_id, title = tostring(def.title) }
            end
        end
    end
    table.sort(results, function(a, b) return a.title < b.title end)
    return results
end

-- ---------------------------------------------------------------------------
-- Create / Edit dialog
-- plugin: the SimpleUI plugin instance (for _rebuildAllNavbars)
-- qa_id:  existing id to edit, or nil to create new
-- on_done: optional zero-arg callback after save
-- ---------------------------------------------------------------------------

function QA.showQuickActionDialog(plugin, qa_id, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local PathChooser      = require("ui/widget/pathchooser")
    local InfoMessage      = require("ui/widget/infomessage")
    local ButtonDialog     = require("ui/widget/buttondialog")

    local getNonFavColl    = Config.getNonFavoritesCollections
    local collections      = getNonFavColl and getNonFavColl() or {}
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

    -- Forward declaration: defined below (after helpers) so callbacks above can close over it.
    local _buildSaveDialog

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

    local sanitize = Config.sanitizeLabel

    local function openPathChooser(plugin)
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
                        if not attr then
                            return string.format(_("Folder not found:\n%s"), p)
                        end
                        if attr.mode ~= "directory" then
                            return string.format(_("Path is not a folder:\n%s"), p)
                        end
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

    local function openCollectionPicker(plugin)
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

    local function openPluginPicker(plugin)
        if not plugin then
            -- Fallback: find the SimpleUI plugin via the FileManager instance.
            -- Never use require("simpleui") — that attempts to load a C .so which does not exist.
            local fm_ok, fm_mod = pcall(require, "apps/filemanager/filemanager")
            if fm_ok and fm_mod and fm_mod.instance then
                local fm = fm_mod.instance
                for i = 1, #fm do
                    if fm[i] and fm[i].name == "filemanagersimpleui" then
                        plugin = fm[i]; break
                    end
                end
            end
        end
        -- Always re-scan when opening the picker — FM is fully initialized
        -- and registered_widgets is populated. Bypassing cache avoids stale
        -- empty results from boot-time calls (Issue 5).
        _cached_plugin_list = nil
        local plugins = QA._getPluginList()

        if #plugins == 0 then
            UIManager:show(InfoMessage:new{
                text    = _("No plugins found."),
                timeout = 3,
            })
            return
        end

        local function showPluginSubmenu(plugins_list, parent_picker, title_override, parent_plugin)
            local sub_buttons = {}
            for _ai, a in ipairs(plugins_list) do
                local _a = a
                sub_buttons[#sub_buttons + 1] = {{ text = _a.title, callback = function()
                    UIManager:close(plugin._qa_plugin_sub_picker)
                    UIManager:close(parent_plugin and parent_plugin._qa_plugin_picker or parent_picker)
                    _buildSaveDialog({
                        fields = { { description = _("Name"), text = cfg.label or _a.title, hint = _("e.g. Rakuyomi…") } },
                        icon_default_label = _("Default (Plugin)"),
                        on_save = function(inputs)
                            local qa_id = Config.nextCustomQAId()
                            local list = Config.getCustomQAList()
                            list[#list + 1] = qa_id
                            Config.saveCustomQAList(list)
                            -- Use __addtomainmenu__ sentinel when we have a harvested callback;
                            -- otherwise save the actual method name for the dispatcher's method path.
                            local method = (_a.callback and "__addtomainmenu__") or (_a.method or "__addtomainmenu__")
                            Config.saveCustomQAConfig(qa_id, sanitize(inputs[1]) or _a.title,
                                nil, nil, Config.CUSTOM_PLUGIN_ICON, _a.fm_key, method, nil)
                            if _a.callback then
                                QA._plugin_callbacks = QA._plugin_callbacks or {}
                                QA._plugin_callbacks[_a.fm_key] = _a.callback
                            end
                            QA.invalidateCustomQACache()
                            plugin:_scheduleRebuild()
                        end,
                    })
                end }}
            end
            sub_buttons[#sub_buttons + 1] = {{ text = _("Back"), callback = function()
                UIManager:close(plugin._qa_plugin_sub_picker)
            end }}
            plugin._qa_plugin_sub_picker = ButtonDialog:new{
                title        = title_override or _("Plugin Actions"),
                width_factor = 0.7,
                buttons      = sub_buttons,
            }
            UIManager:show(plugin._qa_plugin_sub_picker)
        end

        local buttons = {}
        for _ai, a in ipairs(plugins) do
            local _a = a
            if _a.has_submenu and _a.submenu_items then
                -- Grouped plugin: show a submenu of available actions
                buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                    UIManager:close(plugin._qa_plugin_picker)
                    showPluginSubmenu(_a.submenu_items, plugin._qa_plugin_picker, _a.title, plugin)
                end }}
            else
                -- Single-action plugin
                buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                    UIManager:close(plugin._qa_plugin_picker)
                    _buildSaveDialog({
                        fields = { { description = _("Name"), text = cfg.label or _a.title, hint = _("e.g. Rakuyomi…") } },
                        icon_default_label = _("Default (Plugin)"),
                        on_save = function(inputs)
                            local qa_id = Config.nextCustomQAId()
                            local list = Config.getCustomQAList()
                            list[#list + 1] = qa_id
                            Config.saveCustomQAList(list)
                            -- Use __addtomainmenu__ sentinel when we have a harvested callback;
                            -- otherwise save the actual method name for the dispatcher's method path.
                            local method = (_a.callback and "__addtomainmenu__") or (_a.method or "__addtomainmenu__")
                            Config.saveCustomQAConfig(qa_id, sanitize(inputs[1]) or _a.title,
                                nil, nil, Config.CUSTOM_PLUGIN_ICON, _a.fm_key, method, nil)
                            if _a.callback then
                                QA._plugin_callbacks = QA._plugin_callbacks or {}
                                QA._plugin_callbacks[_a.fm_key] = _a.callback
                            end
                            QA.invalidateCustomQACache()
                            plugin:_scheduleRebuild()
                        end,
                    })
                end }}
            end
        end

        buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function()
            UIManager:close(plugin._qa_plugin_picker)
        end }}

        plugin._qa_plugin_picker = ButtonDialog:new{
            title        = _("Plugin"),
            width_factor = 0.7,
            buttons      = buttons,
        }
        UIManager:show(plugin._qa_plugin_picker)
    end


    local function openDispatcherPicker(plugin)
        if not plugin then
            local SimpleUI = require("simpleui")
            plugin = SimpleUI
        end
        local actions = _scanDispatcherActions()
        if #actions == 0 then
            UIManager:show(InfoMessage:new{ text = _("No system actions found."), timeout = 3 })
            return
        end
        local buttons = {}
        table.sort(actions, function(a, b) return a.title:lower() < b.title:lower() end)
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

    -- Build and show the MultiInputDialog for naming/icon selection.
    -- Defined here so it can access iconButtonLabel, chosen_icon, dlg_title,
    -- TOTAL_H, plugin, MultiInputDialog, InfoMessage, UIManager (all upvalues).
    _buildSaveDialog = function(spec)
        local title = spec.title or dlg_title
        local active_dialog = nil

        local function openIconPicker()
            if active_dialog then UIManager:close(active_dialog); active_dialog = nil end
            QA.showIconPicker(chosen_icon, function(new_icon)
                chosen_icon = new_icon
                _buildSaveDialog(spec)
            end, spec.icon_default_label or _("Icon"), plugin, "_qa_icon_picker")
        end

        local fields = {}
        for _fi, f in ipairs(spec.fields) do
            fields[#fields + 1] = {
                description = f.description,
                text = f.text or "",
                hint = f.hint,
            }
        end

        -- MultiInputDialog requires buttons as { { {btn, btn, btn} } }
        -- (list of rows, each row a list of button specs).
        local buttons = { {
            {
                text = iconButtonLabel(spec.icon_default_label or _("Icon: Default")),
                callback = function()
                    openIconPicker()
                end,
            },
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(active_dialog)
                    active_dialog = nil
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local inputs = active_dialog:getFields()
                    if spec.validate then
                        local err = spec.validate(inputs)
                        if err then
                            UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
                            return
                        end
                    end
                    UIManager:close(active_dialog)
                    active_dialog = nil
                    spec.on_save(inputs)
                end,
            },
        } }

        active_dialog = MultiInputDialog:new{
            title = title,
            fields = fields,
            buttons = buttons,
        }
        UIManager:show(active_dialog)
        pcall(function() active_dialog:onShowKeyboard() end)
    end

    local choice_dialog
    choice_dialog = ButtonDialog:new{
        title = _("Quick Action Type"),
        width_factor = 0.7,
        buttons = {
            {{ text = _("Collection"), enabled = #collections > 0,
               callback = function() UIManager:close(choice_dialog); openCollectionPicker() end }},
            {{ text = _("Folder"),
               callback = function() UIManager:close(choice_dialog); openPathChooser() end }},
            {{ text = _("Plugin"),
               callback = function() UIManager:close(choice_dialog); openPluginPicker(plugin) end }},
            {{ text = _("System Actions"),
               callback = function() UIManager:close(choice_dialog); openDispatcherPicker() end }},
            {{ text = _("Cancel"),
               callback = function() UIManager:close(choice_dialog) end }},
        }
    }
    UIManager:show(choice_dialog)
end

-- ---------------------------------------------------------------------------
-- makeMenuItems(plugin) — returns the items table for the Quick Actions menu
-- Called from sui_menu.lua; replaces the old makeQuickActionsMenu closure.
-- ---------------------------------------------------------------------------

function QA.makeMenuItems(plugin)
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox  = require("ui/widget/confirmbox")
    local InputDialog = require("ui/widget/inputdialog")

    local MAX_CUSTOM_QA = Config.MAX_CUSTOM_QA

    -- All overridable actions (default built-ins + custom QAs), sorted by label.
    local function allActions()
        local pool = {}
        for _, a in ipairs(Config.ALL_ACTIONS) do
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

    -- ── Change Icons ─────────────────────────────────────────────────────────

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

    -- ── Rename ───────────────────────────────────────────────────────────────

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
                            {
                                text     = _("Cancel"),
                                callback = function() UIManager:close(dlg) end,
                            },
                            {
                                text         = _("Reset"),
                                enabled_func = function()
                                    return _is_default and QA.getDefaultActionLabel(_id) ~= nil
                                end,
                                callback = function()
                                    UIManager:close(dlg)
                                    QA.setDefaultActionLabel(_id, nil)
                                    plugin:_rebuildAllNavbars()
                                end,
                            },
                            {
                                text             = _("Save"),
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
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    pcall(function() dlg:onShowKeyboard() end)
                end,
            }
        end
        return items
    end

    -- ── Top-level menu ───────────────────────────────────────────────────────

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

    -- Pre-read + sort custom QAs by label.
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
                    desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
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
                            desc = "⬡ " .. c.plugin_key .. ":" .. (c.plugin_method or "?")
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
                        UIManager:show(ConfirmBox:new{
                            text        = string.format(_("Delete quick action \"%s\"?"), c.label),
                            ok_text     = _("Delete"),
                            cancel_text = _("Cancel"),
                            ok_callback = function()
                                Config.deleteCustomQA(_id)
                                Config.invalidateTabsCache()
                                QA.invalidateCustomQACache()
                                plugin:_rebuildAllNavbars()
                            end,
                        })
                    end,
                }
                return sub
            end,
        }
    end

    return items
end

-- Builds the MultiInputDialog for naming and icon selection.
-- spec fields: { description, text, hint }
-- spec.validate(inputs) -> error string or nil
-- spec.on_save(inputs)
-- spec.icon_default_label
-- spec.title (optional)
-- Builtins to skip in plugin picker (already surfaced as built-in tabs).
local _BUILTIN_SKIP = {
    history = true, collections = true, filesearcher = true,
    folder_shortcuts = true, dictionary = true, wikipedia = true,
    bookinfo = true, menu = true, screenshot = true,
    devicestatus = true, devicelistener = true, networklistener = true,
    languagesupport = true, simpleui = true,
}

-- Tries to get a callable entry-point callback from a plugin instance.
-- 1. Force addToMainMenu for registerToMainMenu()-based plugins (AppStore)
-- 2. addToMainMenu capturer (harvests first available callback via mc:add)
-- 3. Direct key assignment harvester (BookFusion-style: menu_items.xxx = {callback=...})
-- 4. Special case: showBrowser (AppStore), onSearchBooks (BookFusion)
-- 5. Direct method probing via _ENTRY_METHODS
-- 6. Pattern fallback (onShow / onOpen / onLaunch)
-- Returns (callback, display_title, method_name). callback is nil if nothing found.
local function _getPluginCallback(inst, fm_key)
    -- Pre-force addToMainMenu for plugins that use self.ui.menu:registerToMainMenu.
    -- AppStore does NOT add via mc:add() - it calls registerToMainMenu which adds
    -- directly to FM's menu. We call it here to trigger any side-effects.
    if type(inst.addToMainMenu) == "function" then
        local dummy_mc = {
            items = {},
            add = function() end,
            registerItem = function() end,
            registerToMainMenu = function(widget)
                if type(widget and widget.addToMainMenu) == "function" then
                    pcall(widget.addToMainMenu, widget, dummy_mc)
                end
            end,
        }
        pcall(inst.addToMainMenu, inst, dummy_mc)
    end

    -- Method 1: rebuild the plugin's addToMainMenu menu and grab first callback
    if type(inst.addToMainMenu) == "function" then
        local mc = {
            items = {},
            add = function(self, item)
                if item then self.items[#self.items + 1] = item end
            end,
            registerItem = function(self, item) return self:add(item) end,
            registerToMainMenu = function(self, widget)
                if type(widget.addToMainMenu) == "function" then
                    pcall(widget.addToMainMenu, widget, mc)
                end
            end,
        }
        local ok = pcall(inst.addToMainMenu, inst, mc)
        if ok then
            for _, item in ipairs(mc.items) do
                local cb = item.callback
                if not cb and type(item.sub_item_table) == "table" then
                    for _, sub in ipairs(item.sub_item_table) do
                        if type(sub) == "table" and type(sub.callback) == "function" then
                            cb = sub.callback; break
                        end
                    end
                end
                if not cb and type(item.sub_item_table_func) == "function" then
                    local sub_func = item.sub_item_table_func
                    cb = function()
                        local ok_sub, sub = pcall(sub_func)
                        if ok_sub and type(sub) == "table" then
                            for idx, s in ipairs(sub) do
                                if type(s) == "table" and type(s.callback) == "function" then
                                    s.callback(); return
                                end
                            end
                        end
                    end
                end
                if type(cb) == "function" then
                    local title = item.text or item.title or _pluginDisplayName(fm_key)
                    return function(...) return cb(inst, ...) end, title, nil
                end
            end
        end
    end

    -- Method 2: also check direct key assignments on mc (BookFusion-style:
    -- plugins that do menu_items.xxx = {callback=...} instead of mc:add())
    if type(inst.addToMainMenu) == "function" then
        local mc = {
            items = {},
            add = function(self, item)
                if item then self.items[#self.items + 1] = item end
            end,
            registerItem = function(self, item) return self:add(item) end,
            registerToMainMenu = function(self, widget)
                if type(widget.addToMainMenu) == "function" then
                    pcall(widget.addToMainMenu, widget, mc)
                end
            end,
        }
        pcall(inst.addToMainMenu, inst, mc)
        for k, v in pairs(mc) do
            if type(k) == "string" and k ~= "items" and k ~= "add" and k ~= "registerItem" and k ~= "registerToMainMenu" then
                if type(v) == "table" then
                    local cb = v.callback
                    if not cb and type(v.sub_item_table_func) == "function" then
                        local sub_func = v.sub_item_table_func
                        cb = function()
                            local ok_sub, sub = pcall(sub_func)
                            if ok_sub and type(sub) == "table" then
                                for idx, s in ipairs(sub) do
                                    if type(s) == "table" and type(s.callback) == "function" then
                                        s.callback(); return
                                    end
                                end
                            end
                        end
                    end
                    if type(cb) == "function" then
                        local title = v.text or _pluginDisplayName(k)
                        return cb, title, nil
                    end
                end
            end
        end
    end

    -- Method 3: special cases for plugins that need specific arguments.
    -- These CANNOT be called with no args, so handle them explicitly.
    if fm_key == "appstore" and type(inst.showBrowser) == "function" then
        -- showBrowser(kind) - "plugin" opens the plugin browser
        return function() inst:showBrowser("plugin") end, "AppStore", "showBrowser"
    end
    if fm_key == "bookfusion" and type(inst.onSearchBooks) == "function" then
        return function() inst:onSearchBooks() end, "BookFusion", "onSearchBooks"
    end

    -- Method 4: direct method probing (NO showBrowser here - needs args)
    for _, method in ipairs({
        "onShow", "show", "open", "launch", "onOpen",
        "onShowHist", "onShowBookInfo", "onShowColl", "onShowCollList",
        "onShowFileSearch", "onShowFolderShortcutsDialog",
        "onShowDictionaryLookup", "onShowWikipediaLookup",
        "onSearchBooks", "onPushPosition",  -- BookFusion (no-arg form)
        "showStatistics",  -- Statistics
    }) do
        if type(inst[method]) == "function" then
            return inst[method], _pluginDisplayName(fm_key), method
        end
    end

    -- Method 5: pattern fallback
    for k, v in pairs(inst) do
        if type(k) == "string" and type(v) == "function" then
            if k:match("^onShow") or k:match("^onOpen") or k:match("^onLaunch") then
                return v, _pluginDisplayName(fm_key), k
            end
        end
    end
    return nil, nil, nil
end
-- Unified plugin scanner: directly probes all loaded plugin instances
-- from both FM registration and PluginLoader (enabled_plugins + loaded_plugins).
-- Replaces the old _scanFMPlugins + _scanNonFMPlugins approach.
function QA._getPluginList()
    if _cached_plugin_list ~= nil then return _cached_plugin_list end

    local results = {}
    local seen_keys = {}

    -- KOReader's pluginloader stores:
    --   .enabled_plugins = { { name="plugname", path="/path/to/plug.koplugin" }, ... }  -- raw modules
    --   .loaded_plugins = { plugname = instance, ... }                                   -- instantiated
    -- NOTE: enabled_plugins and loaded_plugins are nil until loadPlugins() is called.
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if ok_pl and PluginLoader then
        -- Force PluginLoader to populate enabled_plugins / loaded_plugins
        pcall(function() PluginLoader:loadPlugins() end)
    end
    local enabled_plugins = ok_pl and PluginLoader and PluginLoader.enabled_plugins
    local loaded_plugins  = ok_pl and PluginLoader and PluginLoader.loaded_plugins

    -- Force-instantiate any enabled plugins not yet in loaded_plugins.
    -- This ensures AppStore, BookFusion, and other registerToMainMenu()-based plugins
    -- appear in the plugin picker even if FileManager has not been opened yet.
    if type(enabled_plugins) == "table" then
        for _, plugin_module in ipairs(enabled_plugins) do
            if type(plugin_module) == "table" and type(plugin_module.name) == "string" then
                local name = plugin_module.name
                if not loaded_plugins[name] then
                    -- Provide a minimal ui mock so plugins that access self.ui do not crash
                    local mock_ui = { menu = { registerToMainMenu = function() end } }
                    local fm_loaded = package.loaded["apps/filemanager/filemanager"]
                    local fm_instance = fm_loaded and fm_loaded.instance
                    local ui_instance = fm_instance and fm_instance.ui or mock_ui
                    local ok, inst_or_err = pcall(PluginLoader.createPluginInstance, PluginLoader, plugin_module, { ui = ui_instance })
                    if ok and inst_or_err then
                        loaded_plugins[name] = inst_or_err
                        logger.dbg("[simpleui] _getPluginList: instantiated", name)
                    else
                        logger.dbg("[simpleui] _getPluginList: failed to instantiate", name, inst_or_err)
                    end
                end
            end
        end
    end

    local function addPlugin(name, inst)
        if type(name) ~= "string" or name == "" or name == "simpleui" then return end
        if _BUILTIN_SKIP[name] then return end
        if seen_keys[name] then return end
        if type(inst) ~= "table" then return end

        local cb, title, method = _getPluginCallback(inst, name)
        if not cb then
            logger.dbg("[simpleui] _getPluginList: no callback for", name)
            -- Don't mark seen — a later source (loaded_plugins, fs) may find a better instance.
            return
        end
        -- Guard against nil/empty title from MC array-index entries in Method 2
        if not title or title == "" then return end

        seen_keys[name] = true  -- only mark seen once we have a valid callback
        results[#results + 1] = {
            fm_key   = name,
            title    = title,
            callback = cb,
            method   = method,
        }
        logger.dbg("[simpleui] _getPluginList: found plugin:", name, "method:", method or "callback")
    end

    -- Collect from FM instance (covers all FM-registered plugins).
    -- FM is instantiated lazily on first file-manager open; on emulator it
    -- should be available by the time the user opens the QA menu.
    local fm = package.loaded["apps/filemanager/filemanager"]
    if fm and fm.instance then
        fm = fm.instance
    end
    if fm then
        for k, v in pairs(fm) do
            if type(k) == "string" and type(v) == "table" and not _isFMInternalKey(k) then
                addPlugin(k, v)
            end
        end
    end

    -- Collect from PluginLoader loaded_plugins (instantiated instances keyed by plugin name).
    -- This is the most reliable source as it contains all currently-loaded plugin instances.
    local PluginLoader = package.loaded["frontend/pluginloader"]
    if PluginLoader then
        local lp = type(PluginLoader.loaded_plugins) == "table" and PluginLoader.loaded_plugins or {}
        for name, inst in pairs(lp) do
            addPlugin(name, inst)
        end
    end

    -- Source 3: enabled_plugins class tables used directly as plugin "instances".
    -- Each entry in enabled_plugins is the loaded plugin class table — it has
    -- .name, .fullname, .path, and all methods (addToMainMenu, showBrowser, etc.).
    -- NOTE: avoid referencing the `PluginLoader` local here — it is shadowed by the
    -- Source-2 re-declaration above; use the `enabled_plugins` upvalue directly.
    if type(enabled_plugins) == "table" then
        for _, pm in ipairs(enabled_plugins) do
            if type(pm) == "table" then
                local name = pm.name
                if type(name) == "string" and not seen_keys[name] and not _BUILTIN_SKIP[name] then
                    -- Use the plugin class table as the "instance" for callback probing.
                    -- _getPluginCallback calls are wrapped in pcall internally; methods that
                    -- need self.ui will crash gracefully and fall through to special-cases.
                    local cb, title, method = _getPluginCallback(pm, name)
                    if cb then
                        if not title or title == "" then
                            title = pm.fullname or _pluginDisplayName(name)
                        end
                        seen_keys[name] = true
                        results[#results + 1] = {
                            fm_key = name, title = title, callback = cb, method = method,
                        }
                        logger.dbg("[simpleui] _getPluginList: ep-class found:", name, method)
                    end
                end
            end
        end
    end

    -- Source 4: lfs.dir scan of the plugins/ directory.
    -- _plugins_dir is derived from this file's path at module load time.  When the plugin
    -- is accessed via a symlink (emulator), that path may not contain "plugins/" so
    -- _plugins_dir is "".  In that case, try to derive it from enabled_plugins paths.
    local plugins_scan_dir = _plugins_dir
    if plugins_scan_dir == "" and type(enabled_plugins) == "table" then
        for _, pm in ipairs(enabled_plugins) do
            if type(pm) == "table" then
                local p = pm.path or pm.module_path
                if type(p) == "string" and p:match("%.koplugin") then
                    -- e.g. "/root/koreader/plugins/appstore.koplugin" → "/root/koreader/plugins/"
                    plugins_scan_dir = p:match("^(.*/)") or ""
                    if plugins_scan_dir ~= "" then break end
                end
            end
        end
    end

    if plugins_scan_dir ~= "" then
        local attr = lfs.attributes(plugins_scan_dir)
        if attr and attr.mode == "directory" then
            for entry in lfs.dir(plugins_scan_dir) do
                if entry ~= "." and entry ~= ".." and entry:match("%.koplugin$") then
                    local plugin_path = plugins_scan_dir .. entry
                    local meta_path = plugin_path .. "/_meta.lua"
                    local main_path = plugin_path .. "/main.lua"
                    if lfs.attributes(meta_path) and lfs.attributes(main_path) then
                        local ok_meta, meta = pcall(dofile, meta_path)
                        local ok_main, main_mod = pcall(dofile, main_path)
                        if ok_meta and meta and type(meta) == "table" and type(main_mod) == "table" then
                            local name  = meta.name or entry:gsub("%.koplugin$", "")
                            if not seen_keys[name] and not _BUILTIN_SKIP[name] then
                                local title  = meta.fullname or _pluginDisplayName(entry)
                                local method, cb = _getPluginEntryPoint(main_mod)
                                if cb then
                                    seen_keys[name] = true
                                    results[#results + 1] = {
                                        fm_key = name, title = title, callback = cb, method = method,
                                    }
                                    logger.dbg("[simpleui] _getPluginList: fs-dir found:", entry, "->", title)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if #results > 0 then
        table.sort(results, function(a, b) return a.title:lower() < b.title:lower() end)
        _cached_plugin_list = results
        logger.dbg("[simpleui] _getPluginList: found", #results, "plugins")
    else
        logger.warn("[simpleui] _getPluginList: no plugins found (FM or PluginLoader not ready?)")
    end

    return results
end


function QA.showDispatcherPickerForTab(plugin, pos)
    local actions = _scanDispatcherActions()
    if #actions == 0 then
        local UIManager_ = require("ui/uimanager")
        local InfoMessage_ = require("ui/widget/infomessage")
        UIManager_:show(InfoMessage_:new{ text = _("No system actions found."), timeout = 3 })
        return
    end
    local ButtonDialog_ = require("ui/widget/buttondialog")
    local UIManager_    = require("ui/uimanager")
    local buttons = {}
    table.sort(actions, function(a, b) return a.title:lower() < b.title:lower() end)
    for _i, a in ipairs(actions) do
        local _a = a
        buttons[#buttons + 1] = {{ text = _a.title, callback = function()
            UIManager_:close(plugin._qa_tab_dispatcher_picker)
            local qa_id = Config.nextCustomQAId()
            local list  = Config.getCustomQAList()
            list[#list + 1] = qa_id
            Config.saveCustomQAList(list)
            Config.saveCustomQAConfig(qa_id, _a.title, nil, nil,
                Config.CUSTOM_DISPATCHER_ICON, nil, nil, _a.id)
            QA.invalidateCustomQACache()
            local tabs = Config.loadTabConfig()
            local old_id = tabs[pos]
            tabs[pos] = qa_id
            for i, tid in ipairs(tabs) do
                if i ~= pos and tid == qa_id then tabs[i] = old_id; break end
            end
            Config._ensureHomePresent(tabs)
            Config.saveTabConfig(tabs)
            plugin:_scheduleRebuild()
        end }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function()
        UIManager_:close(plugin._qa_tab_dispatcher_picker)
    end }}
    plugin._qa_tab_dispatcher_picker = ButtonDialog_:new{
        title        = _("System Action"),
        width_factor = 0.7,
        buttons      = buttons,
    }
    UIManager_:show(plugin._qa_tab_dispatcher_picker)
end

function QA.showPluginPickerForTab(plugin, pos)
    -- Always re-scan when opening the picker — FM is fully initialized by
    -- now and registered_widgets is populated. Skipping the cache avoids
    -- stale empty results from early boot-time calls (Issue 5).
    _cached_plugin_list = nil
    local plugins = QA._getPluginList()

    if #plugins == 0 then
        local UIManager_ = require("ui/uimanager")
        local InfoMessage_ = require("ui/widget/infomessage")
        UIManager_:show(InfoMessage_:new{ text = _("No plugins found."), timeout = 3 })
        return
    end

    local ButtonDialog_ = require("ui/widget/buttondialog")
    local UIManager_    = require("ui/uimanager")

    local function commitTabPlugin(a)
        UIManager_:close(plugin._qa_tab_plugin_picker)
        local qa_id = Config.nextCustomQAId()
        local list  = Config.getCustomQAList()
        list[#list + 1] = qa_id
        Config.saveCustomQAList(list)
        -- For method-only plugins (no harvested callback), cache a callable
        -- that invokes the saved method name at runtime via navigate()'s
        -- plugin_method dispatch path.
        if a.callback then
            QA._plugin_callbacks = QA._plugin_callbacks or {}
            QA._plugin_callbacks[a.fm_key] = a.callback
        end
        Config.saveCustomQAConfig(qa_id, a.title, nil, nil,
            Config.CUSTOM_PLUGIN_ICON, a.fm_key, a.method or "__addtomainmenu__", nil)
        QA.invalidateCustomQACache()
        local tabs = Config.loadTabConfig()
        local old_id = tabs[pos]
        tabs[pos] = qa_id
        for i, tid in ipairs(tabs) do
            if i ~= pos and tid == qa_id then tabs[i] = old_id; break end
        end
        Config._ensureHomePresent(tabs)
        Config.saveTabConfig(tabs)
        plugin:_scheduleRebuild()
    end

    local function showTabPluginSubmenu(plugins_list, title_override)
        local sub_buttons = {}
        for _ai, a in ipairs(plugins_list) do
            local _a = a
            sub_buttons[#sub_buttons + 1] = {{ text = _a.title, callback = function()
                UIManager_:close(plugin._qa_tab_plugin_sub_picker)
                commitTabPlugin(_a)
            end }}
        end
        sub_buttons[#sub_buttons + 1] = {{ text = _("Back"), callback = function()
            UIManager_:close(plugin._qa_tab_plugin_sub_picker)
        end }}
        plugin._qa_tab_plugin_sub_picker = ButtonDialog_:new{
            title        = title_override or _("Plugin Actions"),
            width_factor = 0.7,
            buttons      = sub_buttons,
        }
        UIManager_:show(plugin._qa_tab_plugin_sub_picker)
    end

    local buttons = {}
    for _ai, a in ipairs(plugins) do
        local _a = a
        if _a.has_submenu and _a.submenu_items then
            buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                UIManager_:close(plugin._qa_tab_plugin_picker)
                showTabPluginSubmenu(_a.submenu_items, _a.title)
            end }}
        else
            buttons[#buttons + 1] = {{ text = _a.title, callback = function()
                commitTabPlugin(_a)
            end }}
        end
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function()
        UIManager_:close(plugin._qa_tab_plugin_picker)
    end }}
    plugin._qa_tab_plugin_picker = ButtonDialog_:new{
        title        = _("Plugin"),
        width_factor = 0.7,
        buttons      = buttons,
    }
    UIManager_:show(plugin._qa_tab_plugin_picker)
end


return QA

