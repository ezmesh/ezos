-- Simple class system for ezOS
-- Provides a clean way to create classes with inheritance

-- Create a new class, optionally inheriting from a base class
-- @param base Optional base class to inherit from
-- @return A new class table
--
-- Usage:
--   local Animal = Class()
--   function Animal:init(name) self.name = name end
--   function Animal:speak() return "..." end
--
--   local Dog = Class(Animal)
--   function Dog:speak() return "Woof!" end
--
--   local dog = Dog:new("Rex")
--   print(dog.name, dog:speak())  -- "Rex", "Woof!"
--
function _G.Class(base)
    local cls = {}
    cls.__index = cls

    -- Set up inheritance
    if base then
        setmetatable(cls, { __index = base })
        cls.super = base
    end

    -- Constructor - creates new instance
    function cls:new(...)
        local instance = setmetatable({}, cls)
        if instance.init then
            instance:init(...)
        end
        return instance
    end

    -- Check if object is instance of this class
    function cls:is_instance(obj)
        local mt = getmetatable(obj)
        while mt do
            if mt == cls then return true end
            mt = mt.super and getmetatable(mt.super)
        end
        return false
    end

    return cls
end

-- For modules that want to require this
return Class
