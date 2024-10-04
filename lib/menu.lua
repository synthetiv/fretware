local Menu = {}
Menu.__index = Menu

function Menu.new(x, y, width, height, arg_values)
	values = {}
	local k = 1
	for a = 1, height do
		for b = 1, width do
			if arg_values then
				values[k] = arg_values[k]
			else
				values[k] = k
			end
			k = k + 1
		end
	end
	local menu = {
		x = x,
		y = y,
		width = width,
		height = height,
		x2 = x + width - 1,
		y2 = y + height - 1,
		toggle = toggle or false,
		values = values,
		n_values = width * height,
		held = {},
		n_held = 0,
		selected = false,
		value = false,
		open = false,
		on_select = function() end
	}
	setmetatable(menu, Menu)
	return menu
end

function Menu.get_key_level(value, selected, held)
	return selected and 13 or 4
end

function Menu:draw()
	if not self.open then
		return
	end
	local k = 1
	for y = self.y, self.y2 do
		for x = self.x, self.x2 do
			local v = self.values[k]
			if v then
				local level = self.get_key_level(self.values[k], self.selected == k, self.held[v])
				g:led(x, y, level)
			end
			k = k + 1
		end
	end
end

function Menu:key(x, y, z)
	if not self.open or x < self.x or x > self.x2 or y < self.y or y > self.y2 then
		return false
	end
	x = x - self.x
	y = y - self.y
	local k = x + (y * self.width) + 1
	local v = self.values[k]
	if v then
		if z == 1 then
			self.held[v] = true
			self.n_held = self.n_held + 1
			if self.toggle and self.selected == k then
				k = false
			end
			self:select(k)
		else
			self.held[v] = false
			self.n_held = self.n_held - 1
			if self.n_held > 0 then
				for k = self.n_values, 1, -1 do
					if self.held[self.values[k]] then
						self:select(k)
						return true
					end
				end
			end
		end
		return true
	end
end

function Menu:select(k)
	local value = self.values[k]
	if value or k == false then
		self.selected = k
		self.value = value
		self.on_select(value)
	end
end

function Menu:select_value(v)
	for k = 1, self.n_values do
		if self.values[k] == v then
			self:select(k)
			return
		end
	end
end

return Menu
