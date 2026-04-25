-- File transfer progress screen. One screen for both roles — the state
-- machine matches the bus events the service emits.
--
-- Push with initial_state(role, xfer_id, extra), where extra carries
-- the static info we want to display: peer name, file name, size.
--
-- Role "tx": initiated by the file manager's Transfer action. extra
-- includes {peer_name, name, size, chunks}.
--
-- Role "rx": entered from the file manager's "Receive file here"
-- action (shown from the global menu). Starts in a waiting state and
-- populates real info once file/offer fires.

local ui = require("ezui")

local FileTransfer = { title = "Transfer" }

function FileTransfer.initial_state(role, xfer_id, extra)
    extra = extra or {}
    return {
        role         = role,             -- "tx" or "rx"
        xfer_id      = xfer_id,
        peer_name    = extra.peer_name or "?",
        file_name    = extra.name or (role == "rx" and "(waiting)" or "?"),
        size         = extra.size or 0,
        chunks_total = extra.chunks or 0,
        chunks_done  = 0,
        bytes        = 0,
        status       = role == "tx"
                       and "Sending offer..."
                       or "Waiting for incoming file...",
        finished     = false,
        error        = nil,
    }
end

local function fmt_size(bytes)
    if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
    if bytes >= 1024    then return string.format("%.1f KB", bytes / 1024)    end
    return bytes .. " B"
end

function FileTransfer:build(state)
    local pct = 0
    if state.size > 0 then
        pct = math.min(1, state.bytes / state.size)
    end

    local title = state.role == "tx" and "Sending" or "Receiving"

    local rows = {
        ui.padding({ 10, 10, 4, 10 },
            ui.text_widget(state.file_name, {
                font = "medium_aa", style = "bold", color = "TEXT",
            })
        ),
        ui.padding({ 0, 10, 6, 10 },
            ui.text_widget(
                (state.role == "tx" and "to " or "from ")
                    .. tostring(state.peer_name),
                { font = "small_aa", color = "TEXT_SEC" }
            )
        ),
        ui.padding({ 4, 10, 8, 10 }, ui.progress(pct, { height = 6 })),
        ui.padding({ 0, 10, 4, 10 },
            ui.text_widget(
                fmt_size(state.bytes) .. " / " .. fmt_size(state.size)
                .. "   " .. state.chunks_done .. " / "
                .. state.chunks_total .. " chunks",
                { font = "tiny_aa", color = "TEXT_MUTED" }
            )
        ),
        ui.padding({ 8, 10, 4, 10 },
            ui.text_widget(
                state.error and ("Error: " .. state.error) or state.status,
                {
                    font  = "small_aa",
                    color = state.error and "ERROR"
                            or state.finished and "SUCCESS"
                            or "TEXT_SEC",
                    wrap  = true,
                }
            )
        ),
    }

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar(title, { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows)),
    })
end

function FileTransfer:on_enter()
    local this = self

    -- New incoming offer — only relevant to the receiver screen.
    -- Populate the display with real metadata.
    self._sub_offer = ez.bus.subscribe("file/offer", function(_, m)
        if this._state.role ~= "rx" then return end
        if this._state.xfer_id and this._state.xfer_id ~= m.xfer_id then return end
        -- Surface the rename so the user knows why the on-disk name
        -- differs from what the sender typed. The file/done event
        -- will carry the full target path too.
        local status = "Receiving..."
        if m.renamed then
            status = "Saving as " .. m.name .. " (original exists)"
        end
        this:set_state({
            xfer_id      = m.xfer_id,
            file_name    = m.name,
            size         = m.size,
            chunks_total = m.chunks,
            peer_name    = m.sender_name or this._state.peer_name,
            status       = status,
        })
    end)

    self._sub_prog = ez.bus.subscribe("file/progress", function(_, m)
        if m.xfer_id ~= this._state.xfer_id then return end
        -- Progress events come from both sides; show whichever applies
        -- to us (role matched).
        if m.role ~= this._state.role then return end
        this:set_state({
            bytes        = m.bytes,
            chunks_done  = m.chunks_done,
            chunks_total = m.chunks_total,
            status       = this._state.role == "tx" and "Sending..." or "Receiving...",
        })
    end)

    self._sub_done = ez.bus.subscribe("file/done", function(_, m)
        if m.xfer_id ~= this._state.xfer_id then return end
        if m.role ~= this._state.role then return end
        this:set_state({
            finished = true,
            bytes    = m.bytes or this._state.size,
            status   = this._state.role == "tx"
                       and "Sent — press Back to return"
                       or ("Saved to " .. tostring(m.path)),
        })
    end)

    self._sub_err = ez.bus.subscribe("file/error", function(_, m)
        if m.xfer_id and m.xfer_id ~= this._state.xfer_id then return end
        this:set_state({ error = m.error or "unknown" })
    end)
end

function FileTransfer:on_leave()
    if self._sub_offer then ez.bus.unsubscribe(self._sub_offer); self._sub_offer = nil end
    if self._sub_prog  then ez.bus.unsubscribe(self._sub_prog);  self._sub_prog  = nil end
    if self._sub_done  then ez.bus.unsubscribe(self._sub_done);  self._sub_done  = nil end
    if self._sub_err   then ez.bus.unsubscribe(self._sub_err);   self._sub_err   = nil end
end

function FileTransfer:on_exit()
    self:on_leave()
    -- If the user backs out mid-send, cancel the outbound. Inbound
    -- receivers stay armed on a per-service basis; backing out just
    -- means no UI listener for the remainder but the file keeps
    -- saving.
    if self._state.role == "tx"
            and not self._state.finished
            and self._state.xfer_id then
        require("services.file_transfer").cancel(self._state.xfer_id)
    end
end

function FileTransfer:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return FileTransfer
