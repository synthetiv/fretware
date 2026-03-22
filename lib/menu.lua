local Menu = {}
Menu.__index = Menu

function Menu.new(x, y, width, height, arg_values)
	local values = {}
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
		n_keys = width * height,
		is_toggle = false,
		is_multi = false,
		values = values,
		held_values = {},
		held_blanks = {},
		n_held = 0,
		value = false,
		is_open = false,
		on_select = function() end
	}
	setmetatable(menu, Menu)
	return menu
end

function Menu.get_key_level(value, selected, held)
	return selected and 13 or 4
end

function Menu:draw()
	if not self.is_open then
		return
	end
	local k = 1
	for y = self.y, self.y2 do
		for x = self.x, self.x2 do
			local v = self.values[k]
			if v then
				local selected = self.value == v
				if self.is_multi and self.n_held > 0 then
					selected = self.held_values[v]
				end
				g:led(x, y, self.get_key_level(self.values[k], selected, self.held_values[v]))
			end
			k = k + 1
		end
	end
end

function Menu:key(x, y, z)
	if not self.is_open or x < self.x or x > self.x2 or y < self.y or y > self.y2 then
		return false
	end
	x = x - self.x
	y = y - self.y
	local k = x + (y * self.width) + 1
	local v = self.values[k]
	if v then
		if z == 1 then
			self.held_values[v] = true
			self.n_held = self.n_held + 1
			if self.is_toggle and self.value == v then
				k = false
			end
			self:select(k)
			return true
		elseif self.held_values[v] then
			self.held_values[v] = false
			self.n_held = self.n_held - 1
			if self.n_held > 0 then
				-- if there are other keys held, change selection to the highest numbered one
				for nk = self.n_keys, 1, -1 do
					if self.held_values[self.values[nk]] then
						self:select(nk)
						return true
					end
				end
			end
			return true
		end
	end
	-- handle events on otherwise-unhandled keys
	-- block keydowns from affecting other controls; but if a key is released that we didn't
	-- previously know was held, allow other controls to handle it
	-- example: press and hold a keyboard note, then open a menu, then release the note key; the
	-- keyboard should be the one to receive the key up event
	if z == 1 then
		self.held_blanks[k] = true
		return true
	elseif self.held_blanks[k] then
		self.held_blanks[k] = false
		return true
	end
	return false
end

function Menu:select(k)
	local value = self.values[k]
	if value or k == false then
		local callback_return = self.on_select(value, self.value)
		-- if callback returns false, we will NOT update the menu value
		if callback_return ~= false then
			self.value = value
		end
	end
end

function Menu:select_value(v)
	for k = 1, self.n_keys do
		if self.values[k] == v then
			self:select(k)
			return
		end
	end
end

function Menu:is_selected(v)
	if self.is_multi and self.n_held > 0 then
		return self.held[v]
	end
	return self.value == v
end

function Menu:toggle()
	if self.is_open then
		self:close()
	else
		self:open()
	end
end

function Menu:open()
	self.is_open = true
end

function Menu:close()
	for k = 1, self.n_keys do
		local v = self.values[k]
		if v and self.held_values[v] then
			self.held_values[v] = false
		end
		if self.held_blanks[k] then
			self.held_blanks[k] = false
		end
	end
	self.is_open = false
end

return Menu
