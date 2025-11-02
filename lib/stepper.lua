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
		scroll_offset = 0,
		held_steps = {},
		held_keys = {},
		-- active_step_index = 0, -- i.e. not active, because first step is 1
		-- active_step = {},
		-- length = 0,
		open = false
	}
	for s = 1, max_length do
		stepper.held_steps[s] = false
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
				end
			elseif x == self.x or x == self.x2 or y == self.y then
				g:led(x, y, 0)
			else
				if s > #self.keyboard.stack then
					g:led(x, y, 2)
				else
					local ks = (s + self.scroll_offset - 1) % #self.keyboard.stack + 1
					local step = self.keyboard.stack[ks]
					if ks == self.keyboard.arp_index then
						g:led(x, y, step.gate and 15 or 10)
					else
						g:led(x, y, self.held_steps[s] and 10 or (step.gate and 7 or 3))
					end
				end
				s = s + 1
			end
		end
	end
end

function Stepper:key(x, y, z, shift)
	if not self.open or x < self.x or x > self.x2 or y < self.y or y > self.y2 then
		return false
	end
	if y == self.y2 then
		if x == self.x + 2 then
			self.held_keys.left = z == 1
			if z == 1 then
				if self.keyboard.held_keys.shift then
					self.keyboard.arp_index = (self.keyboard.arp_index - 2) % #self.keyboard.stack + 1
				else
					self.scroll_offset = (self.scroll_offset - 1) % #self.keyboard.stack
				end
			end
		elseif x == self.x2 - 2 then
			self.held_keys.right = z == 1
			if z == 1 then
				if self.keyboard.held_keys.shift then
					self.keyboard.arp_index = self.keyboard.arp_index % #self.keyboard.stack + 1
				else
					self.scroll_offset = (self.scroll_offset + 1) % #self.keyboard.stack
				end
			end
		end
	else
		x = x - self.x - 1
		y = y - self.y - 1
		local s = x + (y * (self.width - 2)) + 1
		local now = util.time()
		if s <= #self.keyboard.stack then
			if z == 1 then
				self.held_steps[s] = now
			else
				local ks = (s + self.scroll_offset - 1) % #self.keyboard.stack + 1
				if self.keyboard.stack[ks] and self.held_steps[s] and (now - self.held_steps[s]) < 0.1 then
					self.keyboard.stack[ks].gate = not self.keyboard.stack[ks].gate
				end
				self.held_steps[s] = false
			end
		end
		-- TODO: handle hold step + keyboard press
		-- TODO: handle hold step + delete
		-- TODO: handle hold step + shift (copy) followed by shift + other step (paste)
	end
	return true
end

return Stepper
