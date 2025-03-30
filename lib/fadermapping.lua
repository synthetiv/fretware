local FaderMapping = {}
FaderMapping.__index = FaderMapping

function FaderMapping.new(fader, param_name, slider_start_value, slider_style)
	local param = params:lookup_param(param_name)
	local mapping = {
		fader = fader,
		param = param,
		value = 0
	}
	-- wrap param action callback
	local original_action = param.action
	param.action = function(value)
		original_action(value)
		mapping:set(param:get_raw())
	end
	-- create slider
	if slider_style == 'inner' then
		mapping.slider = Slider.new(1, 0, 61, 2, slider_start_value)
	else
		mapping.slider = Slider.new(0, 0, 63, 4, slider_start_value)
	end
	setmetatable(mapping, FaderMapping)
	return mapping
end

-- respond to a fader movement. values must be scaled to [0, 1]
function FaderMapping:move(old_value, new_value)
	local intersected = (old_value <= self.value and self.value <= new_value)
		or (old_value >= self.value and self.value >= new_value)
	if intersected then
		self.param:set_raw(new_value)
	end
end

-- set value directly.
function FaderMapping:set(new_value)
	self.value = new_value
	self.slider.value = new_value
end

return FaderMapping
