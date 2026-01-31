-- Hello World demo script
-- Demonstrates the MessageBox utility

if _G.MessageBox then
    MessageBox.alert("Hello", "Welcome to T-Deck OS!", function(btn)
        ez.system.log("User pressed button: " .. tostring(btn))
    end)
else
    ez.system.log("MessageBox not available")
end
