local Echo = {}
Echo.__index = Echo

Echo.RATE_SMOOTHING = 0.1
Echo.LOOP_LENGTH = 10
Echo.last_used_voice = 0

function Echo.new()
	-- make sure there are enough voices left
	if Echo.last_used_voice + 2 > 6 then
		error('Echo tried to allocate too many softcut voices')
	end
	local echo = {
		rec_voice = Echo.last_used_voice + 1,
		play_voice = Echo.last_used_voice + 2,
		time = 0.11,
		rate = 1,
		rate_smoothed = 1,
		div = 1,
		div_dirty = false,
		drift_factor = 1,
		drift_amount = 0,
		head_distance = 1,
	}
	Echo.last_used_voice = play_voice
	setmetatable(echo, Echo)
	return echo
end

function Echo:init()

	softcut.level_input_cut(self.rec_voice, 1, 1)
	softcut.level_input_cut(self.rec_voice, 2, 1)
	softcut.rec(self.rec_voice, 1)
	softcut.rec_level(self.rec_voice, 1)
	softcut.phase_quant(self.rec_voice, 0.5)
	softcut.event_phase(function(voice, phase)
		if voice == self.rec_voice then
			if self.div_dirty then
				local new_position = phase - (self.head_distance * self.div)
				new_position = (new_position - 1) % Echo.LOOP_LENGTH + 1
				softcut.position(self.play_voice, new_position)
				self.div_dirty = false
			end
		end
	end)
	softcut.poll_start_phase()

	softcut.position(self.rec_voice, 1) -- TODO: would 0 work?
	softcut.position(self.play_voice, (-self.head_distance) % Echo.LOOP_LENGTH + 1)

	softcut.level(self.play_voice, 0.8) -- TODO: why not 1.0 (unity)?

	for scv = self.rec_voice, self.play_voice do
		softcut.buffer(scv, 1)
		softcut.rate(scv, 1)
		softcut.loop_start(scv, 1)
		softcut.loop_end(scv, 1 + Echo.LOOP_LENGTH)
		softcut.loop(scv, 1)
		softcut.fade_time(scv, 0.01)
		softcut.play(scv, 1)
		-- TODO: tilt filter / tone control
		softcut.pre_filter_dry(scv, 1)
		softcut.pre_filter_lp(scv, 0)
		softcut.post_filter_dry(scv, 1)
		softcut.post_filter_lp(scv, 0)
		softcut.enable(scv, 1)
	end

	clock.run(function()
		while true do
			self.rate_smoothed = self.rate_smoothed + (self.rate - self.rate_smoothed) * Echo.RATE_SMOOTHING
			self.drift_factor = self.drift_factor * math.pow(1.1, (math.random() - 0.5) * self.drift_amount)
			for scv = 1, 2 do
				softcut.rate_slew_time(scv, 0.3)
				softcut.rate(scv, self.rate_smoothed * self.drift_factor)
			end
			clock.sleep(0.05)
		end
	end)

end

function Echo:add_params()

	params:add_group('echo', 6)

	params:add {
		name = 'echo time',
		id = 'echo_time',
		type = 'control',
		controlspec = controlspec.new(0.05, 1, 'lin', 0, 0.11, 's'),
		action = function(value)
			self.time = value
			-- softcut voice rates are set based on this, in a clock routine
			self.rate = self.head_distance / self.time
		end
	}

	params:add {
		name = 'echo time div',
		id = 'echo_time_div',
		type = 'number',
		min = -4,
		max = 4,
		default = 0,
		formatter = function(param)
			return string.format('%.2fx', math.pow(2, param:get()))
		end,
		action = function(value)
			self.div = math.pow(2, value)
			self.div_dirty = true
		end
	}

	params:add {
		name = 'echo div fade',
		id = 'echo_div_fade',
		type = 'control',
		controlspec = controlspec.new(0, 25, 'lin', 0, 10, 'ms'),
		action = function(time)
			softcut.fade_time(self.play_voice, time * 0.001)
		end
	}

	params:add {
		name = 'echo feedback',
		id = 'echo_feedback',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.5),
		action = function(value)
			softcut.level_cut_cut(2, 1, value)
		end
	}

	params:add {
		name = 'echo drift',
		id = 'echo_drift',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.01),
		action = function(value)
			self.drift_amount = value
		end
	}

	params:add {
		name = 'echo resolution',
		id = 'echo_resolution',
		type = 'number',
		default = 0,
		min = -7,
		max = 2,
		action = function(value)
			local multiplier = math.pow(2, value)
			softcut.phase_quant(self.rec_voice, multiplier * 0.5)
			self.head_distance = multiplier
			-- reset other related params
			self.rate = self.head_distance / self.time
			self.rate_smoothed = self.rate
			for scv = 1, 2 do
				softcut.rate_slew_time(scv, 0.01)
				softcut.rate(scv, self.rate_smoothed * self.drift_factor)
			end
			self.div_dirty = true
		end
	}
end

return Echo
