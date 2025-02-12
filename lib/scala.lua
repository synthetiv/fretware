-- scala file interpreter

local log2 = math.log(2)

local function parse_cents(value)
	value = tonumber(value)
	if value == nil then
		error('bad cent value: ' .. value)
	end
	return value / 1200
end

local function parse_ratio(value)
	-- get numerator
	local num, den = string.match(value, '^(.+)/(.+)$')
	if num == nil then
		-- no /? read whole value as a number
		num = tonumber(value)
		if value == nil then
			error('bad ratio value: ' .. value)
		end
		den = 1
	else
		num = tonumber(num)
		den = tonumber(den)
		if den == nil or num == nil then
			error('bad ratio value: ' .. value)
		end
	end
	return math.log(num / den) / log2
end

function read_scala_file(path)
	if not util.file_exists(path) then
		error('missing file')
	end
	local desc = nil
	local length = 0
	local expected_length = 0
	local pitches = {}
	for line in io.lines(path) do
		line = string.gsub(line, '\r', '') -- trim pesky CR characters that make debugging a pain
		if string.sub(line, 1, 1) ~= '!' then -- ignore comment lines
			if desc == nil then
				-- first line is a description of the scale
				desc = line
			else
				local value, comment = string.match(line, '^%s*(%S+)%s*(.*)$')
				if expected_length == 0 then
					-- second line is the number of pitches
					expected_length = tonumber(value)
					if expected_length == nil then
						error('bad length: ' .. value)
					end
				else
					-- everything else is a pitch
					length = length + 1
					if string.find(value, '%.') ~= nil then
						value = parse_cents(value)
					else
						value = parse_ratio(value)
					end
					pitches[length] = { value, comment }
				end
			end
		end
	end
	-- if the stated length doesn't match the number of pitches, then something went wrong
	if length ~= expected_length then
		error('length mismatch', length, expected_length)
	end
	-- enforce low -> high pitch order, or scale.lua's quantization won't work
	table.sort(pitches, function(a, b)
		return a[1] < b[1]
	end)
	return pitches, length, desc
end

return read_scala_file
