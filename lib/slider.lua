-- Custom slider class adapted from ui.Slider

local Slider = {}
Slider.__index = Slider

--- Create a new Slider object.
function Slider.new(x, y, width, height, start_value, value)
	local slider = {
		x = x,
		y = y,
		width = width,
		height = height,
		value = value or 0,
		min_value = 0,
		max_value = 1,
		start_value = start_value or 0.5
	}
	setmetatable(slider, Slider)
	return slider
end

--- Set value.
-- @tparam number number Value number.
function Slider:set_value(number)
	self.value = util.clamp(number, self.min_value, self.max_value)
end

--- Redraw Slider.
-- Call when changed.
function Slider:redraw(bg_level, fg_level, cap_level)
	screen.rect(self.x, self.y, self.width, self.height)
	screen.level(bg_level)
	screen.fill()

	--draws the value
	local fill_start = util.linlin(self.min_value, self.max_value, 0, self.width - 1, self.start_value)
	local fill_width = util.linlin(self.min_value, self.max_value, 0, self.width - 1, self.value) - fill_start
	if fill_width >= 0 then
		fill_width = fill_width + 1
	else
		fill_width = fill_width - 1
		fill_start = fill_start + 1
	end
	screen.rect(self.x + fill_start, self.y, fill_width, self.height)
	screen.level(fg_level)
	screen.fill()
end

function Slider:draw_cap(value, border_level, fill_level)
	local cap_x = util.linlin(self.min_value, self.max_value, 0, self.width - 1, value or 0)
	screen.rect(self.x + cap_x - 0.5, self.y - 1.5, 2, self.height + 3)
	screen.level(border_level)
	screen.stroke()
	screen.rect(self.x + cap_x, self.y - 1, 1, self.height + 2)
	screen.level(fill_level)
	screen.fill()
end

return Slider
