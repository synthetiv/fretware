-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'
ui = require 'ui'

n_voices = 7

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

echo_rate = 1
echo_div_dirty = true

redraw_metro = nil

g = grid.connect()

-- TODO: connect to these devices by name
touche = midi.connect(1) -- 'TOUCHE 1'
fbv = midi.connect(4) -- 'FBV Express Mk II 1'

editor = {
	shift = false,
	source_names = {
		'hand',
		'foot',
		'pitch',
		'eg'
		-- TODO: LFO
	},
	dest_names = {
		'tune_a',
		'tune_b',
		'fm_index',
		'fb_b',
		'op_detune',
		'op_mix',
		'fold_gain',
		'fold_bias'
	},
	dest_labels = {
		'tune A',
		'tune B',
		'fm index',
		'feedback B',
		'detune A/B',
		'mix A/B',
		'fold gain',
		'fold bias'
	},
	source = 1,
	dest = 1,
}

dest_dials = {
	-- x, y, size, value, min_value, max_value, rounding, start_value, markers, units, title
	tune_a    = ui.Dial.new(109,  20, 15, 0, -1, 1, 0.01, 0),
	tune_b    = ui.Dial.new(109,  46, 15, 0, -1, 1, 0.01, 0),
	fm_index  = ui.Dial.new(109,  72, 15, 0, -1, 1, 0.01, 0),
	fb_b      = ui.Dial.new(109,  98, 15, 0, -1, 1, 0.01, 0),
	op_detune = ui.Dial.new(109, 124, 15, 0, -1, 1, 0.01, 0),
	op_mix    = ui.Dial.new(109, 150, 15, 0, -1, 1, 0.01, 0),
	fold_gain = ui.Dial.new(109, 176, 15, 0, -1, 1, 0.01, 0),
	fold_bias = ui.Dial.new(109, 202, 15, 0, -1, 1, 0.01, 0)
}

source_dials = {}
for s = 1, #editor.dest_names do
	source_dials[editor.dest_names[s]] = {
		hand  = ui.Dial.new( 2,  2, 12, 0, -1, 1, 0.01, 0),
		foot  = ui.Dial.new(19,  2, 12, 0, -1, 1, 0.01, 0),
		pitch = ui.Dial.new( 2, 22, 12, 0, -1, 1, 0.01, 0),
		eg    = ui.Dial.new(19, 22, 12, 0, -1, 1, 0.01, 0)
		-- ui.Dial.new( 10, 42, 12, 0, -1, 1, 0.01, 0),
	}
end

voice_states = {}
for v = 1, n_voices do
	voice_states[v] = {
		control = v == 1,
		pitch = 0,
		amp = 0,
		looping = false,
		looping_next = false,
		loop_armed = false,
		loop_armed_next = false,
		loop_beat_sec = 0.25
	}
end
selected_voices = { 1 }
n_selected_voices = 1
lead_voice = 1

tip = 0
palm = 0
foot = 0
gate_in = false

arp_clock = false
loop_clock = false
loop_free = false

-- handle grid key or footswitch press for looping
function voice_loop_button(v)
	local voice = voice_states[v]
	if voice.looping then
		-- stop looping
		engine.clearLoop(v)
		voice.looping = false
		if voice.loop_clock then
			clock.cancel(voice.loop_clock)
		end
	elseif not voice.loop_armed then
		-- get ready to loop (set loop start time here)
		if loop_free then
			voice.loop_armed = util.time()
		else
			voice.loop_armed_next = true
		end
	else
		-- start looping
		if loop_free then
			engine.set_loop(v, util.time() - voice.loop_armed)
			voice.looping = true
			voice.loop_armed = false
		else
			voice.looping_next = true
		end
	end
end

function g.key(x, y, z)
	if y < 8 and x <= 2 then
		if z == 1 then
			local v = 8 - y
			if x == 1 then
				voice_loop_button(v)
			elseif x == 2 then
				local voice = voice_states[v]
				-- TODO: is this stuff useful now?
				voice.control = not voice.control
				if voice.control then
					-- force SuperCollider to set delay to 0, to work around the
					-- weird bug that sometimes makes delay something else
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

function fbv.event(data)
	local message = midi.to_msg(data)
	if message.ch == 1 and message.type == 'cc' then
		if message.cc == 13 then
			foot = message.val / 127
			control_engine_voices('foot', foot)
		elseif message.cc == 17 and message.val == 127 then
			voice_loop_button(selected_voices[lead_voice])
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
		elseif voice.looping then
			level = level * 0.75 + 0.25
		end
		level = 2 + math.floor(level * 14)
		g:led(1, 8 - v, level)
		g:led(2, 8 - v, voice.control and (is_lead and 8 or 5) or 1)
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
			local rate = math.pow(2, -params:get('arp_clock_div'))
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

function reset_loop_clock()
	if loop_clock then
		clock.cancel(loop_clock)
	end
	for v = 1, n_voices do
		local voice = voice_states[v]
		voice.loop_armed_next = false
		voice.looping_next = false
	end
	local div = params:get('loop_clock_div')
	loop_free = div == 3 -- 3 = free, unquantized looping
	if not loop_free then
		loop_clock = clock.run(function()
			while true do
				local rate = math.pow(2, -params:get('loop_clock_div'))
				clock.sync(rate)
				for v = 1, n_voices do
					local voice = voice_states[v]
					if voice.loop_armed_next then
						-- get ready to loop (set loop start time here). when looping is synced, we set loop
						-- lengths in beats, not seconds, in case tempo changes
						voice.loop_armed = clock.get_beats()
						voice.loop_armed_next = false
					elseif voice.looping_next then
						-- start looping
						local beat_sec = clock.get_beat_sec()
						local loop_length_beats = (clock.get_beats() - voice.loop_armed)
						-- TODO: is rounding really appropriate here?
						local loop_length_ticks = math.floor(loop_length_beats / rate + 0.5)
						local loop_tick = 1
						engine.setLoop(v, beat_sec * loop_length_beats)
						voice.looping = true
						voice.looping_next = false
						voice.loop_armed = false
						voice.loop_beat_sec = beat_sec
						voice.loop_clock = clock.run(function()
							while true do
								clock.sync(rate)
								loop_tick = loop_tick % loop_length_ticks + 1
								if loop_tick == 1 then
									engine.resetLoopPhase(v)
								end
							end
						end)
					elseif voice.looping then
						-- adjust rate to match tempo as needed
						engine.loopRateScale(v, clock.get_beat_sec() / voice.loop_beat_sec)
					end
				end
			end
		end)
	end
end

function control_engine_voices(method, value)
	for v = 1, n_voices do
		if voice_states[v].control then
			engine[method](v, value)
		end
	end
end

function init()

	k.on_pitch = function()
		local pitch = k.active_pitch + k.octave
		send_pitch_volts()
		grid_redraw()
	end

	k.on_gate = function(gate)
		crow.output[4](gate)
		if n_selected_voices > 0 then
			engine.gate(selected_voices[lead_voice], gate and 1 or 0)
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
		-- TODO: respond more immediately to sudden pitch changes, without calling
		-- grid_redraw() unnecessarily.
		-- grid_redraw() used to be called with EVERY pitch poll callback for EVERY voice.
		-- instead, call it only when triggered by a pitch change, and NOT when doing a
		-- routine pitch check...??
		-- and maybe debounce it too
		local pitch_poll = poll.set('pitch_' .. v, function(value)
			voice_states[v].pitch = value
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
			engine.baseFreq(value)
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
		name = 'arp clock div',
		id = 'arp_clock_div',
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
		name = 'loop clock div',
		id = 'loop_clock_div',
		type = 'number',
		default = 3,
		min = -3,
		max = 3,
		formatter = function(param)
			local measures = -param:get() - 2
			if measures == -5 then -- 3 = 1/32 = no quantization of loop lengths
				return 'free'
			elseif measures >= 0 then
				return string.format('%d', math.pow(2, measures))
			else
				return string.format('1/%d', math.pow(2, -measures))
			end
		end,
		action = function(value)
			reset_loop_clock()
		end
	}

	params:add {
		name = 'voice sel direction (1=fwd)',
		id = 'voice_sel_direction',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 1),
	}

	params:add {
		name = 'arp randomness',
		id = 'arp_randomness',
		type = 'control',
		controlspec = controlspec.new(0, 100, 'lin', 1, 0, '%'),
		action = function(value)
			k.arp_randomness = value / 100
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
		options = { 'legato', 'retrig' },
		default = 2,
		action = function(value)
			k.retrig = value == 2
			if not k.retrig then
				crow.output[4].action = [[{
					held { to(8, dyn { delay = 0 }, 'wait') },
					to(0, 0)
				}]]
				crow.output[4].dyn.delay = params:get('gate_delay')
				crow.output[4](false)
			else
				crow.output[4].action = [[{
					to(0, dyn { delay = 0 }, 'now'),
					held { to(8, 0) },
					to(0, 0)
				}]]
				crow.output[4].dyn.delay = params:get('gate_delay')
				crow.output[4](false)
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
		name = 'amp mode',
		id = 'amp_mode',
		type = 'option',
		options = { 'tip', 'tip*ar', 'adsr' },
		default = 1,
		action = function(value)
			for v = 1, n_voices do
				engine.ampMode(v, value - 1)
			end
		end
	}

	params:add {
		name = 'pitch lag',
		id = 'pitch_lag',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.01, 's'),
		action = function(value)
			for v = 1, n_voices do
				engine.pitchSlew(v, value)
			end
		end
	}

	params:add {
		name = 'tune A',
		id = 'tune_a',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			dest_dials.tune_a:set_value(value)
			for v = 1, n_voices do
				engine.tuneA(v, value + params:get('tune_a_' .. v))
			end
		end
	}

	params:add {
		name = 'tune B',
		id = 'tune_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			dest_dials.tune_b:set_value(value)
			for v = 1, n_voices do
				engine.tuneB(v, value + params:get('tune_b_' .. v))
			end
		end
	}

	params:add {
		name = 'fm index',
		id = 'fm_index',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			dest_dials.fm_index:set_value(value)
			for v = 1, n_voices do
				engine.fmIndex(v, value + params:get('fm_index_' .. v))
			end
		end
	}

	params:add {
		name = 'feedback B',
		id = 'fb_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			dest_dials.fb_b:set_value(value)
			for v = 1, n_voices do
				engine.fbB(v, value + params:get('fb_b_' .. v))
			end
		end
	}

	params:add {
		name = 'detune A/B',
		id = 'op_detune',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			dest_dials.op_detune:set_value(value)
			for v = 1, n_voices do
				engine.opDetune(v, value + params:get('op_detune_' .. v))
			end
		end
	}

	params:add {
		name = 'mix A/B',
		id = 'op_mix',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, -1),
		action = function(value)
			dest_dials.op_mix:set_value(value)
			for v = 1, n_voices do
				engine.opMix(v, value + params:get('op_mix_' .. v))
			end
		end
	}

	params:add {
		name = 'fold gain',
		id = 'fold_gain',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, -0.15),
		action = function(value)
			dest_dials.fold_gain:set_value(value)
			for v = 1, n_voices do
				engine.foldGain(v, value + params:get('fold_gain_' .. v))
			end
		end
	}

	params:add {
		name = 'fold bias',
		id = 'fold_bias',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, -1),
		action = function(value)
			dest_dials.fold_bias:set_value(value)
			for v = 1, n_voices do
				engine.foldBias(v, value + params:get('fold_bias_' .. v))
			end
		end
	}

	params:add_group('pitch', 8)

	params:add {
		name = 'pitch -> tune_a',
		id = 'pitch_tune_a',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.tune_a.pitch:set_value(value)
			for v = 1, n_voices do
				engine.pitch_tuneA(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> tune_b',
		id = 'pitch_tune_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.tune_b.pitch:set_value(value)
			for v = 1, n_voices do
				engine.pitch_tuneB(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> fm_index',
		id = 'pitch_fm_index',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fm_index.pitch:set_value(value)
			for v = 1, n_voices do
				engine.pitch_fmIndex(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> fb_b',
		id = 'pitch_fb_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fb_b.pitch:set_value(value)
			for v = 1, n_voices do
				engine.pitch_fbB(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> op_detune',
		id = 'pitch_op_detune',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.op_detune.pitch:set_value(value)
			for v = 1, n_voices do
				engine.pitch_opDetune(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> op_mix',
		id = 'pitch_op_mix',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.op_mix.pitch:set_value(value)
			for v = 1, n_voices do
				engine.pitch_opMix(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> fold_gain',
		id = 'pitch_fold_gain',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fold_gain.pitch:set_value(value)
			for v = 1, n_voices do
				engine.pitch_foldGain(v, value)
			end
		end
	}

	params:add {
		name = 'pitch -> fold_bias',
		id = 'pitch_fold_bias',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fold_bias.pitch:set_value(value)
			for v = 1, n_voices do
				engine.pitch_foldBias(v, value)
			end
		end
	}

	params:add_group('hand', 12)

	params:add {
		name = 'hand -> tune a',
		id = 'hand_tune_a',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.tune_a.hand:set_value(value)
			for v = 1, n_voices do
				engine.tip_tuneA(v, value)
				engine.palm_tuneA(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> tune_b',
		id = 'hand_tune_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.tune_b.hand:set_value(value)
			for v = 1, n_voices do
				engine.tip_tuneB(v, value)
				engine.palm_tuneB(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> fm_index',
		id = 'hand_fm_index',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fm_index.hand:set_value(value)
			for v = 1, n_voices do
				engine.tip_fmIndex(v, value)
				engine.palm_fmIndex(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> fb_b',
		id = 'hand_fb_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fb_b.hand:set_value(value)
			for v = 1, n_voices do
				engine.tip_fbB(v, value)
				engine.palm_fbB(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> op_detune',
		id = 'hand_op_detune',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.op_detune.hand:set_value(value)
			for v = 1, n_voices do
				engine.tip_opDetune(v, value)
				engine.palm_opDetune(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> op_mix',
		id = 'hand_op_mix',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0.4),
		action = function(value)
			source_dials.op_mix.hand:set_value(value)
			for v = 1, n_voices do
				engine.tip_opMix(v, value)
				engine.palm_opMix(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> fold_gain',
		id = 'hand_fold_gain',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fold_gain.hand:set_value(value)
			for v = 1, n_voices do
				engine.tip_foldGain(v, value)
				engine.palm_foldGain(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> fold_bias',
		id = 'hand_fold_bias',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fold_bias.hand:set_value(value)
			for v = 1, n_voices do
				engine.tip_foldBias(v, value)
				engine.palm_foldBias(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> lfo A freq',
		id = 'hand_lfo_a_freq',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_lfoAFreq(v, value)
				engine.palm_lfoAFreq(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> lfo A amt',
		id = 'hand_lfo_a_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_lfoAAmount(v, value)
				engine.palm_lfoAAmount(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> lfo B freq',
		id = 'hand_lfo_b_freq',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_lfoBFreq(v, value)
				engine.palm_lfoBFreq(v, -value)
			end
		end
	}

	params:add {
		name = 'hand -> lfo B amt',
		id = 'hand_lfo_b_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.tip_lfoBAmount(v, value)
				engine.palm_lfoBAmount(v, -value)
			end
		end
	}

	params:add_group('foot', 12)

	params:add {
		name = 'foot -> tune_a',
		id = 'foot_tune_a',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.tune_a.foot:set_value(value)
			for v = 1, n_voices do
				engine.foot_tuneA(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> tune_b',
		id = 'foot_tune_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.tune_b.foot:set_value(value)
			for v = 1, n_voices do
				engine.foot_tuneB(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> fm_index',
		id = 'foot_fm_index',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fm_index.foot:set_value(value)
			for v = 1, n_voices do
				engine.foot_fmIndex(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> fb_b',
		id = 'foot_fb_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fb_b.foot:set_value(value)
			for v = 1, n_voices do
				engine.foot_fbB(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> op_detune',
		id = 'foot_op_detune',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.op_detune.foot:set_value(value)
			for v = 1, n_voices do
				engine.foot_opDetune(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> op_mix',
		id = 'foot_op_mix',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.op_mix.foot:set_value(value)
			for v = 1, n_voices do
				engine.foot_opMix(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> fold_gain',
		id = 'foot_fold_gain',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fold_gain.foot:set_value(value)
			for v = 1, n_voices do
				engine.foot_foldGain(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> fold_bias',
		id = 'foot_fold_bias',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fold_bias.foot:set_value(value)
			for v = 1, n_voices do
				engine.foot_foldBias(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> lfo A freq',
		id = 'foot_lfo_a_freq',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.foot_lfoAFreq(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> lfo A amt',
		id = 'foot_lfo_a_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.foot_lfoAAmount(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> lfo B freq',
		id = 'foot_lfo_b_freq',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.foot_lfoBFreq(v, value)
			end
		end
	}

	params:add {
		name = 'foot -> lfo B amt',
		id = 'foot_lfo_b_amount',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
		action = function(value)
			for v = 1, n_voices do
				engine.foot_lfoBAmount(v, value)
			end
		end
	}

	params:add_group('eg', 13)

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
		name = 'eg -> tune_a',
		id = 'eg_tune_a',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.tune_a.eg:set_value(value)
			for v = 1, n_voices do
				engine.eg_tuneA(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> tune_b',
		id = 'eg_tune_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.tune_b.eg:set_value(value)
			for v = 1, n_voices do
				engine.eg_tuneB(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> fm_index',
		id = 'eg_fm_index',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fm_index.eg:set_value(value)
			for v = 1, n_voices do
				engine.eg_fmIndex(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> fb_b',
		id = 'eg_fb_b',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fb_b.eg:set_value(value)
			for v = 1, n_voices do
				engine.eg_fbB(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> op_detune',
		id = 'eg_op_detune',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.op_detune.eg:set_value(value)
			for v = 1, n_voices do
				engine.eg_opDetune(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> op_mix',
		id = 'eg_op_mix',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.op_mix.eg:set_value(value)
			for v = 1, n_voices do
				engine.eg_opMix(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> fold_gain',
		id = 'eg_fold_gain',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fold_gain.eg:set_value(value)
			for v = 1, n_voices do
				engine.eg_foldGain(v, value)
			end
		end
	}

	params:add {
		name = 'eg -> fold_bias',
		id = 'eg_fold_bias',
		type = 'control',
		controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
		action = function(value)
			source_dials.fold_bias.eg:set_value(value)
			for v = 1, n_voices do
				engine.eg_foldBias(v, value)
			end
		end
	}

	params:add {
		name = 'detune exp/lin',
		id = 'detune_type',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0.12),
		action = function(value)
			for v = 1, n_voices do
				engine.detuneType(v, value)
			end
		end
	}

	params:add {
		name = 'harmonic fade size',
		id = 'fade_size',
		type = 'control',
		controlspec = controlspec.new(0.01, 1, 'lin', 0, 0.5),
		action = function(value)
			for v = 1, n_voices do
				engine.fadeSize(v, value)
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
				engine.fmCutoff(v, value)
			end
		end
	}

	params:add {
		name = 'hp cutoff',
		id = 'hp_cutoff',
		type = 'control',
		controlspec = controlspec.new(8, 12000, 'exp', 0, 8, 'Hz'),
		action = function(value)
			for v = 1, n_voices do
				engine.hpCutoff(v, value)
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
				engine.lpCutoff(v, value)
			end
		end
	}

	for v = 1, n_voices do

		params:add_separator('int voice ' .. v)

		params:add {
			name = 'loop position',
			id = 'loop_position_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.loopPosition(v, value)
			end
		}

		params:add {
			name = 'tune',
			id = 'tune_' .. v,
			type = 'control',
			controlspec = controlspec.new(-12, 12, 'lin', 0, 0, 'st'),
			action = function(value)
				engine.tune(v, value / 12)
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
			name = 'tune A',
			id = 'tune_a_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.tuneA(v, value + params:get('tune_a'))
			end
		}

		params:add {
			name = 'tune B',
			id = 'tune_b_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.tuneB(v, value + params:get('tune_b'))
			end
		}

		params:add {
			name = 'fm index',
			id = 'fm_index_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.fmIndex(v, value + params:get('fm_index'))
			end
		}

		params:add {
			name = 'feedback B',
			id = 'fb_b_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.fbB(v, value + params:get('fb_b'))
			end
		}

		params:add {
			name = 'detune A/B',
			id = 'op_detune_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.opDetune(v, value + params:get('op_detune'))
			end
		}

		params:add {
			name = 'mix A/B',
			id = 'op_mix_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.opMix(v, value + params:get('op_mix'))
			end
		}

		params:add {
			name = 'fold gain',
			id = 'fold_gain_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.foldGain(v, value + params:get('fold_gain'))
			end
		}

		params:add {
			name = 'fold bias',
			id = 'fold_bias_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.foldBias(v, value + params:get('fold_bias'))
			end
		}

		params:add {
			name = 'fm cutoff',
			id = 'fm_cutoff_' .. v,
			type = 'control',
			controlspec = controlspec.new(32, 23000, 'exp', 0, 12000, 'Hz'),
			action = function(value)
				engine.fmCutoff(v, value)
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
				engine.outLevel(v, value)
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
					engine.voiceFM(v, w, value)
				end
			}
		end

		params:add_group('v' .. v .. ' lfo A', 14)

		params:add {
			name = 'lfo A type',
			id = 'lfo_a_type_' .. v,
			type = 'option',
			options = { 'sine', 'tri', 'saw', 'rand', 's+h' },
			action = function(value)
				engine.lfoAType(v, value)
			end
		}

		params:add {
			name = 'lfo A freq',
			id = 'lfo_a_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.01, 10, 'exp', 0, 0.9, 'Hz'),
			action = function(value)
				engine.lfoAFreq(v, value)
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
				engine.lfoA_pitch(v, value)
			end
		}

		params:add {
			name = 'lfo A -> amp',
			id = 'lfo_a_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_amp(v, value)
			end
		}

		params:add {
			name = 'lfo A -> tune_a',
			id = 'lfo_a_tune_a_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_tuneA(v, value)
			end
		}

		params:add {
			name = 'lfo A -> tune_b',
			id = 'lfo_a_tune_b_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_tuneB(v, value)
			end
		}

		params:add {
			name = 'lfo A -> fm_index',
			id = 'lfo_a_fm_index_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_fmIndex(v, value)
			end
		}

		params:add {
			name = 'lfo A -> fb_b',
			id = 'lfo_a_fb_b_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_fbB(v, value)
			end
		}

		params:add {
			name = 'lfo A -> op_detune',
			id = 'lfo_a_op_detune_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_opDetune(v, value)
			end
		}

		params:add {
			name = 'lfo A -> op_mix',
			id = 'lfo_a_op_mix_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_opMix(v, value)
			end
		}

		params:add {
			name = 'lfo A -> fold_gain',
			id = 'lfo_a_fold_gain_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_foldGain(v, value)
			end
		}

		params:add {
			name = 'lfo A -> fold_bias',
			id = 'lfo_a_fold_bias_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_foldBias(v, value)
			end
		}

		params:add {
			name = 'lfo A -> lfo B freq',
			id = 'lfo_a_lfo_b_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_lfoBFreq(v, value)
			end
		}

		params:add {
			name = 'lfo A -> lfo B amt',
			id = 'lfo_a_lfo_b_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoA_lfoBAmount(v, value)
			end
		}

		params:add_group('v' .. v .. ' lfo B', 14)

		params:add {
			name = 'lfo B type',
			id = 'lfo_b_type_' .. v,
			type = 'option',
			options = { 'sine', 'tri', 'saw', 'rand', 's+h' },
			default = 4,
			action = function(value)
				engine.lfoBType(v, value)
			end
		}

		params:add {
			name = 'lfo B freq',
			id = 'lfo_b_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.01, 10, 'exp', 0, 0.9, 'Hz'),
			action = function(value)
				engine.lfoBFreq(v, value)
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
				engine.lfoB_pitch(v, value)
			end
		}

		params:add {
			name = 'lfo B -> amp',
			id = 'lfo_b_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_amp(v, value)
			end
		}

		params:add {
			name = 'lfo B -> tune_a',
			id = 'lfo_b_tune_a_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_tuneA(v, value)
			end
		}

		params:add {
			name = 'lfo B -> tune_b',
			id = 'lfo_b_tune_b_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_tuneB(v, value)
			end
		}

		params:add {
			name = 'lfo B -> fm_index',
			id = 'lfo_b_fm_index' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_fmIndex(v, value)
			end
		}

		params:add {
			name = 'lfo B -> fb_b',
			id = 'lfo_b_fb_b_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_fbB(v, value)
			end
		}

		params:add {
			name = 'lfo B -> op_detune',
			id = 'lfo_b_op_detune_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_opDetune(v, value)
			end
		}

		params:add {
			name = 'lfo B -> op_mix',
			id = 'lfo_b_op_mix' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_opMix(v, value)
			end
		}

		params:add {
			name = 'lfo B -> fold_gain',
			id = 'lfo_b_fold_gain_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_foldGain(v, value)
			end
		}

		params:add {
			name = 'lfo B -> fold_bias',
			id = 'lfo_b_fold_bias_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_foldBias(v, value)
			end
		}

		params:add {
			name = 'lfo B -> lfo A freq',
			id = 'lfo_b_lfo_a_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_lfoAFreq(v, value)
			end
		}

		params:add {
			name = 'lfo B -> lfo A amt',
			id = 'lfo_b_lfo_a_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.lfoB_lfoAAmount(v, value)
			end
		}

		norns.enc.accel(1, false)
		norns.enc.sens(1, 8)

	end

	params:add_separator('etc')

	-- TODO: add params for tt and crow transposition
	-- ...and yeah, control from keyboard. you'll want that again

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
	reset_loop_clock()

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
		time = 1 / 30,
		event = function()
			for p = 1, #editor.dest_names do
				local dial = dest_dials[editor.dest_names[p]]
				dial.y = dial.y + (((p - editor.dest) * 25 + 20) - dial.y) * 0.5
			end
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
	-- TODO: show held pitch(es) based on how they're specified in scala file!!; indicate bend/glide
	screen.clear()
	screen.fill() -- prevent a flash of stroke when leaving system UI
	for s = 1, #editor.source_names do
		local dial = source_dials[editor.dest_names[editor.dest]][editor.source_names[s]]
		dial:set_active(editor.source == s)
		dial:redraw()
	end
	for d = 1, #editor.dest_names do
		local dial = dest_dials[editor.dest_names[d]]
		dial:set_active(editor.dest == d)
		dial:redraw()
		screen.move(dial.x - 4, dial.y + 11)
		screen.text_right(editor.dest_labels[d])
		screen.stroke()
	end
	screen.update()
end

function enc(n, d)
	if n == 1 then
		editor.source = (editor.source + d - 1) % #editor.source_names + 1
	elseif n == 2 then
		params:delta(editor.source_names[editor.source] .. '_' .. editor.dest_names[editor.dest], d)
	elseif n == 3 then
		params:delta(editor.dest_names[editor.dest], d)
	end
	-- TODO: if editor.shift, edit mod source properties:
	-- A/R, LFO shape/rate...
	-- OR... allow mod-modding
end

function key(n, z)
	if n == 1 then
		editor.shift = z == 1
	elseif z == 1 then
		if n == 2 then
			editor.dest = (editor.dest - 2) % #editor.dest_names + 1
		elseif n == 3 then
			editor.dest = editor.dest % #editor.dest_names + 1
		end
	end
end

function cleanup()
	if redraw_metro ~= nil then
		redraw_metro:stop()
	end
end
