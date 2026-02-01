-- UI Components Index
-- Loads all component modules and exports them

local Components = {}

-- Load individual components
Components.TextInput = load_module("/scripts/ui/components/text_input.lua")
Components.Button = load_module("/scripts/ui/components/button.lua")
Components.Checkbox = load_module("/scripts/ui/components/checkbox.lua")
Components.RadioGroup = load_module("/scripts/ui/components/radio_group.lua")
Components.Dropdown = load_module("/scripts/ui/components/dropdown.lua")
Components.TextArea = load_module("/scripts/ui/components/text_area.lua")
Components.VerticalList = load_module("/scripts/ui/components/vertical_list.lua")
Components.NumberInput = load_module("/scripts/ui/components/number_input.lua")
Components.Toggle = load_module("/scripts/ui/components/toggle.lua")

return Components
