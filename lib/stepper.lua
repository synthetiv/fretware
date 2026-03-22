local Stepper = {}
Stepper.__index = Stepper

function Stepper.new(keyboard, x, y, width, height)
	local max_length = width * height
	local stepper = {
		keyboard = keyboard,
		x = x,
		y = y,
		width = width,
		height = height,
		x2 = x + width - 1,
		y2 = y + height - 1,
		n_keys = width * height,
		max_length = max_length,
		held_steps = {},
		clipboard = {},
		held_keys = {},
		held_blanks = {},
		-- active_step_index = 0, -- i.e. not active, because first step is 1
		-- active_step = {},
		-- length = 0,
		is_open = false
	}
	for s = 1, max_length do
		stepper.held_steps[s] = false
	end
	setmetatable(stepper, Stepper)
	return stepper
end

function Stepper:draw()
	if not self.is_open then
		return
	end
	local s = 1
	for y = self.y, self.y2 do
		for x = self.x, self.x2 do
			if y == self.y2 then
				if x == self.x + 2 then
					g:led(x, y, self.held_keys.left and 7 or 2)
				elseif x == self.x2 - 2 then
					g:led(x, y, self.held_keys.right and 7 or 2)
				else
					g:led(x, y, 0)
				end
			elseif x == self.x or x == self.x2 or y == self.y then
				g:led(x, y, 2)
			else
				if s > #self.keyboard.stack then
					g:led(x, y, 0)
				else
					local step = self.keyboard.stack[s]
					local level = 1
					if step.gate then
						-- get pitch *relative to keyboard octave*
						local pitch = self.keyboard:get_key_id_pitch_value(step.id)
						pitch = pitch - self.keyboard.octave * self.keyboard.scale.span
						-- higher pitches = brighter keys
						local pitch_level = math.max(0, math.min(15, pitch * 4))
						level = led_blend(level, pitch_level)
					end
					if s == self.keyboard.stack_edit_index then
						level = led_blend(level, 10)
					elseif s == self.keyboard.arp_index then
						level = led_blend(level, self.keyboard.stack_edit_index and 7 or 10)
					end
					if self.held_steps[s] and s <= #self.keyboard.stack then
						level = led_blend(level, 10)
					end
					g:led(x, y, math.floor(level + 0.5))
				end
				s = s + 1
			end
		end
	end
	-- delete key
	if self:can_delete_steps() then
		g:led(1, 1, 7)
	end
end

function Stepper:can_delete_step(s)
	local now = util.time()
	return self.held_steps[s] and now - math.abs(self.held_steps[s]) > 0.15
end

function Stepper:can_delete_steps()
	for s = 1, #self.keyboard.stack do
		if self:can_delete_step(s) then
			return true
		end
	end
	return false
end

function Stepper:clear_clipboard()
	self.clipboard = {}
end

function Stepper:paste_steps(dest_index)
	local step_count = #self.clipboard
	for s = 1, step_count do
		local source = self.clipboard[s]
		table.insert(self.keyboard.stack, dest_index, {
			id = source.id,
			gate = source.gate
		})
	end
	if self.keyboard.stack_edit_index and self.keyboard.stack_edit_index >= dest_index then
		self.keyboard.stack_edit_index = self.keyboard.stack_edit_index + step_count
	end
	if self.keyboard.arp_index >= dest_index then
		self.keyboard.arp_index = self.keyboard.arp_index + step_count
	end
	-- TODO: remind me what the difference between arp_insert and arp_index is??
	if self.keyboard.arp_insert >= dest_index then
		self.keyboard.arp_insert = self.keyboard.arp_insert + step_count
	end
end

function Stepper:duplicate_step(source_index, dest_index)
	local source = self.keyboard.stack[source_index]
	dest_index = dest_index or source_index
	table.insert(self.keyboard.stack, dest_index, {
		id = source.id,
		gate = source.gate
	})
end

function Stepper:key(x, y, z, shift)
	if not self.is_open then
		return false
	elseif x == 1 and y == 1 and z == 1 then
		-- delete key
		-- TODO: move this bit into a :delete_key() handler
		local n_deleted = 0
		for s = 1, #self.keyboard.stack do
			if self:can_delete_step(s) then
				local ks = (s - n_deleted - 1) % #self.keyboard.stack + 1
				self.keyboard:remove_stack_key(ks)
				n_deleted = n_deleted + 1
			end
		end
		return n_deleted > 0
	elseif x < self.x or x > self.x2 or y < self.y or y > self.y2 then
		return false
	elseif y == self.y2 then
		if x == self.x + 2 then
			if z == 1 then
				self.held_keys.left = true
				if shift then
					self.keyboard.arp_index = (self.keyboard.arp_index - 2) % #self.keyboard.stack + 1
				else
					self.keyboard:shift_stack(-1)
				end
				return true
			elseif self.held_keys.left then
				self.held_keys.left = false
				return true
			end
		elseif x == self.x2 - 2 then
			if z == 1 then
				self.held_keys.right = true
				if shift then
					self.keyboard.arp_index = self.keyboard.arp_index % #self.keyboard.stack + 1
				else
					self.keyboard:shift_stack(1)
				end
				return true
			elseif self.held_keys.right then
				self.held_keys.right = false
				return true
			end
		end
	elseif x > self.x and x < self.x2 and y > self.y then
		local x = x - self.x - 1
		local y = y - self.y - 1
		local s = x + (y * (self.width - 2)) + 1
		local now = util.time()
		if shift then
			if z == 1 then
				if #self.clipboard > 0 then
					self:paste_steps(math.min(s, #self.keyboard.stack + 1))
				else
					local length_diff = s - #self.keyboard.stack
					if s <= #self.keyboard.stack then
						-- duplicate the step that was pressed
						self:duplicate_step(s)
					else
						-- copy steps from start until stack is 's' steps long
						for is = 1, length_diff do
							self:duplicate_step(is, #self.keyboard.stack + 1)
						end
					end
				end
				return true
			elseif self.held_steps[s] then
				if self.keyboard.stack[s] then
					-- add this to copied steps
					table.insert(self.clipboard, self.keyboard.stack[s])
				end
				self.held_steps[s] = false
				return true
			end
		elseif self.keyboard.stack[s] then
			if z == 1 then
				if not self.keyboard.stack[s].gate then
					self.keyboard.stack[s].gate = true
					-- negative value indicates that delete key shouldn't be shown yet, but that releasing
					-- this key immediately should NOT toggle it off
					self.held_steps[s] = -now
				else
					self.held_steps[s] = now
				end
				return true
			elseif self.held_steps[s] then
				-- note that can_delete_step() uses math.abs() but the below doesn't 
				-- see note about negative values above
				if self.keyboard.stack[s].gate and (now - self.held_steps[s] < 0.15) then
					self.keyboard.stack[s].gate = false
				end
				self.held_steps[s] = false
				return true
			end
		elseif z == 0 then
			-- always release, even if we're holding the key for a step that no longer exists
			self.held_steps[s] = false
		end
	end
	-- handle events on non-keys
	local k = x + (y * self.width) + 1
	if z == 1 then
		self.held_blanks[k] = true
		return true
	elseif self.held_blanks[k] then
		self.held_blanks[k] = false
		return true
	end
	return false
end

function Stepper:toggle()
	if self.is_open then
		self:close()
	else
		self:open()
	end
end

function Stepper:open()
	self.is_open = true
end

function Stepper:close()
	self.held_keys.left = false
	self.held_keys.right = false
	for s = 1, self.max_length do
		self.held_steps[s] = false
	end
	for k = 1, self.n_keys do
		if self.held_blanks[k] then
			self.held_blanks[k] = false
		end
	end
	self.is_open = false
end

return Stepper
