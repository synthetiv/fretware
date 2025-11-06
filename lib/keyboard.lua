local Keyboard = {}
Keyboard.__index = Keyboard

local Scale = include 'lib/scale'
local et12 = {} -- default scale, 12TET
for p = 1, 12 do
	et12[p] = { p / 12, nil }
end

local Stepper = include 'lib/stepper'

local min_plectrum_distance = 1.5 -- plectrum must be <= 1.5 keys away to play/select a note

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
			voices = {},
			voice_loops = {}
		},
		stack = {}, -- arp/sustain stack: { id, gate... }
		stack_edit_index = false,
		stack_edit_start = 0,
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
	keyboard.stepper = Stepper.new(keyboard, 3, 1, 7, 7)
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

function Keyboard:can_delete_stack_edit_key()
	return self.held_keys.latch and self.stack_edit_index and util.time() - self.stack_edit_start >= 0.15
end

function Keyboard:key(x, y, z)
	if y == self.y2 then
		if x == self.x then
			-- shift key
			self.held_keys.shift = z == 1
			if not self.held_keys.shift then
				self.stepper:clear_clipboard()
			end
		elseif x == self.x + 2 then
			-- latch key
			if z == 1 then
				self.held_keys.latch = not self.held_keys.latch
				self:maybe_clear_stack()
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
				-- delete stack key
				if self:can_delete_stack_edit_key() then
					self:remove_stack_key(self.stack_edit_index)
					self.stack_edit_index = false
				end
				-- delete voice loops
				for ov = 1, n_voices do
					if self.held_keys.voice_loops[ov] then
						voice_loop_clear(ov)
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
					if z == 1 and not voice.loop_playing then
						if voice.loop_record_started then
							voice_loop_set_end(v)
						else
							self:select_voice(v)
							voice_loop_record(v)
						end
					end
				end
			else
				-- voice select keys
				self.held_keys.voices[v] = z == 1
				if z == 1 then
					self:select_voice(v)
				end
			end
		end
	else
		self:note(x, y, z)
	end
end

function Keyboard:shift_stack(d)
	if d > 0 then
		for i = 1, d do
			table.insert(self.stack, table.remove(self.stack, 1))
		end
	else
		for i = 1, -d do
			table.insert(self.stack, 1, table.remove(self.stack, #self.stack))
		end
	end
	if self.stack_edit_index then
		self.stack_edit_index = (self.stack_edit_index - d - 1) % #self.stack + 1
	end
	self.arp_index = (self.arp_index - d - 1) % #self.stack + 1
	self.arp_insert = (self.arp_insert - d - 1) % #self.stack + 1
end

function Keyboard:remove_stack_key(i)
	table.remove(self.stack, i)
	if self.stack_edit_index then
		if self.stack_edit_index >= i then
			self.stack_edit_index = self.stack_edit_index - 1
		end
	end
	if self.arp_index >= i then
		self.arp_index = self.arp_index - 1
	end
	if self.arp_insert >= i then
		self.arp_insert = self.arp_insert - 1
	end
end

function Keyboard:maybe_clear_stack()
	if self.held_keys.latch then
		return
	end
	local held_keys = self.held_keys
	local stack = self.stack
	local i = 1
	while i <= #self.stack do
		if held_keys[stack[i].id] then
			i = i + 1
		else
			self:remove_stack_key(i)
		end
	end
	local n_stack = #self.stack
	if n_stack > 0 then
		self.arp_index = (self.arp_index - 1) % n_stack + 1
		self.arp_insert = (self.arp_insert - 1) % n_stack + 1
		self:set_active_key(stack[self.arp_index].id, true)
	else
		-- even if no keys are held, bend targets may need to be reset
		self:set_bend_targets()
	end
	if self.arp_plectrum then
		self:move_plectrum(0, 0)
	end
end

function Keyboard:shift_octave(od)
	-- change octave, clamping to +/-5
	local o = self.octave
	self.octave = util.clamp(self.octave + od, -7, 7)
	-- clamp od if octave was clamped above
	od = self.octave - o
	local held_keys = self.held_keys
	-- move bent pitch, if appropriate
	-- this needs to happen BEFORE we move stack keys around,
	-- so we can know if all stack keys were held before the shift happened
	if self.gliding then
		-- always move if scroll is off
		local move_bent_pitch = not held_keys.octave_scroll
		-- or if ALL stack keys are being held
		if not move_bent_pitch and #self.stack > 0 then
			move_bent_pitch = true
			local k = 1
			while move_bent_pitch and k <= #self.stack do
				move_bent_pitch = move_bent_pitch and held_keys[self.stack[k].id]
				k = k + 1
			end
		end
		if move_bent_pitch then
			self.bent_pitch = self.bent_pitch + od
		end
	end
	-- when scroll is not engaged, all key IDs remain the same so that pitches change.
	-- when engaged, stack keys that aren't held must be shifted so that pitches remain the same
	if held_keys.octave_scroll then
		local stack = self.stack
		-- how far must keys be shifted so that their pitches remain the same?
		local d = -od * self.scale.length
		for i = 1, #self.stack do
			if not held_keys[stack[i].id] then
				stack[i].id = self:get_key_id_neighbor(stack[i].id, d)
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
		self:move_plectrum(0, 0)
	end
	-- recalculate active pitch with new octave
	if not self.arping or #self.stack == 0 then
		self:set_active_key(self.active_key)
		if #self.stack > 0 and self.retrig and not self.gliding then
			self.on_gate(true)
		end
	end
end

function Keyboard:set_bend_targets()
	if not self.gliding or #self.stack <= 1 then
		return
	end
	local min = self.active_pitch
	local max = self.active_pitch
	for k = 1, #self.stack do
		local pitch = self:get_key_id_pitch_value(self.stack[k].id)
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
	if not self.gliding or #self.stack <= 1 then
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
	local stack_key_index = self:find_key_in_stack(key_id)
	self.held_keys[key_id] = z == 1
	if z == 1 then
		-- key pressed
		if self.held_keys.latch then
			local did_edit_step = false
			-- TODO: if a stepper key OUTSIDE stack length is held and a key is
			-- pressed, rests should be added to fill gap between end and that step,
			-- then that step set to the key.
			for s = 1, #self.stack do
				if self.stepper.held_steps[s] then
					self.stack[s].id = key_id
					did_edit_step = true
				end
			end
			if did_edit_step then
				self:set_bend_targets()
				if self.arp_plectrum then
					self:move_plectrum(0, 0)
				end
				return
			end
			if self.stack_edit_index then
				self.stack[self.stack_edit_index].id = key_id
				self:set_bend_targets()
				if self.arp_plectrum then
					self:move_plectrum(0, 0)
				end
				self.stack_edit_start = 0 -- even if new key is released immediately, now that it's been moved, it won't be removed from the stack
				return
			elseif not self.held_keys.shift and stack_key_index then
				self.stack_edit_start = util.time()
				self.stack_edit_index = stack_key_index
				return
			end
		end
		if self.gliding or not self.arping or #self.stack == 0 then
			-- glide mode, no arp, or first note held: push new note to the stack
			self.arp_index = #self.stack
			self.arp_insert = #self.stack
			table.insert(self.stack, {
				id = key_id,
				gate = true
			})
			self:set_active_key(key_id)
			-- set gate high if we're in retrig mode, or if this is the first note held
			if not self.arping and ((self.retrig and not self.gliding) or #self.stack == 1) then
				self.on_gate(true)
			end
		else
			-- arp: insert note to be played at next arp tick
			self.arp_insert = self.arp_insert + 1
			table.insert(self.stack, self.arp_insert, {
				id = key_id,
				gate = true
			})
		end
	elseif self.held_keys.latch then
		-- latch held, key released
		if stack_key_index and stack_key_index == self.stack_edit_index then
			if util.time() - self.stack_edit_start < 0.15 then
				self:remove_stack_key(stack_key_index)
			end
			if not self.arping then
				if stack_key_index > #self.stack and #self.stack > 0 then
					self:set_active_key(self.stack[#self.stack].id)
				else
					self:set_bend_targets()
				end
			end
			if #self.stack == 0 then
				self.on_gate(false)
			end
			self.stack_edit_index = false
		end
	else
		-- key released: release or remove from stack
		local i = 1
		while i <= #self.stack do
			if self.stack[i].id == key_id then
				self:remove_stack_key(i)
			else
				i = i + 1
			end
		end
		local n_stack = #self.stack
		if n_stack > 0 then
			self.arp_index = (self.arp_index - 1) % n_stack + 1
			self.arp_insert = (self.arp_insert - 1) % n_stack + 1
			if not self.arping then
				local released_active_key = key_id == self.active_key
				self:set_active_key(self.stack[self.arp_index].id, true)
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
	if self.arping and #self.stack > 0 then
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
					step_size = math.ceil((1 - math.random()) * (#self.stack - 1))
				end
				self.arp_index = (self.arp_index + step_size - 1) % #self.stack + 1
			end
			self.arp_insert = self.arp_index
			if self.stack[self.arp_index].gate then
				self:set_active_key(self.stack[self.arp_index].id)
				self.on_gate(true)
			end
		else
			self.on_gate(false)
		end
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

function Keyboard:move_plectrum(dx, dy, nowrap)
	local now = util.time()
	if dx ~= 0 or dy ~= 0 then
		self.plectrum.last_moved = now
	end
	local new_x, new_y = self.plectrum.x + dx, self.plectrum.y + dy
	local octave_shift = 0
	if nowrap then
		-- if moving the plectrum would push it off an edge of the screen, don't move it
		if new_x < self.x + 2 or new_x > self.x2 or new_y < self.y or new_y > self.y2 - 1 then
			new_x, new_y = self.plectrum.x, self.plectrum.y
		end
	else
		-- if moving the plectrum pushes it off an edge, change octaves and wrap
		new_x, new_y, octave_shift = self:wrap_coords(new_x, new_y)
	end
	self.plectrum.x, self.plectrum.y = new_x, new_y
	if octave_shift ~= 0 then
		self:shift_octave(octave_shift)
	end
	if self.arp_plectrum and #self.stack > 1 then
		local old_key_id, old_pitch_id = self.plectrum.key_id, self.plectrum.pitch_id
		local new_arp_index = self:update_plectrum_arp_index()
		if not new_arp_index then
			if old_key_id then
				self.on_gate(false)
			end
		else
			if old_key_id ~= self.plectrum.key_id or old_pitch_id ~= self.plectrum.pitch_id then
				self.arp_index = new_arp_index
				self.arp_insert = self.arp_index
				self:set_active_key(self.stack[self.arp_index].id)
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
	if #self.stack < 1 then
		self.plectrum.arp_index = nil
		self.plectrum.key_distance = math.huge
		self.plectrum.key_id = nil
		self.plectrum.pitch_id = nil
		return nil
	end
	local best_distance = math.huge
	local closest_arp_index = nil
	for n = 1, #self.stack do
		local key_x, key_y = self:get_key_id_coords(self.stack[n].id)
		local dx, dy = self:get_plectrum_distances(key_x, key_y)
		-- first, compare x and y directly so we can throw out any way-off candidates
		if dx < min_plectrum_distance and dy < min_plectrum_distance then
			-- now try a more precise distance calculation
			local distance = math.sqrt(dx * dx + dy * dy)
			if distance < min_plectrum_distance and distance < best_distance then
				best_distance = distance
				closest_arp_index = n
			end
		end
	end
	-- if we found a nearby key, update plectrum properties
	if closest_arp_index then
		self.plectrum.arp_index = closest_arp_index
		self.plectrum.key_distance = best_distance
		self.plectrum.key_id = self.stack[closest_arp_index].id
		self.plectrum.pitch_id = self:get_key_id_pitch_id(self.plectrum.key_id)
	end
	return closest_arp_index
end

function Keyboard:bend(amount)
	-- TODO: document/explain the logic here
	if not self.gliding or #self.stack <= 1 then
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
	if is_release and self.gliding and #self.stack == 1 then
		-- we just released the 2nd note of a glide pair; jump straight to the new active
		-- pitch, as if bend value were 0, even though it's not. bend range will linearize
		-- over time as bend() is called.
		self.bent_pitch = self.active_pitch
	elseif not self.gliding or #self.stack == 1 then
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

function Keyboard:find_key_in_stack(key_id)
	local stack = self.stack
	local found_key = false
	-- TODO: why is stack_edit_index sometimes out of bounds...?
	if self.stack_edit_index and self.stack[self.stack_edit_index] and self.stack[self.stack_edit_index].id == key_id then
		return self.stack_edit_index, self.stack[self.stack_edit_index].gate
	end
	for k = 1, #self.stack do
		local index = (self.arp_index + k - 2) % #self.stack + 1
		if stack[index].id == key_id then
			if stack[index].gate then
				-- found the key AND the gate is high
				return index, true
			end
			-- found but gate is low, keep looking just in case
			found_key = index
		end
	end
	return found_key, false
end

function Keyboard:select_voice(v)
	if self.selected_voice == v then
		return
	end
	self.selected_voice = v
	self.on_select_voice(v)
end

function Keyboard:draw()
	g:led(self.x, self.y2, self.held_keys.shift and 15 or 6)
	g:led(self.x + 2, self.y2, self.held_keys.latch and 7 or 2)
	g:led(self.x + 3, self.y2, self.gliding and 7 or 2)
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
		g:led(2, 8 - v, self.selected_voice == v and 8 or self.held_keys.voices[v] and 5 or 2)
	end

	-- highlight plectrum location, if it's been moved recently
	local plectrum_level = math.min(1, 2 - (util.time() - self.plectrum.last_moved)) * 7

	for x = self.x + 2, self.x2 do
		for y = self.y, self.y2 - 1 do
			local key_id = self:get_key_id(x, y)
			local p = self:get_key_pitch_id(x, y)
			local level = 0
			-- highlight stack keys
			local stack_index, stack_gate = self:find_key_in_stack(key_id)
			if stack_index then
				level = led_blend(level, stack_gate and 6 or 3)
				if stack_index == self.stack_edit_index or self.stepper.held_steps[stack_index] then
					level = led_blend(level, 6)
				end
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

	-- stack edit delete key
	if self:can_delete_stack_edit_key() then
		g:led(self.x, self.y, 7)
	else
		-- voice loop delete key
		for v = 1, n_voices do
			if self.held_keys.voice_loops[v] and voice_states[v].loop_playing then
				g:led(self.x, self.y, 7)
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
