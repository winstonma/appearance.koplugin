local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiutil = require("ffi/util")

require("ffi/posix_h")

local POLL_INTERVAL = 1       -- In seconds
local RESTART_MIN_DELAY = 2   -- In seconds, doubles on each consecutive failure
local RESTART_MAX_DELAY = 60
local STABLE_AFTER = 30       -- A child that lived this long resets the backoff
local MAX_FAST_FAILURES = 5   -- Then give up (gdbus missing, no session bus)

local MONITOR_CMD = "exec gdbus monitor --session "
    .. "--dest org.freedesktop.portal.Desktop "
    .. "--object-path /org/freedesktop/portal/desktop 2>/dev/null"

local ThemeWatcher = { pid = nil, fd = nil, buf = "", running = false }

-- on_change(is_dark): called on each color-scheme change.
-- on_stopped(had_worked): optional, called if the watcher gives up on its own.
-- had_worked is true if it delivered an event or a child stayed up for a while.
function ThemeWatcher:start(on_change, on_stopped)
    if self.running then return true end
    self.on_change = on_change
    self.on_stopped = on_stopped
    self.failures = 0
    self.has_worked = false
    self._tick_fn = function() self:_tick() end
    self._restart_fn = function() self:_restart() end
    self.running = true
    if not self:_spawn() then
        self.running = false
        return false
    end
    return true
end

function ThemeWatcher:_spawn()
    self.buf = ""
    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local p = io.popen(MONITOR_CMD, "r")
        if not p then return end
        for line in p:lines() do
            -- ... SettingChanged ('org.freedesktop.appearance', 'color-scheme', <uint32 1>)
            local v = line:match("color%-scheme.-uint32 (%d)")
            if v then
                ffiutil.writeToFD(write_fd, v .. "\n")
            end
        end
        p:close()
    end, true) -- true = create a pipe

    if not pid then return false end
    self.pid, self.fd = pid, read_fd
    self.spawned_at = os.time()
    UIManager:scheduleIn(POLL_INTERVAL, self._tick_fn)
    return true
end

function ThemeWatcher:_drain()
    local n = ffiutil.getNonBlockingReadSize(self.fd)
    if not (n and n > 0) then return end
    local buf = ffi.new("char[?]", n)
    local got = tonumber(ffi.C.read(self.fd, buf, n))
    if got and got > 0 then
        self.buf = self.buf .. ffi.string(buf, got)
        -- Process complete lines, keep any partial remainder
        for line in self.buf:gmatch("([^\n]*)\n") do
            self.has_worked = true
            self.on_change(line == "1") -- true = dark
            if not self.running then break end -- on_change may have called stop()
        end
        self.buf = self.buf:match("[^\n]*$")
    end
end

function ThemeWatcher:_tick()
    if not self.running then return end

    self:_drain()
    if not self.running then return end -- on_change may have called stop()

    if ffiutil.isSubProcessDone(self.pid) then
        self:_drain() -- The child may have written just before exiting
        if not self.running then return end
        self:_child_exited()
        return
    end

    UIManager:scheduleIn(POLL_INTERVAL, self._tick_fn)
end

function ThemeWatcher:_child_exited()
    -- The child is already reaped, so just release the fd.
    ffi.C.close(self.fd)
    self.pid, self.fd = nil, nil

    if os.time() - self.spawned_at >= STABLE_AFTER then
        self.failures = 0
        self.has_worked = true
    end
    self.failures = self.failures + 1

    if self.failures >= MAX_FAST_FAILURES then
        self:_give_up()
        return
    end

    local delay = math.min(RESTART_MIN_DELAY * 2 ^ (self.failures - 1), RESTART_MAX_DELAY)
    UIManager:scheduleIn(delay, self._restart_fn)
end

function ThemeWatcher:_restart()
    if not self.running then return end
    if not self:_spawn() then
        self:_give_up()
    end
end

function ThemeWatcher:_give_up()
    self.running = false
    if self.on_stopped then self.on_stopped(self.has_worked) end
end

function ThemeWatcher:stop()
    if not self.running then return end
    self.running = false
    UIManager:unschedule(self._tick_fn)
    UIManager:unschedule(self._restart_fn)
    if self.pid then
        ffiutil.terminateSubProcess(self.pid)
        ffi.C.close(self.fd)
        self.pid, self.fd = nil, nil
    end
end

return ThemeWatcher
