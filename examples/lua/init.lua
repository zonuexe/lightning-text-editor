-- init.lua - Micro-style Lua extension script for inzm (Full Lua Edition)
-- This file is loaded automatically on startup.

-- 1. Register custom command: > upper
micro.addCommand("upper", function()
    local buf = micro.getBuffer()
    for i, line in ipairs(buf) do
        buf[i] = string.upper(line)
    end
    micro.info("✨ Uppercased all lines in buffer!")
end)

-- 2. Register custom command: > count
micro.addCommand("count", function()
    local buf = micro.getBuffer()
    local words = 0
    for _, line in ipairs(buf) do
        for _ in line:gmatch("%S+") do
            words = words + 1
        end
    end
    micro.info(string.format("📊 Total: %d lines, %d words", #buf, words))
end)

-- 3. Hook: onSave
micro.on("onSave", function(filename)
    micro.info("💾 Successfully written to: " .. filename)
end)

micro.info("🚀 init.lua loaded! Type Ctrl+E and 'upper' or 'count'")
