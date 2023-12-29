local Keyboard = {}
Keyboard.__index = Keyboard

local Scale = include 'lib/scale'
local et12 = {} -- default scale, 12TET
for p = 1, 12 do
	et12[p] = p / 12
end

-- TODO: panic function, for when a note gets stuck due to momentary grid connection loss
--       or whatever it is that causes that

-- TODO: VOICE CONTROL MODES:
--
-- 1. MONO, select voice manually
-- volume envelope is ADSR or touche tip
-- glide from any note to any other
-- 1 arp controls selected voice only
-- ...eventually: 7 arps control each voice independently :O
-- left grid column selects voice
-- each voice may be looped (using double taps, maybe?)
--
-- 2. PARALLEL VOICES, each row of keys controls 1 voice
-- volume envelope is either ADSR or (tip * AR)
-- glide from any note to any other IN THAT ROW
-- -- and if >1 key is held in one voice and 1 key in another,
--    the voice with 1 key should have NO glide (not even vibrato)
-- 1 arp scrolls/strums thru selected voices
-- left grid column enables arp for voices
--
-- 3. POLYPHONIC, with LRU voice stealing
-- volume envelope is either ADSR or (tip * AR)
-- no glide... for now
-- 1 arp plays a sequence distributed across a selection of voices
-- left grid column enables arp for voices

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
		arping = false,
		gliding = false,
		held_keys = {}, -- map of key names/ids to boolean states
		sustained_keys = {}, -- stack of sustained key IDs
		n_sustained_keys = 0,
		editing_sustained_key_index = false,
		arp_index = 0,
		arp_insert = 0,
		arp_randomness = 0,
		octave = 0,
		transposition = 0,
		active_key = 0,
		active_key_x = 8,
		active_key_y = 6,
		active_pitch_id = 0,
		active_pitch = 0,
		bent_pitch = 0,
		retrig = true,
		bend_range = 0.5,
		bend_amount = 0,
		glide_rate = 0.2,
		glide_min = 0,
		glide_max = 0,
		glide_min_target = 0,
		glide_max_target = 0,
		scale = Scale.new(et12, 12),
		voice_data = {},
		-- overridable callbacks
		on_pitch = function() end,
		on_gate = function() end,
		on_arp = function() end
	}
	setmetatable(keyboard, Keyboard)
	for v = 1, n_voices do
		keyboard.voice_data[v] = {
			low = 0,
			high = 0,
			weight = 0,
			amp = 0
		}
	end
	-- start at 0 / middle C
	keyboard:key(keyboard.x_center, keyboard.y_center, 1)
	keyboard:key(keyboard.x_center, keyboard.y_center, 0)
	-- update glide values when needed
	clock.run(function()
		while true do
			keyboard:glide()
			clock.sleep(0.01)
		end
	end)
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
	if y == self.y2 then
		if x == self.x then
			-- shift key
			self.held_keys.shift = z == 1
		elseif x == self.x + 2 then
			-- latch key
			if z == 1 then
				self.held_keys.latch = not self.held_keys.latch
				self:maybe_release_sustained_keys()
			end
		elseif x == self.x + 3 then
			-- arp toggle
			if z == 1 then
				self.arping = not self.arping
				if self.arping then
					self.gliding = false
					self.bent_pitch = self.active_pitch
					self:set_bend_targets()
				else
					self.on_gate(false)
				end
			end
		elseif x == self.x + 5 then
			-- glide toggle
			if z == 1 then
				self.gliding = not self.gliding
				self:set_bend_targets()
				if self.gliding then
					self.arping = false
				end
			end
		elseif x > self.x2 - 2 then
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
					if self.n_sustained_keys > 0 and self.retrig and not self.gliding then
						self.on_gate(true)
					end
				end
			elseif z == 1 then
				-- otherwise, jump up or down
				self.octave = util.clamp(self.octave + d, -5, 5)
				if not self.arping or self.n_sustained_keys == 0 then
					self.on_pitch()
					if self.n_sustained_keys > 0 and self.retrig and not self.gliding then
						self.on_gate(true)
					end
				end
			end
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
		self:set_active_key(sustained_keys[self.arp_index], true)
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

function Keyboard:set_bend_targets()
	if not self.gliding or self.n_sustained_keys <= 1 then
		return
	end
	local min = self.active_pitch
	local max = self.active_pitch
	for k = 1, self.n_sustained_keys do
		local pitch = self:get_key_id_pitch_value(self.sustained_keys[k])
		min = math.min(min, pitch)
		max = math.max(max, pitch)
	end
	-- if we've just released the highest or lowest note of several, then bent_pitch may now be
	-- outside the range of [min, max]. so we save the min/max held pitches as "target" values,
	-- but stretch the range temporarily so that it includes bent_pitch. as bent_pitch moves,
	-- glide() will adjust the range so that it's no wider than it needs to be.
	self.glide_min_target = min
	self.glide_min = math.min(self.bent_pitch, min)
	self.glide_max_target = max
	self.glide_max = math.max(self.bent_pitch, max)
end

function Keyboard:glide()
	if not self.gliding or self.n_sustained_keys <= 1 then
		return
	end
	-- one-pole glide with overshoot and clamp: fixed-ISH glide time, expo/log-ISH approach but
	-- not asymtotic -- because glide is smoothing toward just beyond the min/max, then being
	-- clamped to min/max
	-- TODO: it might even be useful to save the *unclamped* pitch somewhere and glide that
	-- around; that would create a small dead zone in the center of the paddle after gliding all
	-- the way to (and past) a target pitch.
	local amount = math.abs(self.bend_amount * self.bend_amount * self.bend_amount)
	if self.bend_amount < 0 then
		self.bent_pitch = math.max(
			self.glide_min,
			self.bent_pitch + (self.glide_min - self.bend_range - self.bent_pitch) * self.glide_rate * amount
		)
		-- move glide_max if needed/possible
		if self.glide_max > self.glide_max_target then
			self.glide_max = math.max(self.glide_max_target, self.bent_pitch)
		end
	elseif self.bend_amount > 0 then
		self.bent_pitch = math.min(
			self.glide_max,
			self.bent_pitch + (self.glide_max + self.bend_range - self.bent_pitch) * self.glide_rate * amount
		)
		-- move glide_min if needed/possible
		if self.glide_min < self.glide_min_target then
			self.glide_min = math.min(self.glide_min_target, self.bent_pitch)
		end
	end
	--]]
	self.on_pitch()
end

function Keyboard:transpose(t)
	self.transposition = t
	self.on_pitch()
end

function Keyboard:note(x, y, z)
	local key_id = self:get_key_id(x, y)
	local sustained_key_index = self:find_sustained_key(key_id)
	self.held_keys[key_id] = z == 1
	if z == 1 then
		-- key pressed
		if self.held_keys.latch then
			if self.editing_sustained_key_index then
				self.sustained_keys[self.editing_sustained_key_index] = key_id
				self.editing_sustained_key_index = false
				return
			elseif not self.held_keys.shift and sustained_key_index then
				self.editing_sustained_key_index = sustained_key_index
				return
			end
		end
		if self.gliding or not self.arping or self.n_sustained_keys == 0 then
			-- glide mode, no arp, or first note held: push new note to the stack
			self.n_sustained_keys = self.n_sustained_keys + 1
			self.arp_index = self.n_sustained_keys
			self.arp_insert = self.n_sustained_keys
			table.insert(self.sustained_keys, key_id)
			self:set_active_key(key_id)
			-- set gate high if we're in retrig mode, or if this is the first note held
			if (self.retrig and not self.gliding) or self.n_sustained_keys == 1 then
				self.on_gate(true)
			end
		else
			-- arp: insert note to be played at next arp tick
			self.arp_insert = self.arp_insert + 1
			table.insert(self.sustained_keys, self.arp_insert, key_id)
			self.n_sustained_keys = self.n_sustained_keys + 1
		end
	elseif self.held_keys.latch then
		-- latch held, key released
		if sustained_key_index and sustained_key_index == self.editing_sustained_key_index then
			table.remove(self.sustained_keys, sustained_key_index)
			if self.arp_index >= sustained_key_index then
				self.arp_index = self.arp_index - 1
			end
			if self.arp_insert >= sustained_key_index then
				self.arp_insert = self.arp_insert - 1
			end
			self.n_sustained_keys = self.n_sustained_keys - 1
			if not self.arping and sustained_key_index > self.n_sustained_keys and self.n_sustained_keys > 0 then
				self:set_active_key(self.sustained_keys[self.n_sustained_keys])
			else
				self:set_bend_targets()
			end
			if self.n_sustained_keys == 0 then
				self.on_gate(false)
			end
			self.editing_sustained_key_index = false
		end
	else
		-- key released: release or remove from sustained keys
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
				self:set_active_key(self.sustained_keys[self.arp_index], true)
				if released_active_key and self.retrig and not self.gliding then
					self.on_gate(true)
				end
			end
		else
			self.on_gate(false)
		end
	end
end

function Keyboard:arp(gate)
	if self.arping and self.n_sustained_keys > 0 then
		if gate then
			-- at randomness = 0, step size is always 1; at randomness = 1, step size varies from
			-- (-n/2 + 1) to (n/2), but is never zero
			local step_size = math.ceil((math.random() - 0.5) * self.arp_randomness * self.n_sustained_keys + 0.5)
			if step_size < 1 then
				step_size = step_size - 1
			end
			self.arp_index = (self.arp_index + step_size - 1) % self.n_sustained_keys + 1
			self.arp_insert = self.arp_index
			self:set_active_key(self.sustained_keys[self.arp_index])
			self.on_arp()
		end
		self.on_gate(gate)
	end
end

function Keyboard:bend(amount)
	-- if not self.gliding then
	-- 	amount = math.sin(amount * math.pi / 2)
	-- end
	-- TODO: document/explain the logic here
	if not self.gliding or self.n_sustained_keys <= 1 then
		local delta = amount - self.bend_amount
		if delta < 0 then
			self.bent_pitch = self.bent_pitch + (self.active_pitch - self.bend_range - self.bent_pitch) * delta / (-1 - self.bend_amount)
		else
			self.bent_pitch = self.bent_pitch + (self.active_pitch + self.bend_range - self.bent_pitch) * delta / (1 - self.bend_amount)
		end
	end
	self.bend_amount = amount
end

function Keyboard:set_active_key(key_id, is_release)
	local old_active_pitch = self.active_pitch
	self.active_key = key_id
	self.active_key_x, self.active_key_y = self:get_key_id_coords(key_id)
	self.active_pitch_id = self:get_key_pitch_id(self.active_key_x, self.active_key_y)
	self.active_pitch = self:get_pitch_id_value(self.active_pitch_id)
	if is_release and self.gliding and self.n_sustained_keys == 1 then
		-- we just released the 2nd note of a glide pair; jump straight to the new active
		-- pitch, as if bend value were 0, even though it's not. bend range will linearize
		-- over time as bend() is called.
		self.bent_pitch = self.active_pitch
	elseif not self.gliding or self.n_sustained_keys == 1 then
		-- measure the current bend amount. if we've just released a note, measure bend from
		-- the newly active pitch [TODO: but that basically has the effect of setting bend
		-- to 0... right?]; if we've just added a note, measure from the previously active
		-- pitch, so that we can apply the same amount of bend to the new active pitch.
		local bend_interval = self.bent_pitch - (is_release and self.active_pitch or old_active_pitch)
		bend_interval = util.clamp(
			bend_interval,
			self.bend_range * math.min(0, self.bend_amount),
			self.bend_range * math.max(0, self.bend_amount)
		)
		self.bent_pitch = self.active_pitch + bend_interval
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
	-- TODO: blink editing_sustained_key_index
	g:led(self.x, self.y2, self.held_keys.shift and 15 or 6)
	g:led(self.x + 2, self.y2, self.held_keys.latch and 7 or 2)
	g:led(self.x + 3, self.y2, self.arping and 7 or 2)
	g:led(self.x + 5, self.y2, self.gliding and 7 or 2)

	-- TODO: remind me why this exists again...
	local offset = -self.scale.center_pitch_id - self.scale.length * self.octave

	for v = 1, n_voices do
		local low, high, weight = self.scale:get_nearest_pitch_id(voice_states[v].pitch, true)
		self.voice_data[v].low = low + offset
		self.voice_data[v].high = high + offset
		self.voice_data[v].weight = weight
		self.voice_data[v].amp = voice_states[v].amp
		self.voice_data[v].control = voice_states[v].control
	end

	for x = self.x, self.x2 do
		for y = self.y, self.y2 do
			if y == self.y2 then
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
				-- highlight sustained keys
				if self:is_key_sustained(key_id) then
					level = led_blend(level, 6)
				end

				local pitch = self:get_key_id_pitch_value(key_id)

				for v = 1, n_voices do
					local voice = self.voice_data[v]
					local is_control = voice.control and 1 or 0
					if p == voice.low then
						level = led_blend(level, (1 - voice.weight) * ((is_control * 4) + (is_control * 3 + 16) * math.sqrt(voice.amp)))
					elseif p == voice.high then
						level = led_blend(level, voice.weight * ((is_control * 4) + (is_control * 3 + 16) * math.sqrt(voice.amp)))
					end
				end

				g:led(x, y, math.min(15, math.ceil(level)))
			end
		end
	end
end

function led_blend(a, b)
	a = 1 - a / 15
	b = 1 - b / 15
	return (1 - (a * b)) * 15
end

return Keyboard
