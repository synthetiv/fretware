local Keyboard = {}
Keyboard.__index = Keyboard

-- TODO: paraphony with note stack
-- TODO: quantizer: send inputs to TT and/or crow
-- TODO: send scale mask to TT for use with QT.B <value> <root=0?> <mask>
-- TODO: quantizer presets (left col, y = [2, 6])
-- TODO: alt control scheme: use leftmost 2 cols only:
--       edit mask at 1,1
--       quant presets from 1,2 to 2,6
--       up/down at 1,7 and 2,7
--       shift at 1,8; sustain at 2,8
-- TODO: panic function, for when a note gets stuck due to momentary grid connection loss
--       or whatever it is that causes that

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
		held_keys = {}, -- map of key names/ids to boolean states
		sustained_keys = {}, -- stack of sustained key IDs
		n_sustained_keys = 0,
		octave = 0,
		active_key = 0,
		active_key_x = 8,
		active_key_y = 6,
		active_pitch = 0,
		mask = { false, false, false, false, false, false, false, false, false, false, false, false },
		-- TODO: mask presets!
		mask_notes = 'none' -- for use with Crow output modes
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

function Keyboard:quantize(pitch)
	local octave = math.floor(pitch / 12)
	pitch = pitch % 12
	local found_pitch = pitch
	local best_distance = math.huge
	-- check all enabled notes, including C + 1 oct if that's enabled
	for p = 0, 12 do
		if self.mask[p % 12 + 1] then
			local distance = math.abs(pitch - p)
			if distance < best_distance then
				found_pitch = p
				best_distance = distance
			end
		end
	end
	return found_pitch + octave * 12
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
			-- sustain+shift = hands-free latch
			if z == 1 and self.held_keys.sustain then
				self.held_keys.latch = not self.held_keys.latch
				self:maybe_release_sustained_keys()
			end
		elseif y == self.y2 - 1 then
			-- sustain key
			self.held_keys.sustain = z == 1
			-- shift+sustain = hands-free latch
			if z == 1 then
				self.held_keys.latch = self.held_keys.shift and not self.held_keys.latch
			end
			self:maybe_release_sustained_keys()
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
			self.octave = util.clamp(self.octave + d, -5, 5)
		end
	elseif self.mask_edit then
		if z == 1 then
			pitch_class = self:get_key_pitch(x, y) % 12 + 1
			self.mask[pitch_class] = not self.mask[pitch_class]
			self:update_mask_notes()
		end
	else
		self:note(x, y, z)
	end
end

function Keyboard:maybe_release_sustained_keys()
	if self.held_keys.sustain or self.held_keys.latch then
		return
	end
	local held_keys = self.held_keys
	local sustained_keys = self.sustained_keys
	local n_sustained_keys = self.n_sustained_keys
	local i = 1
	while i <= n_sustained_keys do
		if held_keys[sustained_keys[i]] then
			i = i + 1
		else
			table.remove(sustained_keys, i)
			n_sustained_keys = n_sustained_keys - 1
		end
	end
	if n_sustained_keys > 0 then
		self:set_active_key(sustained_keys[n_sustained_keys])
	end
	self.n_sustained_keys = n_sustained_keys
end

function Keyboard:note(x, y, z)
	local key_id = self:get_key_id(x, y)
	local held_keys = self.held_keys
	local sustained_keys = self.sustained_keys
	local n_sustained_keys = self.n_sustained_keys
	local active_key = self.active_key
	if z == 1 then
		-- key pressed: set held_keys state and add to sustained_keys
		held_keys[key_id] = true
		n_sustained_keys = n_sustained_keys + 1
		sustained_keys[n_sustained_keys] = key_id
		-- TODO: make this arp-friendly
		active_key = key_id
	else
		-- key released: set held_keys_state and maybe release it
		held_keys[key_id] = false
		if not self.held_keys.sustain and not self.held_keys.latch then
			-- find key in sustained_keys, remove it, and shift other values down
			local found = false
			for i = 1, n_sustained_keys do
				if sustained_keys[i] == key_id then
					found = true
				end
				if found then
					sustained_keys[i] = sustained_keys[i + 1]
				end
			end
			-- decrement n_sustained_keys only after we've looped over all
			-- sustained_keys table values, and only if we found the key in
			-- sustained_keys (which won't be the case if a key was held while switching
			-- the active keyboard, or a key on the pitch keyboard was held before
			-- holding shift)
			if found then
				n_sustained_keys = n_sustained_keys - 1
			end
			-- if the active key was just released, jump to the next most recent key
			-- TODO: make this arp-friendly
			if active_key == key_id and n_sustained_keys > 0 then
				active_key = sustained_keys[n_sustained_keys]
			end
		end
	end
	self.n_sustained_keys = n_sustained_keys
	self:set_active_key(active_key)
end

function Keyboard:set_active_key(key_id)
	self.active_key = key_id
	self.active_key_x, self.active_key_y = self:get_key_id_coords(key_id)
	self.active_pitch = self:get_key_pitch(self.active_key_x, self.active_key_y)
end

function Keyboard:is_key_sustained(key_id)
	local sustained_keys = self.sustained_keys
	for i = 1, self.n_sustained_keys do
		if sustained_keys[i] == key_id then
			return true
		end
	end
	return false
end

function Keyboard:draw()
	g:led(self.x, self.y, self.mask_edit and 7 or 2)
	g:led(self.x, self.y2 - 1, self.held_keys.latch and 9 or (self.held_keys.sustain and 15 or 3))
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

function Keyboard:is_mask_pitch(p)
	p = p % 12
	return self.mask[p + 1]
end

function Keyboard:update_mask_notes()
	local notes = {}
	local has_notes = false
	for p = 1, 12 do
		if self.mask[p] then
			has_notes = true
			table.insert(notes, p - 1)
		end
	end
	self.mask_notes = has_notes and notes or 'none'
end

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

function Keyboard:get_key_level(x, y, key_id, p)
	local level = 0
	if self.mask_edit then
		-- show mask
		level = self:is_mask_pitch(p) and 4 or 0
		-- and highlight Cs as reference points
		if p % 12 == 0 then
			level = led_blend(level, 2)
		end
	else
		-- highlight white keys
		level = self:is_white_pitch(p) and 3 or 0
	end
	-- highlight active key, offset by bend as needed
	if y == self.active_key_y then
		local bent_diff = math.abs(key_id - self.active_key - bend_volts * 12)
		-- TODO: get actual output volts from crow and use that when drawing, so that the
		-- effects of slew + quantization are indicated correctly
		-- local volt_diff = math.abs(key_id - self.active_key - (self.active_pitch - crow.output[1].volts * 12))
		if bent_diff < 1 then
			level = led_blend(level, (1 - bent_diff) * 8)
		end
	end
	-- highlight sustained keys
	if self:is_key_sustained(key_id) then
		level = led_blend(level, 5)
	end
	if self.mask_edit then
	end
	return math.min(15, math.ceil(level))
end

return Keyboard
