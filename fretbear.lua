-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

-- tt_chord = 0

-- TODO: internal poly engine -- SinOscFB, VarSaw, SmoothFoldS / SmoothFoldQ
-- with envelope(s) + mod matrix (sources: EG1, EG2, touche tip, touche heel)

redraw_metro = nil
relax_metro = nil

g = grid.connect()

touche = midi.connect(1)

n_voices = 3

tip = 0
palm = 0
amp_volts = 0
damp_volts = 0
pitch_volts = 0
bent_pitch_volts = 0
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
	k:key(x, y, z)
	-- TODO: sync the whole note stack with TT
	-- I think you'll need to trigger events from the keyboard class, and... urgh...
	-- it's more information than you can easily send to TT
	grid_redraw()
end

function send_pitch_volts()
	bent_pitch_volts = pitch_volts + k.bend_value
	-- TODO: this added offset for the quantizer really shouldn't be necessary; what's going on here?
	-- crow.output[1].volts = bent_pitch_volts + (k.quantizing and 1/24 or 0)
	engine.pitch(bent_pitch_volts)
end

function touche.event(data)
	local message = midi.to_msg(data)
	if message.ch == 1 and message.type == 'cc' then
		-- back = 16, front = 17, left = 18, right = 19
		if message.cc == 17 then
			tip = message.val / 126
			engine.tip(tip) -- let SC do the scaling
			-- amp_volts = 10 * math.sqrt(tip) -- fast attack
			-- crow.output[2].volts = amp_volts
		elseif message.cc == 16 then
			palm = message.val / 126
			engine.palm(palm)
			-- damp_volts = palm * params:get('damp_range') + params:get('damp_base')
			-- crow.output[3].volts = damp_volts
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
	-- for c = 0, 2 do
		-- g:led(c + 1, 1, tt_chord == c and 15 or 7)
	-- end
	g:refresh()
end

function crow_init()

	print('crow add')
	params:bang()

	-- TODO: internal clock
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
		pitch_volts = k.scale:snap(pitch)
		send_pitch_volts()
		grid_redraw()
	end

	k.on_mask = function()
		-- local temperament = (k.mask_notes == 'none' or k.ratios == nil) and 12 or 'ji'
		-- crow.output[1].scale(k.mask_notes, temperament)
		-- TODO: send to TT as well, as a bit mask
	end

	k.on_gate = function(gate)
		if k.gate_mode ~= 3 then
			-- crow.output[4](gate)
			engine.gate(gate and 1 or 0)
		elseif gate then

			crow.output[4]()
			engine.gate(1)
			-- TODO: finesse this: there should be control over gate time, and this should handle
			-- overlapping gates
			clock.run(function()
				clock.sleep(0.1)
				engine.gate(0)
			end)
		end
		if gate and not do_pitch_detection then
			crow.ii.tt.script_v(2, k.scale:snap(pitch_volts + k.transposition))
		end
	end

	-- TODO: why doesn't crow.add() work anymore?
	crow_init()

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
			name = 'freeze',
			id = 'freeze_' .. v,
			type = 'binary',
			behavior = 'toggle',
			default = 0,
			action = function(value)
				engine.freeze(v, value)
			end
		}

		params:add {
			name = 'tune',
			id = 'tune_' .. v,
			type = 'control',
			controlspec = controlspec.new(-12, 12, 'lin', 0, -0.05 + ((v - 1) * 0.1), 'st'),
			action = function(value)
				engine.base_freq(v, musicutil.note_num_to_freq(60 + value))
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
			name = 'sine fb',
			id = 'fb_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 10, 'exp', 0, (n_voices - v) / n_voices * 0.3, 0),
			action = function(value)
				engine.fb(v, value)
			end
		}

		params:add {
			name = 'sine fold',
			id = 'fold_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.1, 10, 'exp', 0, (n_voices - v) / n_voices * 0.6, 0),
			action = function(value)
				engine.fold(v, value)
			end
		}

		params:add_group('v' .. v .. ' tip', 9)

		params:add {
			name = 'tip -> amp',
			id = 'tip_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, v < 3 and 1 or 0),
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
			name = 'tip -> fb',
			id = 'tip_fb_' .. v,
			type = 'control',
			controlspec = controlspec.new(-10, 10, 'lin', 0, 0),
			action = function(value)
				engine.tip_fb(v, value)
			end
		}

		params:add {
			name = 'tip -> fold',
			id = 'tip_fold_' .. v,
			type = 'control',
			controlspec = controlspec.new(-10, 10, 'lin', 0, 0),
			action = function(value)
				engine.tip_fold(v, value)
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

		params:add_group('v' .. v .. ' palm', 9)

		params:add {
			name = 'palm -> amp',
			id = 'palm_amp_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 1, 'exp', 0, 0),
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
			name = 'palm -> fb',
			id = 'palm_fb_' .. v,
			type = 'control',
			controlspec = controlspec.new(-10, 10, 'lin', 0, 0),
			action = function(value)
				engine.palm_fb(v, value)
			end
		}

		params:add {
			name = 'palm -> fold',
			id = 'palm_fold_' .. v,
			type = 'control',
			controlspec = controlspec.new(-10, 10, 'lin', 0, 0),
			action = function(value)
				engine.palm_fold(v, value)
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

		params:add_group('v' .. v .. ' eg', 10)

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
			name = 'eg -> fb',
			id = 'eg_fb_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 10, 'exp', 0, 0),
			action = function(value)
				engine.eg_fb(v, value)
			end
		}

		params:add {
			name = 'eg -> fold',
			id = 'eg_fold_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 10, 'exp', 0, 0),
			action = function(value)
				engine.eg_fold(v, value)
			end
		}

		params:add_group('v' .. v .. ' lfo A', 10)

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
			name = 'lfo A -> fb',
			id = 'lfo_a_fb_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 10, 'exp', 0, 0),
			action = function(value)
				engine.lfo_a_fb(v, value)
			end
		}

		params:add {
			name = 'lfo A -> fold',
			id = 'lfo_a_fold_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 10, 'exp', 0, 0),
			action = function(value)
				engine.lfo_a_fold(v, value)
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

		params:add_group('v' .. v .. ' lfo B', 10)

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
			name = 'lfo B -> fb',
			id = 'lfo_b_fb_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 10, 'exp', 0, 0),
			action = function(value)
				engine.lfo_b_fb(v, value)
			end
		}

		params:add {
			name = 'lfo B -> fold',
			id = 'lfo_b_fold_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.001, 10, 'exp', 0, 0),
			action = function(value)
				engine.lfo_b_fold(v, value)
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
			name = 'lfo B -> lfo B freq',
			id = 'lfo_b_lfo_a_freq_' .. v,
			type = 'control',
			controlspec = controlspec.new(-5, 5, 'lin', 0, 0),
			action = function(value)
				engine.lfo_b_lfo_a_freq(v, value)
			end
		}

		params:add {
			name = 'lfo B -> lfo B amt',
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
			gate = not gate
			k:arp(gate)
		end
	end)
	
	relax_metro = metro.init {
		time = 1 / 40,
		event = function()
			k:relax_bend()
			send_pitch_volts() -- TODO: there's some steppiness here; more slew?
		end
	}
	relax_metro:start()
	
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
	if relax_metro ~= nil then
		relax_metro:stop()
	end
	-- for p = 1, #poll_names do
	-- 	local name = poll_names[p]
	-- 	if polls[name] ~= nil then
	-- 		polls[name]:stop()
	-- 	end
	-- end
end
