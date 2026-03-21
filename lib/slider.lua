-- Custom slider class adapted from ui.Slider

local Slider = {}
Slider.__index = Slider

--- Create a new Slider object.
function Slider.new(neutral_value, marker_y, marker_height)
	local slider = {
		y = 0,
		value = 0,
		min_value = 0,
		max_value = 1,
		neutral_value = neutral_value,
		marker_y = marker_y or -2,
		marker_height = marker_height or 3
	}
	setmetatable(slider, Slider)
	return slider
end

--- Set value.
-- @tparam number number Value number.
function Slider:set_value(number)
	self.value = util.clamp(number, 0, 1)
end

--- Redraw Slider.
-- Call when changed.
function Slider:redraw(bg_level, fg_level)
	screen.rect(0, self.y, 64, 1)
	screen.level(bg_level)
	screen.fill()

	if fg_level > 0 then
		local fill_start = util.linlin(0, self.max_value, 0, 63, self.neutral_value)
		local fill_end = util.linlin(0, self.max_value, 0, 63, self.value)
		local fill_width = fill_end - fill_start
		if fill_width >= 0 then
			fill_width = fill_width + 1
		else
			fill_width = fill_width - 1
			fill_start = fill_start + 1
		end
		screen.rect(fill_start, self.y, fill_width, 1)
		screen.level(fg_level)
		screen.fill()

		screen.rect(fill_end, self.y + self.marker_y, 1, self.marker_height)
		screen.level(fg_level)
		screen.fill()
	end
end

function Slider:draw_point(value, level)
	local x = util.linlin(0, self.max_value, 0, 63, value)
	screen.pixel(x, self.y + self.marker_y)
	screen.level(level)
	screen.fill()
end

return Slider
