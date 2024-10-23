local Echo = {}
Echo.__index = Echo

local LFO = require 'lfo'

Echo.RATE_SMOOTHING = 0.2
Echo.LOOP_LENGTH = 60
Echo.DRIFT_BASE = 0.13
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
		div_dirty = true,
		resolution = 0,
		cutoff_hp = 300,
		cutoff_lp = 8000,
		tone = 0,
		tone_dirty = false,
		gain_compensation = 0.838,
		gain_base = 0.838,
		gain_hp = 0.855,
		gain_lp = 0.855,
		wow = 0,
		flutter = 0,
		jump_amount = 0,
		jump_div = 0,
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
	-- this is called once every 0.0125 seconds by a clock routine
	softcut.event_position(function(voice, rec_position)
		if voice == self.rec_voice then
			-- update filter mix
			if self.tone_dirty then
				if self.tone >= 0 then
					softcut.post_filter_fc(self.play_voice, self.cutoff_hp)
					self.gain_compensation = util.linexp(0.1, 1, self.gain_base, self.gain_hp, self.tone)
				else
					softcut.post_filter_fc(self.play_voice, self.cutoff_lp)
					self.gain_compensation = util.linexp(0.1, 1, self.gain_base, self.gain_lp, -self.tone)
				end
				softcut.post_filter_dry(self.play_voice, util.linlin(0.1, 1, 1, 0, math.abs(self.tone)))
				softcut.post_filter_lp(self.play_voice, util.linlin(0.1, 1, 0, 1, -self.tone))
				softcut.post_filter_hp(self.play_voice, util.linlin(0.1, 1, 0, 1, self.tone))
				softcut.post_filter_rq(self.play_voice, 4)
				self.tone_dirty = false
			end
			-- jump to a new division, if needed
			local div_jump_compensation = 1
			if self.div_dirty then
				-- move the play head closer to or further from the record head, depending on echo_div
				self.div = params:get('echo_time_div') + self.jump_div
				local play_position = rec_position - (self.head_distance * math.pow(2, self.div))
				-- wrap to within loop boundaries
				play_position = (play_position - 1) % Echo.LOOP_LENGTH + 1
				softcut.position(self.play_voice, play_position)
				-- when jumping, duck feedback by sqrt(0.5), to compensate for equal power fade.
				-- equal power will eventually make feedback blow up, especially when div is small,
				-- so this basically creates an equal gain fade instead.
				div_jump_compensation = 0.7071
				self.div_dirty = false
			end
			-- apply drift and resolution scaling to rate
			local rate_factor = self.rate_smoothed + self.resolution + Echo.DRIFT_BASE * (self.wow + self.flutter)
			local rate = math.pow(2, rate_factor)
			-- update voice rates
			for scv = self.rec_voice, self.play_voice do
				softcut.rate(scv, rate)
			end
			-- adjust feedback relative to time
			-- TODO: where'd I even get this exp(x * log(y)) idea?
			local time = self.head_distance * math.pow(2, self.div - rate_factor)
			local gain = math.exp(time * math.log(self.feedback))
			if self.feedback > 1 then
				-- the main problem with the above approach is that when delay time is long,
				-- feedback settings > 1.0x lead to very high gain values.
				-- so use the lower of the two (time-scaled and non-time-scaled) feedback settings.
				gain = math.min(self.feedback, gain)
			end
			softcut.level_cut_cut(self.play_voice, self.rec_voice, gain * self.gain_compensation * div_jump_compensation)
			-- adjust play voice output level too, to help monitor when feedback is too high over unity
			-- but prevent output level from ever dropping below -3db
			softcut.level(self.play_voice, math.max(0.707, gain))
		end
	end)

	softcut.position(self.rec_voice, 1)
	-- play voice position and level will be set by clock routine above

	for scv = self.rec_voice, self.play_voice do
		softcut.buffer(scv, 1)
		softcut.rate(scv, 1)
		softcut.rate_slew_time(scv, 0.05)
		softcut.loop_start(scv, 1)
		softcut.loop_end(scv, 1 + Echo.LOOP_LENGTH)
		softcut.loop(scv, 1)
		softcut.fade_time(scv, 0.05)
		softcut.level_slew_time(scv, 0.05)
		softcut.recpre_slew_time(scv, 0.05)
		softcut.play(scv, 1)
		softcut.pre_filter_dry(scv, 1)
		softcut.pre_filter_lp(scv, 0)
		softcut.post_filter_dry(scv, 1)
		softcut.post_filter_lp(scv, 0)
		softcut.enable(scv, 1)
	end

	softcut.pre_filter_dry(self.rec_voice, 0.8)
	softcut.pre_filter_hp(self.rec_voice, 0.2)
	softcut.pre_filter_fc(self.rec_voice, 30)
	softcut.pre_filter_rq(self.rec_voice, 6)

	self.wowLFO = LFO:add {
		shape = 'sine',
		min = -1,
		max = 1,
		baseline = 'center',
		depth = 0.1,
		mode = 'free',
		period = 1.6,
		action = function(value)
			local rand = math.min(math.random(), math.random(), math.random())
			value = value * rand
			self.wow = value
		end
	}
	self.wowLFO:start()

	self.flutterLFO = LFO:add {
		shape = 'sine',
		min = -1,
		max = 1,
		baseline = 'center',
		depth = 0.1,
		mode = 'free',
		period = 0.15,
		action = function(value)
			-- randomize rate at zero crossings
			if (self.flutter <= 0 and value >= 0) or (self.flutter >= 0 and value <= 0) then
				local rand = (math.random() + math.random() + math.random()) / 3
				local rate = 1 / params:get('echo_flutter_rate')
				rate = rate * (1 + (rand * 0.5))
				self.flutterLFO:set('period', rate)
			end
			self.flutter = value
		end
	}
	self.flutterLFO:start()

	clock.run(function()
		while true do
			clock.sleep(0.0125)
			self.rate_smoothed = self.rate_smoothed + (self.rate - self.rate_smoothed) * Echo.RATE_SMOOTHING
			softcut.query_position(self.rec_voice)
		end
	end)

end

function Echo:jump()
	if self.jump_amount > 0 then
		self.jump_div = self.jump_amount * (math.random() - 0.5)
		self.div_dirty = true
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

	params:add_group('echo', 11)

	params:add {
		name = 'echo tone',
		id = 'echo_tone',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			self.tone = value
			self.tone_dirty = true
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
		max = 7,
		default = -2,
		formatter = Echo.div_formatter('%d'),
		action = function(value)
			self.div_dirty = true
		end
	}

	params:add {
		name = 'echo jump trigger',
		id = 'echo_jump_trigger',
		type = 'option',
		options = { 'none', 'lfoA', 'lfoB', 'lfoC', 'lfoA=B', 'lfoB=C', 'lfoC=A' },
		default = 1,
		action = function(value)
			if uc4 then
				-- reset UC4 blinkenlights
				for note = 12, 19 do
					uc4:note_off(note)
				end
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
		name = 'echo decay time',
		id = 'echo_feedback',
		type = 'control',
		controlspec = controlspec.new(0, 1.27, 'lin', 0, 0.1),
		action = function(value)
			-- square response below unity, linear response above
			if value < 1 then
				value = value * value
			end
			self.feedback = value
		end
	}

	params:add {
		name = 'echo resolution',
		id = 'echo_resolution',
		type = 'number',
		default = -2,
		min = -7,
		max = 1,
		formatter = Echo.div_formatter('%d'),
		action = function(value)
			self.resolution = value
		end
	}

	params:add {
		name = 'echo wow depth',
		id = 'echo_wow_depth',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0.1, 'x'),
		action = function(value)
			self.wowLFO:set('depth', value)
		end
	}

	params:add {
		name = 'echo wow rate',
		id = 'echo_wow_rate',
		type = 'control',
		controlspec = controlspec.new(0.3, 3, 'exp', 0, 1.6, 'Hz'),
		action = function(value)
			self.wowLFO:set('period', 1 / value)
		end
	}

	params:add {
		name = 'echo flutter depth',
		id = 'echo_flutter_depth',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0.1, 'x'),
		action = function(value)
			self.flutterLFO:set('depth', value)
		end
	}

	params:add {
		name = 'echo flutter rate',
		id = 'echo_flutter_rate',
		type = 'control',
		controlspec = controlspec.new(2, 10, 'exp', 0, 6.7, 'Hz'),
		action = function(value)
			self.flutterLFO:set('period', 1 / value)
		end
	}

end

return Echo
