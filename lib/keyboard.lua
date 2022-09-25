local Keyboard = {}
Keyboard.__index = Keyboard

local Scale = include 'lib/scale'
local et12 = {} -- default scale, 12TET
for p = 1, 12 do
	et12[p] = p / 12
end

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
		arping = false,
		gliding = false,
		held_keys = {}, -- map of key names/ids to boolean states
		sustained_keys = {}, -- stack of sustained key IDs
		n_sustained_keys = 0,
		arp_index = 0,
		arp_insert = 0,
		arp_forward_probability = 1,
		octave = 0,
		transposition = 0,
		active_key = 0,
		active_key_x = 8,
		active_key_y = 6,
		active_pitch_id = 0,
		active_pitch = 0,
		gate_mode = 2,
		bend_range = 0.5,
		bend_min = 0,
		bend_max = 0,
		bend_min_target = 0,
		bend_max_target = 0,
		bend_amount = 0,
		bend_value = 0,
		bend_relax_coefficient = 0.1,
		scale = Scale.new(et12, 12),
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

function Keyboard:get_key_pitch_id(x, y)
	return (x - self.x_center) + (self.y_center - y) * 5
end

function Keyboard:get_key_id_pitch_id(id)
	local x, y = self:get_key_id_coords(id)
	return self:get_key_pitch_id(x, y)
end

function Keyboard:get_key_id_pitch_value(id)
	return self:get_pitch_id_value(self:get_key_id_pitch_id(id))
end

function Keyboard:get_pitch_id_value(p)
	-- TODO: root note shouldn't have to be 0
	return (self.scale.values[p + self.scale.center_pitch_id] or 0)
end

function Keyboard:key(x, y, z)
	if x == self.x then
		if y == self.y then
			-- mask edit key
			if z == 1 then
				if self.held_keys.shift then
					self.scale:set_mask {}
					self.mask_edit = false
				else
					self.mask_edit = not self.mask_edit
					-- if no mask is active but notes are sustained, build a mask from those notes
					-- TODO: this ain't working right
					-- if self.mask_edit and not self.scale.mask_empty and self.n_sustained_keys > 0 then
					-- 	local mask = {}
					-- 	for k = 1, self.n_sustained_keys do
					-- 		local key_id = self.sustained_keys[k]
					-- 		local pitch_class = self:get_key_id_pitch_id(key_id) % self.scale.length + 1
					-- 		mask[pitch_class] = true
					-- 	end
					-- 	self.scale:set_mask(mask)
					-- end
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
				if self.arping then
					self.gliding = false
					self.bend_value = 0 -- TODO: this is useful when switching from glide mode, but is this ALWAYS a good idea?
					self:set_bend_targets()
				end
			end
		elseif y == self.y + 2 then
			-- glide toggle
			if z == 1 then
				self.gliding = not self.gliding
				self:set_bend_targets()
				if self.gliding then
					self.arping = false
				end
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
			pitch_class = self:get_key_pitch_id(x, y) % self.scale.length + 1
			self.scale.next_mask[pitch_class] = not self.scale.next_mask[pitch_class]
			self.scale:apply_edits()
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
	local i = 1
	while i <= self.n_sustained_keys do
		if held_keys[sustained_keys[i]] then
			i = i + 1
		else
			table.remove(sustained_keys, i)
			self.n_sustained_keys = self.n_sustained_keys - 1
			if self.arp_index >= i then
				self.arp_index = self.arp_index - 1
			end
			if self.arp_insert >= i then
				self.arp_insert = self.arp_insert - 1
			end
		end
	end
	if self.n_sustained_keys > 0 then
		self.arp_index = (self.arp_index - 1) % self.n_sustained_keys + 1
		self.arp_insert = (self.arp_insert - 1) % self.n_sustained_keys + 1
		-- TODO: should this be handled differently depending on arp state?
		-- TODO: or gate mode == 4 ?
		self:set_active_key(sustained_keys[self.arp_index])
	else
		-- even if no keys are held, bend targets may need to be reset
		self:set_bend_targets()
	end
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
	-- -- nudge min/max toward targets, and bend_value toward a linear point between min and max,
	-- -- thus reducing any offset that may have been caused by changes in min/max points
	-- self.bend_max = self.bend_max + (self.bend_max_target - self.bend_max) * self.bend_relax_coefficient
	-- self.bend_min = self.bend_min + (self.bend_min_target - self.bend_min) * self.bend_relax_coefficient
	-- -- how quickly bend_value should adjust depends on whether there are keys held
	-- local linear_bend = self.bend_min + (self.bend_amount + 1) * (self.bend_max - self.bend_min) / 2
	-- local coefficient = self.bend_relax_coefficient * (self.n_sustained_keys > 0 and self.bend_relax_coefficient or 2)
	-- self.bend_value = self.bend_value + (linear_bend - self.bend_value) * coefficient
end

function Keyboard:set_bend_targets()
	if not self.gliding then
		self.bend_min_target = -self.bend_range
		self.bend_min = self.bend_min_target
		self.bend_max_target = self.bend_range
		self.bend_max = self.bend_max_target
	else
		local range = (self.n_sustained_keys > 1) and 0 or self.bend_range
		local min = -range
		local max = range
		for k = 1, self.n_sustained_keys do
			local interval = self:get_key_id_pitch_value(self.sustained_keys[k]) - self.active_pitch
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

function Keyboard:transpose(t)
	self.transposition = t
	self.on_pitch()
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
				if self.arp_insert >= index then
					self.arp_insert = self.arp_insert - 1
				end
				self.n_sustained_keys = self.n_sustained_keys - 1
				if index > self.n_sustained_keys and self.n_sustained_keys > 0 then
					self:set_active_key(self.sustained_keys[self.n_sustained_keys])
				else
					self:set_bend_targets()
				end
				return
			end
		end
		if self.gliding or not self.arping or self.n_sustained_keys == 0 then
			-- glide mode, no arp, or first note held: push new note to the stack
			self.n_sustained_keys = self.n_sustained_keys + 1
			self.arp_index = self.n_sustained_keys
			self.arp_insert = self.n_sustained_keys
			table.insert(self.sustained_keys, key_id)
			self:set_active_key(key_id, self.n_sustained_keys == 1)
			-- set gate high if we're in retrig or pulse mode, or if this is the first note held
			if self.gate_mode ~= 1 or self.n_sustained_keys == 1 then
				self.on_gate(true)
			end
		else
			-- arp: insert note to be played at next arp tick
			self.arp_insert = self.arp_insert + 1
			table.insert(self.sustained_keys, self.arp_insert, key_id)
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
					if self.arp_insert >= i then
						self.arp_insert = self.arp_insert - 1
					end
				else
					i = i + 1
				end
			end
			if self.n_sustained_keys > 0 then
				self.arp_index = (self.arp_index - 1) % self.n_sustained_keys + 1
				self.arp_insert = (self.arp_insert - 1) % self.n_sustained_keys + 1
				if not self.arping then
					local released_active_key = key_id == self.active_key
					self:set_active_key(self.sustained_keys[self.arp_index])
					if released_active_key and self.gate_mode == 2 then
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
	if self.arping and self.n_sustained_keys > 0 then
		if gate then
			-- > works well with Lua's random range of [0,1):
			-- 0 prob really will be 0%, and 1.0 prob really will be 100%
			if math.random() > self.arp_forward_probability then
				-- advance
				self.arp_index = self.arp_index % self.n_sustained_keys + 1
			else
				-- retreat
				self.arp_index = (self.arp_index - 2) % self.n_sustained_keys + 1
			end
			self.arp_insert = self.arp_index
			self:set_active_key(self.sustained_keys[self.arp_index])
			self.on_arp()
		end
		self.on_gate(gate)
	end
end

function Keyboard:bend(amount)
	amount = math.sin(amount * math.pi / 2)
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

function Keyboard:set_active_key(key_id, glide_jump)
	local old_pitch = self.active_pitch
	self.active_key = key_id
	self.active_key_x, self.active_key_y = self:get_key_id_coords(key_id)
	self.active_pitch_id = self:get_key_pitch_id(self.active_key_x, self.active_key_y)
	self.active_pitch = self:get_pitch_id_value(self.active_pitch_id)
	if self.gliding and not glide_jump then
		-- glide_jump will hop from (e.g.) 0.1 st above old pitch to 0.1 st above new pitch.
		-- without glide_jump, bend_value will change to keep the output pitch the same, even while the
		-- base active pitch changes.
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
	g:led(self.x, self.y, self.mask_edit and 7 or (self.scale.mask_empty and 2 or 5))
	g:led(self.x, self.y + 2, self.gliding and 7 or 2)
	g:led(self.x, self.y2 - 3, self.arping and 7 or 2)
	g:led(self.x, self.y2 - 2, self.held_keys.latch and 7 or 2)
	g:led(self.x, self.y2, self.held_keys.shift and 15 or 6)

	local hand_pitch_low, hand_pitch_high, hand_pitch_weight = self.scale:get_nearest_mask_pitch_id(self.active_pitch + self.bend_value + self.octave, true)
	local transposed_pitch_low, transposed_pitch_high, transposed_pitch_weight = self.scale:get_nearest_mask_pitch_id(self.active_pitch + self.bend_value + self.transposition + self.octave, true)
	local sampled_pitch_low, sampled_pitch_high, sampled_pitch_weight = self.scale:get_nearest_mask_pitch_id(detected_pitch + self.transposition + self.bend_value, true)
	local detected_pitch_low, detected_pitch_high, detected_pitch_weight = self.scale:get_nearest_pitch_id(poll_values.pitch - 1, true)

	local offset = -self.scale.center_pitch_id - self.scale.length * self.octave
	hand_pitch_low = hand_pitch_low + offset
	hand_pitch_high = hand_pitch_high + offset
	transposed_pitch_low = transposed_pitch_low + offset
	transposed_pitch_high = transposed_pitch_high + offset
	sampled_pitch_low = sampled_pitch_low + offset
	sampled_pitch_high = sampled_pitch_high + offset
	detected_pitch_low = detected_pitch_low + offset
	detected_pitch_high = detected_pitch_high + offset

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
				local p = self:get_key_pitch_id(x, y)
				local level = 0
				if self.mask_edit then
					-- show mask
					level = self:is_mask_pitch(p) and 4 or 0
					-- when shift is held, highlight Cs as reference points
					if self.held_keys.shift and p % self.scale.length == 0 then
						level = led_blend(level, 2)
					end
				else
					-- highlight mask keys
					level = self:is_mask_pitch(p) and 3 or 0
					-- highlight sustained keys
					if self:is_key_sustained(key_id) then
						level = led_blend(level, 6)
					end
				end

				local pitch = self:get_key_id_pitch_value(key_id)

				if not do_pitch_detection or self.n_sustained_keys > 0 then
					if p == hand_pitch_low then
						level = led_blend(level, (1 - hand_pitch_weight) * 7)
					elseif p == hand_pitch_high then
						level = led_blend(level, hand_pitch_weight * 7)
					end
					if p == transposed_pitch_low then
						level = led_blend(level, (1 - transposed_pitch_weight) * 5)
					elseif p == transposed_pitch_high then
						level = led_blend(level, transposed_pitch_weight * 5)
					end
				elseif gate_in and do_pitch_detection then
					if p == sampled_pitch_low then
						level = led_blend(level, (1 - sampled_pitch_weight) * 7)
					elseif p == sampled_pitch_high then
						level = led_blend(level, sampled_pitch_weight * 7)
					end
				end

				if do_pitch_detection then
					if p == detected_pitch_low then
						level = led_blend(level, (1 - detected_pitch_weight) * 7 * poll_values.clarity)
					elseif p == detected_pitch_high then
						level = led_blend(level, detected_pitch_weight * 7 * poll_values.clarity)
					end
				end

				g:led(x, y, math.min(15, math.ceil(level)))
			end
		end
	end
end

function Keyboard:is_mask_pitch(p)
	p = p % self.scale.length
	return self.scale.mask[p + 1]
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

return Keyboard
