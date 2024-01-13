-- Custom dial class adapted from ui.Dial

local Dial = {}
Dial.__index = Dial

--- Create a new Dial object.
-- @tparam number x X position, defaults to 0.
-- @tparam number y Y position, defaults to 0.
-- @tparam number size Diameter of dial, defaults to 22.
-- @tparam number value Current value, defaults to 0.
-- @tparam number min_value Minimum value, defaults to 0.
-- @tparam number max_value Maximum value, defaults to 1.
-- @tparam number start_value Sets where fill line is drawn from, defaults to 0.
-- @tparam string units String to display after value text.
-- @tparam string title String to be displayed instead of value text.
-- @treturn Dial Instance of Dial.
function Dial.new(x, y, size, value, min_value, max_value, start_value)
  local markers_table = markers or {}
  local dial = {
    x = x or 0,
    y = y or 0,
    size = size or 22,
    value = value or 0,
    min_value = min_value or -1,
    max_value = max_value or 1,
    start_value = start_value or 0,
    active = true,
    _start_angle = math.pi * 0.7,
    _end_angle = math.pi * 2.3,
  }
  setmetatable(dial, Dial)
  return dial
end

--- Set value.
-- @tparam number number Value number.
function Dial:set_value(number)
  self.value = util.clamp(number, self.min_value, self.max_value)
end

--- Redraw Dial.
-- Call when changed.
function Dial:redraw()
  local radius = self.size * 0.5
  
  local fill_start_angle = util.linlin(self.min_value, self.max_value, self._start_angle, self._end_angle, self.start_value)
  local fill_end_angle = util.linlin(self.min_value, self.max_value, self._start_angle, self._end_angle, self.value)
  
  if fill_end_angle < fill_start_angle then
    local temp_angle = fill_start_angle
    fill_start_angle = fill_end_angle
    fill_end_angle = temp_angle
  end
  
  screen.level(self.active and 3 or 1)
  screen.arc(self.x + radius, self.y + radius, radius - 0.5, self._start_angle, self._end_angle)
  screen.stroke()
  
  screen.level(self.active and 15 or 3)
  screen.line_width(2.5)
  screen.arc(self.x + radius, self.y + radius, radius - 0.5, fill_start_angle, fill_end_angle)
  screen.stroke()
  screen.line_width(1)
end

return Dial
