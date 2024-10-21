local Echo = {}
Echo.__index = Echo

local LFO = require 'lfo'

Echo.RATE_SMOOTHING = 0.2
Echo.LOOP_LENGTH = 60
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
		tone_gain_compensation = 0.838,
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
	softcut.event_position(function(voice, position)
		if voice == self.rec_voice then
			-- apply drift
			local drift_factor = math.pow(Echo.DRIFT_BASE, self.wow + self.flutter)
			local rate = math.pow(2, self.rate_smoothed + self.resolution) * drift_factor
			-- update voice rates
			for scv = self.rec_voice, self.play_voice do
				softcut.rate(scv, rate)
			end
			-- TODO: update play head's loop points to avoid overlap with rec head when playback pitch != 1x?
			-- (the tricky part will be handling this near the rec head's loop points...)
			local div_jump_compensation = 1
			if self.div_dirty then
				-- TODO: reduce feedback
				-- move the play head closer to or further from the record head, depending on echo_div
				self.div = params:get('echo_time_div') + self.jump_div
				local new_position = position - (self.head_distance * math.pow(2, self.div + self.resolution))
				-- wrap to within loop boundaries
				new_position = (new_position - 1) % Echo.LOOP_LENGTH + 1
				softcut.position(self.play_voice, new_position)
				-- when jumping, duck feedback by sqrt(0.5), to compensate for equal power fade.
				-- equal power will eventually make feedback blow up, especially when div is small,
				-- so this basically creates an equal gain fade instead.
				div_jump_compensation = 0.7071
				self.div_dirty = false
			end
			local rate_scale = math.pow(2, self.div - rate)
			local time = self.head_distance * rate_scale
			local gain = math.exp(time * math.log(self.feedback)) * self.tone_gain_compensation
			softcut.level_cut_cut(self.play_voice, self.rec_voice, gain * div_jump_compensation)
		end
	end)

	softcut.position(self.rec_voice, 1)
	softcut.position(self.play_voice, (-self.head_distance) % Echo.LOOP_LENGTH + 1)

	softcut.level(self.play_voice, 1)

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

	-- TODO: change mix and/or freq with resolution... and/or rate
	softcut.pre_filter_dry(self.rec_voice, 0.8)
	softcut.pre_filter_hp(self.rec_voice, 0.2)
	softcut.pre_filter_fc(self.rec_voice, 30)
	softcut.pre_filter_rq(self.rec_voice, 6)

	self:set_tone(0)

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
			local rand = (math.random() + math.random() + math.random()) / 3
			local rate = 1 / params:get('echo_flutter_rate')
			rate = rate * (1 + (rand * 0.5))
			self.flutterLFO:set('period', rate)
			self.flutter = value
		end
	}
	self.flutterLFO:start()

	clock.run(function()
		while true do
			self.rate_smoothed = self.rate_smoothed + (self.rate - self.rate_smoothed) * Echo.RATE_SMOOTHING
			softcut.query_position(self.rec_voice)
			clock.sleep(0.0125)
		end
	end)

end

function Echo:set_tone(tone)
	-- if tone >= 0 then
	-- 	softcut.post_filter_fc(self.play_voice, util.linexp(0, 1, 10, 10000, math.pow(tone, 2)))
	-- 	self.tone_gain_compensation = util.linlin(0.2, 1, 0.835, 1.2, tone)
	-- else
	-- 	softcut.post_filter_fc(self.play_voice, util.linexp(0, 1, 23000, 230, math.pow(-tone, 0.5)))
	-- 	self.tone_gain_compensation = util.linlin(0.1, 1, 0.835, 1.2, -tone)
	-- end
	-- softcut.post_filter_dry(self.play_voice, util.linlin(0.1, 1, 1, 0, math.abs(tone)))
	-- softcut.post_filter_lp(self.play_voice, util.linlin(-1, 0.1, 1, 0, tone))
	-- softcut.post_filter_hp(self.play_voice, util.linlin(0.1, 1, 0, 1, tone))
	softcut.post_filter_dry(self.play_voice, 1)
	softcut.post_filter_lp(self.play_voice, 0)
	softcut.post_filter_hp(self.play_voice, 0)
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

	params:add_group('echo', 12)

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
		name = 'echo decay',
		id = 'echo_feedback',
		type = 'control',
		controlspec = controlspec.new(0, 1.27, 'lin', 0, 0.1),
		action = function(value)
			-- exponential-ize response below unity gain; linear response above
			if value < 1 then
				value = value * value * value
			else
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
		max = 2,
		formatter = Echo.div_formatter('%d'),
		action = function(value)
			self.resolution = value
			self.resolution_dirty = true
			self.div_dirty = true
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
