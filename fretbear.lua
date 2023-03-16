-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'

n_voices = 3

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

-- tt_chord = 0

-- TODO: internal poly engine -- SinOscFB, VarSaw, SmoothFoldS / SmoothFoldQ
-- with envelope(s) + mod matrix (sources: EG1, EG2, touche tip, touche heel)

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
		loop_armed = false
	}
end

tip = 0
palm = 0
do_pitch_detection = false
-- pitch_poll = nil
detected_pitch = 0
gate_in = false

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
				voice.control = not voice.control
				-- TODO: does it make sense to set everything (or some things: tip,
				-- palm) to 0 when setting control to false?
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
	control_engine_voices('pitch', k.bent_pitch + k.octave)
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
		if voice.loop_armed then
			level = level * 0.5 + 0.5
		elseif voice.frozen then
			level = level * 0.75 + 0.25
		end
		level = 2 + math.floor(level * 14)
		g:led(v + 1, 1, level)
		g:led(v + 1, 2, voice.control and 5 or 1)
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

function control_engine_voices(method, value)
	for v = 1, n_voices do
		if voice_states[v].control then
			engine[method](v, value)
		end
	end
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
		if k.gate_mode ~= 3 then
			crow.output[4](gate)
			control_engine_voices('gate', gate and 1 or 0)
		elseif gate then

			crow.output[4]()
			control_engine_voices('gate', 1)
			-- TODO: finesse this: there should be control over gate time, and this should handle
			-- overlapping gates
			clock.run(function()
				clock.sleep(0.1)
				control_engine_voices('gate', 0)
			end)
		end
		if gate and not do_pitch_detection then
			-- TODO: I've lost track of what this is supposed to do...
			crow.ii.tt.script_v(2, k.scale:snap(k.active_pitch + k.transposition))
		end
	end

	-- TODO: why doesn't crow.add() work anymore?
	crow_init()

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
		options = { 'int', 'crow' },
		default = 1
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

	params:add {
		name = 'tip -> int clock rate',
		id = 'tip_clock_rate',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
	}
	
	params:add {
		name = 'palm -> int clock rate',
		id = 'palm_clock_rate',
		type = 'control',
		controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
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

	for v = 1, n_voices do

		params:add_separator('int voice ' .. v)

		params:add {
			name = 'pitch lag',
			id = 'pitch_lag_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.01, 's'),
			action = function(value)
				engine.pitch_slew(v, value)
			end
		}

		params:add {
			name = 'other lag',
			id = 'other_lag_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.1, 's'),
			action = function(value)
				engine.lag(v, value)
			end
		}

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
				engine.p1(v, value)
			end
		}

		params:add {
			name = 'param 2',
			id = 'p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.p2(v, value)
			end
		}

		params:add {
			name = 'param 3',
			id = 'p3_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.p3(v, value)
			end
		}

		params:add {
			name = 'param 4',
			id = 'p4_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.p4(v, value)
			end
		}

		params:add_group('v' .. v .. ' fm', 4)

		params:add {
			name = 'voice 1 -> voice ' .. v,
			id = 'voice1_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 20, 'lin', 0, 0),
			action = function(value)
				engine.voice1_fm(v, value)
			end
		}

		params:add {
			name = 'voice 2 -> voice ' .. v,
			id = 'voice2_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 20, 'lin', 0, 0),
			action = function(value)
				engine.voice2_fm(v, value)
			end
		}

		params:add {
			name = 'voice 3 -> voice ' .. v,
			id = 'voice3_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 20, 'lin', 0, 0),
			action = function(value)
				engine.voice3_fm(v, value)
			end
		}

		params:add {
			name = 'voice ' .. v .. ' out level',
			id = 'out_level_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 0.5, 'lin', 0, 0.2),
			action = function(value)
				engine.out_level(v, value)
			end
		}

		params:add_group('v' .. v .. ' pitch', 4)

		params:add {
			name = 'pitch -> p1',
			id = 'pitch_p1_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.pitch_p1(v, value)
			end
		}

		params:add {
			name = 'pitch -> p2',
			id = 'pitch_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.pitch_p2(v, value)
			end
		}

		params:add {
			name = 'pitch -> p3',
			id = 'pitch_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.pitch_p3(v, value)
			end
		}

		params:add {
			name = 'pitch -> p4',
			id = 'pitch_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.pitch_p4(v, value)
			end
		}

		params:add_group('v' .. v .. ' tip', 11)

		params:add {
			name = 'tip -> amp',
			id = 'tip_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 1),
			action = function(value)
				engine.tip_amp(v, value - 0.001)
			end
		}

		params:add {
			name = 'tip -> delay',
			id = 'tip_delay_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.tip_delay(v, value)
			end
		}

		params:add {
			name = 'tip -> p1',
			id = 'tip_p1_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.tip_p1(v, value)
			end
		}

		params:add {
			name = 'tip -> p2',
			id = 'tip_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.tip_p2(v, value)
			end
		}

		params:add {
			name = 'tip -> p3',
			id = 'tip_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.tip_p3(v, value)
			end
		}

		params:add {
			name = 'tip -> p4',
			id = 'tip_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.tip_p4(v, value)
			end
		}

		params:add {
			name = 'tip -> eg amt',
			id = 'tip_eg_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 1),
			action = function(value)
				engine.tip_eg_amount(v, value)
			end
		}

		params:add {
			name = 'tip -> lfo A freq',
			id = 'tip_lfo_a_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.tip_lfo_a_freq(v, value)
			end
		}

		params:add {
			name = 'tip -> lfo A amt',
			id = 'tip_lfo_a_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
			action = function(value)
				engine.tip_lfo_a_amount(v, value)
			end
		}

		params:add {
			name = 'tip -> lfo B freq',
			id = 'tip_lfo_b_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.tip_lfo_b_freq(v, value)
			end
		}

		params:add {
			name = 'tip -> lfo B amt',
			id = 'tip_lfo_b_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
			action = function(value)
				engine.tip_lfo_b_amount(v, value)
			end
		}

		params:add_group('v' .. v .. ' palm', 11)

		params:add {
			name = 'palm -> amp',
			id = 'palm_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.palm_amp(v, value - 0.001)
			end
		}

		params:add {
			name = 'palm -> delay',
			id = 'palm_delay_' .. v,
			type = 'control',
			controlspec = controlspec.new(-2, 2, 'lin', 0, 0),
			action = function(value)
				engine.palm_delay(v, value)
			end
		}

		params:add {
			name = 'palm -> p1',
			id = 'palm_p1_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.palm_p1(v, value)
			end
		}

		params:add {
			name = 'palm -> p2',
			id = 'palm_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.palm_p2(v, value)
			end
		}

		params:add {
			name = 'palm -> p3',
			id = 'palm_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.palm_p3(v, value)
			end
		}

		params:add {
			name = 'palm -> p4',
			id = 'palm_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.palm_p4(v, value)
			end
		}

		params:add {
			name = 'palm -> eg amt',
			id = 'palm_eg_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
			action = function(value)
				engine.palm_eg_amount(v, value)
			end
		}

		params:add {
			name = 'palm -> lfo A freq',
			id = 'palm_lfo_a_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.palm_lfo_a_freq(v, value)
			end
		}

		params:add {
			name = 'palm -> lfo A amt',
			id = 'palm_lfo_a_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
			action = function(value)
				engine.palm_lfo_a_amount(v, value)
			end
		}

		params:add {
			name = 'palm -> lfo B freq',
			id = 'palm_lfo_b_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.palm_lfo_b_freq(v, value)
			end
		}

		params:add {
			name = 'palm -> lfo B amt',
			id = 'palm_lfo_b_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
			action = function(value)
				engine.palm_lfo_b_amount(v, value)
			end
		}

		params:add_group('v' .. v .. ' eg', 12)

		params:add {
			name = 'attack',
			id = 'attack_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.01, 's'),
			action = function(value)
				engine.attack(v, value)
			end
		}

		params:add {
			name = 'decay',
			id = 'decay_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.1, 's'),
			action = function(value)
				engine.decay(v, value)
			end
		}

		params:add {
			name = 'sustain',
			id = 'sustain_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0.8),
			action = function(value)
				engine.sustain(v, value)
			end
		}

		params:add {
			name = 'release',
			id = 'release_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 3, 'exp', 0, 0.3, 's'),
			action = function(value)
				engine.release(v, value)
			end
		}

		params:add {
			name = 'amount',
			id = 'eg_amount_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 1),
			action = function(value)
				engine.eg_amount(v, value)
			end
		}

		params:add {
			name = 'eg -> pitch',
			id = 'eg_pitch_' .. v,
			type = 'control',
			controlspec = controlspec.new(-0.2, 0.2, 'lin', 0, 0),
			formatter = function(param)
				local value = param:get()
				return string.format('%.2f', value * 12)
			end,
			action = function(value)
				engine.eg_pitch(v, value)
			end
		}

		params:add {
			name = 'eg -> amp',
			id = 'eg_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0, 1, 'lin', 0, 0),
			action = function(value)
				engine.eg_amp(v, value)
			end
		}

		params:add {
			name = 'eg -> delay',
			id = 'eg_delay_' .. v,
			type = 'control',
			controlspec = controlspec.new(-2, 2, 'lin', 0, 0),
			action = function(value)
				engine.eg_delay(v, value)
			end
		}

		params:add {
			name = 'eg -> p1',
			id = 'eg_p1_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.eg_p1(v, value)
			end
		}

		params:add {
			name = 'eg -> p2',
			id = 'eg_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.eg_p2(v, value)
			end
		}

		params:add {
			name = 'eg -> p3',
			id = 'eg_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.eg_p3(v, value)
			end
		}

		params:add {
			name = 'eg -> p4',
			id = 'eg_p2_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.eg_p4(v, value)
			end
		}

		params:add_group('v' .. v .. ' lfo A', 12)

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
			name = 'lfo A -> delay',
			id = 'lfo_a_delay_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.lfo_a_delay(v, value)
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

		params:add_group('v' .. v .. ' lfo B', 12)

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
			name = 'lfo B -> delay',
			id = 'lfo_b_delay_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0.2),
			action = function(value)
				engine.lfo_b_delay(v, value)
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

	clock.run(function()
		local gate = false
		while true do
			local tick_mod = tip * params:get('tip_clock_rate') + palm * params:get('palm_clock_rate')
			clock.sleep(clock.get_beat_sec() * 0.125 * math.pow(0.5, tick_mod))
			if params:get('arp_clock_source') == 1 and k.arping and k.n_sustained_keys > 0 then
				gate = not gate
				k:arp(gate)
			end
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
