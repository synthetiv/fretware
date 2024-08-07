-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'

Dial = include 'lib/dial'

n_voices = 6

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

Echo = include 'lib/echo'
echo = Echo.new()

redraw_metro = nil
blink = true

g = grid.connect()

editor = {
	source_names = {
		'amp',
		'hand',
		'eg',
		'lfoA',
		'lfoB',
		'runglerA',
		'runglerB',
		'lfoSH'
	},
	dests = {
		{
			name = 'tuneA',
			label = 'tune A',
			default = -0.4167 -- 1/1 (4th out of 12 harmonics)
		},
		{
			name = 'tuneB',
			label = 'tune B',
			default = -0.25 -- 2/1 (5th out of 12 harmonics)
		},
		{
			name = 'fmIndex',
			label = 'fm index',
			default = -1,
			source_defaults = {
				amp = 0.2
			}
		},
		{
			name = 'fbB',
			label = 'feedback B',
			default = -1
		},
		{
			name = 'opDetune',
			label = 'detune A:B',
			default = 0
		},
		{
			name = 'opMix',
			label = 'mix A:B',
			default = -1
		},
		{
			name = 'squiz',
			label = 'squiz',
			default = 0
		},
		{
			name = 'lpgTone',
			label = 'lpg tone',
			default = 0.6,
			has_divider = true
		},
		{
			name = 'attack',
			label = 'attack',
			default = 0
		},
		{
			name = 'decay',
			label = 'decay',
			default = 0
		},
		{
			name = 'sustain',
			label = 'sustain',
			default = 0
		},
		{
			name = 'release',
			label = 'release',
			default = 0,
			has_divider = true
		},
		{
			name = 'lfoAFreq',
			label = 'lfo a freq',
			default = 0
		},
		{
			name = 'lfoBFreq',
			label = 'lfo b freq',
			default = 0,
			has_divider = true
		},
		{
			name = 'pitch',
			label = 'pitch'
		},
		{
			name = 'pan',
			label = 'pan',
			voice_param = 'pan'
		},
		{
			name = 'amp',
			label = 'amp',
			voice_param = 'outLevel'
		}
	},
	source = 1,
	dest1 = 1,
	dest2 = 2
}

dest_dials = {
	-- x, y, size, value, min_value, max_value, rounding, start_value, markers, units, title
	tuneA    = Dial.new(82,  50, 15),
	tuneB    = Dial.new(101, 50, 15),
	fmIndex  = Dial.new(120, 50, 15),
	fbB      = Dial.new(139, 50, 15),
	opDetune = Dial.new(158, 50, 15),
	opMix    = Dial.new(177, 50, 15),
	squiz    = Dial.new(196, 50, 15),
	lpgTone  = Dial.new(215, 50, 15),
	attack   = Dial.new(239, 50, 15),
	decay    = Dial.new(258, 50, 15),
	sustain  = Dial.new(277, 50, 15),
	release  = Dial.new(296, 50, 15),
	lfoAFreq = Dial.new(321, 50, 15),
	lfoBFreq = Dial.new(340, 50, 15),
	pitch    = Dial.new(364, 50, 15),
	pan      = Dial.new(383, 50, 15),
	amp      = Dial.new(402, 50, 15)
}

source_dials = {}
for s = 1, #editor.dests do
	source_dials[editor.dests[s].name] = {
		amp   = Dial.new(82, 2, 11),
		hand  = Dial.new(82, 2, 11),
		eg    = Dial.new(82, 2, 11),
		lfoA  = Dial.new(82, 2, 11),
		lfoB  = Dial.new(82, 2, 11),
		runglerA = Dial.new(82, 2, 11),
		runglerB = Dial.new(82, 2, 11),
		lfoSH = Dial.new(82, 2, 11),
	}
end

held_keys = { false, false, false }

voice_states = {}
for v = 1, n_voices do
	voice_states[v] = {
		pitch = 0,
		amp = 0,
		shift = 0,
		looping = false,
		looping_next = false,
		loop_armed = false,
		loop_armed_next = false,
		loop_beat_sec = 0.25,
		lfoA_gate = false,
		lfoB_gate = false,
		lfoEqual_gate = false,
		polls = {},
	}
end

tip = 0
palm = 0
expo_scaling = false
gate_in = false

n_arp_divs = 4
arp_clocks = {}
for d = 1, 3 do
	local rate = math.pow(2, 1 - d)
	arp_clocks[d] = clock.run(function()
		while true do
			clock.sync(rate)
			k:arp(d, true)
			clock.sleep(clock.get_beat_sec() * rate / 2)
			k:arp(d, false)
		end
	end)
end

loop_clock = false
loop_free = false

function clear_voice_loop(v)
	-- stop looping (clear loop)
	local voice = voice_states[v]
	if not voice.looping then
		return
	end
	engine.clearLoop(v)
	voice.looping = false
	if voice.loop_clock then
		clock.cancel(voice.loop_clock)
	end
	-- clear pitch shift, because it only confuses things when loop isn't engaged
	voice.shift = 0
	engine.shift(v, 0)
end

function record_voice_loop(v)
	-- start recording (set loop start time here)
	local voice = voice_states[v]
	if loop_free then
		voice.loop_armed = util.time()
	else
		voice.loop_armed_next = true
	end
end

function play_voice_loop(v)
	-- stop recording, start looping
	local voice = voice_states[v]
	if loop_free then
		engine.setLoop(v, util.time() - voice.loop_armed)
		voice.looping = true
		voice.loop_armed = false
	else
		voice.looping_next = true
	end
end

function g.key(x, y, z)
	k:key(x, y, z)
	-- TODO: sync the whole note stack with TT
	-- I think you'll need to trigger events from the keyboard class, and... urgh...
	-- it's more information than you can easily send to TT
	grid_redraw()
end

function send_pitch_volts()
	-- TODO: this added offset for the quantizer really shouldn't be necessary; what's going on here?
	crow.output[1].volts = k.bent_pitch + (k.quantizing and 1/24 or 0)
	engine.pitch(k.selected_voice, k.bent_pitch)
end

-- TODO: debounce here
function grid_redraw()
	g:all(0)
	k:draw()
	for v = 1, n_voices do
		local voice = voice_states[v]
		local level = voice.amp
		if voice.loop_armed then
			level = level * 0.5 + (blink and 0.5 or 0)
		elseif voice.looping then
			level = level * 0.75 + 0.25
		end
		level = math.floor(level * 15)
		g:led(1, 8 - v, level)
	end
	g:refresh()
end

-- function crow_init()
-- 
-- 	print('crow add')
-- 	params:bang()
-- 
-- 	crow.input[1].change = function(gate)
-- 		gate_in = gate
-- 		if k.arp_clock_source == ?? and k.n_sustained_keys > 0 then
-- 			k:arp(??, gate)
-- 		end
-- 	end
-- 	crow.input[1].mode('change', 1, 0.01, 'both')
-- 
-- 	crow.input[2].stream = function(v)
-- 		k:transpose(v)
-- 	end
-- 	crow.input[2].mode('stream', 0.01)
-- end

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

function init()

	norns.enc.accel(1, false)
	norns.enc.sens(1, 8)

	k.on_select_voice = function(v, old_v)
		-- if any other voice is recording, stop recording & start looping it
		for ov = 1, n_voices do
			if ov ~= v and voice_states[ov].loop_armed then
				play_voice_loop(ov)
			end
		end
		engine.tip(old_v, 0)
		engine.palm(old_v, 0)
		engine.gate(old_v, 0)
		engine.select_voice(v)
		dest_dials.amp:set_value(params:get_raw('outLevel_' .. v) * 2 - 1)
		dest_dials.pan:set_value(params:get_raw('pan_' .. v) * 2 - 1)
		send_pitch_volts()
	end

	k.on_voice_shift = function(v, d)
		local voice = voice_states[v]
		if d == 0 then
			voice.shift = 0
		else
			voice.shift = voice.shift + d
		end
		engine.shift(v, voice.shift)
	end

	k.on_pitch = function()
		local pitch = k.active_pitch
		send_pitch_volts()
		grid_redraw()
	end

	k.on_gate = function(gate)
		crow.output[4](gate)
		engine.gate(k.selected_voice, gate and 1 or 0)
	end

	-- TODO: why doesn't crow.add() work anymore?
	-- crow_init()

	-- set up softcut echo
	softcut.reset()
	echo:init()

	-- set up polls
	-- TODO: stop these at cleanup
	for v = 1, n_voices do
		local voice = voice_states[v]
		-- one poll to respond to voice amplitude info
		voice.polls.amp = poll.set('amp_' .. v, function(value)
			voice.amp = value
		end)
		voice.polls.amp:start()
		-- a second to respond to pitch AND refresh grid; this helps a lot when voices are arpeggiating or looping
		voice.polls.instant_pitch = poll.set('instant_pitch_' .. v, function(value)
			voice.pitch = value
			grid_redraw()
		end)
		voice.polls.instant_pitch:start()
		-- and another poll for "routine" pitch updates, to show glide, vibrato, etc.
		voice.polls.pitch = poll.set('pitch_' .. v, function(value)
			voice.pitch = value
		end)
		voice.polls.pitch:start()
		-- and polls for LFO updates, which will only fire when a voice is selected and an LFO is used as an arp clock
		voice.polls.lfoA = poll.set('lfoA_gate_' .. v, function(gate)
			gate = gate > 0
			voice.lfoA_gate = gate
			if v == k.selected_voice then
				if echo.jump_trigger == 2 then
					if gate then
						uc4:note_on(16, 127)
						echo:jump()
					else
						uc4:note_off(16)
					end
				end
				k:arp(4, gate)
			end
		end)
		voice.polls.lfoA:start()
		voice.polls.lfoB = poll.set('lfoB_gate_' .. v, function(gate)
			gate = gate > 0
			voice.lfoB_gate = gate
			if v == k.selected_voice then
				if echo.jump_trigger == 3 then
					if gate then
						uc4:note_on(17, 127)
						echo:jump()
					else
						uc4:note_off(17)
					end
				end
				k:arp(5, gate)
			end
		end)
		voice.polls.lfoB:start()
		voice.polls.lfoEqual = poll.set('lfoEqual_gate_' .. v, function(gate)
			gate = gate > 0
			voice.lfoEqual_gate = gate
			if v == k.selected_voice then
				if echo.jump_trigger == 4 then
					if gate then
						uc4:note_on(18, 127)
						echo:jump()
					else
						uc4:note_off(18)
					end
				end
				k:arp(6, gate)
			end
		end)
		voice.polls.lfoEqual:start()
	end

	params:add_group('tuning', 7)

	-- TODO: add params for tt and crow transposition
	-- ...and yeah, control from keyboard. you'll want that again

	params:add {
		name = 'base frequency (C)',
		id = 'base_freq',
		type = 'control',
		controlspec = controlspec.new(musicutil.note_num_to_freq(48), musicutil.note_num_to_freq(72), 'exp', 0, musicutil.note_num_to_freq(60), 'Hz'),
		action = function(value)
			dest_dials.pitch:set_value(params:get_raw('base_freq') * 2 - 1)
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
		type = 'file',
		id = 'tuning_file',
		name = 'tuning_file',
		path = '/home/we/dust/data/fretwork/scales/12tet.scl',
		action = function(value)
			k.scale:read_scala_file(value)
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
		name = 'pitch slew',
		id = 'pitchSlew',
		type = 'control',
		controlspec = controlspec.new(0, 0.1, 'lin', 0, 0.01, 's'),
		action = function(value)
			engine.pitchSlew(value)
		end
	}

	params:add {
		name = 'detune exp/lin',
		id = 'detuneType',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0.12),
		action = function(value)
			engine.detuneType(value)
		end
	}

	params:add {
		name = 'harmonic fade size',
		id = 'fadeSize',
		type = 'control',
		controlspec = controlspec.new(0.01, 1, 'lin', 0, 0.8),
		action = function(value)
			engine.fadeSize(value)
		end
	}

	echo:add_params()

	params:add_group('clock/arp', 2)

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
		name = 'arp randomness',
		id = 'arp_randomness',
		type = 'control',
		controlspec = controlspec.new(0, 100, 'lin', 1, 0, '%'),
		action = function(value)
			k.arp_randomness = value / 100
		end
	}

	params:add_group('filter settings', 4)

	params:add {
		name = 'lpg on',
		id = 'lpgOn',
		type = 'option',
		options = { 'off', 'on' },
		default = 2,
		action = function(value)
			engine.lpgOn(value - 1)
		end
	}

	params:add {
		name = 'lpg q',
		id = 'lpgQ',
		type = 'control',
		controlspec = controlspec.new(1.414, 5, 'lin', 0, 1.414),
		action = function(value)
			engine.lpgQ(value)
		end
	}

	params:add {
		name = 'lpg curve',
		id = 'lpgCurve',
		type = 'control',
		controlspec = controlspec.new(-4, 4, 'lin', 0, 3),
		action = function(value)
			engine.lpgCurve(value)
		end
	}

	params:add {
		name = 'hp cutoff',
		id = 'hpCutoff',
		type = 'control',
		controlspec = controlspec.new(8, 12000, 'exp', 0, 8, 'Hz'),
		action = function(value)
			engine.hpCutoff(value)
		end
	}

	params:add_group('eg settings', 3)

	params:add {
		name = 'eg type',
		id = 'eg_type',
		type = 'option',
		options = { 'adsr', 'gated ar', 'trig\'d ar' },
		default = 3,
		action = function(value)
			engine.egType(value - 1)
			-- show/hide decay and sustain controls
			editor.dests[10].hidden = value ~= 1
			editor.dests[11].hidden = value ~= 1
		end
	}

	params:add {
		name = 'eg curve',
		id = 'eg_curve',
		type = 'control',
		controlspec = controlspec.new(-8, 8, 'lin', 0, -4),
		action = function(value)
			engine.egCurve(value)
		end
	}

	params:add {
		name = 'amp mode',
		id = 'amp_mode',
		type = 'option',
		options = { 'tip', 'tip*eg', 'eg' },
		default = 1,
		action = function(value)
			engine.ampMode(value - 1)
		end
	}

	params:add {
		name = 'expo tip/palm scaling',
		id = 'expo_scaling',
		type = 'option',
		options = { 'off', 'on' },
		default = 1,
		action = function(value)
			expo_scaling = value == 2
		end
	}

	params:add {
		name = 'fm pitch scale',
		id = 'fm_pitch_scale',
		type = 'control',
		controlspec = controlspec.new(0.5, 1, 'lin', 0, 0.87),
		action = function(value)
			engine.fmPitchScale(value)
		end
	}

	for d = 1, #editor.dests do
		local dest = editor.dests[d]
		if dest.name ~= 'attack' and dest.name ~= 'decay' and dest.name ~= 'sustain' and dest.name ~= 'release' and dest.name ~= 'lfoAFreq' and dest.name ~= 'lfoBFreq' and dest.name ~= 'pitch' and not dest.voice_param then
			local engine_command = engine[dest.name]
			print(dest.name)
			params:add {
				name = dest.label,
				id = dest.name,
				type = 'control',
				controlspec = controlspec.new(-1, 1, 'lin', 0, dest.default),
				action = function(value)
					dest_dials[dest.name]:set_value(value)
					engine_command(value)
				end
			}
		end
	end

	for s = 1, #editor.source_names do
		local source = editor.source_names[s]

		if source == 'eg' then
			-- EG group gets extra parameters
			params:add_group('eg', 4 + #editor.dests)
			params:add {
				name = 'attack',
				id = 'attack',
				type = 'control',
				controlspec = controlspec.new(0.001, 3, 'exp', 0, 0.001, 's'),
				action = function(value)
					dest_dials.attack:set_value(params:get_raw('attack') * 2 - 1)
					engine.attack(value)
				end
			}
			params:add {
				name = 'decay',
				id = 'decay',
				type = 'control',
				controlspec = controlspec.new(0.001, 12, 'exp', 0, 0.2, 's'),
				action = function(value)
					dest_dials.decay:set_value(params:get_raw('decay') * 2 - 1)
					engine.decay(value)
				end
			}
			params:add {
				name = 'sustain',
				id = 'sustain',
				type = 'control',
				controlspec = controlspec.new(0, 1, 'lin', 0, 0.8),
				action = function(value)
					dest_dials.sustain:set_value(params:get_raw('sustain') * 2 - 1)
					engine.sustain(value)
				end
			}
			params:add {
				name = 'release',
				id = 'release',
				type = 'control',
				controlspec = controlspec.new(0.001, 12, 'exp', 0, 1, 's'),
				action = function(value)
					dest_dials.release:set_value(params:get_raw('release') * 2 - 1)
					engine.release(value)
				end
			}
		elseif source == 'lfoA' or source == 'lfoB' then
			-- LFOs have extra parameters too
			params:add_group(source, 1 + #editor.dests)
			local freq_param = source .. 'Freq'
			local freq_command = engine[freq_param]
			local dest_dial = dest_dials[freq_param]
			params:add {
				name = source .. ' freq',
				id = freq_param,
				type = 'control',
				controlspec = controlspec.new(0.03, 21, 'exp', 0, source == 'lfoA' and 0.323 or 0.2, 'Hz'),
				action = function(value, param)
					dest_dial:set_value(params:get_raw(freq_param) * 2 - 1)
					freq_command(value)
				end
			}
		else
			params:add_group(source, #editor.dests)
		end

		for d = 1, #editor.dests do
			local dest = editor.dests[d]
			local engine_command = engine[source .. '_' .. dest.name]
			params:add {
				name = source .. ' -> ' .. dest.label,
				id = source .. '_' .. dest.name,
				type = 'control',
				controlspec = controlspec.new(-1, 1, 'lin', 0, (dest.source_defaults and dest.source_defaults[source]) or 0),
				action = function(value)
					source_dials[dest.name][source]:set_value(value)
					-- create a dead zone near 0.0
					value = (value > 0 and 1 or -1) * (1 - math.min(1, (1 - math.abs(value)) * 1.1))
					engine_command(value)
				end
			}
		end
	end

	params:add_group('voices', n_voices)

	for v = 1, n_voices do

		params:add {
			name = 'voice level ' .. v,
			id = 'outLevel_' .. v,
			type = 'taper',
			min = 0,
			max = 1,
			k = 2,
			default = 0.3,
			action = function(value)
				if v == k.selected_voice then
					dest_dials.amp:set_value(params:get_raw('outLevel_' .. v) * 2 - 1)
				end
				engine.outLevel(v, value)
			end
		}

		params:add {
			name = 'voice pan ' .. v,
			id = 'pan_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				if v == k.selected_voice then
					dest_dials.pan:set_value(params:get_raw('pan_' .. v) * 2 - 1)
				end
				engine.pan(v, value)
			end
		}
	end

	params:add_group('crow', 6)

	-- TODO: damp base + range are a way to avoid using an extra attenuator + offset,
	-- but is that worth it?
	params:add {
		name = 'damp range',
		id = 'crow_damp_range',
		type = 'control',
		controlspec = controlspec.new(-10, 10, 'lin', 0, -5, 'v')
	}

	params:add {
		name = 'damp base',
		id = 'crow_damp_base',
		type = 'control',
		controlspec = controlspec.new(-10, 10, 'lin', 0, 0, 'v')
	}

	params:add {
		name = 'pitch slew',
		id = 'crow_pitch_slew',
		type = 'control',
		controlspec = controlspec.new(0, 0.1, 'lin', 0, 0, 's'),
		action = function(value)
			crow.output[1].slew = value
		end
	}

	params:add {
		name = 'amp/damp slew',
		id = 'crow_amp_slew',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.05, 's'),
		action = function(value)
			crow.output[2].slew = value
			crow.output[3].slew = value
		end
	}

	params:add {
		name = 'gate mode',
		id = 'crow_gate_mode',
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
				crow.output[4].dyn.delay = params:get('crow_gate_delay')
				crow.output[4](false)
			else
				crow.output[4].action = [[{
					to(0, dyn { delay = 0 }, 'now'),
					held { to(8, 0) },
					to(0, 0)
				}]]
				crow.output[4].dyn.delay = params:get('crow_gate_delay')
				crow.output[4](false)
			end
		end
	}

	params:add {
		name = 'gate delay',
		id = 'crow_gate_delay',
		type = 'control',
		controlspec = controlspec.new(0.001, 0.05, 'lin', 0, 0.001, 's'),
		action = function(value)
			crow.output[4].dyn.delay = value
		end
	}

	-- TODO: global transpose, for working with oscillators that aren't tuned to C
	-- TODO: quantize lock on/off: apply post-bend quantization to keyboard notes

	params:bang()

	params:set('reverb', 1) -- off
	params:set('input_level', 0) -- ADC input at unity
	params:set('cut_input_adc', 0) -- feed echo from ext input
	params:set('cut_input_eng', -18.99) -- feed echo from internal synth (this can also be MIDI mapped)
	params:set('cut_input_tape', -math.huge) -- do NOT feed echo from tape
	params:set('monitor_level', -math.huge) -- monitor off (ext. echo fully wet)

	reset_loop_clock()

	redraw_metro = metro.init {
		time = 1 / 30,
		event = function(n)
			blink = (n % 7 < 3)
			-- TODO: is another offset of 20px needed?
			local x = 82
			for p = 1, editor.dest1 do
				local dest = editor.dests[p]
				if not dest.hidden then
					if dest.has_divider then
						x = x - 26
					else
						x = x - 18
					end
				end
			end
			for p = 1, #editor.dests do
				local dest = editor.dests[p]
				if not dest.hidden then
					local dial = dest_dials[dest.name]
					if dial.x ~= x then
						dial.x = math.floor(dial.x + (x - dial.x) * 0.6)
					end
					if dest.has_divider then
						x = x + 26
					else
						x = x + 19
					end
				end
			end
			redraw()
			grid_redraw()
		end
	}
	redraw_metro:start()

	k:select_voice(1)

	-- start at 0 / middle C
	k.on_pitch()

	-- TODO: connect to these devices by name
	touche = midi.connect(1) -- 'TOUCHE 1'
	uc4 = midi.connect(3) -- 'Faderfox UC4'

	function touche.event(data)
		local message = midi.to_msg(data)
		if message.ch == 1 and message.type == 'cc' then
			-- back = 16, front = 17, left = 18, right = 19
			if message.cc == 17 then
				tip = message.val / 126
				local scaled_tip = tip
				if expo_scaling then
					tip = tip * tip
				end
				engine.tip(k.selected_voice, tip)
				crow.output[2].volts = 10 * math.sqrt(tip)
			elseif message.cc == 16 then
				palm = message.val / 126
				local scaled_palm
				if expo_scaling then
					scaled_palm = palm * palm * palm
				else
					scaled_palm = palm * palm
				end
				engine.palm(k.selected_voice, palm)
				crow.output[3].volts = palm * params:get('crow_damp_range') + params:get('crow_damp_base')
			elseif message.cc == 18 then
				k:bend(-math.min(1, message.val / 126)) -- TODO: not sure why 126 is the max value I'm getting from Touche...
				send_pitch_volts()
			elseif message.cc == 19 then
				k:bend(math.min(1, message.val / 126))
				send_pitch_volts()
			end
		end
	end

	function uc4.event(data)
		local message = midi.to_msg(data)
		if message.ch == 1 then
			if message.type == 'note_on' then
				if message.note == 2 then
					params:delta('echo_resolution', -1)
				elseif message.note == 3 then
					params:delta('echo_resolution', 1)
				elseif message.note == 16 then
					if params:get('echo_jump_trigger') == 2 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 2)
					end
				elseif message.note == 17 then
					if params:get('echo_jump_trigger') == 3 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 3)
					end
				elseif message.note == 18 then
					if params:get('echo_jump_trigger') == 4 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 4)
					end
				elseif message.note == 19 then
					params:set('echo_jump_trigger', 5)
					echo:jump()
				end
			end
		end
	end

	grid_redraw()
end

function ampdb(amp)
	return math.log(amp) / 0.05 / math.log(10)
end

function redraw()
	-- TODO: show held pitch(es) based on how they're specified in scala file!!; indicate bend/glide
	screen.clear()
	screen.fill() -- prevent a flash of stroke when leaving system UI

	for d = 1, #editor.dests do

		if not editor.dests[d].hidden then

			local dest = editor.dests[d].name
			local dest_dial = dest_dials[dest]
			local source_dial = source_dials[dest][editor.source_names[editor.source]]
			local active = editor.dest1 == d or editor.dest2 == d

			dest_dial.active = active
			dest_dial:redraw()

			source_dial.x = dest_dial.x + 2
			source_dial.y = dest_dial.y + 2
			source_dial.active = active
			source_dial:redraw()

			screen.move(dest_dial.x - 4, dest_dial.y + 11)
			screen.level(active and 15 or 2)
			screen.text_rotate(dest_dial.x + 10, dest_dial.y - 4, editor.dests[d].label, -90)
			screen.stroke()
		end
	end

	screen.rect(0, 0, 30, 43)
	screen.level(0)
	screen.fill()

	-- TODO: icons
	
	local voice = voice_states[k.selected_voice]

	screen.level('amp' == editor.source_names[editor.source] and 15 or 3)
	screen.move(2, 7)
	screen.text('Am')

	screen.level('hand' == editor.source_names[editor.source] and 15 or 3)
	screen.move(2, 18)
	screen.text('Hd')

	screen.level('eg' == editor.source_names[editor.source] and 15 or 3)
	screen.move(18, 18)
	screen.text('Eg')

	screen.level('lfoA' == editor.source_names[editor.source] and 15 or 3)
	screen.move(2, 29)
	screen.text('La')
	screen.level(voice.lfoA_gate and 15 or 3)
	screen.text('.')

	screen.level('lfoB' == editor.source_names[editor.source] and 15 or 3)
	screen.move(18, 29)
	screen.text('Lb')
	screen.level(voice.lfoB_gate and 15 or 3)
	screen.text('.')

	screen.level('runglerA' == editor.source_names[editor.source] and 15 or 3)
	screen.move(2, 40)
	screen.text('Ra')

	screen.level('runglerB' == editor.source_names[editor.source] and 15 or 3)
	screen.move(18, 40)
	screen.text('Rb')

	screen.level('lfoSH' == editor.source_names[editor.source] and 15 or 3)
	screen.move(2, 51)
	screen.text('Ls')
	screen.level(voice.lfoEqual_gate and 15 or 3)
	screen.text('.')

	screen.update()
end

function enc(n, d)
	if n == 1 then
		if d > 0 then
			editor.source = editor.source % #editor.source_names + 1
		elseif d < 0 then
			editor.source = (editor.source - 2) % #editor.source_names + 1
		end
	elseif n == 2 or n == 3 then
		local dest = (n == 2 and editor.dests[editor.dest1]) or editor.dests[editor.dest2]
		if held_keys[n] then
			params:delta(editor.source_names[editor.source] .. '_' .. dest.name, d)
		elseif dest.voice_param then
			params:delta(dest.voice_param .. '_' .. k.selected_voice, d)
		elseif dest.name == 'pitch' then
			params:delta('base_freq', d)
		else
			params:delta(dest.name, d)
		end
	end
end

function key(n, z)
	if n == 1 and z == 1 then
		for d = 1, 2 do
			if held_keys[d + 1] then
				local dest = editor.dests[d == 1 and editor.dest1 or editor.dest2]
				for s = 1, #editor.source_names do
					params:lookup_param(editor.source_names[s] .. '_' .. dest.name):set_default()
				end
				if dest.voice_param then
					for v = 1, n_voices do
						params:lookup_param(dest.voice_param .. '_' .. v):set_default()
					end
				elseif dest.name == 'pitch' then
					params:lookup_param('base_freq'):set_default()
				else
					params:lookup_param(dest.name):set_default()
				end
			end
		end
	elseif n > 1 and z == 0 and util.time() - held_keys[n] < 0.2 then
		local d = n == 2 and -1 or 1
		-- move dest1.
		-- wrap from first to NEXT-to-last dest, in order to leave room for dest2.
		-- skip dests with dividers.
		-- NB: this assumes the last dest will never be hidden,
		-- and that the next-to-last won't have a divider.
		repeat
			editor.dest1 = util.wrap(editor.dest1 + d, 1, #editor.dests - 1)
		until not editor.dests[editor.dest1].has_divider and not editor.dests[editor.dest1].hidden
		-- move dest2 right from there
		editor.dest2 = editor.dest1
		repeat
			editor.dest2 = util.wrap(editor.dest2 + 1, 1, #editor.dests)
		until not editor.dests[editor.dest2].hidden
	end
	held_keys[n] = z == 1 and util.time() or false
end

function cleanup()
	if redraw_metro ~= nil then
		redraw_metro:stop()
	end
	local voice_polls = {
		'amp',
		'instant_pitch',
		'pitch',
		'lfoA',
		'lfoB',
		'lfoEqual',
	}
	for v = 1, n_voices do
		local voice = voice_states[v]
		for p = 1, #voice_polls do
			local poll = voice.polls[voice_polls[p]]
			if poll then
				poll:stop()
			end
		end
	end
end
