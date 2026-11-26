-- Central hook management to avoid monkey-patching fragility
-- This module provides a safe way for multiple components to hook into UIManager methods
-- luacheck: globals unpack

local UIManager = require("ui/uimanager")
local logger = require("logger")

-- Portable fallback for table.pack/table.unpack (Lua 5.2 compat)
-- LuaJIT may not have these if built without compat flag
local pack = table.pack or function(...) return { n = select("#", ...), ... } end
local unpack = table.unpack or unpack

local Hooks = {}

-- Store the original function and registered callbacks
local hook_registry = {}

--- Register a function name to be hooked into UIManager
-- Should be called once per function to initialize the hook
-- @param func_name string: Name of the UIManager function (e.g., "ToggleNightMode")
-- @return boolean: true if hook was set up, false if method not found, nil if already set up
local function setupHook(func_name)
    if hook_registry[func_name] then
        return nil -- Already set up
    end

    local original_func = UIManager[func_name]
    if not original_func then
        logger.warn("Hooks: UIManager." .. func_name .. " not found, skipping hook setup")
        hook_registry[func_name] = { failed = true } -- Mark as failed to avoid re-logging
        return false
    end

    hook_registry[func_name] = {
        original = original_func,
        callbacks = {},
    }

    -- Replace the original function with one that calls all registered callbacks
    UIManager[func_name] = function(self, ...)
        local entry = hook_registry[func_name]
        -- Call the original function first and preserve its return values
        local results = pack(entry.original(self, ...))

        -- Then call all registered callbacks in order, with error isolation
        for _, callback in ipairs(entry.callbacks) do
            local ok, err = pcall(callback, self, ...)
            if not ok then
                logger.warn("Hooks: " .. func_name .. " callback failed:", err)
            end
        end

        -- Return the original function's results
        return unpack(results, 1, results.n)
    end

    return true
end

--- Register a callback to be called when a hooked function is invoked
-- @param func_name string: Name of the UIManager function (e.g., "ToggleNightMode")
-- @param callback function: Function to call when the hooked function is invoked
--                          receives (self, ...) as arguments
-- @return function or nil: The registered callback if hook was set up successfully,
--                         nil if the method doesn't exist on this KOReader version
function Hooks.register(func_name, callback)
    if not hook_registry[func_name] then
        local ok = setupHook(func_name)
        if ok == false then
            return nil -- Method not found, hook not installed
        end
    elseif hook_registry[func_name].failed then
        return nil -- Previous setup failed, don't try again
    end

    table.insert(hook_registry[func_name].callbacks, callback)
    return callback
end

--- Unregister a callback from a hooked function
-- @param func_name string: Name of the UIManager function (e.g., "ToggleNightMode")
-- @param callback function: The callback to remove
function Hooks.unregister(func_name, callback)
    local entry = hook_registry[func_name]
    if not entry or entry.failed then
        return
    end

    for i, cb in ipairs(entry.callbacks) do
        if cb == callback then
            table.remove(entry.callbacks, i)
            break
        end
    end
end

return Hooks
