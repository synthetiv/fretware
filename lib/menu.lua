local Menu = {}
Menu.__index = Menu

function Menu.new(x, y, width, height, keys, on_select)
	if not keys then
		keys = {}
		for a = 1, height do
			for b = 1, width do
				table.insert(keys, {})
			end
		end
	end
	local menu = {
		x = x,
		y = y,
		width = width,
		height = height,
		x2 = x + width - 1,
		y2 = y + height - 1,
		keys = keys,
		selected = false,
		open = false,
		on_select = on_select or function() end
	}
	setmetatable(menu, Menu)
	menu.on_select(menu.selected)
	return menu
end

function Menu:draw()
	if not self.open then
		return
	end
	local k = 1
	for y = self.y, self.y2 do
		for x = self.x, self.x2 do
			if self.keys[k] then
				if k == self.selected then
					g:led(x, y, (self.keys[k].level or 2) + 11)
				elseif self.keys[k] then
					g:led(x, y, (self.keys[k].level or 0) + 4)
				end
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
	if z == 1 then
		self.selected = k
		self.on_select(k)
	end
	return true
end

return Menu
