local Keyboard = {}
Keyboard.__index = Keyboard

local Scale = include 'lib/scale'
local et12 = {} -- default scale, 12TET
for p = 1, 12 do
	et12[p] = { p / 12, nil }
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
		x_center = 9, -- coordinates of the center pitch (0)
		y_center = 6,
		row_offset = 5, -- each row's pitch is a fourth higher than the last
		gliding = false,
		held_keys = { -- map of key names/ids to boolean states
			voice_loops = {}
		},
		sustained_keys = {}, -- stack of sustained key IDs
		n_sustained_keys = 0,
		editing_sustained_key_index = false,
		arp_index = 0,
		arp_insert = 0,
		arp_direction = 1, -- select arp notes by (1) order played, (2) random, or (3) plectrum distance
		arp_plectrum = false, -- trigger by plectrum
		arping = false,
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
		selected_voice = 1,
		-- overridable callbacks
		on_select_voice = function() end,
		on_voice_octave = function() end,
		on_pitch = function() end,
		on_gate = function() end,
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
	-- start plectrum there too
	keyboard.plectrum = {
		x = keyboard.x_center,
		y = keyboard.y_center,
		last_moved = 0,
		arp_index = nil,
		key_id = nil,
		key_distance = math.huge
	}
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
	return (x - self.x_center) + (self.y_center - y) * self.row_offset + self.scale.length * self.octave
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
	return self.scale:get(p)
end

function Keyboard:get_key_neighbor(x, y, d)
	if d > 0 then
		while d > self.row_offset or x + d > self.width do
			y = y - 1
			d = d - self.row_offset
		end
		x = x + d
	else
		while d < -self.row_offset or x + d <= 0 do
			y = y + 1
			d = d + self.row_offset
		end
		x = x + d
	end
	return x, y
end

function Keyboard:get_key_id_neighbor(id, d)
	local x, y = self:get_key_id_coords(id)
	x, y = self:get_key_neighbor(x, y, d)
	return self:get_key_id(x, y)
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
			-- glide toggle
			if z == 1 then
				self.gliding = not self.gliding
				self:set_bend_targets()
				if self.gliding then
					self.arping = false
					arp_menu:select(false)
				end
			end
		elseif x >= self.x + 5 and x <= self.x + 10 then
			-- arp select / toggle
			-- TODO: move this outside the Keyboard class
			-- local source = x - self.x - 4
			-- if z == 1 then
			-- 	if self.arp_clock_source == source then
			-- 		self.arp_clock_source = false
			-- 		self.on_gate(false)
			-- 	else
			-- 		self.arp_clock_source = source
			-- 		self.gliding = false
			-- 		self.bent_pitch = self.active_pitch
			-- 		self:set_bend_targets()
			-- 	end
			-- end
		elseif x == self.x2 - 3 then
			self.held_keys.octave_scroll = z == 1
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
			if z == 1 then
				-- if both keys are pressed together, reset octave to 0
				local do_octave_reset = self.held_keys.up and self.held_keys.down
				local shifted_voice = false
				if not self.held_keys.octave_scroll then
					-- if scroll is off and voice key(s) are held, change voice octave(s)
					for v = 1, n_voices do
						if self.held_keys.voice_loops[v] then
							self.on_voice_shift(v, do_octave_reset and 0 or d * self.scale.span)
							shifted_voice = true
						end
					end
				end
				-- otherwise, change keyboard octave
				if not shifted_voice then
					self:shift_octave(do_octave_reset and -self.octave or d)
				end
			end
		end
	elseif x <= self.x + 1 then
		local v = self.y2 - y
		if x == self.x and y == self.y then
			if z == 1 then
				-- loop delete key
				for v = 1, n_voices do
					if self.held_keys.voice_loops[v] then
						clear_voice_loop(v)
					end
				end
			end
		elseif v <= n_voices then
			if x == self.x then
				if y == self.y then
				elseif v <= n_voices then
					-- voice loop keys
					self.held_keys.voice_loops[v] = z == 1
					local voice = voice_states[v]
					-- cheating a little here by calling functions from fretware.lua. TODO: clean up?
					if z == 1 and not voice.looping then
						if voice.loop_armed then
							play_voice_loop(v)
						else
							self:select_voice(v)
							record_voice_loop(v)
						end
					end
				end
			else
				-- voice select keys
				if z == 1 then
					self:select_voice(v)
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
	if self.arp_plectrum then
		self:move_plectrum(0, 0)
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

function Keyboard:shift_octave(od)
	-- change octave, clamping to +/-5
	local o = self.octave
	self.octave = util.clamp(self.octave + od, -7, 7)
	-- clamp od if octave was clamped above
	od = self.octave - o
	local held_keys = self.held_keys
	-- move bent pitch, if appropriate
	-- this needs to happen BEFORE we move sustained_keys around,
	-- so we can know if all sustained keys were held before the shift happened
	if self.gliding then
		-- always move if scroll is off
		local move_bent_pitch = not held_keys.octave_scroll
		-- or if ALL sustained keys are being held
		if not move_bent_pitch and self.n_sustained_keys > 0 then
			move_bent_pitch = true
			local k = 1
			while move_bent_pitch and k <= self.n_sustained_keys do
				move_bent_pitch = move_bent_pitch and held_keys[self.sustained_keys[k]]
				k = k + 1
			end
		end
		if move_bent_pitch then
			self.bent_pitch = self.bent_pitch + od
		end
	end
	-- when scroll is not engaged, all key IDs remain the same so that pitches change.
	-- when engaged, sustained (but not held) keys must be shifted so that pitches remain the same
	if held_keys.octave_scroll then
		local sustained_keys = self.sustained_keys
		-- how far must keys be shifted so that their pitches remain the same?
		local d = -od * self.scale.length
		for i = 1, self.n_sustained_keys do
			if not held_keys[sustained_keys[i]] then
				sustained_keys[i] = self:get_key_id_neighbor(sustained_keys[i], d)
			end
		end
		if not held_keys[self.active_key] then
			self:set_active_key(self:get_key_id_neighbor(self.active_key, d))
		end
		-- move the plectrum too!
		-- TODO: make this work with non-12-tone tunings!
		-- this assumes an octave is spelled the way it is in 12TET.
		self:move_plectrum(od * -2, od * 2, true)
	else
		-- TODO NEXT: this still isn't making the instantaneous change
		-- I would want, I think because key IDs remain the same...
		-- update_plectrum_arp_index() should probably save the NOTE too for comparison in move_plectrum()
		self:move_plectrum(0, 0, true)
	end
	-- recalculate active pitch with new octave
	if not self.arping or self.n_sustained_keys == 0 then
		self:set_active_key(self.active_key)
		if self.n_sustained_keys > 0 and self.retrig and not self.gliding then
			self.on_gate(true)
		end
	end
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
				self:set_bend_targets()
				if self.arp_plectrum then
					self:move_plectrum(0, 0)
				end
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
			if not self.arping and ((self.retrig and not self.gliding) or self.n_sustained_keys == 1) then
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
	if self.arp_plectrum then
		self:move_plectrum(0, 0)
	end
end

function Keyboard:arp(gate)
	if self.arping and self.n_sustained_keys > 0 then
		if gate then
			if self.arp_direction == 3 then
				local new_arp_index = self:update_plectrum_arp_index()
				if new_arp_index then
					self.arp_index = new_arp_index
				end
			else
				-- at randomness = 0, step size is always 1; at randomness = 1, step size varies from
				-- (-n/2 + 1) to (n/2), but is never zero
				local step_size = 1
				if self.arp_direction == 2 then
					-- 1-rand makes random range (0,1] instead of [0,1)
					-- so we'll be jumping at least 1 step, up to n_keys-1
					step_size = math.ceil((1 - math.random()) * (self.n_sustained_keys - 1))
				end
				self.arp_index = (self.arp_index + step_size - 1) % self.n_sustained_keys + 1
			end
			self.arp_insert = self.arp_index
			self:set_active_key(self.sustained_keys[self.arp_index])
		end
		self.on_gate(gate)
	end
end

function Keyboard:wrap_coords(x, y)
	local octave_shift = 0
	if x >= self.x2 + 0.5 then
		x = x - (self.width - 2)
		octave_shift = octave_shift + 1
	elseif x < self.x + 1.5 then
		x = x + (self.width - 2)
		octave_shift = octave_shift - 1
	end
	if y > self.y2 - 0.5 then
		y = y - (self.height - 1)
		octave_shift = octave_shift - 1
	elseif y <= self.y - 0.5 then
		y = y + (self.height - 1)
		octave_shift = octave_shift + 1
	end
	return x, y, octave_shift
end

function Keyboard:move_plectrum(dx, dy, skip_octave_shift)
	local now = util.time()
	if dx ~= 0 or dy ~= 0 then
		self.plectrum.last_moved = now
	end
	-- change octaves and wrap when we go off an edge
	local new_x, new_y, octave_shift = self:wrap_coords(self.plectrum.x + dx, self.plectrum.y + dy)
	self.plectrum.x, self.plectrum.y = new_x, new_y
	if not skip_octave_shift and octave_shift ~= 0 then
		self:shift_octave(octave_shift)
	end
	if self.arp_plectrum and self.n_sustained_keys > 1 then
		local old_arp_index, old_key_id, old_distance = self.plectrum.arp_index, self.plectrum.key_id, self.plectrum.key_distance
		local new_arp_index = self:update_plectrum_arp_index()
		if not new_arp_index then
			if old_key_id then
				self.on_gate(false)
			end
		else
			if old_key_id ~= self.sustained_keys[new_arp_index] then
				self.arp_index = new_arp_index
				self.arp_insert = self.arp_index
				self:set_active_key(self.sustained_keys[self.arp_index])
				self.on_gate(true)
			end
		end
	end
end

function Keyboard:get_plectrum_distances(x, y)
	-- overall distance
	local dx = math.abs(x - self.plectrum.x)
	local dy = math.abs(y - self.plectrum.y)
	-- wrap around edges
	dx = math.min(dx, math.abs(dx - (self.width - 2)))
	dy = math.min(dy, math.abs(dy - (self.height - 1)))
	return dx, dy
end

function Keyboard:update_plectrum_arp_index()
	if self.n_sustained_keys < 1 then
		self.plectrum.arp_index = nil
		self.plectrum.key_id = nil
		self.plectrum.key_distance = math.huge
		return nil
	end
	local best_distance = math.huge
	local closest_arp_index = nil
	for n = 1, self.n_sustained_keys do
		local key_x, key_y = self:get_key_id_coords(self.sustained_keys[n])
		local dx, dy = self:get_plectrum_distances(key_x, key_y)
		if dx < 1.5 and dy < 1.5 then
			local distance = math.sqrt(dx * dx + dy * dy)
			if distance < 1.5 and distance < best_distance then
				best_distance = distance
				closest_arp_index = n
			end
		end
	end
	self.plectrum.arp_index = closest_arp_index
	self.plectrum.key_id = self.sustained_keys[closest_arp_index]
	self.plectrum.key_distance = best_distance
	return closest_arp_index
end

function Keyboard:bend(amount)
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

function Keyboard:select_voice(v)
	if self.selected_voice == v then
		return
	end
	self.selected_voice = v
	self.on_select_voice(v)
end

function Keyboard:draw()
	-- TODO: blink editing_sustained_key_index
	g:led(self.x, self.y2, self.held_keys.shift and 15 or 6)
	g:led(self.x + 2, self.y2, self.held_keys.latch and 7 or 2)
	g:led(self.x + 3, self.y2, self.gliding and 7 or 2)
	-- TODO: draw arp button and menu in main script
	g:led(self.x2 - 3, self.y2, self.held_keys.octave_scroll and 7 or 2)
	g:led(self.x2 - 1, self.y2, math.min(15, math.max(0, (self.held_keys.down and 7 or 2) - math.min(self.octave, 0))))
	g:led(self.x2, self.y2, math.min(15, math.max(0, (self.held_keys.up and 7 or 2) + math.max(self.octave, 0))))

	local has_voice_key_held = false

	for v = 1, n_voices do
		local low, high, weight = self.scale:get_nearest_pitch_id(voice_states[v].pitch, true)
		self.voice_data[v].low = low
		self.voice_data[v].high = high
		self.voice_data[v].weight = weight
		self.voice_data[v].amp = voice_states[v].amp
		self.voice_data[v].mix_level = voice_states[v].mix_level
		has_voice_key_held = has_voice_key_held or self.held_keys.voice_loops[v]
		g:led(2, 8 - v, self.selected_voice == v and 8 or 2)
	end

	-- highlight plectrum location, if it's been moved recently
	local plectrum_level = math.min(1, 2 - (util.time() - self.plectrum.last_moved)) * 7

	for x = self.x + 2, self.x2 do
		for y = self.y, self.y2 - 1 do
			local key_id = self:get_key_id(x, y)
			local p = self:get_key_pitch_id(x, y)
			local level = 0
			-- highlight sustained keys
			if self:is_key_sustained(key_id) then
				level = led_blend(level, 6)
			end

			local pitch = self:get_key_id_pitch_id(key_id)
			local pitch_class = pitch % self.scale.length
			level = led_blend(level, self.scale.levels[pitch_class])

			for v = 1, n_voices do
				local voice = self.voice_data[v]
				local is_control = self.selected_voice == v and 1 or 0
				if p == voice.low or p == voice.high then
					local voice_level = ((is_control * 4) + (is_control * 3 + 16) * math.sqrt(voice.amp))
					if not self.held_keys.voice_loops[v] then
						-- when this voice's loop key is not held, scale brightness by output level in mix
						voice_level = voice_level * voice.mix_level
						-- when any OTHER voice's loop key is held, dim non-held voices
						if has_voice_key_held then
							voice_level = voice_level * 0.1
						end
					end
					-- scale levels of high + low approximations of this voice's pitch by weight
					if p == voice.low then
						voice_level = (1 - voice.weight) * voice_level
					elseif p == voice.high then
						voice_level = voice.weight * voice_level
					end
					level = led_blend(level, voice_level)
				end
			end

			if plectrum_level > 0 then
				local dx, dy = self:get_plectrum_distances(x, y)
				-- level is (1 - distance) or 0
				if dx < 1 and dy < 1 then
					local distance = math.sqrt(dx * dx + dy * dy)
					level = led_blend(level, plectrum_level * math.max(0, 1 - distance))
				end
			end

			g:led(x, y, math.min(15, math.ceil(level)))
		end
	end

	-- voice loop delete key
	for v = 1, n_voices do
		if self.held_keys.voice_loops[v] and voice_states[v].looping then
			g:led(self.x, self.y, 7)
		end
	end
end

function led_blend(a, b)
	a = 1 - a / 15
	b = 1 - b / 15
	return (1 - (a * b)) * 15
end

return Keyboard
