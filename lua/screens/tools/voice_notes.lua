-- Voice notes: record short WAV clips to /sd/recordings/ and play
-- them back. Recording uses the onboard ES7210 codec (see
-- audio/mic.cpp on the firmware side); playback reuses
-- ez.audio.play_wav which already understands 16-bit mono.
--
-- Keys:
--   ENTER on a clip       -> play
--   M                     -> per-clip actions menu (play, delete)
--   alt+R / MIC side key  -> toggle record
--   BACKSPACE             -> back

local ui          = require("ezui")
local theme       = require("ezui.theme")
local screen_mod  = require("ezui.screen")

local Voice = { title = "Voice notes" }

-- ez.storage.list_dir treats "/sd/recordings/" (trailing slash) and
-- "/sd/recordings" differently: the slashy form returns 0 entries on
-- the SD-card mount, while the non-slashy form returns the real
-- contents. Build the directory path without a trailing slash and
-- glue the slash on only when joining a filename.
local REC_DIR  = "/sd/recordings"
local REC_FILE = REC_DIR .. "/"

local function format_size(bytes)
    if bytes >= 1048576 then
        return string.format("%.1f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return bytes .. " B"
    end
end

local function ensure_dir()
    -- list_dir on a missing path returns nil; mkdir is idempotent.
    local entries = ez.storage.list_dir(REC_DIR)
    if not entries then
        ez.storage.mkdir(REC_DIR)
    end
end

local function load_clips()
    ensure_dir()
    local entries = ez.storage.list_dir(REC_DIR) or {}
    local clips = {}
    for _, e in ipairs(entries) do
        if not e.is_dir and e.name:lower():match("%.wav$") then
            clips[#clips + 1] = {
                name = e.name,
                path = REC_FILE .. e.name,
                size = e.size or 0,
            }
        end
    end
    -- Newest first (filenames embed a sortable timestamp).
    table.sort(clips, function(a, b) return a.name > b.name end)
    return clips
end

local function next_clip_path()
    -- Prefer a wall-clock filename so the clip list stays sorted in
    -- recording order. If the clock hasn't been set yet (no NTP, no
    -- RTC) fall back to a millisecond counter so a fresh boot still
    -- produces unique names.
    local t = ez.system.get_time()
    if t and t.year then
        return string.format("%snote_%04d%02d%02d_%02d%02d%02d.wav",
            REC_FILE,
            t.year, t.month, t.day, t.hour, t.minute, t.second)
    end
    return string.format("%snote_boot_%010d.wav", REC_FILE, ez.system.millis())
end

local function show_clip_menu(self, clip)
    local MenuDef = { title = clip.name }

    function MenuDef:build(state)
        local items = {}
        items[#items + 1] = ui.title_bar(clip.name, { back = true })
        local actions = {
            ui.list_item({
                title = "Play",
                on_press = function()
                    screen_mod.pop()
                    ez.audio.play_wav(clip.path)
                end,
            }),
            ui.list_item({
                title = "Delete",
                subtitle = "Remove this clip",
                on_press = function()
                    ez.storage.remove(clip.path)
                    screen_mod.pop()
                    self:set_state({ clips = load_clips() })
                end,
            }),
            ui.list_item({
                title = format_size(clip.size),
                disabled = true,
            }),
        }
        items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, actions))
        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function MenuDef:handle_key(k)
        if k.special == "BACKSPACE" or k.special == "ESCAPE" or k.character == "q" then
            return "pop"
        end
        return nil
    end

    screen_mod.push(screen_mod.create(MenuDef, {}))
end

local function start_record(self)
    if ez.audio.is_recording() then return end
    if not ez.audio.mic_available() then
        require("services.notifications").post({
            title = "No microphone",
            body  = "ES7210 not detected on this device.",
            source = "voice_notes",
            ttl_ms = 3000,
        })
        return
    end
    local path = next_clip_path()
    if not ez.audio.record(path, { sample_rate = 16000, gain_db = 24 }) then
        require("services.notifications").post({
            title = "Recording failed",
            body  = "Could not start capture",
            source = "voice_notes",
            ttl_ms = 3000,
        })
        return
    end
    self:set_state({
        recording      = true,
        recording_path = path,
        record_started = ez.system.millis(),
    })
end

local function stop_record(self)
    if not ez.audio.is_recording() then return end
    local bytes = ez.audio.stop_record()
    self:set_state({
        recording      = false,
        recording_path = nil,
        record_started = nil,
        clips          = load_clips(),
    })
    if not bytes or bytes == 0 then
        require("services.notifications").post({
            title = "Empty clip",
            body  = "No audio captured",
            source = "voice_notes",
            ttl_ms = 3000,
        })
    end
end

function Voice:initial_state()
    return { clips = load_clips(), recording = false }
end

function Voice:on_enter()
    self:set_state({ clips = load_clips() })
    local me = self
    -- Tick twice a second while recording so the timer label updates.
    -- invalidate() repaints the existing tree; we need _rebuild() so
    -- build() runs again and recomputes the "Recording... N s" text
    -- from the live millis() delta.
    self._tick = ez.system.set_interval(500, function()
        if me._state and me._state.recording then
            me:_rebuild()
            require("ezui.screen").invalidate()
        end
    end)
    -- Listen for the MIC side key. We grab it at the screen level so
    -- the on-screen "Record" button doesn't need focus.
    self._mic_sub = ez.bus.subscribe("key/down", function(_, k)
        if not k then return end
        if k.special == "MIC" then
            if me._state.recording then
                stop_record(me)
            else
                start_record(me)
            end
        end
    end)
end

function Voice:on_exit()
    if self._tick then
        ez.system.cancel_timer(self._tick)
        self._tick = nil
    end
    if self._mic_sub then
        ez.bus.unsubscribe(self._mic_sub)
        self._mic_sub = nil
    end
    -- Make sure we don't strand the codec/I2S if the user backs out
    -- mid-record.
    if ez.audio.is_recording() then
        ez.audio.stop_record()
    end
end

function Voice:build(state)
    local items = {}
    items[#items + 1] = ui.title_bar("Voice notes", { back = true })

    -- Status / record bar.
    local me = self
    local status
    if state.recording then
        local secs = math.max(0,
            math.floor((ez.system.millis() - (state.record_started or 0)) / 1000))
        status = ui.padding({ 8, 8, 8, 8 },
            ui.vbox({ gap = 4 }, {
                ui.text_widget(string.format("Recording... %d s", secs),
                    { color = "ERROR" }),
                ui.text_widget("Press MIC or Enter to stop",
                    { color = "TEXT_MUTED", font = "small_aa" }),
            })
        )
    else
        status = ui.padding({ 8, 8, 8, 8 },
            ui.button("Record", {
                on_press = function() start_record(me) end,
            })
        )
    end
    items[#items + 1] = status

    local clips = state.clips or {}
    if #clips == 0 then
        items[#items + 1] = ui.padding({ 16, 12, 12, 12 },
            ui.text_widget(
                "No recordings yet. Press Record (or the MIC side key) to capture.",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )
    else
        local rows = {}
        for _, c in ipairs(clips) do
            local clip = c
            rows[#rows + 1] = ui.list_item({
                title    = clip.name,
                subtitle = format_size(clip.size),
                _clip    = clip,
                on_press = function()
                    if state.recording then
                        stop_record(me)
                    else
                        ez.audio.play_wav(clip.path)
                    end
                end,
            })
        end
        items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows))
    end

    items[#items + 1] = ui.padding({ 4, 8, 2, 8 },
        ui.text_widget("MIC: toggle record  |  M: actions",
            { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Voice:handle_key(key)
    -- Alt+R as a keyboard alternative to the MIC side key.
    if key.alt and (key.character == "r" or key.character == "R") then
        if self._state.recording then stop_record(self) else start_record(self) end
        return "handled"
    end
    -- ENTER while recording: stop. We only intercept it here because
    -- the on-screen Record button (which lives in the focus chain
    -- while idle) already handles ENTER to *start* a recording; once
    -- recording begins the button is gone and ENTER would otherwise
    -- fall through with nothing to do.
    if key.special == "ENTER" and self._state.recording then
        stop_record(self)
        return "handled"
    end
    if key.character == "m" or key.character == "M" then
        local focus_mod = require("ezui.focus")
        local n = focus_mod.current()
        if n and n._clip then
            show_clip_menu(self, n._clip)
            return "handled"
        end
    end
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Voice
