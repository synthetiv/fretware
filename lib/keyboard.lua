local Keyboard = {}
Keyboard.__index = Keyboard

function Keyboard.new(x, y, width, height)
	local keyboard = {
		x = x,
		y = y,
		width = width,
		height = height,
		x2 = x + width - 1,
		y2 = y + height - 1,
		x_center = x + math.floor((width - 0.5) / 2),
		y_center = y + math.floor((height - 0.5) / 2),
		held_keys = {},
		n_held_keys = 0,
		last_key = 0,
		row_offsets = {}
	}
	for row = keyboard.y, keyboard.y2 do
		keyboard.row_offsets[row] = 69 + (keyboard.y_center - row) * 5
	end
	keyboard.octave = 0
	keyboard.held_octave_keys = {
		down = false,
		up = false
	}
	return setmetatable(keyboard, Keyboard)
end

function Keyboard:get_key_id(x, y)
	return (x - self.x) + (y - self.y) * self.width
end

function Keyboard:get_key_id_coords(id)
	local x = id % self.width
	local y = math.floor((id - x) / self.width)
	return self.x + x, self.y + y
end

function Keyboard:get_key_pitch_id(x, y)
	return x - self.x_center + self.row_offsets[y] + self.octave * 12
end

function Keyboard:get_key_id_pitch_id(id)
	local x, y = self:get_key_id_coords(id)
	local pitch_id = self:get_key_pitch_id(x, y)
	return pitch_id
end

function Keyboard:get_last_value()
	return (self.last_pitch_id - 69) / 12
end

function Keyboard:key(x, y, z)
	if self:is_octave_key(x, y) then
		self:octave_key(x, y, z)
		return
	end
	self:note(x, y, z)
	pitch_volts = self:get_last_value()
	crow.output[1].volts = pitch_volts + bend_volts
	crow.output[4].volts = pitch_volts + bend_volts
end

function Keyboard:note(x, y, z)
	local key_id = self:get_key_id(x, y)
	local held_keys = self.held_keys
	local n_held_keys = self.n_held_keys
	local last_key = self.last_key
	if z == 1 then
		-- key pressed: add this key to held_keys
		n_held_keys = n_held_keys + 1
		held_keys[n_held_keys] = key_id
		last_key = key_id
	else
		if held_keys[n_held_keys] == key_id then
			-- most recently held key released: remove it from held_keys
			held_keys[n_held_keys] = nil
			n_held_keys = n_held_keys - 1
			if n_held_keys > 0 then
				last_key = held_keys[n_held_keys]
			end
		else
			-- other key released: find it in held_keys, remove it, and shift other values down
			local found = false
			for i = 1, n_held_keys do
				if held_keys[i] == key_id then
					found = true
				end
				if found then
					held_keys[i] = held_keys[i + 1]
				end
			end
			-- decrement n_held_keys only after we've looped over all held_keys table values, and only if
			-- we found the key in held_keys (which won't be the case if a key was held while switching
			-- the active keyboard, or a key on the pitch keyboard was held before holding shift)
			if found then
				n_held_keys = n_held_keys - 1
			end
		end
	end
	self.n_held_keys = n_held_keys
	self.last_key = last_key
	self.last_pitch_id = self:get_key_id_pitch_id(last_key)
end

function Keyboard:reset()
	self.held_keys = {}
	self.n_held_keys = 0
	self.held_octave_keys.down = false
	self.held_octave_keys.up = false
end

function Keyboard:is_key_held(x, y)
	local key_id = self:get_key_id(x, y)
	local held_keys = self.held_keys
	for i = 1, self.n_held_keys do
		if held_keys[i] == key_id then
			return true
		end
	end
	return false
end

function Keyboard:is_key_last(x, y)
	return self:get_key_id(x, y) == self.last_key
end

function Keyboard:draw()
	for x = self.x, self.x2 do
		for y = self.y, self.y2 do
			if self:is_octave_key(x, y) then
				g:led(x, y, 0) -- clear space around octave keys
			else
				local n = self:get_key_pitch_id(x, y)
				g:led(x, y, self:get_key_level(x, y, n))
			end
		end
	end
	-- draw octave keys
	local down_level = self.held_octave_keys.down and 7 or 2
	local up_level = self.held_octave_keys.up and 7 or 2
	g:led(self.x2 - 1, self.y, math.min(15, math.max(0, down_level - math.min(self.octave, 0))))
	g:led(self.x2, self.y, math.min(15, math.max(0, up_level + math.max(self.octave, 0))))
end

local white_keys = { true, false, true, false, true, true, false, true, false, true, false, true }
function Keyboard:is_white_key(n)
	return white_keys[(n - 70) % 12 + 1]
end

function Keyboard:is_octave_key(x, y)
	return y <= self.y + 1 and x >= self.x2 - 2
end

function Keyboard:octave_key(x, y, z)
	local d = 0
	if y == self.y then
		if x == self.x2 then
			self.held_octave_keys.up = z == 1
			d = 1
		elseif x == self.x2 - 1 then
			self.held_octave_keys.down = z == 1
			d = -1
		end
	end
	if self.held_octave_keys.up and self.held_octave_keys.down then
		self.octave = 0
	elseif z == 1 then
		self.octave = self.octave + d
	end
end

function led_blend(a, b)
	a = 1 - a / 15
	b = 1 - b / 15
	return (1 - (a * b)) * 15
end

function Keyboard:get_key_level(x, y, n)
	-- highlight white keys
	level = self:is_white_key(n) and 3 or 0
	-- highlight held keys
	if n == self.last_pitch_id then
		level = led_blend(level, 8)
	elseif self:is_key_held(x, y) then
		level = led_blend(level, 3)
	end
	return math.min(15, math.ceil(level))
end

return Keyboard
