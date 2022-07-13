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
--       shift at 1,8; latch at 2,8
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
		quantizing = false,
		arping = false,
		held_keys = {}, -- map of key names/ids to boolean states
		sustained_keys = {}, -- stack of sustained key IDs
		n_sustained_keys = 0,
		arp_index = 0,
		octave = 0,
		active_key = 0,
		active_key_x = 8,
		active_key_y = 6,
		active_pitch = 0,
		gate_mode = 4,
		bend_range = 0.5,
		bend_min = 0,
		bend_max = 0,
		bend_min_target = 0,
		bend_max_target = 0,
		bend_amount = 0,
		bend_value = 0,
		bend_relax_coefficient = 0.1,
		mask = { false, false, false, false, false, false, false, false, false, false, false, false },
		-- TODO: mask presets!
		mask_notes = 'none', -- for use with Crow output modes
		mask_edit = false,
		-- overridable callbacks
		on_pitch = function() end,
		on_gate = function() end,
		on_mask = function() end,
		on_arp = function() end
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
				if self.held_keys.shift then
					self:clear_mask_notes()
					self.mask_edit = false
				else
					self.mask_edit = not self.mask_edit
					-- if no mask is active but notes are sustained, build a mask from those notes
					if self.mask_edit and not self.quantizing and self.n_sustained_keys > 0 then
						for k = 1, self.n_sustained_keys do
							local key_id = self.sustained_keys[k]
							local pitch_class = self:get_key_id_pitch(key_id) % 12 + 1
							self.mask[pitch_class] = true
						end
						self:update_mask_notes()
					end
				end
			end
		elseif y == self.y2 then
			-- shift key
			self.held_keys.shift = z == 1
		elseif y == self.y2 - 2 then
			-- latch key
			if z == 1 then
				self.held_keys.latch = not self.held_keys.latch
				self:maybe_release_sustained_keys()
			end
		elseif y == self.y2 - 3 then
			-- arp toggle
			if z == 1 then
				self.arping = not self.arping
			end
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
			if not self.arping or self.n_sustained_keys == 0 then
				self.on_pitch()
				if self.n_sustained_keys > 0 and self.gate_mode == 2 then
					self.on_gate() -- TODO: true/false??
				end
			end
		elseif z == 1 then
			-- otherwise, jump up or down
			self.octave = util.clamp(self.octave + d, -5, 5)
			if not self.arping or self.n_sustained_keys == 0 then
				self.on_pitch()
				if self.n_sustained_keys > 0 and self.gate_mode == 2 then
					self.on_gate() -- TODO: true/false??
				end
			end
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
	if self.held_keys.latch then
		return
	end
	local held_keys = self.held_keys
	local sustained_keys = self.sustained_keys
	local n_sustained_keys = self.n_sustained_keys
	local arp_index = self.arp_index
	local i = 1
	while i <= n_sustained_keys do
		if held_keys[sustained_keys[i]] then
			i = i + 1
		else
			table.remove(sustained_keys, i)
			n_sustained_keys = n_sustained_keys - 1
			if arp_index >= i then
				arp_index = arp_index - 1
			end
		end
	end
	if n_sustained_keys > 0 then
		arp_index = (arp_index - 1) % n_sustained_keys + 1
		-- TODO: should this be handled differently depending on arp state?
		-- TODO: or gate mode == 4 ?
		self:set_active_key(sustained_keys[arp_index])
	end
	self.n_sustained_keys = n_sustained_keys
	self.arp_index = arp_index
end


function Keyboard:find_sustained_key(key_id)
	for k = 1, self.n_sustained_keys do
		local index = (self.arp_index + k - 2) % self.n_sustained_keys + 1
		if self.sustained_keys[index] == key_id then
			return index
		end
	end
	return false
end

function Keyboard:relax_bend()
	-- nudge min/max toward targets, and bend_value toward a linear point between min and max,
	-- thus reducing any offset that may have been caused by changes in min/max points
	self.bend_max = self.bend_max + (self.bend_max_target - self.bend_max) * self.bend_relax_coefficient
	self.bend_min = self.bend_min + (self.bend_min_target - self.bend_min) * self.bend_relax_coefficient
	-- how quickly bend_value should adjust depends on whether there are keys held
	local linear_bend = self.bend_min + (self.bend_amount + 1) * (self.bend_max - self.bend_min) / 2
	local coefficient = self.bend_relax_coefficient * (self.n_sustained_keys > 0 and self.bend_relax_coefficient or 2)
	self.bend_value = self.bend_value + (linear_bend - self.bend_value) * coefficient
end

function Keyboard:set_bend_targets()
	if self.gate_mode ~= 4 then
		self.bend_min_target = -self.bend_range
		self.bend_min = self.bend_min_target
		self.bend_max_target = self.bend_range
		self.bend_max = self.bend_max_target
	else
		local range = (self.n_sustained_keys > 1) and 0 or self.bend_range
		local min = -range
		local max = range
		for k = 1, self.n_sustained_keys do
			local interval = self:get_key_id_pitch(self.sustained_keys[k]) - self.active_pitch
			min = math.min(min, interval)
			max = math.max(max, interval)
		end
		-- we want to avoid placing bend_value outside the range, so we set target values directly,
		-- but actual mins/maxes may differ based on current bend value
		self.bend_min_target = min
		self.bend_min = math.min(min, self.bend_value - self.bend_range)
		self.bend_max_target = max
		self.bend_max = math.max(max, self.bend_value + self.bend_range)
	end
end

function Keyboard:note(x, y, z)
	local key_id = self:get_key_id(x, y)
	-- TODO: if you HOLD an already sustained key and then press another,
	-- MOVE that key instead of REmoving it
	if z == 1 then
		-- key pressed: set held_keys state and add to or remove from sustained_keys
		self.held_keys[key_id] = true
		if not self.held_keys.shift then
			local index = self:find_sustained_key(key_id)
			if index then
				table.remove(self.sustained_keys, index)
				if self.arp_index >= index then
					self.arp_index = self.arp_index - 1
				end
				self.n_sustained_keys = self.n_sustained_keys - 1
				self:set_bend_targets()
				return
			end
		end
		if self.gate_mode == 4 or not self.arping or self.n_sustained_keys == 0 then
			-- glide mode, no arp, or first note held: push new note to the stack
			self.n_sustained_keys = self.n_sustained_keys + 1
			self.arp_index = self.n_sustained_keys
			table.insert(self.sustained_keys, key_id)
			self:set_active_key(key_id, self.n_sustained_keys == 1)
			-- set gate high if we're in retrig or pulse mode, or if this is the first note held
			if self.gate_mode ~= 1 or self.n_sustained_keys == 1 then
				self.on_gate(true)
			end
		else
			-- arp: insert note to be played at next arp tick
			table.insert(self.sustained_keys, self.arp_index + 1, key_id)
			self.n_sustained_keys = self.n_sustained_keys + 1
		end
	else
		-- key released: set held_keys_state and maybe release it
		self.held_keys[key_id] = false
		if not self.held_keys.latch then
			local i = 1
			while i <= self.n_sustained_keys do
				if self.sustained_keys[i] == key_id then
					table.remove(self.sustained_keys, i)
					self.n_sustained_keys = self.n_sustained_keys - 1
					if self.arp_index >= i then
						self.arp_index = self.arp_index - 1
					end
				else
					i = i + 1
				end
			end
			if self.n_sustained_keys > 0 then
				self.arp_index = (self.arp_index - 1) % self.n_sustained_keys + 1
				if not self.arping then
					self:set_active_key(self.sustained_keys[self.arp_index])
					if self.gate_mode == 2 then
						self.on_gate(true)
					end
				end
			else
				self.on_gate(false)
			end
		end
	end
end

function Keyboard:arp(gate)
	if self.gate_mode ~= 4 and self.arping and self.n_sustained_keys > 0 then
		if gate then
			self.arp_index = self.arp_index % self.n_sustained_keys + 1
			self:set_active_key(self.sustained_keys[self.arp_index])
			self.on_arp()
		end
		self.on_gate(gate)
	end
end

function Keyboard:bend(amount)
	local delta = amount - self.bend_amount
	if delta > 0 then
		-- interpolate linearly between (bend, bend_value) and (1, bend_max)
		self.bend_value = self.bend_value + (self.bend_max - self.bend_value) * delta / (1 - self.bend_amount)
		-- move min point toward center, if we can / need to
		-- NB, this assumes bend_min <= -bend_range,
		-- which is safe as long as bend_range <= smallest interval on keyboard
		if self.bend_min < self.bend_min_target then
			self.bend_min = util.clamp(self.bend_min, self.bend_value - self.bend_range, self.bend_min_target)
		end
	else
		-- interpolate linearly between (bend, bend_value) and (-1, bend_min)
		self.bend_value = self.bend_value + (self.bend_min - self.bend_value) * delta / (-1 - self.bend_amount)
		-- move max point toward center, if we can / need to
		if self.bend_max > self.bend_max_target then
			self.bend_max = util.clamp(self.bend_max, self.bend_max_target, self.bend_value + self.bend_range)
		end
	end
	self.bend_amount = amount
end

function Keyboard:set_active_key(key_id, preserve_bend)
	local old_pitch = self.active_pitch
	self.active_key = key_id
	self.active_key_x, self.active_key_y = self:get_key_id_coords(key_id)
	self.active_pitch = self:get_key_pitch(self.active_key_x, self.active_key_y)
	if self.gate_mode == 4 and not preserve_bend then
		self.bend_value = self.bend_value - (self.active_pitch - old_pitch)
	end
	self:set_bend_targets()
	self.on_pitch()
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
	g:led(self.x, self.y, self.mask_edit and 7 or (self.quantizing and 5 or 2))
	g:led(self.x, self.y2 - 3, self.arping and 7 or 2)
	g:led(self.x, self.y2 - 2, self.held_keys.latch and 7 or 2)
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

function Keyboard:clear_mask_notes()
	for p = 1, 12 do
		self.mask[p] = false
	end
	self:update_mask_notes()
end

function Keyboard:update_mask_notes()
	local notes = {}
	local quantizing = false
	for p = 1, 12 do
		if self.mask[p] then
			quantizing = true
			table.insert(notes, p - 1)
		end
	end
	self.quantizing = quantizing
	self.mask_notes = quantizing and notes or 'none'
	self.on_mask()
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
		-- when shift is held, highlight Cs as reference points
		if self.held_keys.shift and p % 12 == 0 then
			level = led_blend(level, 2)
		end
	else
		-- highlight white keys
		level = self:is_white_pitch(p) and 3 or 0
		-- highlight sustained keys
		if self:is_key_sustained(key_id) then
			level = led_blend(level, 6)
		end
	end
	-- highlight active key, offset by bend as needed
	if y == self.active_key_y then
		-- TODO: adjust level based on latch / gate state ...?
		local bent_diff = math.abs(key_id - self.active_key - self.bend_value - (transpose_volts * 12))
		-- TODO: get actual output volts from crow and use that when drawing, so that the
		-- effects of slew + quantization are indicated correctly
		-- the following doesn't work, though, because norns can't just grab output volts synchronously
		-- local volt_diff = math.abs(key_id - self.active_key - (self.active_pitch - crow.output[1].volts * 12))
		if bent_diff < 1 then
			level = led_blend(level, (1 - bent_diff) * 7)
		end
	end
	return math.min(15, math.ceil(level))
end

return Keyboard
