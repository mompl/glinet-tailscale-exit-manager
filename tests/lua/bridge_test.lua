-- Runs the REAL native-GUI RPC bridge (src/usr/lib/oui-httpd/rpc/tsem) under a Lua interpreter.
-- usage: <lua> bridge_test.lua BRIDGE_FILE PLUGIN_FILE      (cjson = the test stand-in next to this file)
local dir = arg[0]:match("^(.*/)") or "./"
package.path = dir .. "?.lua;" .. package.path
local loader = loadstring or load

local f = assert(io.open(arg[1], "r"))
local src = f:read("*a")
f:close()
local n
src, n = src:gsub('local PLUGIN = "[^"]*"', function() return 'local PLUGIN = "' .. arg[2] .. '"' end)
assert(n == 1, "the bridge no longer has exactly one PLUGIN constant: adapt this test")
local bridge = assert(loader(src, "=bridge"))()

local fails = 0
local function check(cond, msg)
	if not cond then fails = fails + 1; io.stderr:write("FAIL: " .. msg .. "\n") end
end

local r = bridge.call({ m = "no_such_method" })
check(r.ok == false and r.code == "not_found", "unknown method must be refused (not_found)")
r = bridge.call("not a table")
check(r.ok == false and r.code == "not_found", "a non-table argument must be refused")

r = bridge.call({ m = "status" })
check(r.ok == true and type(r.status) == "table" and type(r.status.mode) == "string", "status must reach the controller API (ok=true, status.mode string)")

r = bridge.call({ m = "set_mode", p = { mode = "german", evil = "1" } })
check(r.ok == false and r.code == "invalid_argument", "an unknown parameter must be refused")
r = bridge.call({ m = "set_mode", p = { mode = "german", confirm = "yes" } })
check(r.ok == false and r.code == "invalid_argument", "a wrongly typed parameter must be refused")
r = bridge.call({ m = "set_mode", p = { mode = "ger\nman" } })
check(r.ok == false and r.code == "invalid_argument", "a control character in a string must be refused")
r = bridge.call({ m = "set_mode", p = { mode = string.rep("x", 200) } })
check(r.ok == false and r.code == "invalid_argument", "an over-long string must be refused")

-- the list of released networks (8 CIDRs = about 110 characters) is longer than a name but must pass; 200+ must not
r = bridge.call({ m = "config_set", p = { allow_subnets4 = "10.76.0.0/24 10.76.1.0/24 10.76.2.0/24 10.77.0.0/23 10.77.2.0/23 10.79.0.0/24 10.80.0.0/24 192.168.0.0/23" } })
check(r.ok == true, "eight released networks must pass the bridge, got " .. tostring(r.code) .. " " .. tostring(r.error))
r = bridge.call({ m = "config_set", p = { allow_subnets4 = string.rep("1", 201) } })
check(r.ok == false and r.code == "invalid_argument", "an over-long network list must be refused")

-- DIRECT without the boolean confirm must not switch (the plugin enforces it; the bridge must not weaken it)
r = bridge.call({ m = "set_mode", p = { mode = "direct" } })
check(r.ok == false and r.code == "confirmation_required", "direct without confirm must be refused, got " .. tostring(r.code))
local s = bridge.call({ m = "status" })
check(s.status and s.status.mode ~= "direct", "mode changed to direct without confirmation")

-- the caller cannot choose the source; the call still goes through the same controller
r = bridge.call({ m = "set_mode", p = { mode = "blocked", source = "hw" } })
check(r.ok == true, "set_mode blocked via the bridge failed: " .. tostring(r.code))
s = bridge.call({ m = "status" })
check(s.status and s.status.mode == "blocked", "the controller did not reach mode blocked through the bridge")

r = bridge.call({ m = "set_mode", p = { mode = "direct", confirm = true } })
check(r.ok == true, "direct with confirm=true must work: " .. tostring(r.code))
s = bridge.call({ m = "status" })
check(s.status and s.status.mode == "direct", "mode did not become direct after the confirmed call")

if fails > 0 then os.exit(1) end
print("bridge: all checks passed under " .. (_VERSION or "lua"))
