local miniz = require("miniz")
local strext = require("string-extensions")

pcall(require, "table.new")
pcall(require, "table.clear")

local MAX_UNPACK_SIZE = 0xFFF
local SIZE_T = 0
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
	local result = table.new(utf8.len(str))

	for i, codepoint in utf8.codes(str) do
		assert(codepoint <= 255, "Character cannot be represented in Latin-1")

		result[i] = string.char(codepoint)
	end

	return table.concat(result)
end

local function schemaUnpack(data, schema, idx)
	if not string.find(schema, "[sz]") then
		return string.packsize(schema), string.unpack(data, schema, idx)
	else -- TODO: Make this support endian (and alingment?)
		local schemas = string.split(schema, "s")
		local args = table.pack(string.unpack(data, schemas[1], idx))
		local len = string.packsize(string.gsub(schemas[1], "z", "")) -- TODO: Handle Z

		for i = 2, #schemas do
			local v = schemas[i]
			local slen = nil

			if string.find(v, "%d") then
				slen = string.unpack(data, "I"..string.sub(v, 1, 1), idx + len)
				len = len + 1
			end

			local newArgs = table.pack(string.unpack(data, slen and "c"..slen..string.sub(v, 2) or v, idx + len))
			table.move(newArgs, 1, newArgs.n, args.n + 1)
			args.n = args.n + newArgs.n
			len = len + string.packsize(string.gsub(v, "z", "")) -- TODO: Handle Z
		end

		return len, table.unpack(args)
	end
end

local function compress(data, name, t, comment)  -- TODO: Maybe build or a part of it in C or with FFI to avoid double allocation of compressed string?
	local result = { string.pack("c2 b B L b b", "\x1F\x8B", 8, bit.bor(#data <= 2^12 and not string.find(data, "[^%g ]") and 0x1 or 0, 0x2, 0x0, name and 0x4 or 0, comment and 0x8 and 0), t or 0, 0, FILESYSTEM) }

	if name then
		table.insert(result, select(2, pcall(utf8_to_latin1, string.gsub(name, "\r\n", "\n")))..(string.sub(name, -1, -1) ~= "\0" and "\0" or ""))
	end

	if comment then
		table.insert(result, select(2, pcall(utf8_to_latin1, string.gsub(comment, "\r\n", "\n")))..(string.sub(comment, -1, -1) ~= "\0" and "\0" or ""))
	end

	table.insert(result, string.pack("H", bit.rshift(miniz.crc32(table.concat(result)), 16)))
	table.insert(result, miniz.inflate(data))
	table.insert(result, string.pack("L L", miniz.crc32(result[#result]), #result[#result]))

	return table.concat(result)
end

local function decompress(data, strict)
	assert(string.sub(data, 1, 2) == "\x1F\x8B", "Input is not a gzip stream!")
	assert(string.byte(data, 3, 3) == 8, "Unsupported compression method.")
	local flags, t, extra, filesystem = string.unpack(data, "B L b b")
	local ftext, fhcrc, fextra, fname, fcomment = bit.band(flags, 0x1) == 0x1, bit.band(flags, 0x2) == 0x2, bit.band(flags, 0x4) == 0x4, bit.band(flags, 0x8) == 0x8, bit.band(flags, 0x16) == 0x16
	local i = 10
	local name, comment

	if fextra then
		 -- TODO: Finish this
	end

	if fname then
		i, name = schemaUnpack(data, "z", i)
		name = string.gsub(name, "\r\n", "\n")
	end

	if fcomment then
		i, comment = schemaUnpack(data, "z", i)
		comment = string.gsub(comment, "\r\n", "\n")
	end

	if fhcrc then
		if strict then
			assert(schemaUnpack(data, "H", i) == bit.rshift(miniz.crc32(string.sub(data, 1, i)), 16), "Header checksum doesn't match!")
		end

		i = i + 2
	end

	if strict then
		local real = miniz.deflate(MINIZ_NOCOPY and data or string.sub(data, i, -9), MINIZ_NOCOPY and i or nil, MINIZ_NOCOPY and #data - 9 or nil)
		assert(schemaUnpack(data, "L", i) == miniz.crc32(real), "Header checksum doesn't match!")

		return real
	else
		return miniz.deflate(MINIZ_NOCOPY and data or string.sub(data, i, -9), MINIZ_NOCOPY and i or nil, MINIZ_NOCOPY and #data - 9 or nil)
	end
end

local success, err = pcall(function()
	local s = "abc"..miniz.inflate("1234567890qwertyuiopasdfghjklzxcvbnm").."def"
	return miniz.deflate(s, 4, #s - 3)
end)

if not miniz.deflate then
	miniz.deflate = miniz.decompress
end

if not miniz.deflate then
	miniz.deflate = miniz.compress
end

MINIZ_NOCOPY = success and err

return {
	compress = compress,
	Compress = compress,
	decompress = decompress,
	Decompress = decompress
}
