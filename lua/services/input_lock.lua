-- Input lock service
--
-- Global input gate toggled by Shift+Alt+L (lock) / Shift+Alt+U (unlock).
-- While locked, the keyboard and touch input layers swallow every event
-- except the unlock chord, so a T-Deck Plus put into a pocket or bag
-- can't fire random keypresses or stray touches at the UI. Background
-- services (mesh, GPS, notifications) keep running -- this is purely an
-- input-layer filter, not a sleep/standby mode.
--
-- State is in-memory only and reset to "unlocked" on every boot, to
-- avoid the soft-brick failure mode where a regression in the chord
-- path leaves the device permanently locked across reboots.
--
-- Posts `input_lock/changed` on the bus with `{ locked = bool }` every
-- time the state flips, so anything that wants to react (dim the
-- backlight, suppress sounds, etc.) can subscribe.

local M = {}

local locked = false

function M.is_locked()
    return locked
end

function M.set(new_locked)
    new_locked = new_locked and true or false
    if new_locked == locked then return end
    locked = new_locked
    if ez and ez.bus and ez.bus.post then
        ez.bus.post("input_lock/changed", { locked = locked })
    end
    if ez and ez.log then
        ez.log(locked and "[InputLock] locked" or "[InputLock] unlocked")
    end
end

function M.toggle()
    M.set(not locked)
end

return M
