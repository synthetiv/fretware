-- quantization code owes a lot to Emilie Gillet's code for Braids:
-- https://github.com/pichenettes/eurorack/blob/master/braids/quantizer.cc

local read_scala_file = include 'lib/scala'

local Scale = {}
Scale.__index = Scale

function Scale.new(pitch_class_values, length)
	local instance = setmetatable({
		values = { [0] = 0 },
		levels = { [0] = 3 }
	}, Scale)
	instance:init(pitch_class_values, length)
	return instance
end

function Scale:init(pitch_class_info, length)
	for p = 1, length do
		self.values[p] = pitch_class_info[p][1]
		local level = tonumber(pitch_class_info[p][2])
		if level ~= nil then
			self.levels[p] = level
		else
			self.levels[p] = 0
		end
	end
	self.length = length
	self.span = self.values[length]
end

function Scale:get_nearest_pitch_id(value, get_pair)
	local values = self.values
	-- constrain to 1 scale span (octave or other)
	local span = math.floor(value / self.span)
	local span_offset = span * self.length
	local constrained_value = value % self.span
	-- binary search to find the first pitch ID whose value is higher than the one we want
	local compare_id = 0
	local upper_id = 0
	local jump_size = 0 -- size of binary search jump
	local n_remaining = self.length -- number of IDs left to check
	while n_remaining > 0 do
		jump_size = math.floor(n_remaining / 2)
		compare_id = upper_id + jump_size
		if values[compare_id] > constrained_value then
			n_remaining = jump_size
		else
			upper_id = compare_id + 1
			n_remaining = n_remaining - jump_size - 1
		end
	end
	upper_id = upper_id + span_offset
	local lower_id = upper_id - 1
	local upper_value = self:get(upper_id)
	local lower_value = self:get(lower_id)
	if get_pair then
		local weight = (value - lower_value) / (upper_value - lower_value)
		return lower_id, upper_id, weight
	else
		if math.abs(value - lower_value) < math.abs(value - upper_value) then
			return lower_id
		else
			return upper_id
		end
	end
end

function Scale:snap(value)
	nearest_pitch_id = self:get_nearest_pitch_id(value)
	return self:get(nearest_pitch_id)
end

function Scale:get(pitch_id)
	return self.values[pitch_id % self.length] + math.floor(pitch_id / self.length) * self.span
end

function Scale:read_scala_file(path)
	-- read the file
	local pitch_class_info, length, desc = read_scala_file(path)
	-- set scale values
	self:init(pitch_class_info, length)
	-- announce ourselves
	print(desc)
end

return Scale
