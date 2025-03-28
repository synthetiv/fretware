-- Custom slider class adapted from ui.Slider

local Slider = {}
Slider.__index = Slider

--- Create a new Slider object.
-- @tparam number x X position, defaults to 0.
-- @tparam number y Y position, defaults to 0.
-- @tparam number value Current value, defaults to 0.
-- @tparam number min_value Minimum value, defaults to -1.
-- @tparam number max_value Maximum value, defaults to 1.
-- @tparam number start_value Sets where fill line is drawn from, defaults to 0.
-- @tparam string units String to display after value text.
-- @tparam string title String to be displayed instead of value text.
-- @treturn Slider Instance of Slider.
function Slider.new(x, y, width, height, start_value, value)
	local slider = {
		x = x,
		y = y,
		width = width,
		height = height,
		value = value or 0,
		min_value = -1,
		max_value = 1,
		start_value = start_value or -1
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
function Slider:redraw(bg_level, fg_level)
	screen.rect(self.x, self.y, self.width, self.height)
	screen.level(bg_level)
	screen.fill()
	
	--draws the value
	fill_start = util.linlin(self.min_value, self.max_value, 0, self.width - 1, self.start_value)
	fill_width = util.linlin(self.min_value, self.max_value, 0, self.width - 1, self.value) - fill_start
	if fill_width >= 0 then
		fill_width = math.max(0, fill_width) + 1
		-- fill_start = fill_start - 1
	else
		fill_width = math.min(0, fill_width) - 1
		fill_start = fill_start + 1
	end
	screen.rect(self.x + fill_start, self.y, fill_width, self.height)
	screen.level(fg_level)
	screen.fill()
end

return Slider
