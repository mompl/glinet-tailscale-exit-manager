-- Test-only stand-in for lua-cjson (the router firmware ships the real one). Just enough JSON for the RPC bridge.
local M = {}

local function esc(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
		return map[c] or string.format("\\u%04x", c:byte())
	end) .. '"'
end

local function enc(v)
	local t = type(v)
	if t == "string" then return esc(v)
	elseif t == "number" or t == "boolean" then return tostring(v)
	elseif t == "table" then
		local parts, n = {}, 0
		for k, x in pairs(v) do
			n = n + 1
			parts[#parts + 1] = esc(tostring(k)) .. ":" .. enc(x)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("cannot encode " .. t)
end
function M.encode(v) return enc(v) end

function M.decode(s)
	local i = 1
	local function ws() i = s:find("%S", i) or #s + 1 end
	local value
	local function str()
		local out = {}
		i = i + 1
		while true do
			local c = s:sub(i, i)
			if c == "" then error("unterminated string") end
			if c == '"' then i = i + 1; return table.concat(out) end
			if c == "\\" then
				local n = s:sub(i + 1, i + 1)
				local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
				if n == "u" then out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16) % 256); i = i + 6
				else out[#out + 1] = map[n] or n; i = i + 2 end
			else out[#out + 1] = c; i = i + 1 end
		end
	end
	function value()
		ws()
		local c = s:sub(i, i)
		if c == "{" then
			local r = {}
			i = i + 1; ws()
			if s:sub(i, i) == "}" then i = i + 1; return r end
			while true do
				ws(); local k = str(); ws()
				assert(s:sub(i, i) == ":", "expected ':'"); i = i + 1
				r[k] = value(); ws()
				local d = s:sub(i, i); i = i + 1
				if d == "}" then return r end
				assert(d == ",", "expected ','")
			end
		elseif c == "[" then
			local r = {}
			i = i + 1; ws()
			if s:sub(i, i) == "]" then i = i + 1; return r end
			while true do
				r[#r + 1] = value(); ws()
				local d = s:sub(i, i); i = i + 1
				if d == "]" then return r end
				assert(d == ",", "expected ','")
			end
		elseif c == '"' then return str()
		elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
		elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
		elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
		else
			local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
			assert(num and #num > 0, "bad JSON at " .. i)
			i = i + #num
			return tonumber(num)
		end
	end
	local r = value(); ws()
	assert(i > #s, "trailing garbage")
	return r
end

return M
