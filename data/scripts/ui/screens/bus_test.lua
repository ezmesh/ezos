-- Message Bus Diagnostics Screen for T-Deck OS
-- Tests pub/sub message passing between Lua and C++

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local BusTest = {
    title = "Message Bus Test",
    tests = {
        {name = "Lua->Lua", status = "pending", description = "Lua subscribe and post"},
        {name = "C++ Echo", status = "pending", description = "Ping C++ handler"},
        {name = "Multi-Sub", status = "pending", description = "Multiple subscribers"},
        {name = "Unsub", status = "pending", description = "Unsubscribe works"},
        {name = "Filter", status = "pending", description = "Topic filtering"}
    },
    log = {},
    max_log = 8,
    running = false,
    current_test = 0,
    subscriptions = {}
}

function BusTest:new()
    local o = {
        title = self.title,
        tests = {},
        log = {},
        max_log = self.max_log,
        running = false,
        current_test = 0,
        subscriptions = {}
    }
    -- Deep copy tests
    for i, t in ipairs(self.tests) do
        o.tests[i] = {name = t.name, status = "pending", description = t.description}
    end
    setmetatable(o, {__index = BusTest})
    return o
end

function BusTest:add_log(msg)
    table.insert(self.log, msg)
    while #self.log > self.max_log do
        table.remove(self.log, 1)
    end
    ScreenManager.invalidate()
end

function BusTest:cleanup()
    -- Unsubscribe all active subscriptions
    for _, sub_id in ipairs(self.subscriptions) do
        if ez.bus and ez.bus.unsubscribe then
            ez.bus.unsubscribe(sub_id)
        end
    end
    self.subscriptions = {}
end

function BusTest:on_exit()
    self:cleanup()
end

-- Test 1: Lua to Lua messaging
function BusTest:run_test_1()
    self.tests[1].status = "running"
    self:add_log("> Test 1: Lua->Lua")

    local received = false
    local test_data = "hello_lua"

    -- Subscribe to test topic
    local sub_id = ez.bus.subscribe("test/lua", function(topic, data)
        if data == test_data then
            received = true
        end
        self:add_log("  Recv: " .. topic .. " = " .. data)
    end)
    table.insert(self.subscriptions, sub_id)
    self:add_log("  Sub id=" .. sub_id)

    -- Post message
    ez.bus.post("test/lua", test_data)
    self:add_log("  Post: test/lua = " .. test_data)

    -- Check result after a short delay (messages are processed next frame)
    spawn_delay(100, function()
        if received then
            self.tests[1].status = "pass"
            self:add_log("  PASS")
        else
            self.tests[1].status = "fail"
            self:add_log("  FAIL: not received")
        end
        self:run_next_test()
    end)
end

-- Test 2: C++ Echo round-trip
function BusTest:run_test_2()
    self.tests[2].status = "running"
    self:add_log("> Test 2: C++ Echo")

    local received = false
    local ping_data = "ping_" .. tostring(ez.system.uptime())

    -- Subscribe to echo response
    local sub_id = ez.bus.subscribe("bus/echo", function(topic, data)
        if data == ping_data then
            received = true
        end
        self:add_log("  Echo: " .. data)
    end)
    table.insert(self.subscriptions, sub_id)

    -- Post ping (C++ will echo it back)
    ez.bus.post("bus/ping", ping_data)
    self:add_log("  Ping: " .. ping_data)

    -- Check result
    spawn_delay(100, function()
        if received then
            self.tests[2].status = "pass"
            self:add_log("  PASS")
        else
            self.tests[2].status = "fail"
            self:add_log("  FAIL: no echo")
        end
        self:run_next_test()
    end)
end

-- Test 3: Multiple subscribers on same topic
function BusTest:run_test_3()
    self.tests[3].status = "running"
    self:add_log("> Test 3: Multi-Sub")

    local count = 0

    -- Subscribe twice to same topic
    local sub1 = ez.bus.subscribe("test/multi", function(topic, data)
        count = count + 1
    end)
    local sub2 = ez.bus.subscribe("test/multi", function(topic, data)
        count = count + 1
    end)
    table.insert(self.subscriptions, sub1)
    table.insert(self.subscriptions, sub2)
    self:add_log("  2 subscribers")

    -- Post one message
    ez.bus.post("test/multi", "data")

    -- Check both received
    spawn_delay(100, function()
        self:add_log("  Count: " .. count)
        if count == 2 then
            self.tests[3].status = "pass"
            self:add_log("  PASS")
        else
            self.tests[3].status = "fail"
            self:add_log("  FAIL: count=" .. count)
        end
        self:run_next_test()
    end)
end

-- Test 4: Unsubscribe verification
function BusTest:run_test_4()
    self.tests[4].status = "running"
    self:add_log("> Test 4: Unsub")

    local count = 0

    -- Subscribe
    local sub_id = ez.bus.subscribe("test/unsub", function(topic, data)
        count = count + 1
    end)
    self:add_log("  Sub id=" .. sub_id)

    -- Post first message
    ez.bus.post("test/unsub", "msg1")

    spawn_delay(50, function()
        -- Unsubscribe
        local ok = ez.bus.unsubscribe(sub_id)
        self:add_log("  Unsub: " .. tostring(ok))

        -- Post second message (should not be received)
        ez.bus.post("test/unsub", "msg2")

        spawn_delay(50, function()
            self:add_log("  Count: " .. count)
            if count == 1 then
                self.tests[4].status = "pass"
                self:add_log("  PASS")
            else
                self.tests[4].status = "fail"
                self:add_log("  FAIL: count=" .. count)
            end
            self:run_next_test()
        end)
    end)
end

-- Test 5: Topic filtering (no cross-talk)
function BusTest:run_test_5()
    self.tests[5].status = "running"
    self:add_log("> Test 5: Filter")

    local topic_a_count = 0
    local topic_b_count = 0

    -- Subscribe to topic A only
    local sub_a = ez.bus.subscribe("test/topic_a", function(topic, data)
        topic_a_count = topic_a_count + 1
    end)
    table.insert(self.subscriptions, sub_a)

    -- Subscribe to topic B only
    local sub_b = ez.bus.subscribe("test/topic_b", function(topic, data)
        topic_b_count = topic_b_count + 1
    end)
    table.insert(self.subscriptions, sub_b)

    -- Post to topic A twice, topic B once
    ez.bus.post("test/topic_a", "a1")
    ez.bus.post("test/topic_a", "a2")
    ez.bus.post("test/topic_b", "b1")

    -- Check counts
    spawn_delay(100, function()
        self:add_log("  A=" .. topic_a_count .. " B=" .. topic_b_count)
        if topic_a_count == 2 and topic_b_count == 1 then
            self.tests[5].status = "pass"
            self:add_log("  PASS")
        else
            self.tests[5].status = "fail"
            self:add_log("  FAIL")
        end
        self:run_next_test()
    end)
end

function BusTest:run_next_test()
    self.current_test = self.current_test + 1

    if self.current_test > #self.tests then
        self.running = false
        self:add_log("All tests complete")
        ScreenManager.invalidate()
        return
    end

    local test_func = self["run_test_" .. self.current_test]
    if test_func then
        test_func(self)
    else
        self:run_next_test()
    end
end

function BusTest:run_all()
    if self.running then return end

    -- Reset all tests
    for _, t in ipairs(self.tests) do
        t.status = "pending"
    end
    self.log = {}
    self:cleanup()

    self.running = true
    self.current_test = 0
    self:add_log("Starting all tests...")
    self:run_next_test()
end

function BusTest:run_single(num)
    if self.running then return end
    if num < 1 or num > #self.tests then return end

    -- Reset just this test
    self.tests[num].status = "pending"
    self.log = {}
    self:cleanup()

    self.running = true
    self.current_test = num - 1  -- Will be incremented
    self:add_log("Running test " .. num .. "...")

    -- Run just this one test, then stop
    local orig_next = self.run_next_test
    self.run_next_test = function(self_inner)
        self_inner.running = false
        self_inner.run_next_test = orig_next
        ScreenManager.invalidate()
    end

    local test_func = self["run_test_" .. num]
    if test_func then
        test_func(self)
    end
end

function BusTest:render(display)
    local colors = ListMixin.get_colors(display)

    -- Background
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    display.set_font_size("small")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local y = fh + 6
    local x = 2 * fw

    -- Tests list
    for i, t in ipairs(self.tests) do
        -- Test number
        display.draw_text(x, y, "[" .. i .. "]", colors.TEXT_SECONDARY)

        -- Test name
        display.draw_text(x + 4 * fw, y, t.name, colors.TEXT)

        -- Status indicator
        local status_x = x + 14 * fw
        local status_color = colors.TEXT_SECONDARY
        local status_text = "..."

        if t.status == "pass" then
            status_color = colors.SUCCESS
            status_text = "PASS"
        elseif t.status == "fail" then
            status_color = colors.ERROR
            status_text = "FAIL"
        elseif t.status == "running" then
            status_color = colors.WARNING
            status_text = "RUN"
        end

        display.draw_text(status_x, y, status_text, status_color)

        y = y + fh + 1
    end

    -- Separator
    y = y + 4
    display.draw_hline(fw, y, display.width - 2 * fw, colors.SURFACE_ALT)
    y = y + 6

    -- Log area
    display.draw_text(x, y, "Log:", colors.TEXT_SECONDARY)
    y = y + fh

    for _, line in ipairs(self.log) do
        display.draw_text(x, y, line, colors.TEXT)
        y = y + fh
    end

    -- Bottom help
    local help_y = display.height - fh - 2
    display.draw_text(x, help_y, "ENTER=Run All  1-5=Single  Q=Back", colors.TEXT_SECONDARY)
end

function BusTest:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        self:cleanup()
        return "pop"
    elseif key.special == "ENTER" then
        self:run_all()
    elseif key.character and key.character >= "1" and key.character <= "5" then
        local num = tonumber(key.character)
        self:run_single(num)
    end

    return "continue"
end

return BusTest
