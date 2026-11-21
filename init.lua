local miniz = require("miniz")

pcall(require, "table.new") -- Support for LuaJIT's require requirement (LuaJIT should make them always on tbh)
pcall(require, "table.clear")

local MAX_UNPACK_SIZE = 0xFFF
local MINIZ_NOCOPY = false

local function latin1_to_utf8(str)
	local len = #str
	local result = table.new(math.ceil(#str / MAX_UNPACK_SIZE))

	for i = 1, len, MAX_UNPACK_SIZE do
		result[math.ceil(i / MAX_UNPACK_SIZE)] = utf8.char(string.byte(str, i, math.min(i + MAX_UNPACK_SIZE - 1, len)))
	end

	return table.concat(result)
end

local function utf8_to_latin1(str)
	local i, result = i, table.new(utf8.len(str))

	for _, codepoint in utf8.codes(str) do
		assert(codepoint <= 255, "Character cannot be represented in Latin-1")
		i = i + 1
		result[i] = string.char(codepoint)
	end

	return table.concat(result)
end

-- TODO: Unnecessary so remove. But use parts of this for other project
--[[local function getStrSizes(schema, args, onlyNull)
	schema = string.gsub(schema, "[<>=%dx!]", "")
	local size, last = 0, 1

	while last and last <= #schema do
		last = string.find(schema, onlyNull and "z" or "[sz]", last, onlyNull)
		size = size + args[last] + 1
		last = last + 1
	end

	return size
end

local function schemaUnpack(data, schema, idx)
	if not string.find(schema, "[sz]") then
		return idx + string.packsize(schema), string.unpack(data, schema, idx)
	else -- TODO: Make this support endian (and alingment?)
		local schemas = string.split(schema, "s")
		local args = table.pack(string.unpack(data, schemas[1], idx))
		local len = string.packsize(string.gsub(schemas[1], "z", "")) + getStrSizes(schemas[1], args, true)

		for i = 2, #schemas do
			local v = schemas[i]
			local _, si =  string.find(v, "^%d+")

			local pSchema = "c"..string.unpack(data, si and ("I"..string.sub(v, 1, si)) or "T", idx + len)..string.sub(v, si + 1)
			len = len + (si or string.packsize("T"))

			local newArgs = table.pack(string.unpack(data, pSchema, idx + len))
			len = len + string.packsize(string.gsub(pSchema, "z", "")) + getStrSizes(pSchema, newArgs, true)

			table.move(newArgs, 1, newArgs.n, args.n + 1)
			args.n = args.n + newArgs.n
		end

		return len, table.unpack(args)
	end
end]]

local function compress(data, name, t, comment, filesystem)  -- TODO: Maybe build or a part of it in C or with FFI to avoid double allocation of compressed string?
	local result = { string.pack("<c2 b B L b b", "\x1F\x8B", 8, bit.bor(#data <= 2^12 and not string.find(data, "[^%g ]") and 0x1 or 0, 0x2, 0x0, name and 0x8 or 0, comment and 0x10 or 0), t or 0, 2, filesystem or 0xFF) }

	if name then
		table.insert(result, select(2, pcall(utf8_to_latin1, string.gsub(name, "\r\n", "\n")))..(string.sub(name, -1, -1) ~= "\0" and "\0" or ""))
	end

	if comment then
		table.insert(result, select(2, pcall(utf8_to_latin1, string.gsub(comment, "\r\n", "\n")))..(string.sub(comment, -1, -1) ~= "\0" and "\0" or ""))
	end

	table.insert(result, string.pack("<H", bit.band(miniz.crc32(table.concat(result)), 0xFFFF)))
	table.insert(result, miniz.deflate(data))
	table.insert(result, string.pack("<L L", miniz.crc32(data), #data))

	return table.concat(result)
end

local function decompress(data, strict)
	assert(string.sub(data, 1, 2) == "\x1F\x8B", "Input is not a gzip stream!")
	assert(string.byte(data, 3, 3) == 8, "Unsupported compression method.")
	local flags, t, extra, filesystem, i = string.unpack(data, "<B L b b")
	local ftext, fhcrc, fextra, fname, fcomment = bit.band(flags, 0x1) ~= 0, bit.band(flags, 0x2) ~= 0, bit.band(flags, 0x4) ~= 0, bit.band(flags, 0x8) ~= 0, bit.band(flags, 0x10) ~= 0
	assert(not strict or bit.band(flags, 0xE0) == 0, "Reserved flags present but behavior not implemented.")
	local name, comment

	if fextra then
		local xdata
		xdata, i = string.unpack("<S2", data, i)
		-- TODO: Parse extra data
	end

	if fname then
		name, i = string.unpack("<z", data, i)
		name = latin1_to_utf8(string.gsub(name, "\r\n", "\n"))
	end

	if fcomment then
		comment, i = string.unpack("<z", data, i)
		comment = latin1_to_utf8(string.gsub(comment, "\r\n", "\n"))
	end

	if fhcrc then
		if strict then
			assert(string.unpack("<H", data, i) == bit.band(miniz.crc32(string.sub(data, 1, i - 1)), 0xFFFF), "Header checksum doesn't match!")
		end

		i = i + 2
	end

	if strict then
		local real = miniz.inflate(MINIZ_NOCOPY and data or string.sub(data, i, -9), MINIZ_NOCOPY and i or nil, MINIZ_NOCOPY and #data - 8 - i or nil)
		i = #data - 8
		assert(string.unpack("<L", data, i) == miniz.crc32(real), "Data checksum doesn't match!")
		assert(string.unpack("<L", data, i + 4) == #real % 2^32, "Data length doesn't match!")

		return real
	else
		return miniz.inflate(MINIZ_NOCOPY and data or string.sub(data, i, -9), MINIZ_NOCOPY and i or nil, MINIZ_NOCOPY and #data - 8 - i or nil)
	end
end

local success, err = pcall(function()
	local test = "1234567890qwertyuiopasdfghjklzxcvbnm"
	local s = "abc"..miniz.deflate(test).."def"
	return miniz.inflate(s, 4, #s - 6) == test
end)

MINIZ_NOCOPY = success and err

if not miniz.deflate then
	miniz.deflate = miniz.decompress
end

if not miniz.deflate then
	miniz.deflate = miniz.compress
end

return {
	compress = compress,
	Compress = compress,
	decompress = decompress,
	Decompress = decompress
}
