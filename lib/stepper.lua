local Stepper = {}
Stepper.__index = Stepper

function Stepper.new(x, y, width, height)
	local max_length = width * height
	local stepper = {
		x = x,
		y = y,
		width = width,
		height = height,
		x2 = x + width - 1,
		y2 = y + height - 1,
		max_length = max_length,
		steps = {
			[0] = {}
		},
		held_steps = {},
		active_step_index = 0, -- i.e. not active, because first step is 1
		active_step = {},
		length = 0,
		open = false
	}
	for s = 1, max_length do
		stepper.steps[s] = {}
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
	for y = self.y - 1, self.y2 + 1 do
		for x = self.x - 1, self.x2 + 1 do
			if x < self.x or x > self.x2 or y < self.y or y > self.y2 then
				g:led(x, y, 0)
			else
				local step = self.steps[s]
				if s == self.active_step_index then
					g:led(x, y, step.gate and 15 or 10)
				elseif s <= self.length then
					g:led(x, y, self.held_steps[s] and 10 or (step.gate and 7 or 3))
				else
					g:led(x, y, 1)
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
	x = x - self.x
	y = y - self.y
	local s = x + (y * self.width) + 1
	local now = util.time()
	if z == 1 then
		self.held_steps[s] = now
	else
		if self.held_steps[s] and (now - self.held_steps[s]) < 0.1 then
			self.steps[s].gate = not self.steps[s].gate
		end
		self.held_steps[s] = false
	end
	if shift then
		self.length = s
	end
	return true
end

function Stepper:step(s)
	if self.length > 0 then
		if not s and self.length > 0 then
			s = self.active_step_index % self.length + 1
		end
		-- TODO: maybe call a callback or something?
		self.active_step_index = s
		self.active_step = self.steps[s]
	end
end

return Stepper
