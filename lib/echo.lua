local Echo = {}
Echo.__index = Echo

Echo.RATE_SMOOTHING = 0.2
Echo.LOOP_LENGTH = 10
Echo.DRIFT_BASE = 1.1
Echo.last_used_voice = 0

function Echo.new()
	-- make sure there are enough voices left
	if Echo.last_used_voice + 2 > 6 then
		error('Echo tried to allocate too many softcut voices')
	end
	local echo = {
		rec_voice = Echo.last_used_voice + 1,
		play_voice = Echo.last_used_voice + 2,
		rate = 0,
		rate_smoothed = 0,
		div = 0,
		div_dirty = false,
		resolution = 0,
		resolution_dirty = false,
		jump_amount = 0,
		jump_div = 0,
		drift_state = 0,
		drift_amount = 0.15,
		drift_leak = 0.8,
		-- TODO: make sure head distance + loop length are an evenly divisible number of sample frames... if that's important
		-- TODO: add control over playback pitch, relative to rec pitch
		head_distance = 0.11,
	}
	Echo.last_used_voice = play_voice
	setmetatable(echo, Echo)
	return echo
end

function Echo:init()

	softcut.level_input_cut(1, self.rec_voice, 1)
	softcut.level_input_cut(2, self.rec_voice, 1)
	softcut.rec(self.rec_voice, 1)
	softcut.rec_level(self.rec_voice, 1)
	softcut.event_position(function(voice, position)
		if voice == self.rec_voice then
			-- TODO: update play head's loop points to avoid overlap with rec head when playback pitch != 1x?
			-- (the tricky part will be handling this near the rec head's loop points...)
			if self.div_dirty or self.resolution_dirty then
				if self.resolution_dirty then
					local drift_factor = math.pow(Echo.DRIFT_BASE, self.drift_state)
					for scv = self.rec_voice, self.play_voice do
						-- TODO: why doesn't this set the new rate instantaneously?
						softcut.rate_slew_time(scv, 0.001)
						softcut.rate(scv, math.pow(2, self.rate_smoothed + self.resolution) * drift_factor)
					end
					self.resolution_dirty = false
				end
				-- move the play head closer to or further from the record head, depending on echo_div
				-- TODO: use 'sync' instead?
				local new_position = position - (self.head_distance * math.pow(2, self.div + self.jump_div + self.resolution))
				new_position = new_position % Echo.LOOP_LENGTH
				softcut.position(self.play_voice, new_position)
				self.div_dirty = false
			end
		end
	end)

	softcut.position(self.rec_voice, 0)
	softcut.position(self.play_voice, (-self.head_distance) % Echo.LOOP_LENGTH)

	softcut.level(self.play_voice, 1)

	for scv = self.rec_voice, self.play_voice do
		softcut.buffer(scv, 1)
		softcut.rate(scv, 1)
		softcut.loop_start(scv, 0)
		softcut.loop_end(scv, Echo.LOOP_LENGTH)
		softcut.loop(scv, 1)
		softcut.fade_time(scv, 0.01)
		softcut.play(scv, 1)
		softcut.pre_filter_dry(scv, 1)
		softcut.pre_filter_lp(scv, 0)
		softcut.post_filter_dry(scv, 1)
		softcut.post_filter_lp(scv, 0)
		softcut.enable(scv, 1)
	end

	softcut.pre_filter_dry(self.rec_voice, 0.85)
	softcut.pre_filter_hp(self.rec_voice, 0.15)
	softcut.pre_filter_fc(self.rec_voice, 5)

	self:set_tone(0)

	clock.run(function()
		while true do
			self.rate_smoothed = self.rate_smoothed + (self.rate - self.rate_smoothed) * Echo.RATE_SMOOTHING
			self.drift_state = self.drift_state * (1 - self.drift_leak)
			self.drift_state = self.drift_state + (math.random() - 0.5) * self.drift_amount
			local drift_factor = math.pow(Echo.DRIFT_BASE, self.drift_state)
			for scv = self.rec_voice, self.play_voice do
				softcut.rate_slew_time(scv, 0.3)
				softcut.rate(scv, math.pow(2, self.rate_smoothed + self.resolution) * drift_factor)
			end
			clock.sleep(0.05)
		end
	end)

end

function Echo:set_tone(tone)
	-- TODO: is it useful to try to compensate for lost volume?
	if tone >= 0 then
		softcut.post_filter_fc(self.play_voice, util.linexp(0, 1, 10, 10000, math.pow(tone, 2)))
	else
		softcut.post_filter_fc(self.play_voice, util.linexp(0, 1, 23000, 230, math.pow(-tone, 0.5)))
	end
	softcut.post_filter_dry(self.play_voice, util.linlin(0, 0.9, 1, 0, math.abs(tone)))
	softcut.post_filter_lp(self.play_voice, util.linlin(-0.9, 0, 1, 0, tone))
	softcut.post_filter_hp(self.play_voice, util.linlin(0, 0.9, 0, 1, tone))
end

function Echo:jump()
	if self.jump_amount > 0 then
		self.jump_div = self.jump_amount * (math.random() - 0.5)
		self.div_dirty = true
		softcut.query_position(self.rec_voice)
	end
end

function Echo.div_formatter(format, invert)
	local div_format = '/' .. format
	local mul_format = format .. 'x'
	return function(param)
		local value = param:get()
		if invert then
			value = -value
		end
		if value < 0 then
			return string.format(div_format, math.pow(2, -value))
		end
		return string.format(mul_format, math.pow(2, value))
	end
end

function Echo:add_params()

	params:add_group('echo', 10)

	params:add {
		name = 'echo tone',
		id = 'echo_tone',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			self:set_tone(value)
		end
	}

	params:add {
		name = 'echo rate',
		id = 'echo_rate',
		type = 'control',
		formatter = Echo.div_formatter('%0.2f', true),
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			-- softcut voice rates are set based on this, in a clock routine
			self.rate = -value
		end
	}

	params:add {
		name = 'echo time div',
		id = 'echo_time_div',
		type = 'number',
		min = -7,
		max = 4,
		default = 0,
		formatter = Echo.div_formatter('%d'),
		action = function(value)
			self.div = value
			self.div_dirty = true
			softcut.query_position(self.rec_voice)
		end
	}

	params:add {
		name = 'echo jump trigger',
		id = 'echo_jump_trigger',
		type = 'option',
		options = { 'none', 'lfoA', 'lfoB', 'lfoEqual', 'manual' },
		default = 1,
		action = function(value)
			if uc4 then
				uc4:note_off(16)
				uc4:note_off(17)
				uc4:note_off(18)
				uc4:note_off(19)
			end
			self.jump_trigger = value
		end
	}

	params:add {
		name = 'echo jump amount',
		id = 'echo_jump_amount',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0.4),
		action = function(value)
			self.jump_amount = value * 2
		end
	}

	params:add {
		name = 'echo div fade',
		id = 'echo_div_fade',
		type = 'control',
		controlspec = controlspec.new(0, 250, 'lin', 0, 15, 'ms'),
		action = function(time)
			softcut.fade_time(self.play_voice, time * 0.001)
		end
	}

	params:add {
		name = 'echo feedback',
		id = 'echo_feedback',
		type = 'taper',
		min = 0,
		max = 1.1,
		default = 0.5,
		k = 2,
		action = function(value)
			softcut.level_cut_cut(self.play_voice, self.rec_voice, value)
		end
	}

	params:add {
		name = 'echo drift',
		id = 'echo_drift',
		type = 'control',
		controlspec = controlspec.new(0, 0.7, 'lin', 0, 0.125),
		action = function(value)
			self.drift_amount = value
		end
	}

	params:add {
		name = 'echo drift leak',
		id = 'echo_drift_leak',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0.9),
		action = function(value)
			self.drift_leak = value
		end
	}

	params:add {
		name = 'echo resolution',
		id = 'echo_resolution',
		type = 'number',
		default = 0,
		min = -7,
		max = 2,
		formatter = Echo.div_formatter('%d'),
		action = function(value)
			local diff = value - self.resolution
			self.resolution = value
			self.resolution_dirty = true
			-- 'div' setting is NOT relative to resolution. to retain the same looped
			-- audio after a resolution change, we need to change resolution: use a
			-- longer div if resolution has decreased, shorter div if increased.
			params:delta('echo_time_div', -diff)
		end
	}
end

return Echo
