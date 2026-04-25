-- Contact picker for initiating a file transfer from the file manager.
-- Kept as its own screen so the selection flow doesn't complicate the
-- file-manager source. Exposes a single entry point, `show(path,size)`,
-- that pushes the picker; selecting a contact kicks off the transfer
-- and pushes the transfer-progress screen on top.

local ui         = require("ezui")
local screen_mod = require("ezui.screen")

local M = {}

function M.show(source_path, source_size)
    local contacts_svc = require("services.contacts")
    local contacts = contacts_svc.get_all()

    local Picker = { title = "Transfer" }

    function Picker:build(state)
        local rows = {}

        if #contacts == 0 then
            rows[#rows + 1] = ui.padding({ 20, 10, 10, 10 },
                ui.text_widget("No contacts yet", {
                    color = "TEXT_MUTED", text_align = "center",
                })
            )
            rows[#rows + 1] = ui.padding({ 4, 10, 10, 10 },
                ui.text_widget(
                    "Add a contact from the Contacts screen before sending files.",
                    { color = "TEXT_MUTED", font = "small_aa",
                      text_align = "center", wrap = true }
                )
            )
        else
            rows[#rows + 1] = ui.padding({ 8, 10, 4, 10 },
                ui.text_widget("Send to...", {
                    color = "TEXT_MUTED", font = "tiny_aa",
                })
            )
            for _, c in ipairs(contacts) do
                rows[#rows + 1] = ui.list_item({
                    title    = c.name,
                    subtitle = c.pub_key_hex:sub(1, 16) .. "...",
                    on_press = function()
                        local ft = require("services.file_transfer")
                        local xfer_id, name, chunks =
                            ft.send(c.pub_key_hex, source_path)
                        screen_mod.pop()  -- close the picker
                        if not xfer_id then
                            -- `name` carries the error string in this
                            -- contract.
                            ez.log("[xfer] send failed: " .. tostring(name))
                            return
                        end
                        local FT = require("screens.tools.file_transfer")
                        screen_mod.push(screen_mod.create(FT,
                            FT.initial_state("tx", xfer_id, {
                                peer_name = c.name,
                                name      = name,
                                size      = source_size,
                                chunks    = chunks,
                            })))
                    end,
                })
            end
        end

        return ui.vbox({ gap = 0, bg = "BG" }, {
            ui.title_bar("Send file", { back = true }),
            ui.padding({ 4, 10, 6, 10 },
                ui.text_widget(source_path, {
                    color = "TEXT_SEC", font = "tiny_aa",
                })
            ),
            ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows)),
        })
    end

    function Picker:handle_key(key)
        if key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    screen_mod.push(screen_mod.create(Picker, {}))
end

return M
