-- Direct message conversation screen
-- Shows chat bubbles for a specific contact with text input for sending.
-- Pass contact via initial state: { contact_key = "ABCDEF..." }

local ui = require("ezui")
local dm_svc = require("services.direct_messages")
local contacts_svc = require("services.contacts")
local channels_svc = require("services.channels")
local sharing_svc = require("services.sharing")
local time_share = require("screens.chat.time_share")
local reactions_svc = require("services.reactions")
local cal_share = require("screens.chat.cal_share")
require("screens.chat.chat_common")  -- registers chat_bubble node type

local screen_mod = require("ezui.screen")

-- Build the share-specific menu items for an inbound message whose
-- text contains an ezme.sh share URL. Returns a list of list_item
-- nodes, possibly empty. Self-sent shares get a non-actionable status
-- line (you can't accept your own contact share); incoming shares get
-- the prominent Add/Join action with up-front decoding so the menu
-- can show the actual channel name and gracefully disable already-
-- joined / undecryptable invites.
local function build_share_actions(msg, sender_pub_key_hex)
    local share = sharing_svc.parse(msg.text or "")
    if not share then return {} end

    local out = {}

    if share.kind == "contact" then
        local already = contacts_svc.is_contact(share.pub_key_hex)
        local label = share.name and share.name ~= "" and share.name or share.pub_key_hex:sub(1, 8)
        if msg.is_self then
            out[#out + 1] = ui.list_item({
                title = "Shared contact: " .. label,
                subtitle = "Sent in this message",
                disabled = true,
            })
        elseif already then
            out[#out + 1] = ui.list_item({
                title = label .. " is already a contact",
                disabled = true,
            })
        else
            out[#out + 1] = ui.list_item({
                title = "Add " .. label .. " to contacts",
                subtitle = share.pub_key_hex:sub(1, 12) .. "...",
                on_press = function()
                    local dialog = require("ezui.dialog")
                    dialog.confirm({
                        title = "Add contact?",
                        message = "Add " .. label .. " to your contacts?",
                        ok_label = "Add",
                        cancel_label = "Cancel",
                    }, function()
                        contacts_svc.add(share.pub_key_hex, share.name)
                        screen_mod.pop()
                    end)
                end,
            })
        end
        return out
    end

    if share.kind == "channel_invite" then
        if msg.is_self then
            out[#out + 1] = ui.list_item({
                title = "Shared channel invite",
                subtitle = "Sent in this message",
                disabled = true,
            })
            return out
        end

        -- Need the sender's pubkey to derive the shared secret. The DM
        -- service stamps `sender_key` on inbound messages; if the
        -- candidate isn't a known contact we can't decrypt anyway.
        local invite, err = sharing_svc.decode_channel_invite(share.token, sender_pub_key_hex)
        if not invite then
            out[#out + 1] = ui.list_item({
                title = "Channel invite (cannot open)",
                subtitle = err or "decrypt failed",
                disabled = true,
            })
            return out
        end

        if channels_svc.is_joined(invite.name) then
            out[#out + 1] = ui.list_item({
                title = "Already in channel '" .. invite.name .. "'",
                disabled = true,
            })
            -- Don't burn the nonce on a no-op accept; user might still
            -- want to redeem on a different device with the same
            -- identity.
            return out
        end

        out[#out + 1] = ui.list_item({
            title = "Join channel '" .. invite.name .. "'",
            subtitle = "Invited by " .. (msg.sender_name or "contact"),
            on_press = function()
                local dialog = require("ezui.dialog")
                dialog.confirm({
                    title = "Join channel?",
                    message = "Join '" .. invite.name .. "'?",
                    ok_label = "Join",
                    cancel_label = "Cancel",
                }, function()
                    channels_svc.join(invite.name, invite.password)
                    screen_mod.pop()
                end)
            end,
        })
        return out
    end

    return out
end

-- Context menu shown when pressing Enter on a chat bubble
local function show_context_menu(self, key, msg, msg_index)
    local MenuDef = { title = "Message" }

    function MenuDef:build(state)
        local items = {}
        local preview = msg.text or ""
        if #preview > 30 then preview = preview:sub(1, 27) .. "..." end

        items[#items + 1] = ui.title_bar(preview, { back = true })

        local actions = {}

        -- Share actions are shown first because they're the user's
        -- intent on opening the menu for a share-bearing bubble; the
        -- generic "Repeat Send" / "Delete" actions stay visible below.
        -- The sender pubkey is the conversation key for inbound
        -- messages and our own pubkey for self-sent ones; the inbound
        -- case needs the contact's key to derive the shared secret
        -- that decrypts channel-invite tokens.
        local share_sender_key = msg.is_self and ez.mesh.get_public_key_hex() or key
        for _, item in ipairs(build_share_actions(msg, share_sender_key)) do
            actions[#actions + 1] = item
        end

        for _, item in ipairs(time_share.build_actions(msg)) do
            actions[#actions + 1] = item
        end

        -- React to this message. Picker pops itself before invoking
        -- reactions.send, so the user lands back on this conversation
        -- with the freshly recorded reaction already painted on the
        -- target bubble. The target message's hash is computed from
        -- the sender's pubkey (theirs if inbound, ours if self-sent)
        -- + timestamp + text -- both peers can reproduce it without
        -- extra wire bits.
        do
            local target_sender = msg.is_self
                and ez.mesh.get_public_key_hex() or key
            local target_hash = reactions_svc.compute_msg_hash(
                target_sender, msg.timestamp, msg.text)
            if target_hash then
                actions[#actions + 1] = ui.list_item({
                    title = "React...",
                    subtitle = "Send a quick reaction",
                    on_press = function()
                        local Picker = require("screens.chat.reactions_picker")
                        local state = Picker.initial_state(key, target_hash, msg.text)
                        screen_mod.pop()  -- close context menu first
                        screen_mod.push(screen_mod.create(Picker, state))
                    end,
                })
            end
        end

        for _, item in ipairs(cal_share.build_actions(msg)) do
            actions[#actions + 1] = item
        end

        if msg.is_self and (msg.status == "failed" or msg.status == "unconfirmed") then
            actions[#actions + 1] = ui.list_item({
                title = "Retry Send",
                subtitle = "Resend this message",
                on_press = function()
                    dm_svc.send(key, msg.text)
                    screen_mod.pop()
                end,
            })
        end

        if msg.is_self then
            actions[#actions + 1] = ui.list_item({
                title = "Status: " .. (msg.status or "sent"),
                disabled = true,
            })
        end

        if not msg.is_self then
            local sender_name = msg.sender_name or "?"
            local count = msg.count or 1
            -- See channel_chat.lua for the rationale on the count > 1
            -- branch -- mirrored here so DM bubbles get the same
            -- repeat-count + RSSI/hops/SNR ranges when the same DM was
            -- relayed by multiple repeaters.
            if count > 1 then
                actions[#actions + 1] = ui.list_item({
                    title = "From: " .. sender_name
                        .. " (" .. count .. " repeats)",
                    disabled = true,
                })
                if msg.rssi_min and msg.rssi_max then
                    actions[#actions + 1] = ui.list_item({
                        title = string.format("RSSI: %d..%d dBm",
                            math.floor(msg.rssi_min),
                            math.floor(msg.rssi_max)),
                        disabled = true,
                    })
                end
                if msg.hops_min and msg.hops_max then
                    actions[#actions + 1] = ui.list_item({
                        title = string.format("Hops: %d..%d",
                            msg.hops_min, msg.hops_max),
                        disabled = true,
                    })
                end
                if msg.snr_min and msg.snr_max then
                    actions[#actions + 1] = ui.list_item({
                        title = string.format("SNR:  %.1f..%.1f dB",
                            msg.snr_min, msg.snr_max),
                        disabled = true,
                    })
                end
            else
                local rssi_str = msg.rssi and
                    string.format("%d dBm", math.floor(msg.rssi))
                    or "unknown"
                actions[#actions + 1] = ui.list_item({
                    title = "From: " .. sender_name,
                    subtitle = "Signal: " .. rssi_str,
                    disabled = true,
                })
            end
        end

        if msg.is_self then
            actions[#actions + 1] = ui.list_item({
                title = "Repeat Send",
                subtitle = "Send this text again",
                on_press = function()
                    dm_svc.send(key, msg.text)
                    screen_mod.pop()
                end,
            })
        end

        actions[#actions + 1] = ui.list_item({
            title = "Delete Message",
            subtitle = "Remove from history",
            on_press = function()
                dm_svc.delete_message(key, msg_index)
                screen_mod.pop()
            end,
        })

        local content = ui.vbox({ gap = 0 }, actions)
        items[#items + 1] = ui.scroll({ grow = 1 }, content)

        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function MenuDef:handle_key(k)
        if k.character == "q" or k.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    local inst = screen_mod.create(MenuDef, {})
    screen_mod.push(inst)
end

local DMConversation = { title = "Chat" }

-- Find the scroll node inside an already-built tree. Returns nil if the
-- tree hasn't been built yet.
local function find_scroll(node)
    if not node then return nil end
    if node.type == "scroll" then return node end
    if node.children then
        for _, c in ipairs(node.children) do
            local s = find_scroll(c)
            if s then return s end
        end
    end
    return nil
end

-- Pin the scroll viewport to the most recent message. ezui persists
-- scroll_offset across rebuilds (see _PERSISTENT_FIELDS in
-- ezui/screen.lua), which normally keeps the viewport stable but here
-- overrides the build()-time `scroll_offset = 99999` — so we reach in
-- after the rebuild and set the live node directly. The scroll node
-- clamps the value to max_scroll on draw.
local function stick_to_bottom(inst)
    local s = find_scroll(inst._tree)
    if s then s.scroll_offset = 99999 end
    require("ezui.screen").invalidate()
end

-- Build the per-bubble share descriptor used by chat_common's
-- card-style render path. Returns nil for plain text. Decoded
-- channel-invite results are cached in self._share_cache because
-- decode_channel_invite runs an X25519 derive (~30 ms) we don't want
-- to repeat on every rebuild -- the cache is keyed by the token
-- string so a successful decode survives across redraws and even
-- across redemption-state changes (the ezme.sh URL never mutates).
function DMConversation:_share_for_message(msg, sender_pub_key_hex)
    -- Time shares don't need sender key decryption
    local ts_card = time_share.card_for_message(msg)
    if ts_card then return ts_card end

    local cal_card = cal_share.card_for_message(msg)
    if cal_card then return cal_card end

    local share = sharing_svc.parse(msg.text or "")
    if not share then return nil end

    if share.kind == "contact" then
        local label = (share.name and share.name ~= "")
            and share.name or share.pub_key_hex:sub(1, 8)
        local hint, disabled
        if msg.is_self then
            hint = "Sent in this message"
            disabled = true
        elseif contacts_svc.is_contact(share.pub_key_hex) then
            hint = "Already in contacts"
            disabled = true
        else
            hint = "Tap to add"
            disabled = false
        end
        return {
            kind_label = "CONTACT CARD",
            title = label,
            action_hint = hint,
            disabled = disabled,
        }
    end

    if share.kind == "channel_invite" then
        if msg.is_self then
            return {
                kind_label = "CHANNEL INVITE",
                title = "(invite sent)",
                action_hint = "Sent in this message",
                disabled = true,
            }
        end

        self._share_cache = self._share_cache or {}
        local cached = self._share_cache[share.token]
        if cached == nil then
            local invite, err = sharing_svc.decode_channel_invite(share.token, sender_pub_key_hex)
            cached = invite or { _err = err or "decrypt failed" }
            self._share_cache[share.token] = cached
        end

        if cached._err then
            return {
                kind_label = "CHANNEL INVITE",
                title = "(cannot open)",
                action_hint = cached._err,
                disabled = true,
            }
        end

        local hint, disabled
        if channels_svc.is_joined(cached.name) then
            hint = "Already joined"
            disabled = true
        else
            hint = "Tap to join"
            disabled = false
        end
        return {
            kind_label = "CHANNEL INVITE",
            title = cached.name,
            action_hint = hint,
            disabled = disabled,
        }
    end

    return nil
end

function DMConversation:build(state)
    local key = state.contact_key or ""
    local contact = contacts_svc.get(key)
    local name = contact and contact.name or key:sub(1, 8)
    local items = {}

    items[#items + 1] = ui.title_bar(name, { back = true })

    local msgs = dm_svc.get_history(key)
    local content_items = {}

    if #msgs == 0 then
        content_items[#content_items + 1] = ui.padding({ 20, 10, 10, 10 },
            ui.text_widget("No messages yet", {
                color = "TEXT_MUTED",
                text_align = "center",
            })
        )
        content_items[#content_items + 1] = ui.padding({ 4, 10, 10, 10 },
            ui.text_widget("Type a message below to start chatting.", {
                color = "TEXT_MUTED",
                font = "small_aa",
                text_align = "center",
            })
        )
    else
        -- Sender pubkey for invite decryption: our own for self-sent,
        -- the chat partner's for inbound. (build_share_actions in the
        -- context menu uses the same dispatch.)
        local self_pub = ez.mesh.get_public_key_hex()
        content_items[#content_items + 1] = { type = "spacer", h = 2, grow = 0 }
        for i, msg in ipairs(msgs) do
            local share_sender = msg.is_self and self_pub or key
            local target_sender = msg.is_self and self_pub or key
            local target_hash = reactions_svc.compute_msg_hash(
                target_sender, msg.timestamp, msg.text)
            local reaction_list = target_hash
                and reactions_svc.compress(key, target_hash) or nil
            -- Drop the array when empty so the bubble renderer's
            -- `if n.reactions and #n.reactions > 0` short-circuit holds
            -- without painting a 0-height footer block.
            if reaction_list and #reaction_list == 0 then reaction_list = nil end
            content_items[#content_items + 1] = {
                type = "chat_bubble",
                msg = msg,
                share = self:_share_for_message(msg, share_sender),
                reactions = reaction_list,
                on_press = function()
                    show_context_menu(self, key, msg, i)
                end,
            }
        end
    end

    local content = ui.vbox({ gap = 0 }, content_items)
    items[#items + 1] = ui.scroll({ grow = 1, scroll_offset = state.scroll or 99999 }, content)

    -- Text input bar at bottom
    items[#items + 1] = ui.padding({ 4, 4, 4, 4 },
        ui.text_input({
            value = state.input or "",
            placeholder = "Type a message...",
            on_change = function(val)
                state.input = val
            end,
            on_submit = function(val)
                if val and #val > 0 then
                    dm_svc.send(key, val)
                    self:set_state({ input = "" })
                    stick_to_bottom(self)
                end
            end,
        })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

-- Push a sub-menu that lists candidate items and dispatches `on_pick`
-- with the chosen entry. Reused by both share variants below; both
-- follow the "list of contacts/channels, pick one, fire-and-forget"
-- shape so it's worth abstracting once. The dialog menu pops itself
-- before invoking on_press, so when the user presses Back from this
-- picker they land on DMConversation rather than on a stale parent
-- menu (which we already popped).
local function push_picker(title, items, on_pick)
    local screen_mod = require("ezui.screen")
    local MenuDialog = require("screens.dialog.menu")
    local entries = {}
    for _, item in ipairs(items) do
        entries[#entries + 1] = {
            title = item.title,
            subtitle = item.subtitle,
            on_press = function() on_pick(item.value) end,
        }
    end
    if #entries == 0 then
        entries[#entries + 1] = {
            title = "(nothing to share)",
            disabled = true,
        }
    end
    screen_mod.push(screen_mod.create(MenuDialog,
        MenuDialog.initial_state(entries, title)))
end

-- Top-level Alt+M menu for the DM conversation. Lets the user share a
-- contact card or channel invite with the current chat partner; the
-- chosen item is rendered into an ezme.sh share URL and sent through
-- the regular dm.send pipeline so it flows through the same
-- encryption / ACK / retry path as a normal message bubble.
function DMConversation:menu()
    local key = self._state.contact_key or ""
    local items = {}

    items[#items + 1] = {
        title = "Share a contact...",
        subtitle = "Send one of your contacts to the other side",
        on_press = function()
            local picker = {}
            -- Skip the chat partner themselves -- sharing their own
            -- card back to them is a no-op (they already have their
            -- own pubkey) and just clutters the picker.
            for _, c in ipairs(contacts_svc.get_all()) do
                if c.pub_key_hex ~= key then
                    picker[#picker + 1] = {
                        title = c.name or c.pub_key_hex:sub(1, 8),
                        subtitle = c.pub_key_hex:sub(1, 12) .. "...",
                        value = c,
                    }
                end
            end
            push_picker("Share contact", picker, function(contact)
                local url = sharing_svc.encode_contact(contact.pub_key_hex, contact.name)
                if url then dm_svc.send(key, url) end
            end)
        end,
    }

    items[#items + 1] = {
        title = "Invite to a channel...",
        subtitle = "Send a one-shot invite for one of your channels",
        on_press = function()
            local picker = {}
            for _, ch in ipairs(channels_svc.get_list()) do
                -- #Public has no password and inviting to it is
                -- pointless (every device is already on it). Hidden
                -- channels are still listed -- the user opted in by
                -- joining them, so making them shareable is fine.
                local info = channels_svc.get_info(ch.name)
                if info and info.password and info.password ~= "" then
                    picker[#picker + 1] = {
                        title = ch.name,
                        subtitle = "Invite to this private channel",
                        value = ch.name,
                    }
                end
            end
            push_picker("Invite to channel", picker, function(channel_name)
                local info = channels_svc.get_info(channel_name)
                if not info then return end
                local url, err = sharing_svc.encode_channel_invite(key, channel_name, info.password)
                if url then
                    dm_svc.send(key, url)
                else
                    -- Surface the failure as a chat-bubble-shaped
                    -- system message so the user knows the invite
                    -- didn't go out. dm.send only delivers if the
                    -- text is small enough; for invite errors we
                    -- post directly to the bus.
                    ez.bus.post("dm/message", {
                        sender_key = key,
                        sender_name = "system",
                        text = "Invite failed: " .. (err or "unknown"),
                        timestamp = ez.system.millis(),
                        is_self = false,
                    })
                end
            end)
        end,
    }

    items[#items + 1] = {
        title = "Share time",
        subtitle = "Send your current clock to sync",
        on_press = function()
            local url, err = sharing_svc.encode_time()
            if url then
                dm_svc.send(key, url)
            end
        end,
    }

    items[#items + 1] = {
        title = "Attach event...",
        subtitle = "Build a cal/v1 meetup invite",
        on_press = function()
            local Compose = require("screens.chat.event_compose")
            local inst = screen_mod.create(Compose,
                Compose.initial_state({
                    on_submit = function(url)
                        dm_svc.send(key, url)
                    end,
                }))
            screen_mod.push(inst)
        end,
    }

    return items
end

function DMConversation:on_enter()
    local key = self._state.contact_key or ""
    dm_svc.mark_read(key)

    -- screen.push calls on_enter BEFORE the first _rebuild, so the
    -- focus chain is still empty at this point. Force a rebuild now so
    -- we can target the text input directly — the subsequent rebuild
    -- inside screen.push() preserves focus.index as long as it stays
    -- within bounds, so our choice sticks.
    self:_rebuild()

    -- Land the user directly at the compose box so typing a reply needs
    -- zero setup keystrokes. Focus the last focusable node (the text
    -- input, since chat bubbles precede it in the tree) and flip the
    -- global edit flag so keystrokes route into the input immediately.
    local focus_mod = require("ezui.focus")
    if #focus_mod.chain > 0 then
        focus_mod.index = #focus_mod.chain
        focus_mod._update_marks()
        focus_mod.enter_edit()
    end

    -- Snap the scroll to the most recent message. The initial rebuild
    -- above populated self._tree; reach into it directly because the
    -- scroll-offset persistence mechanism would otherwise preserve any
    -- stale offset from a previous screen instance.
    stick_to_bottom(self)

    -- set_state({}) would normally do here, but it defers the rebuild
    -- when focus.editing is true (so widgets with internal state -- our
    -- text input -- aren't disrupted). For chat history that's exactly
    -- the wrong tradeoff: a freshly arrived (or freshly sent) bubble
    -- would not appear until the user moved focus out of the compose
    -- box, leaving "where did my share invite go?" gaps. The text
    -- input's cursor and value are preserved across rebuilds via
    -- _PERSISTENT_FIELDS + the state.input round-trip, so a forced
    -- rebuild is safe.
    local screen = require("ezui.screen")
    self._sub = ez.bus.subscribe("dm/message", function(topic, msg)
        if msg and (msg.sender_key == key or msg.is_self) then
            self:_rebuild()
            stick_to_bottom(self)
            screen.invalidate()
        end
    end)

    -- Refresh on delivery status changes (ACK received, retry, failed)
    self._status_sub = ez.bus.subscribe("dm/status", function(topic, info)
        if info and info.pub_key_hex == key then
            self:_rebuild()
            screen.invalidate()
        end
    end)

    -- Refresh on reaction events (inbound or self). Filter on the
    -- conversation partner so reactions in other DMs don't trigger a
    -- rebuild here.
    self._reaction_sub = ez.bus.subscribe("chat/reaction", function(_topic, info)
        if info and info.target_pub == key then
            self:_rebuild()
            screen.invalidate()
        end
    end)
end

-- Keep screen redrawing while messages have pending status (for spinner animation)
function DMConversation:update()
    local key = self._state.contact_key or ""
    local msgs = dm_svc.get_history(key)
    for i = #msgs, math.max(1, #msgs - 5), -1 do
        if msgs[i] and msgs[i].status == "pending" then
            require("ezui.screen").invalidate()
            return
        end
    end
end

function DMConversation:on_leave()
    if self._sub then ez.bus.unsubscribe(self._sub); self._sub = nil end
    if self._status_sub then ez.bus.unsubscribe(self._status_sub); self._status_sub = nil end
    if self._reaction_sub then
        ez.bus.unsubscribe(self._reaction_sub); self._reaction_sub = nil
    end
end

function DMConversation:on_exit()
    self:on_leave()
end

function DMConversation:handle_key(key)
    local focus_mod = require("ezui.focus")
    if not focus_mod.editing then
        if key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
    end
    return nil
end

return DMConversation
