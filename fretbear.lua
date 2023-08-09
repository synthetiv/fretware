-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'

n_voices = 5

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

echo_rate = 1
echo_div_dirty = true

-- tt_chord = 0

redraw_metro = nil

g = grid.connect()

touche = midi.connect(1)

voice_states = {}
for v = 1, n_voices do
	voice_states[v] = {
		control = v == 1,
		pitch = 0,
		amp = 0,
		frozen = false,
		loop_armed = false,
		last_tap = util.time()
	}
end
selected_voices = { 1 }
n_selected_voices = 1
lead_voice = 1

tip = 0
palm = 0
do_pitch_detection = false
-- pitch_poll = nil
detected_pitch = 0
gate_in = false

arp_clock = false

-- poll_names = {
-- 	'pitch',
-- 	'amp',
-- 	'clarity',
-- }
-- polls = {}
-- poll_values = {}

function g.key(x, y, z)
	if y >= 1 and y <= 2 and x > 1 and x <= 1 + n_voices then
		if z == 1 then
			local v = x - 1
			local voice = voice_states[v]
			if y == 1 then
				if voice.frozen then
					-- stop looping
					engine.clear_loop(v)
					voice.frozen = false
					voice.loop_armed = false
				elseif not voice.loop_armed then
					-- get ready to loop (set loop start time here)
					voice.loop_armed = util.time()
				else
					-- start looping
					engine.set_loop(v, util.time() - voice.loop_armed)
					voice.frozen = true
					voice.loop_armed = false
				end
			elseif y == 2 then
				local now = util.time()
				if k.held_keys.shift then
					local delay = now - voice.last_tap
					-- if would-be tapped delay time is out of range, don't modify the time
					if delay < 8 then
						params:set('delay_' .. v, delay)
					end
				else
					voice.control = not voice.control
					if voice.control then
						params:set('delay_' .. v, 0)
						-- since delay param is likely already set to 0, the above may have no effect;
						-- so force SuperCollider to set delay to 0, to work around the weird bug that
						-- sometimes makes delay something other than 0
						engine.delay(v, 0)
						table.insert(selected_voices, v)
						n_selected_voices = n_selected_voices + 1
						lead_voice = n_selected_voices
						send_pitch_volts()
					else
						local sv = 1
						while sv <= n_selected_voices do
							if selected_voices[sv] == v then
								table.remove(selected_voices, sv)
								n_selected_voices = n_selected_voices - 1
								lead_voice = n_selected_voices
								send_pitch_volts()
							else
								sv = sv + 1
							end
						end
						engine.tip(v, 0)
						engine.palm(v, 0)
						engine.gate(v, 0)
					end
				end
				voice.last_tap = now
			end
		end
	else
		k:key(x, y, z)
	end
	-- TODO: sync the whole note stack with TT
	-- I think you'll need to trigger events from the keyboard class, and... urgh...
	-- it's more information than you can easily send to TT
	grid_redraw()
end

function send_pitch_volts()
	-- TODO: this added offset for the quantizer really shouldn't be necessary; what's going on here?
	crow.output[1].volts = k.bent_pitch + k.octave + (k.quantizing and 1/24 or 0)
	if n_selected_voices > 0 then
		engine.pitch(selected_voices[lead_voice], k.bent_pitch + k.octave)
	end
end

function touche.event(data)
	local message = midi.to_msg(data)
	if message.ch == 1 and message.type == 'cc' then
		-- back = 16, front = 17, left = 18, right = 19
		if message.cc == 17 then
			tip = message.val / 126
			control_engine_voices('tip', tip) -- let SC do the scaling
			crow.output[2].volts = 10 * math.sqrt(tip)
		elseif message.cc == 16 then
			palm = message.val / 126
			control_engine_voices('palm', palm)
			crow.output[3].volts = palm * params:get('damp_range') + params:get('damp_base')
		elseif message.cc == 18 then
			k:bend(-math.min(1, message.val / 126)) -- TODO: not sure why 126 is the max value I'm getting from Touche...
			send_pitch_volts()
		elseif message.cc == 19 then
			k:bend(math.min(1, message.val / 126))
			send_pitch_volts()
		end
	end
end

function grid_redraw()
	g:all(0)
	k:draw()
	for v = 1, n_voices do
		local voice = voice_states[v]
		local level = voice.amp
		local is_lead = n_selected_voices > 1 and selected_voices[lead_voice] == v
		if voice.loop_armed then
			level = level * 0.5 + 0.5
		elseif voice.frozen then
			level = level * 0.75 + 0.25
		end
		level = 2 + math.floor(level * 14)
		g:led(v + 1, 1, level)
		g:led(v + 1, 2, voice.control and (is_lead and 8 or 5) or 1)
	end
	g:refresh()
end

function crow_init()

	print('crow add')
	params:bang()

	crow.input[1].change = function(gate)
		gate_in = gate
		if params:get('arp_clock_source') == 2 and k.arping and k.n_sustained_keys > 0 then
			k:arp(gate)
		else
			-- if gate then
			-- 	detected_pitch = poll_values.pitch - 1
			-- 	if do_pitch_detection then
			-- 		crow.ii.tt.script_v(2, util.clamp(k.scale:snap(detected_pitch + k.transposition), -5, 5))
			-- 	end
			-- 	k.on_pitch()
			-- end
		end
	end
	crow.input[1].mode('change', 1, 0.01, 'both')

	crow.input[2].stream = function(v)
		k:transpose(v)
	end
	crow.input[2].mode('stream', 0.01)
end

function reset_arp_clock()
	if arp_clock then
		clock.cancel(arp_clock)
	end
	arp_clock = clock.run(function()
		while true do
			-- TODO: find a way to allow modulation to nudge clock pulses back & forth without losing sync... somehow...
			local rate = math.pow(2, -params:get('system_clock_div'))
			clock.sync(rate)
			if params:get('arp_clock_source') == 1 and k.arping and k.n_sustained_keys > 0 then
				if n_selected_voices > 0 then
					if math.random() < params:get('voice_sel_direction') then
						lead_voice = lead_voice % n_selected_voices + 1
					else
						lead_voice = (lead_voice - 2) % n_selected_voices + 1
					end
				end
				k:arp(true)
				clock.sleep(clock.get_beat_sec() * rate / 2)
				k:arp(false)
			end
		end
	end)
end

function control_engine_voices(method, value)
	for v = 1, n_voices do
		if voice_states[v].control then
			engine[method](v, value)
		end
	end
end

-- convenience function for exp-ifying a [-1, 1] linear range
function square_with_sign(n)
	return n * n * (n < 0 and -1 or 1)
end

function init()

	-- for p = 1, #poll_names do
	-- 	local name = poll_names[p]
	-- 	poll_values[name] = 0
	-- 	local new_poll = poll.set(name, function(value)
	-- 		poll_values[name] = value
	-- 	end)
	-- 	new_poll.time = 1 / 10
	-- 	new_poll:start()
	-- 	polls[name] = new_poll
	-- end

	k.on_pitch = function()
		local pitch = k.active_pitch + k.octave
		if do_pitch_detection and k.n_sustained_keys < 1 then
			pitch = util.clamp(detected_pitch + k.transposition, -5, 5)
		end
		send_pitch_volts()
		grid_redraw()
	end

	k.on_mask = function()
		-- local temperament = (k.mask_notes == 'none' or k.ratios == nil) and 12 or 'ji'
		crow.output[1].scale(k.mask_notes, temperament)
		-- TODO: send to TT as well, as a bit mask
	end

	k.on_gate = function(gate)
		if gate and k.gate_mode == 3 then
			-- pulse mode
			crow.output[4]()
			if n_selected_voices > 0 then
				engine.gate(selected_voices[lead_voice], 1)
			end
			-- TODO: finesse this: there should be control over gate time, and this should handle
			-- overlapping gates
			clock.run(function()
				clock.sleep(0.1)
				control_engine_voices('gate', 0) -- TODO
			end)
		else
			crow.output[4](gate)
			if n_selected_voices > 0 then
				engine.gate(selected_voices[lead_voice], gate and 1 or 0)
			end
		end
		if gate and not do_pitch_detection then
			-- TODO: I've lost track of what this is supposed to do...
			crow.ii.tt.script_v(2, k.scale:snap(k.active_pitch + k.transposition))
		end
	end

	-- TODO: why doesn't crow.add() work anymore?
	crow_init()

	-- set up softcut echo
	-- TODO: make something like this in SC instead, so you can add saturation / compander, and maybe a freeze function
	softcut.reset()
	local echo_loop_length = 10
	local echo_head_distance = 1
	for scv = 1, 2 do
		softcut.enable(scv, 1)
		softcut.buffer(scv, 1)
		softcut.rate(scv, 1)
		softcut.loop_start(scv, 1)
		softcut.loop_end(scv, 1 + echo_loop_length)
		softcut.loop(scv, 1)
		softcut.fade_time(scv, 0.01)
		softcut.rec_level(scv, 1)
		softcut.pre_level(scv, 0)
		softcut.position(scv, ((scv - 1) * -echo_head_distance) % echo_loop_length + 1)
		softcut.level_slew_time(scv, 0.001)
		softcut.rate_slew_time(scv, 0.7)
		softcut.play(scv, 1)
		softcut.pre_filter_dry(scv, 1)
		softcut.pre_filter_lp(scv, 0)
		softcut.post_filter_dry(scv, 1)
		softcut.post_filter_lp(scv, 0)
	end
	-- voice 1 = rec head
	softcut.level_input_cut(1, 1, 1)
	softcut.level_input_cut(2, 1, 1)
	softcut.rec(1, 1)
	softcut.phase_quant(1, 0.125)
	softcut.event_phase(function(voice, phase)
		if voice == 1 then
			if echo_div_dirty then
				local div = math.pow(2, params:get('echo_time_div'))
				local new_position = phase - (echo_head_distance * div)
				new_position = (new_position - 1) % echo_loop_length + 1
				softcut.position(2, new_position)
				echo_div_dirty = false
			end
		end
	end)
	softcut.poll_start_phase()
	-- voice 2 = play head
	softcut.level(2, 0.8)

	-- set up polls
	for v = 1, n_voices do
		local pitch_poll = poll.set('pitch_' .. v, function(value)
			voice_states[v].pitch = value
			grid_redraw()
		end)
		pitch_poll:start()
		local amp_poll = poll.set('amp_' .. v, function(value)
			voice_states[v].amp = value
		end)
		amp_poll:start()
	end

	params:add {
		name = 'base frequency (C)',
		id = 'base_freq',
		type = 'control',
		controlspec = controlspec.new(130, 522, 'exp', 0, musicutil.note_num_to_freq(60), 'Hz'),
		action = function(value)
			engine.base_freq(value)
		end
	}

	params:add {
		name = 'base freq reset',
		id = 'base_freq_reset',
		type = 'binary',
		behavior = 'trigger',
		action = function(value)
			params:set('base_freq', musicutil.note_num_to_freq(60))
		end
	}

	params:add {
		name = 'bend range',
		id = 'bend_range',
		type = 'number',
		min = -7,
		max = 24,
		default = -2,
		formatter = function(param)
			local value = k.bend_range * 12
			if value < 1 then
				return string.format('%.2f', value)
			end
			return string.format('%d', value)
		end,
		action = function(value)
			if value < 1 then
				value = math.pow(0.75, 1 - value)
			end
			k.bend_range = value / 12
			k:set_bend_targets()
			k:bend(k.bend_amount)
			send_pitch_volts()
		end
	}

	params:add {
		name = 'arp clock source',
		id = 'arp_clock_source',
		type = 'option',
		options = { 'system', 'crow' },
		default = 1
	}

	params:add {
		name = 'system clock div',
		id = 'system_clock_div',
		type = 'number',
		default = 2,
		min = -3,
		max = 5,
		formatter = function(param)
			local measures = -param:get() - 2
			if measures >= 0 then
				return string.format('%d', math.pow(2, measures))
			else
				return string.format('1/%d', math.pow(2, -measures))
			end
		end,
		action = function(value)
			reset_arp_clock()
		end
	}

	params:add {
		name = 'voice sel direction (1=fwd)',
		id = 'voice_sel_direction',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 1),
	}

	params:add {
		name = 'arp direction (1=fwd)',
		id = 'arp_direction',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 1),
		action = function(value)
			k.arp_forward_probability = value
		end
	}

	params:add_group('crow', 7)
	
	-- TODO: damp base + range are a way to avoid using an extra attenuator + offset,
	-- but is that worth it?
	params:add {
		name = 'damp range',
		id = 'damp_range',
		type = 'control',
		controlspec = controlspec.new(-10, 10, 'lin', 0, -5, 'v')
	}
	
	params:add {
		name = 'damp base',
		id = 'damp_base',
		type = 'control',
		controlspec = controlspec.new(-10, 10, 'lin', 0, 0, 'v')
	}
	
	params:add {
		name = 'pitch slew',
		id = 'pitch_slew',
		type = 'control',
		controlspec = controlspec.new(0, 0.1, 'lin', 0, 0, 's'),
		action = function(value)
			crow.output[1].slew = value
		end
	}
	
	params:add {
		name = 'amp/damp slew',
		id = 'amp_slew',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.05, 's'),
		action = function(value)
			crow.output[2].slew = value
			crow.output[3].slew = value
		end
	}

	params:add {
		name = 'gate mode',
		id = 'gate_mode',
		type = 'option',
		options = { 'legato', 'retrig', 'pulse' },
		default = 2,
		action = function(value)
			k.gate_mode = value
			if value == 1 then
				crow.output[4].action = [[{
					held { to(8, dyn { delay = 0 }, 'wait') },
					to(0, 0)
				}]]
				crow.output[4].dyn.delay = params:get('gate_delay')
				crow.output[4](false)
			elseif value == 2 then
				crow.output[4].action = [[{
					to(0, dyn { delay = 0 }, 'now'),
					held { to(8, 0) },
					to(0, 0)
				}]]
				crow.output[4].dyn.delay = params:get('gate_delay')
				crow.output[4](false)
			elseif value == 3 then
				crow.output[4].action = [[{
					to(0, dyn { delay = 0 }, 'now'),
					to(8, dyn { length = 0.01 }, 'now'),
					to(0, 0)
				}]]
				crow.output[4].dyn.delay = params:get('gate_delay')
				crow.output[4].dyn.length = params:get('pulse_length')
			end
		end
	}

	params:add {
		name = 'gate delay',
		id = 'gate_delay',
		type = 'control',
		controlspec = controlspec.new(0.001, 0.05, 'lin', 0, 0.001, 's'),
		action = function(value)
			crow.output[4].dyn.delay = value
		end
	}

	params:add {
		name = 'pulse length',
		id = 'pulse_length',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.01, 's'),
		action = function(value)
			if params:get('gate_mode') == 3 then
				crow.output[4].dyn.length = value
			end
		end
	}

	params:add_separator('echo')

	params:add {
		name = 'echo send',
		id = 'echo_send',
		type = 'taper',
		min = 0,
		max = 1,
		k = 2,
		default = 0.2,
		action = function(value)
			softcut.level_input_cut(1, 1, value)
			softcut.level_input_cut(2, 1, value)
		end
	}

	params:add {
		name = 'echo time',
		id = 'echo_time',
		type = 'control',
		controlspec = controlspec.new(0.05, 1, 'lin', 0, 0.11, 's'),
		action = function(time)
			-- softcut voice rates are set based on this, in a clock routine
			echo_rate = echo_head_distance / time
		end
	}

	params:add {
		name = 'echo time div',
		id = 'echo_time_div',
		type = 'number',
		min = -2,
		max = 4,
		default = 0,
		formatter = function(param)
			return string.format('%.2fx', math.pow(2, param:get()))
		end,
		action = function(value)
			echo_div_dirty = true
		end
	}

	params:add {
		name = 'echo div fade',
		id = 'echo_div_fade',
		type = 'control',
		controlspec = controlspec.new(0, 25, 'lin', 0, 10, 'ms'),
		action = function(time)
			for scv = 1, 2 do
				softcut.fade_time(scv, time * 0.001)
			end
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
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.01)
	}

	params:add {
		name = 'echo resolution',
		id = 'echo_resolution',
		type = 'number',
		default = 0,
		min = -5,
		max = 1,
		action = function(value)
			echo_head_distance = math.pow(2, value)
			-- reset other related params
			echo_rate = echo_head_distance / params:get('echo_time')
			echo_div_dirty = true
		end
	}

	params:add_separator('ALL int voices')

	params:add {
		name = 'pitch lag',
		id = 'pitch_lag',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.01, 's'),
		action = function(value)
			for v = 1, n_voices do
				engine.pitch_slew(v, value)
			end
		end
	}

	params:add {
		name = 'other lag',
		id = 'other_lag',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.1, 's'),
		action = function(value)
			for v = 1, n_voices do
				engine.lag(v, value)
			end
		end
	}

	params:add {
		name = 'param 1',
		id = 'p1',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.p1(v, value + params:get('p1_' .. v))
			end
		end
	}

	params:add {
		name = 'param 2',
		id = 'p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				-- p2 = tuning. square for finer control near 0 so close detuning is easier
				engine.p2(v, square_with_sign(value) + square_with_sign(params:get('p2_' .. v)))
			end
		end
	}

	params:add {
		name = 'param 3',
		id = 'p3',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.p3(v, value + params:get('p3_' .. v))
			end
		end
	}

	params:add {
		name = 'param 4',
		id = 'p4',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.p4(v, value + params:get('p4_' .. v))
			end
		end
	}

	params:add_group('pitch', 4)

	params:add {
		name = 'pitch -> p1',
		id = 'pitch_p1',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.pitch_p1(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> p2',
		id = 'pitch_p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.pitch_p2(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> p3',
		id = 'pitch_p3',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.pitch_p3(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> p4',
		id = 'pitch_p4',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.pitch_p4(v, value)
			end
		end
	}

	params:add_group('tip', 10)

	params:add {
		name = 'tip -> amp',
		id = 'tip_amp',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 1),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_amp(v, value - 0.001)
				engine.eg_amp(v, 1 - value + 0.001)
			end
		end
	}

	params:add {
		name = 'tip -> p1',
		id = 'tip_p1',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_p1(v, value)
			end
		end
	}

	params:add {
		name = 'tip -> p2',
		id = 'tip_p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_p2(v, value)
			end
		end
	}

	params:add {
		name = 'tip -> p3',
		id = 'tip_p3',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_p3(v, value)
			end
		end
	}

	params:add {
		name = 'tip -> p4',
		id = 'tip_p4',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_p4(v, value)
			end
		end
	}

	params:add {
		name = 'tip -> eg amt',
		id = 'tip_eg_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 1),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_eg_amount(v, value)
			end
		end
	}

	params:add {
		name = 'tip -> lfo A freq',
		id = 'tip_lfo_a_freq',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_lfo_a_freq(v, value)
			end
		end
	}

	params:add {
		name = 'tip -> lfo A amt',
		id = 'tip_lfo_a_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_lfo_a_amount(v, value)
			end
		end
	}

	params:add {
		name = 'tip -> lfo B freq',
		id = 'tip_lfo_b_freq',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_lfo_b_freq(v, value)
			end
		end
	}

	params:add {
		name = 'tip -> lfo B amt',
		id = 'tip_lfo_b_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_lfo_b_amount(v, value)
			end
		end
	}

	params:add_group('palm', 10)

	params:add {
		name = 'palm -> amp',
		id = 'palm_amp',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_amp(v, value - 0.001)
			end
		end
	}

	params:add {
		name = 'palm -> p1',
		id = 'palm_p1',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, -0.25),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_p1(v, value)
			end
		end
	}

	params:add {
		name = 'palm -> p2',
		id = 'palm_p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_p2(v, value)
			end
		end
	}

	params:add {
		name = 'palm -> p3',
		id = 'palm_p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, -0.25),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_p3(v, value)
			end
		end
	}

	params:add {
		name = 'palm -> p4',
		id = 'palm_p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_p4(v, value)
			end
		end
	}

	params:add {
		name = 'palm -> eg amt',
		id = 'palm_eg_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_eg_amount(v, value)
			end
		end
	}

	params:add {
		name = 'palm -> lfo A freq',
		id = 'palm_lfo_a_freq',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_lfo_a_freq(v, value)
			end
		end
	}

	params:add {
		name = 'palm -> lfo A amt',
		id = 'palm_lfo_a_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_lfo_a_amount(v, value)
			end
		end
	}

	params:add {
		name = 'palm -> lfo B freq',
		id = 'palm_lfo_b_freq',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_lfo_b_freq(v, value)
			end
		end
	}

	params:add {
		name = 'palm -> lfo B amt',
		id = 'palm_lfo_b_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.palm_lfo_b_amount(v, value)
			end
		end
	}

	params:add_group('eg', 12)

	params:add {
		name = 'attack',
		id = 'attack',
		type = 'control',
		controlspec = controlspec.new(0.001, 2, 'exp', 0, 0.01, 's'),
		action = function(value)
			for v = 1, n_voices do
				engine.attack(v, value)
			end
		end
	}

	params:add {
		name = 'decay',
		id = 'decay',
		type = 'control',
		controlspec = controlspec.new(0.001, 6, 'exp', 0, 0.1, 's'),
		action = function(value)
			for v = 1, n_voices do
				engine.decay(v, value)
			end
		end
	}

	params:add {
		name = 'sustain',
		id = 'sustain',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0.8),
		action = function(value)
			for v = 1, n_voices do
				engine.sustain(v, value)
			end
		end
	}

	params:add {
		name = 'release',
		id = 'release',
		type = 'control',
		controlspec = controlspec.new(0.001, 6, 'exp', 0, 0.3, 's'),
		action = function(value)
			for v = 1, n_voices do
				engine.release(v, value)
			end
		end
	}

	params:add {
		name = 'amount',
		id = 'eg_amount',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 1),
		action = function(value)
			for v = 1, n_voices do
				engine.eg_amount(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> pitch',
		id = 'eg_pitch',
		type = 'control',
		controlspec = controlspec.new(-0.2, 0.2, 'lin', 0, 0),
		formatter = function(param)
			local value = param:get()
			return string.format('%.2f', value * 12)
		end,
		action = function(value)
			for v = 1, n_voices do
				engine.eg_pitch(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> amp',
		id = 'eg_amp',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				-- engine.eg_amp(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> p1',
		id = 'eg_p1',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.eg_p1(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> p2',
		id = 'eg_p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.eg_p2(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> p3',
		id = 'eg_p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.eg_p3(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> p4',
		id = 'eg_p2',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.eg_p4(v, value)
			end
		end
	}

	params:add {
		name = 'fm cutoff',
		id = 'fm_cutoff',
		type = 'control',
		controlspec = controlspec.new(32, 23000, 'exp', 0, 12000, 'Hz'),
		action = function(value)
			for v = 1, n_voices do
				engine.fm_cutoff(v, value)
			end
		end
	}

	params:add {
		name = 'hp cutoff',
		id = 'hp_cutoff',
		type = 'control',
		controlspec = controlspec.new(16, 12000, 'exp', 0, 16, 'Hz'),
		action = function(value)
			for v = 1, n_voices do
				engine.hp_cutoff(v, value)
			end
		end
	}

	params:add {
		name = 'lp cutoff',
		id = 'lp_cutoff',
		type = 'control',
		controlspec = controlspec.new(32, 23000, 'exp', 0, 23000, 'Hz'),
		action = function(value)
			for v = 1, n_voices do
				engine.lp_cutoff(v, value)
			end
		end
	}

	for v = 1, n_voices do

		params:add_separator('int voice ' .. v)

		params:add {
			name = 'delay',
			id = 'delay_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 8, 'lin', 0, 0, 's'),
			action = function(value)
				engine.delay(v, value)
			end
		}

		params:add {
			name = 'loop position',
			id = 'loop_position_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.loop_position(v, value)
			end
		}

		params:add {
			name = 'detune',
			id = 'detune_' .. v,
			type = 'control',
			controlspec = controlspec.new(-12, 12, 'lin', 0, 0, 'st'),
			action = function(value)
				engine.detune(v, value / 12)
			end
		}

		params:add {
			name = 'octave',
			id = 'octave_' .. v,
			type = 'number',
			min = -5,
			max = 5,
			default = 0,
			action = function(value)
				engine.octave(v, value)
			end
		}

		params:add {
			name = 'param 1',
			id = 'p1_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.p1(v, value + params:get('p1'))
			end
		}

		params:add {
			name = 'param 2',
			id = 'p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.p2(v, square_with_sign(value) + square_with_sign(params:get('p2')))
			end
		}

		params:add {
			name = 'param 3',
			id = 'p3_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.p3(v, value + params:get('p3'))
			end
		}

		params:add {
			name = 'param 4',
			id = 'p4_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.p4(v, value + params:get('p4'))
			end
		}

		params:add {
			name = 'fm cutoff',
			id = 'fm_cutoff_' .. v,
			type = 'control',
			controlspec = controlspec.new(32, 23000, 'exp', 0, 12000, 'Hz'),
			action = function(value)
				engine.fm_cutoff(v, value)
			end
		}

		params:add {
			name = 'out level',
			id = 'out_level_' .. v,
			type = 'taper',
			min = 0,
			max = 0.5,
			k = 2,
			default = 0.2,
			-- controlspec = controlspec.new(0, 0.5, 'exp', 0, 0.2),
			action = function(value)
				engine.out_level(v, value)
			end
		}

		params:add_group('v' .. v .. ' fm', n_voices)

		for w = 1, n_voices do 
			params:add {
				name = 'voice ' .. w .. ' -> voice ' .. v,
				id = 'voice' .. w .. '_' .. v,
				type = 'taper',
				min = 0,
				max = 7,
				k = 6,
				default = 0,
				action = function(value)
					engine['voice' .. w ..'_fm'](v, value)
				end
			}
		end

		params:add_group('v' .. v .. ' lfo A', 11)

		params:add {
			name = 'lfo A type',
			id = 'lfo_a_type_' .. v,
			type = 'option',
			options = { 'sine', 'tri', 'saw', 'rand', 's+h' },
			action = function(value)
				engine.lfo_a_type(v, value)
			end
		}

		params:add {
			name = 'lfo A freq',
			id = 'lfo_a_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.01, 10, 'exp', 0, 0.9, 'Hz'),
			action = function(value)
				engine.lfo_a_freq(v, value)
			end
		}

		params:add {
			name = 'lfo A -> pitch',
			id = 'lfo_a_pitch_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			formatter = function(param)
				local value = param:get()
				return string.format('%.2f', value * 12)
			end,
			action = function(value)
				engine.lfo_a_pitch(v, value)
			end
		}

		params:add {
			name = 'lfo A -> amp',
			id = 'lfo_a_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_amp(v, value)
			end
		}

		params:add {
			name = 'lfo A -> p1',
			id = 'lfo_a_p1_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_p1(v, value)
			end
		}

		params:add {
			name = 'lfo A -> p2',
			id = 'lfo_a_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_p2(v, value)
			end
		}

		params:add {
			name = 'lfo A -> p3',
			id = 'lfo_a_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_p3(v, value)
			end
		}

		params:add {
			name = 'lfo A -> p4',
			id = 'lfo_a_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_p4(v, value)
			end
		}

		params:add {
			name = 'lfo A -> eg amt',
			id = 'lfo_a_eg_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_eg_amount(v, value)
			end
		}

		params:add {
			name = 'lfo A -> lfo B freq',
			id = 'lfo_a_lfo_b_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_lfo_b_freq(v, value)
			end
		}

		params:add {
			name = 'lfo A -> lfo B amt',
			id = 'lfo_a_lfo_b_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_lfo_b_amount(v, value)
			end
		}

		params:add_group('v' .. v .. ' lfo B', 11)

		params:add {
			name = 'lfo B type',
			id = 'lfo_b_type_' .. v,
			type = 'option',
			options = { 'sine', 'tri', 'saw', 'rand', 's+h' },
			default = 4,
			action = function(value)
				engine.lfo_b_type(v, value)
			end
		}

		params:add {
			name = 'lfo B freq',
			id = 'lfo_b_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.01, 10, 'exp', 0, 0.9, 'Hz'),
			action = function(value)
				engine.lfo_b_freq(v, value)
			end
		}

		params:add {
			name = 'lfo B -> pitch',
			id = 'lfo_b_pitch_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			formatter = function(param)
				local value = param:get()
				return string.format('%.2f', value * 12)
			end,
			action = function(value)
				engine.lfo_b_pitch(v, value)
			end
		}

		params:add {
			name = 'lfo B -> amp',
			id = 'lfo_b_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_amp(v, value)
			end
		}

		params:add {
			name = 'lfo B -> p1',
			id = 'lfo_b_p1_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_p1(v, value)
			end
		}

		params:add {
			name = 'lfo B -> p2',
			id = 'lfo_b_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_p2(v, value)
			end
		}

		params:add {
			name = 'lfo B -> p3',
			id = 'lfo_b_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_p3(v, value)
			end
		}

		params:add {
			name = 'lfo B -> p4',
			id = 'lfo_b_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_p4(v, value)
			end
		}

		params:add {
			name = 'lfo B -> eg amt',
			id = 'lfo_b_eg_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_eg_amount(v, value)
			end
		}

		params:add {
			name = 'lfo B -> lfo A freq',
			id = 'lfo_b_lfo_a_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_lfo_a_freq(v, value)
			end
		}

		params:add {
			name = 'lfo B -> lfo A amt',
			id = 'lfo_b_lfo_a_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_lfo_a_amount(v, value)
			end
		}

	end

	params:add_separator('etc')

	-- TODO: add params for tt and crow transposition
	-- ...and yeah, control from keyboard. you'll want that again

	params:add {
		name = 'pitch detection',
		id = 'pitch_detection',
		type = 'option',
		options = { 'off', 'on' },
		default = 1,
		action = function(value)
			do_pitch_detection = value == 2
		end
	}

	params:add {
		type = 'file',
		id = 'tuning_file',
		name = 'tuning_file',
		path = '/home/we/dust/data/fretwork/scales/12tet.scl',
		action = function(value)
			k.scale:read_scala_file(value)
			k.scale:apply_edits()
		end
	}

	-- TODO: global transpose, for working with oscillators that aren't tuned to C
	-- TODO: quantize lock on/off: apply post-bend quantization to keyboard notes
	
	params:bang()

	params:set('reverb', 1) -- off

	reset_arp_clock()

	clock.run(function()
		local rate = echo_rate
		while true do
			rate = rate + (echo_rate - rate) * 0.2
			rate = rate * math.pow(1.1, math.random() * params:get('echo_drift'))
			for scv = 1, 2 do
				softcut.rate(scv, rate)
			end
			clock.sleep(0.1)
		end
	end)

	redraw_metro = metro.init {
		time = 1 / 12,
		event = function()
			redraw()
			grid_redraw()
		end
	}
	redraw_metro:start()
	
	-- start at 0 / middle C
	k.on_pitch()

	grid_redraw()
end

function ampdb(amp)
	return math.log(amp) / 0.05 / math.log(10)
end

function redraw()
	-- TODO: show held pitch(es), bend, amp/damp
	screen.clear()
	screen.update()
end

function enc(n, d)
	-- TODO: adjust slew, bend range
end

function key(n, z)
	if z == 1 then
	end
end

function cleanup()
	if redraw_metro ~= nil then
		redraw_metro:stop()
	end
	-- for p = 1, #poll_names do
	-- 	local name = poll_names[p]
	-- 	if polls[name] ~= nil then
	-- 		polls[name]:stop()
	-- 	end
	-- end
end
