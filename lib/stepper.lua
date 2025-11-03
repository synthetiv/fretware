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
		max_length = max_length,
		held_steps = {},
		copied_steps = {},
		held_keys = {},
		-- active_step_index = 0, -- i.e. not active, because first step is 1
		-- active_step = {},
		-- length = 0,
		open = false
	}
	for s = 1, max_length do
		stepper.held_steps[s] = false
		stepper.copied_steps[s] = false
	end
	setmetatable(stepper, Stepper)
	return stepper
end

function Stepper:draw()
	if not self.open then
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
				g:led(x, y, 0)
			else
				if s > #self.keyboard.stack then
					g:led(x, y, 2)
				else
					local step = self.keyboard.stack[s]
					-- TODO: highlight stack_edit_index
					if s == self.keyboard.arp_index then
						g:led(x, y, step.gate and 15 or 10)
					elseif s == self.keyboard.stack_edit_index then
						g:led(x, y, step.gate and 10 or 7)
					else
						g:led(x, y, self.held_steps[s] and 10 or (step.gate and 7 or 3))
					end
				end
				s = s + 1
			end
		end
	end
	-- delete key
	if self:has_held_steps() then
		g:led(1, 1, 7)
	end
end

function Stepper:has_held_steps()
	for s = 1, #self.keyboard.stack do
		if self.held_steps[s] then
			return true
		end
	end
	return false
end

function Stepper:key(x, y, z, shift)
	if not self.open then
		return false
	elseif x == 1 and y == 1 then
		local n_deleted = 0
		for s = 1, #self.keyboard.stack do
			if self.held_steps[s] then
				local ks = (s - n_deleted - 1) % #self.keyboard.stack + 1
				self.keyboard:remove_stack_key(ks)
				n_deleted = n_deleted + 1
				self.held_steps[s] = false
			end
		end
		return n_deleted > 0
	elseif x < self.x or x > self.x2 or y < self.y or y > self.y2 then
		return false
	elseif y == self.y2 then
		if x == self.x + 2 then
			self.held_keys.left = z == 1
			if z == 1 then
				if self.keyboard.held_keys.shift then
					self.keyboard.arp_index = (self.keyboard.arp_index - 2) % #self.keyboard.stack + 1
				else
					self.keyboard:shift_stack(-1)
				end
			end
		elseif x == self.x2 - 2 then
			self.held_keys.right = z == 1
			if z == 1 then
				if self.keyboard.held_keys.shift then
					self.keyboard.arp_index = self.keyboard.arp_index % #self.keyboard.stack + 1
				else
					self.keyboard:shift_stack(1)
				end
			end
		end
	else
		x = x - self.x - 1
		y = y - self.y - 1
		local s = x + (y * (self.width - 2)) + 1
		local now = util.time()
		if self.keyboard.held_keys.shift then
			if z == 1 then
				local pasted_steps = 0
				for cs = 1, self.max_length do
					local copied_step = self.copied_steps[cs]
					if copied_step then
						-- TODO: move arp_index + arp_insert
						table.insert(self.keyboard.stack, s + pasted_steps, {
							id = copied_step.id,
							gate = copied_step.gate
						})
						pasted_steps = pasted_steps + 1
					end
				end
				if pasted_steps > 0 then
					if self.keyboard.stack_edit_index and self.keyboard.stack_edit_index >= s then
						self.keyboard.stack_edit_index = self.keyboard.stack_edit_index + pasted_steps
					end
					if self.keyboard.arp_index >= s then
						self.keyboard.arp_index = self.keyboard.arp_index + pasted_steps
					end
					if self.keyboard.arp_insert >= s then
						self.keyboard.arp_insert = self.keyboard.arp_insert + pasted_steps
					end
				else
					local length_diff = s - #self.keyboard.stack
					if length_diff < 0 then
						-- delete steps at end
						length_diff = -length_diff
						for ds = 1, length_diff do
							if self.keyboard.arp_index >= s then
								self.keyboard.arp_index = self.keyboard.arp_index - length_diff
							end
							if self.keyboard.arp_insert >= s then
								self.keyboard.arp_insert = self.keyboard.arp_insert - length_diff
							end
							self.keyboard:remove_stack_key(s)
						end
					elseif length_diff > 0 then
						-- copy steps to end
						local insert_point = #self.keyboard.stack + 1
						for is = 1, length_diff do
							local copy_step = self.keyboard.stack[is]
							table.insert(self.keyboard.stack, insert_point, {
								id = copy_step.id,
								gate = copy_step.gate
							})
							insert_point = insert_point + 1
						end
					end
				end
			else
				if self.held_steps[s] then
					-- add this to copied steps
					self.copied_steps[s] = self.keyboard.stack[s]
					self.held_steps[s] = false
				end
			end
		else
			if s <= #self.keyboard.stack then
				if z == 1 then
					self.held_steps[s] = now
				else
					local is_tap = self.held_steps[s] and (now - self.held_steps[s] < 0.1)
					if is_tap and self.keyboard.stack[s] and self.held_steps[s] then
						self.keyboard.stack[s].gate = not self.keyboard.stack[s].gate
					end
					self.held_steps[s] = false
				end
			end
			-- TODO: should this happen in the keyboard?
			for cs = 1, self.max_length do
				self.copied_steps[cs] = false
			end
		end
	end
	return true
end

return Stepper
