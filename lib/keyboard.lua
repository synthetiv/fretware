local Keyboard = {}
Keyboard.__index = Keyboard

-- TODO: paraphony with note stack
-- TODO: sustain key (left col, y = 7; ctrl y = 8, ctrl+sustain = hands free latch)
-- TODO: quantizer
-- TODO: quantizer presets (left col, y = [2, 6])

function Keyboard.new(x, y, width, height)
	local keyboard = {
		x = x,
		y = y,
		width = width,
		height = height,
		x2 = x + width - 1,
		y2 = y + height - 1,
		x_center = 8,
		y_center = 6,
		mask_edit = false,
		held_keys = {},
		n_held_keys = 0,
		last_key = 0,
		last_key_x = 8,
		last_key_y = 6,
		last_pitch = 0,
		mask = { true, false, true, false, true, true, false, true, false, true, false, true } -- C major
	}
	keyboard.octave = 0
	keyboard.held_keys = {
		shift = false,
		down = false,
		up = false
	}
	setmetatable(keyboard, Keyboard)
	-- start at 0 / middle C
	keyboard:key(keyboard.x_center, keyboard.y_center, 1)
	keyboard:key(keyboard.x_center, keyboard.y_center, 0)
	return keyboard
end

function Keyboard:get_key_id(x, y)
	return (x - self.x) + (self.y2 - y) * self.width
end

function Keyboard:get_key_id_coords(id)
	local x = id % self.width
	local y = math.floor((id - x) / self.width)
	return self.x + x, self.y2 - y
end

function Keyboard:get_key_pitch(x, y)
	return (x - self.x_center) + (self.y_center - y) * 5
end

function Keyboard:get_key_id_pitch(id)
	local x, y = self:get_key_id_coords(id)
	return self:get_key_pitch(x, y)
end

function Keyboard:key(x, y, z)
	if x == self.x then
		if y == self.y then
			-- mask edit key
			if z == 1 then
				self.mask_edit = not self.mask_edit
			end
		elseif y == self.y2 then
			-- shift key
			self.held_keys.shift = z == 1
		end
	elseif y == self.y2 and x > self.x2 - 2 then
		-- octave up/down
		local d = 0
		if x == self.x2 - 1 then -- down
			self.held_keys.down = z == 1
			d = -1
		elseif x == self.x2 then -- up
			self.held_keys.up = z == 1
			d = 1
		end
		if self.held_keys.up and self.held_keys.down then
			-- if both keys are pressed together, reset octave
			self.octave = 0
		elseif z == 1 then
			-- otherwise, jump up or down
			self.octave = self.octave + d
		end
	elseif self.mask_edit then
		if z == 1 then
			p = self:get_key_pitch(x, y) % 12 + 1
			self.mask[p] = not self.mask[p]
		end
	else
		self:note(x, y, z)
	end
end

-- TODO: apply global_transpose
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
	self.last_key_x, self.last_key_y = self:get_key_id_coords(last_key)
	self.last_pitch = self:get_key_pitch(self.last_key_x, self.last_key_y)
end

function Keyboard:reset()
	self.held_keys = {}
	self.n_held_keys = 0
	self.held_keys.down = false
	self.held_keys.up = false
end

function Keyboard:is_key_held(key_id)
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
	g:led(self.x, self.y, self.mask_edit and 7 or 2)
	g:led(self.x, self.y2, self.held_keys.shift and 15 or 6)
	for x = self.x + 1, self.x2 do
		for y = self.y, self.y2 do
			if y == self.y2 and x > self.x2 - 2 then
				if x == self.x2 - 1 then
					local down_level = self.held_keys.down and 7 or 2
					g:led(x, y, math.min(15, math.max(0, down_level - math.min(self.octave, 0))))
				elseif x == self.x2 then
					local up_level = self.held_keys.up and 7 or 2
					g:led(x, y, math.min(15, math.max(0, up_level + math.max(self.octave, 0))))
				end
			else
				local key_id = self:get_key_id(x, y)
				local p = self:get_key_pitch(x, y)
				g:led(x, y, self:get_key_level(x, y, key_id, p))
			end
		end
	end
end

-- TODO: apply global_transpose
function Keyboard:is_mask_pitch(p)
	p = p % 12 + 1
	return self.mask[p]
end

-- TODO: apply global_transpose
function Keyboard:is_white_pitch(p)
	p = p % 12
	if p == 0 or p == 2 or p == 4 or p == 5 or p == 7 or p == 9 or p == 11 then
		return true
	end
	return false 
end

function led_blend(a, b)
	a = 1 - a / 15
	b = 1 - b / 15
	return (1 - (a * b)) * 15
end

-- TODO: apply global_transpose
function Keyboard:get_key_level(x, y, key_id, p)
	local level = 0
	if self.mask_edit then
		-- show mask
		level = self:is_mask_pitch(p) and 4 or 0
		-- and highlight Cs as reference points
		if p % 12 == 0 then
			level = led_blend(level, 2, 0)
		end
	else
		-- highlight white keys
		level = self:is_white_pitch(p) and 3 or 0
	end
	-- highlight last key, offset by bend as needed
	if y == self.last_key_y then
		local bent_diff = math.abs(key_id - self.last_key - bend_volts * 12)
		if bent_diff < 1 then
			level = led_blend(level, (1 - bent_diff) * 8)
		end
	end
	-- highlight held keys
	if self:is_key_held(key_id) then
		level = led_blend(level, 3)
	end
	if self.mask_edit then
	end
	return math.min(15, math.ceil(level))
end

return Keyboard
