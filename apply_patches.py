#!/usr/bin/env python3
"""
Apply patches to SimpleUI plugin files.
Run from the root of the simpleui.koplugin directory:
  python3 apply_patches.py
"""

import re, sys, os

def patch_file(path, patches):
    if not os.path.exists(path):
        print(f"ERROR: {path} not found. Run from simpleui.koplugin root.", file=sys.stderr)
        return False
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
    original = content
    for description, old, new in patches:
        if old not in content:
            print(f"  WARNING [{path}]: pattern not found for: {description}")
            continue
        content = content.replace(old, new, 1)
        print(f"  OK [{path}]: {description}")
    if content == original:
        print(f"  (no changes made to {path})")
        return False
    # Backup
    with open(path + '.bak', 'w', encoding='utf-8') as f:
        f.write(original)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  Saved {path} (backup: {path}.bak)")
    return True


# ============================================================
# sui_config.lua patches
# ============================================================
config_patches = [
    # 1. Remove bookfusion from ICON table
    (
        "Remove bookfusion icon from ICON table",
        "    bookfusion     = _P .. \"bookfusion.svg\",\n",
        "",
    ),
    # 2. Remove bookfusion from ALL_ACTIONS
    (
        "Remove bookfusion from ALL_ACTIONS",
        "    { id = \"bookfusion\",       label = _(\"BookFusion\"),      icon = M.ICON.bookfusion  },\n",
        "",
    ),
    # 3. Remove legacy ICON alias if present
    (
        "Remove CUSTOM_BOOKFUSION_ICON alias if present",
        "M.BOOKFUSION_ICON            = M.ICON.bookfusion\n",
        "",
    ),
]

# ============================================================
# sui_bottombar.lua patches
# ============================================================
# Remove the bookfusion in-place action classifier
bottombar_patches = [
    (
        "Remove bookfusion from _isInPlaceAction",
        "    if action_id == \"bookfusion\"       then return true end\n",
        "",
    ),
    (
        "Remove bookfusion from _executeInPlace",
        """\
    elseif action_id == \"bookfusion\" then
        -- Try FileManager first (home screen), then ReaderUI (while reading)
        local ui = fm or plugin.ui
        local bf = fm and fm[\"bookfusion\"]
        if bf and type(bf.onSearchBooks) == \"function\" then
            bf:onSearchBooks()
        else
            showUnavailable(_(\"BookFusion not available. Make sure it is linked.\"))
        end

""",
        "",
    ),
]

# ============================================================
# sui_bottombar.lua - also remove bookfusion from navigate()
# ============================================================
bottombar_navigate_patches = [
    (
        "Remove bookfusion from navigate()",
        """\
    elseif action_id == \"bookfusion\" then
        -- Try FileManager first (home screen), then ReaderUI (while reading)
        local ui = fm or plugin.ui
        local bf = fm and fm[\"bookfusion\"]
        if bf and type(bf.onSearchBooks) == \"function\" then
            bf:onSearchBooks()
        else
            showUnavailable(_(\"BookFusion not available. Make sure it is linked.\"))
        end

""",
        "",
    ),
]

# ============================================================
# sui_menu.lua patches - expose plugins in Tabs toggle list
# ============================================================
# The key change: in makeTabsMenu(), after building action_pool from ALL_ACTIONS
# and custom QAs, also scan installed plugins and add them as custom QA entries
# if they don't already exist. This makes plugins appear in the toggle list.
#
# We replace the pool-building block in makeTabsMenu with an extended version.
menu_patches = [
    (
        "Expose installed plugins in Tabs toggle list",
        """\
        local toggle_items = {}
        local action_pool  = {}
        for _i, action in ipairs(ALL_ACTIONS) do
            if actionAvailable(action.id) then action_pool[#action_pool + 1] = action.id end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do action_pool[#action_pool + 1] = qa_id end""",
        """\
        local toggle_items = {}
        local action_pool  = {}
        for _i, action in ipairs(ALL_ACTIONS) do
            if actionAvailable(action.id) then action_pool[#action_pool + 1] = action.id end
        end
        for _i, qa_id in ipairs(getCustomQAList()) do action_pool[#action_pool + 1] = qa_id end

        -- Auto-register installed plugins as custom QAs so they appear in the
        -- tab toggle list without requiring the user to go through "Plugins..."
        -- first.  We only create the QA entry when it doesn't already exist.
        do
            local QA_mod = require("sui_quickactions")
            local ok_plugins, plugin_list = pcall(function()
                -- _scanAllPlugins is internal; expose a thin wrapper here.
                -- We replicate the public surface: iterate disk plugins.
                local lfs_m  = require("libs/libkoreader-lfs")
                local ds_ok, ds = pcall(require, "datastorage")
                local plugins_dir = nil
                if ds_ok and ds then
                    local d = ds.getDataDir():gsub("/$","") .. "/plugins/"
                    if lfs_m.attributes(d,"mode") == "directory" then plugins_dir = d end
                end
                if not plugins_dir then return {} end
                local results = {}
                for entry in lfs_m.dir(plugins_dir) do
                    if entry ~= "." and entry ~= ".." and entry ~= "simpleui.koplugin"
                            and entry:match("%.koplugin$") then
                        local meta_path = plugins_dir .. entry .. "/_meta.lua"
                        local f = io.open(meta_path, "r")
                        if f then
                            local src = f:read("*a"); f:close()
                            local name     = src:match('name%s*=%s*"([^"]+)"')
                                         or src:match('%["name"%]%s*=%s*"([^"]+)"')
                            local fullname = src:match('fullname%s*=%s*"([^"]+)"')
                                         or src:match('%["fullname"%]%s*=%s*"([^"]+)"')
                            local skip = { simpleui=true, gestures=true, backgroundrunner=true,
                                           timesync=true, autowarmth=true }
                            if name and not skip[name] then
                                results[#results+1] = {
                                    name = name,
                                    title = fullname or name,
                                }
                            end
                        end
                    end
                end
                return results
            end)
            if ok_plugins and plugin_list then
                -- Build a lookup of existing custom QAs keyed by plugin_key so
                -- we don't create duplicates on every menu open.
                local existing_plugin_keys = {}
                for _i, qa_id in ipairs(getCustomQAList()) do
                    local c = getCustomQAConfig(qa_id)
                    if c.plugin_key and c.plugin_key ~= "" then
                        existing_plugin_keys[c.plugin_key] = qa_id
                    end
                end
                for _i, plug in ipairs(plugin_list) do
                    local existing_id = existing_plugin_keys[plug.name]
                    if not existing_id then
                        -- Create a new custom QA for this plugin.
                        local qa_id = Config.nextCustomQAId()
                        local list  = getCustomQAList()
                        list[#list+1] = qa_id
                        saveCustomQAList(list)
                        Config.saveCustomQAConfig(qa_id, plug.title, nil, nil,
                            CUSTOM_PLUGIN_ICON, plug.name, "onShow", nil)
                        QA_mod.invalidateCustomQACache()
                        action_pool[#action_pool+1] = qa_id
                    else
                        -- Already registered; make sure it's in the pool.
                        local already_in_pool = false
                        for _j, pid in ipairs(action_pool) do
                            if pid == existing_id then already_in_pool = true; break end
                        end
                        if not already_in_pool then
                            action_pool[#action_pool+1] = existing_id
                        end
                    end
                end
            end
        end""",
    ),
]

# Also fix the plugin method resolution: when a custom QA has plugin_key but
# the method stored is "onShow" which may not exist, sui_bottombar should
# try common methods. Patch _executeInPlace and navigate's custom_qa block.
bottombar_plugin_fix_patches = [
    (
        "Fix plugin method resolution in _executeInPlace custom_qa block",
        """\
            elseif cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then
                local plugin_inst = fm and fm.menu_items and fm[cfg.plugin_key]
                if plugin_inst and type(plugin_inst[cfg.plugin_method]) == "function" then
                    local ok, err = pcall(function() plugin_inst[cfg.plugin_method](plugin_inst) end)
                    if not ok then showUnavailable(string.format(_("Plugin error: %s"), tostring(err))) end
                else
                    showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
                end
            end
        end
    end

    -- Restore HS to its original position""",
        """\
            elseif cfg.plugin_key and cfg.plugin_key ~= "" then
                local plugin_inst = fm and fm[cfg.plugin_key]
                if plugin_inst then
                    -- Try the stored method, then common fallbacks.
                    local methods_to_try = {}
                    if cfg.plugin_method and cfg.plugin_method ~= "" then
                        methods_to_try[#methods_to_try+1] = cfg.plugin_method
                    end
                    for _, m in ipairs({"onShow","show","open","onOpen","launch",
                            "onSearchBooks","onShowStore","onShowTextEditor"}) do
                        methods_to_try[#methods_to_try+1] = m
                    end
                    local called = false
                    for _, m in ipairs(methods_to_try) do
                        if type(plugin_inst[m]) == "function" then
                            local ok, err = pcall(function() plugin_inst[m](plugin_inst) end)
                            if not ok then
                                showUnavailable(string.format(_("Plugin error: %s"), tostring(err)))
                            end
                            called = true; break
                        end
                    end
                    if not called then
                        showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
                    end
                else
                    showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
                end
            end
        end
    end

    -- Restore HS to its original position""",
    ),
]

# Fix the navigate() custom_qa plugin block similarly
bottombar_navigate_plugin_fix = [
    (
        "Fix plugin method resolution in navigate() custom_qa block",
        """\
            elseif cfg.plugin_key and cfg.plugin_method and cfg.plugin_key ~= "" then
                local plugin_inst = fm and fm.menu_items and fm[cfg.plugin_key]
                if plugin_inst and type(plugin_inst[cfg.plugin_method]) == "function" then
                    local ok, err = pcall(function() plugin_inst[cfg.plugin_method](plugin_inst) end)
                    if not ok then showUnavailable(string.format(_("Plugin error: %s"), tostring(err))) end
                else
                    showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
                end
            elseif cfg.collection and cfg.collection ~= "" then""",
        """\
            elseif cfg.plugin_key and cfg.plugin_key ~= "" then
                local plugin_inst = fm and fm[cfg.plugin_key]
                if plugin_inst then
                    local methods_to_try = {}
                    if cfg.plugin_method and cfg.plugin_method ~= "" then
                        methods_to_try[#methods_to_try+1] = cfg.plugin_method
                    end
                    for _, m in ipairs({"onShow","show","open","onOpen","launch",
                            "onSearchBooks","onShowStore","onShowTextEditor"}) do
                        methods_to_try[#methods_to_try+1] = m
                    end
                    local called = false
                    for _, m in ipairs(methods_to_try) do
                        if type(plugin_inst[m]) == "function" then
                            local ok, err = pcall(function() plugin_inst[m](plugin_inst) end)
                            if not ok then
                                showUnavailable(string.format(_("Plugin error: %s"), tostring(err)))
                            end
                            called = true; break
                        end
                    end
                    if not called then
                        showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
                    end
                else
                    showUnavailable(string.format(_("Plugin not available: %s"), cfg.plugin_key))
                end
            elseif cfg.collection and cfg.collection ~= "" then""",
    ),
]


def main():
    print("=== SimpleUI Plugin Patcher ===\n")
    print("Patching sui_config.lua ...")
    patch_file("sui_config.lua", config_patches)

    print("\nPatching sui_bottombar.lua ...")
    patch_file("sui_bottombar.lua",
        bottombar_patches +
        bottombar_navigate_patches +
        bottombar_plugin_fix_patches +
        bottombar_navigate_plugin_fix
    )

    print("\nPatching sui_menu.lua ...")
    patch_file("sui_menu.lua", menu_patches)

    print("\nDone! Restart KOReader to apply changes.")
    print("Backup files created with .bak extension.")


if __name__ == "__main__":
    main()
