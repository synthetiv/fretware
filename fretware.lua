-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'
Lattice = require 'lattice'

Slider = include 'lib/slider'

n_voices = 4

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

Menu = include 'lib/menu'

arp_menu = Menu.new(5, 5, 9, 2, {
	1, 2, 3,  4,  5,  6, 7, 8, 9,
	_, _, _, 10, 11, 12
})
arp_menu.toggle = true
arp_menu.on_select = function(source)
	-- enable arp when a source is selected, disable when toggled off
	if source and not k.arping then
		k.arping = true
	elseif not source then
		k:arp(false)
		k.arping = false
	end
end
arp_menu.get_key_level = function(value, selected)
	local level = 0
	if value <= #arp_divs then
		if arp_gates[value] then
			level = 2
		end
	elseif voice_states[k.selected_voice][lfo_gate_names[value - #arp_divs]] then
		level = 2
	end
	return level + (selected and 11 or 4)
end

arp_direction_menu = Menu.new(5, 3, 4, 1, {
	100, 50, 15, 0
})
arp_direction_menu.on_select = function(value)
	-- param doesn't exist when this is initialized
	if params.lookup['arp_randomness'] then
		params:set('arp_randomness', value)
	end
end
arp_direction_menu:select_value(0)

source_menu = Menu.new(7, 1, 9, 2, {
	-- map of source numbers (in editor.source_names) to keys
	 2, _, 3, _, 5, 6,  7, _, 1,
	 _, _, 4, _, _, 8
})
source_menu.multi = true
source_menu:select_value(1)
source_menu.get_key_level = function(value, selected, held)
	local source_name = editor.source_names[value]
	local level = 0
	-- darken LFO + amp sources when low
	if value == 1 then
		if voice_states[k.selected_voice].amp < 0.5 then
			level = -1
		end
	elseif value == 2 then
		if tip - palm < 0 then
			level = -1
		end
	elseif value == 3 then
		-- TODO: indicate env state
	elseif value == 4 then
		-- TODO: indicate env state
	elseif value >= 5 and value <= 7 then
		if not voice_states[k.selected_voice][lfo_gate_names[value - 4]] then
			level = -1
		end
	end
	return (held and 11 or (selected and 6 or 3)) + level
end

Echo = include 'lib/echo'
echo = Echo.new()

redraw_metro = nil

g = grid.connect()

editor = {
	source_names = {
		'amp',
		'hand',
		'eg',
		'eg2',
		'lfoA',
		'lfoB',
		'lfoC',
		'sh'
	},
	dests = {
		{
			name = 'ratioA',
			label = 'ratio A',
			default = -0.4167 -- 1/1 (4th out of 12 harmonics)
		},
		{
			name = 'detuneA',
			label = 'detune A',
			default = 0
		},
		{
			name = 'indexA',
			label = 'index A',
			default = -1,
			source_defaults = {
				amp = 0.2
			}
		},
		{
			name = 'opMix',
			label = 'mix A:B',
			default = -1
		},
		{
			name = 'ratioB',
			label = 'ratio B',
			default = -0.25 -- 2/1 (5th out of 12 harmonics)
		},
		{
			name = 'detuneB',
			label = 'detune B',
			default = 0
		},
		{
			name = 'indexB',
			label = 'index B',
			default = -1,
			source_defaults = {
				amp = 0.2
			},
			has_divider = true
		},
		{
			name = 'fxA',
			label = 'fx A',
			default = -1
		},
		{
			name = 'fxB',
			label = 'fx B',
			default = -1
		},
		{
			name = 'hpCutoff',
			label = 'hp cutoff',
			default = -1
		},
		{
			name = 'lpCutoff',
			label = 'lp cutoff',
			default = 0.8,
			source_defaults = {
				amp = 0.2
			},
			has_divider = true
		},
		{
			name = 'attack',
			label = 'attack',
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
			default = -0.2
		},
		{
			name = 'lfoCFreq',
			label = 'lfo c freq',
			default = -0.4,
			has_divider = true
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
	selected_dest = 1
}

dest_sliders = {
	ratioA   = Slider.new(82, 8, 2, 55),
	detuneA  = Slider.new(101, 8, 2, 55, 0),
	indexA   = Slider.new(120, 8, 2, 55),

	opMix    = Slider.new(196, 8, 2, 55, 0),

	ratioB   = Slider.new(139, 8, 2, 55),
	detuneB  = Slider.new(158, 8, 2, 55, 0),
	indexB   = Slider.new(177, 8, 2, 55),

	fxA      = Slider.new(215, 8, 2, 55),
	fxB      = Slider.new(234, 8, 2, 55),
	hpCutoff = Slider.new(253, 8, 2, 55),
	lpCutoff = Slider.new(253, 8, 2, 55, 1),

	attack   = Slider.new(277, 8, 2, 55),
	release  = Slider.new(516, 8, 2, 55),

	lfoAFreq = Slider.new(321, 8, 2, 55),
	lfoBFreq = Slider.new(340, 8, 2, 55),
	lfoCFreq = Slider.new(359, 8, 2, 55),

	pan      = Slider.new(383, 8, 2, 55, 0),
	amp      = Slider.new(402, 8, 2, 55, 0)
}

source_sliders = {}
for s = 1, #editor.dests do
	source_sliders[editor.dests[s].name] = {
		amp    = Slider.new(82, 7, 4, 57, 0),
		hand   = Slider.new(82, 7, 4, 57, 0),
		eg     = Slider.new(82, 7, 4, 57, 0),
		eg2    = Slider.new(82, 7, 4, 57, 0),
		lfoA   = Slider.new(82, 7, 4, 57, 0),
		lfoB   = Slider.new(82, 7, 4, 57, 0),
		lfoC   = Slider.new(82, 7, 4, 57, 0),
		sh     = Slider.new(82, 7, 4, 57, 0)
	}
end

xvi_values = {}
xvi_mappings = {
	'ratioA',
	'detuneA',
	'indexA',
	'opMix',
	'ratioB',
	'detuneB',
	'indexB',
	'fxA',
	'fxB',
	'hpCutoff',
	'lpCutoff',
	'attack',
	'release',
	'lfoAFreq',
	'lfoBFreq',
	'lfoCFreq'
}

held_keys = { false, false, false }

voice_states = {}
for v = 1, n_voices do
	voice_states[v] = {
		pitch = 0,
		amp = 0,
		mix_level = 1,
		shift = 0,
		looping = false,
		looping_next = false,
		loop_armed = false,
		loop_armed_next = false,
		loop_beat_sec = 0.25,
		lfoA_gate = false,
		lfoB_gate = false,
		lfoC_gate = false,
		polls = {},
	}
end

lfo_gate_names = {
	'lfoA_gate',
	'lfoB_gate',
	'lfoC_gate'
}

tip = 0
palm = 0
gate_in = false

arp_divs = { 1/2, 3/8, 1/4, 3/16, 1/8, 3/32, 1/16, 1/24, 1/32 }
arp_gates = {}
arp_lattice = Lattice.new()
for d = 1, #arp_divs do
	local rate = arp_divs[d]
	arp_gates[d] = false
	arp_lattice:new_sprocket {
		division = rate,
		action = function()
			arp_gates[d] = true
			if arp_menu.value == d then
				k:arp(true)
			end
		end
	}
	arp_lattice:new_sprocket {
		division = rate,
		delay = 0.5,
		action = function()
			arp_gates[d] = false
			if arp_menu.value == d then
				k:arp(false)
			end
		end
	}
end

arp_lattice_reset = {
	key_held = false,
	interval = false,
	clocks = {}
}
for c = 1, 3 do
	local rate = math.pow(2, -c)
	arp_lattice_reset.clocks[c] = clock.run(function()
		while true do
			clock.sync(rate)
			if arp_lattice_reset.interval == c and not arp_lattice_reset.key_held then
				arp_lattice:start()
				arp_lattice_reset.interval = false
				-- send transport start signal to any devices connected to UC4
				uc4:start()
			end
		end
	end)
end

clock.transport.start = function()
	arp_lattice:hard_restart()
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
		-- TODO: maybe loop states should be polled from SC, so that we don't need to send as many
		-- messages TO SC...?
		voice.looping = true
		voice.loop_armed = false
	else
		voice.looping_next = true
	end
end

function g.key(x, y, z)
	if x == 6 and y == 8 then
		-- TODO: this could lead to stuck keys, since the menu will steal key input from the
		-- keyboard. how could you work around that? examine keyboard's held keys and give
		-- first priority in key handler to keyboard keyoffs, then menu keyon, then keyboard
		-- keyon?
		if z == 1 then
			arp_menu.open = not arp_menu.open
			arp_direction_menu.open = arp_menu.open
			source_menu.open = false
		end
	elseif x == 9 and y == 8 then
		if z == 1 then
			source_menu.open = not source_menu.open
			arp_menu.open = false
			arp_direction_menu.open = false
		end
	elseif arp_menu.open and x > 2 and y < 8 then
		if x >= 11 and x <= 13 and y == 3 then
			if z == 1 then
				arp_lattice_reset.interval = x - 10
				arp_lattice_reset.key_held = true
			else
				arp_lattice:reset()
				arp_lattice_reset.key_held = false
			end
		elseif (x == 15 or x == 16) and y == 3 then
			if z == 1 then
				-- clock tempo increase/decrease
				if x == 15 then
					params:set('clock_tempo', params:get('clock_tempo') / 1.04)
				elseif x == 16 then
					params:set('clock_tempo', params:get('clock_tempo') * 1.04)
				end
			end
		elseif not arp_direction_menu:key(x, y, z) then
			arp_menu:key(x, y, z)
		end
	elseif source_menu.open and source_menu.n_held > 0 and x == 1 and y == 1 then
		if z == 1 then
			-- if there are any held sources, reset ALL routes involving them
			for source = 1, #editor.source_names do
				if source_menu.held[source] then
					local source_name = editor.source_names[source]
					for dest = 1, #editor.dests do
						local dest_name = editor.dests[dest].name
						params:lookup_param(source_name .. '_' .. dest_name):set_default()
						_menu.set_mode(false)
					end
				end
			end
		end
	elseif source_menu.open and x > 2 and y < 8 then
		source_menu:key(x, y, z)
	else
		k:key(x, y, z)
	end
	grid_redraw()
	screen.ping()
end

function send_pitch()
	engine.pitch(k.bent_pitch)
end

-- TODO: debounce here
function grid_redraw()
	g:all(0)
	k:draw()
	if arp_menu.open or arp_direction_menu.open or source_menu.open then
		for x = 3, 16 do
			for y = 1, 7 do
				g:led(x, y, 0)
			end
		end
	end
	if arp_menu.open then
		g:led(6, 8, 15)
	elseif arp_menu.value then
		-- an arp clock source is selected; blink
		local v = arp_menu.value
		local level = 5
		if v <= #arp_divs then
			if arp_gates[v] then
				level = level + 2
			end
		elseif voice_states[k.selected_voice][lfo_gate_names[v - #arp_divs]] then
			level = level + 2
		end
		g:led(6, 8, level)
	else
		-- no source selected; go dark
		g:led(6, 8, 2)
	end
	arp_menu:draw()
	arp_direction_menu:draw()
	if arp_menu.open then
		-- clock reset keys
		for c = 1, 3 do
			g:led(10 + c, 3, arp_lattice_reset.interval == c and 9 or 5)
		end
		-- tempo nudge keys
		g:led(15, 3, 4)
		g:led(16, 3, 4)
	end
	g:led(9, 8, source_menu.open and 7 or 2)
	source_menu:draw()
	if source_menu.open and source_menu.n_held > 0 then
		g:led(1, 1, 7)
	end
	local blink = arp_gates[5] -- 1/8 notes
	for v = 1, n_voices do
		local voice = voice_states[v]
		local level = voice.amp
		if voice.loop_armed_next then
			-- about to start recording
			level = level * 0.5 + (blink and 0.2 or 0)
		elseif voice.looping_next then
			-- recording, about to stop
			level = level * 0.5 + (blink and 0.35 or 0.25)
		elseif voice.loop_armed then
			-- recording
			level = level * 0.5 + (blink and 0.5 or 0)
		elseif voice.looping then
			-- playing back
			level = level * 0.75 + 0.25
		end
		level = math.floor(level * 15)
		g:led(1, 8 - v, level)
	end
	g:refresh()
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

function init()

	norns.enc.accel(1, false)
	norns.enc.sens(1, 8)
	norns.enc.accel(2, false)
	norns.enc.sens(2, 8)

	k.on_select_voice = function(v)
		-- if any other voice is recording, stop recording & start looping it
		for ov = 1, n_voices do
			if ov ~= v and voice_states[ov].loop_armed then
				play_voice_loop(ov)
			end
		end
		engine.select_voice(v)
		dest_sliders.amp:set_value(params:get_raw('outLevel_' .. v) * 2 - 1)
		dest_sliders.pan:set_value(params:get_raw('pan_' .. v) * 2 - 1)
		send_pitch()
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
		send_pitch()
		grid_redraw()
	end

	k.on_gate = function(gate)
		engine.gate(gate and 1 or 0)
	end

	-- set up softcut echo
	softcut.reset()
	echo:init()

	-- set up polls
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
		for g, name in ipairs(lfo_gate_names) do
			local echo_jump_trigger = 1 + g
			local echo_uc4_note = 11 + g
			local arp_source = #arp_divs + g
			voice.polls[name] = poll.set(name .. '_' .. v, function(gate)
				gate = gate > 0
				voice[name] = gate
				if v == k.selected_voice then
					if echo.jump_trigger == echo_jump_trigger then
						if gate then
							if uc4 then
								uc4:note_off(echo_uc4_note)
								clock.run(function()
									clock.sleep(0.05)
									-- double check trigger setting just in case it's changed in the last 20ms
									if echo.jump_trigger == echo_jump_trigger then
										uc4:note_on(echo_uc4_note, 127)
									end
								end)
							end
							echo:jump()
						else
							if uc4 then uc4:note_on(echo_uc4_note, 127) end
						end
					end
					if arp_menu.value == arp_source then
						k:arp(gate)
					end
				end
			end)
			voice.polls[name]:start()
		end
	end

	params:add_group('tuning', 5)

	params:add {
		name = 'base frequency (C)',
		id = 'base_freq',
		type = 'control',
		controlspec = controlspec.new(musicutil.note_num_to_freq(48), musicutil.note_num_to_freq(72), 'exp', 0, musicutil.note_num_to_freq(60), 'Hz'),
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
			send_pitch()
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

	params:add_group('modes', 9)

	params:add {
		name = 'op type A',
		id = 'opTypeA',
		type = 'option',
		options = { 'FM', 'FB' },
		default = 1,
		action = function(value)
			local opFade = params:get('opFadeA')
			engine.opTypeA((value - 1) * 2 + opFade - 1)
		end
	}

	params:add {
		name = 'op fade A',
		id = 'opFadeA',
		type = 'option',
		options = { 'off', 'on' },
		default = 1,
		action = function(value)
			local opType = params:get('opTypeA')
			engine.opTypeA((opType - 1) * 2 + value - 1)
		end
	}

	params:add {
		name = 'op type B',
		id = 'opTypeB',
		type = 'option',
		options = { 'FB', 'FM' },
		default = 1,
		action = function(value)
			local opFade = params:get('opFadeB')
			engine.opTypeA((2 - value) * 2 + opFade - 1)
		end
	}

	params:add {
		name = 'op fade B',
		id = 'opFadeB',
		type = 'option',
		options = { 'off', 'on' },
		default = 1,
		action = function(value)
			local opType = params:get('opTypeB')
			engine.opTypeB((2 - opType) * 2 + value - 1)
		end
	}

	params:add {
		name = 'fx type A',
		id = 'fxTypeA',
		type = 'option',
		options = { 'squiz', 'fold' },
		default = 1,
		action = function(value)
			engine.fxTypeA(value == 1 and 0 or 2)
		end
	}

	params:add {
		name = 'fx type B',
		id = 'fxTypeB',
		type = 'option',
		options = { 'waveloss', 'chorus' },
		default = 1,
		action = function(value)
			engine.fxTypeB(value == 1 and 1 or 3)
		end
	}

	params:add {
		name = 'lfo type A',
		id = 'lfoTypeA',
		type = 'option',
		options = { 'tri', 's+h', 'dust', 'drift', 'ramp' },
		default = 1,
		action = function(value)
			engine.lfoTypeA(value - 1)
		end
	}

	params:add {
		name = 'lfo type B',
		id = 'lfoTypeB',
		type = 'option',
		options = { 'tri', 's+h', 'dust', 'drift', 'ramp' },
		default = 1,
		action = function(value)
			engine.lfoTypeB(value - 1)
		end
	}

	params:add {
		name = 'lfo type C',
		id = 'lfoTypeC',
		type = 'option',
		options = { 'tri', 's+h', 'dust', 'drift', 'ramp' },
		default = 1,
		action = function(value)
			engine.lfoTypeC(value - 1)
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

	params:add_group('filter settings', 2)

	params:add {
		name = 'lp q',
		id = 'lpQ',
		type = 'control',
		controlspec = controlspec.new(1, 5, 'exp', 0, 1.414),
		action = function(value)
			engine.lpRQ(1 / value)
		end
	}

	params:add {
		name = 'hp q',
		id = 'hpQ',
		type = 'control',
		controlspec = controlspec.new(1, 5, 'exp', 0, 1.414),
		action = function(value)
			engine.hpRQ(1 / value)
		end
	}

	params:add_group('eg settings', 2)

	params:add {
		name = 'eg type',
		id = 'eg_type',
		type = 'option',
		options = { 'gated ar', 'trig\'d ar' },
		default = 2,
		action = function(value)
			engine.egType(value - 1)
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

	params:add_group('voice params', #editor.dests - 7)

	for d = 1, #editor.dests do
		local dest = editor.dests[d]
		if dest.name ~= 'attack' and dest.name ~= 'release' and dest.name ~= 'lfoAFreq' and dest.name ~= 'lfoBFreq' and dest.name ~= 'lfoCFreq' and not dest.voice_param then
			local engine_command = engine[dest.name]
			params:add {
				name = dest.label,
				id = dest.name,
				type = 'control',
				controlspec = controlspec.new(-1, 1, 'lin', 0, dest.default),
				action = function(value)
					dest_sliders[dest.name]:set_value(value)
					engine_command(value)
				end
			}
		end
	end

	for s = 1, #editor.source_names do
		local source = editor.source_names[s]

		if source == 'eg' then
			-- EG group gets extra parameters
			params:add_group('eg', 2 + #editor.dests)
			params:add {
				name = 'attack',
				id = 'attack',
				type = 'control',
				controlspec = controlspec.new(0.001, 7, 'exp', 0, 0.001, 's'),
				action = function(value)
					dest_sliders.attack:set_value(params:get_raw('attack') * 2 - 1)
					engine.attack(value - 0.0005)
				end
			}
			params:add {
				name = 'release',
				id = 'release',
				type = 'control',
				controlspec = controlspec.new(0.001, 26, 'exp', 0, 1, 's'),
				action = function(value)
					dest_sliders.release:set_value(params:get_raw('release') * 2 - 1)
					engine.release(value)
				end
			}
		elseif source == 'lfoA' or source == 'lfoB' or source == 'lfoC' then
			-- LFOs have extra parameters too
			params:add_group(source, 1 + #editor.dests)
			local freq_param = source .. 'Freq'
			local freq_command = engine[freq_param]
			local dest_slider = dest_sliders[freq_param]
			params:add {
				name = source .. ' freq',
				id = freq_param,
				type = 'control',
				controlspec = controlspec.new(0.03, 21, 'exp', 0, 0.2, 'Hz'),
				action = function(value, param)
					dest_slider:set_value(params:get_raw(freq_param) * 2 - 1)
					freq_command(value)
				end
			}
		else
			params:add_group(source, #editor.dests)
		end

		for d = 1, #editor.dests do
			local dest = editor.dests[d]
			local engine_command = engine[source .. '_' .. dest.name]
			local action = function(value)
				source_sliders[dest.name][source]:set_value(value)
				-- create a dead zone near 0.0
				value = (value > 0 and 1 or -1) * (1 - math.min(1, (1 - math.abs(value)) * 1.1))
				engine_command(value)
			end
			if dest.name == 'detuneA' or dest.name == 'detuneB' then
				-- set detune modulation on a curve
				action = function(value)
					source_sliders[dest.name][source]:set_value(value)
					-- create a dead zone near 0.0
					local sign = (value > 0 and 1 or -1)
					value = 1 - math.min(1, (1 - math.abs(value)) * 1.1)
					value = sign * value * value
					engine_command(value)
				end
			end
			params:add {
				name = source .. ' -> ' .. dest.label,
				id = source .. '_' .. dest.name,
				type = 'control',
				controlspec = controlspec.new(-1, 1, 'lin', 0, (dest.source_defaults and dest.source_defaults[source]) or 0),
				action = action
			}
		end
	end

	params:add_group('voice mix', n_voices * 2)

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
					dest_sliders.amp:set_value(params:get_raw('outLevel_' .. v) * 2 - 1)
				end
				voice_states[v].mix_level = value
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
					dest_sliders.pan:set_value(params:get_raw('pan_' .. v) * 2 - 1)
				end
				engine.pan(v, value)
			end
		}
	end

	params:bang()

	params:set('reverb', 1) -- off
	params:set('input_level', 0) -- ADC input at unity
	params:set('cut_input_adc', 0) -- feed echo from ext input
	params:set('cut_input_eng', -8) -- feed echo from internal synth (this can also be MIDI mapped)
	params:set('cut_input_tape', -math.huge) -- do NOT feed echo from tape
	params:set('monitor_level', -math.huge) -- monitor off (ext. echo fully wet)

	reset_loop_clock()
	clock.run(function()
		clock.sync(4)
		arp_lattice:start()
	end)

	redraw_metro = metro.init {
		time = 1 / 30,
		event = function(n)
			local x = 66
			for p = 1, editor.selected_dest - 1 do
				if editor.dests[p].has_divider then
					x = x - 23
				else
					x = x - 16
				end
			end
			for p = 1, #editor.dests do
				local dest = editor.dests[p]
				local slider = dest_sliders[dest.name]
				if slider.hidden then
					slider.x = x
					slider.hidden = false
				elseif slider.x ~= x then
					slider.x = math.floor(slider.x + (x - slider.x) * 0.6)
				end
				if dest.has_divider then
					x = x + 23
				else
					x = x + 16
				end
			end
			grid_redraw()
		end
	}
	redraw_metro:start()

	k:select_voice(1)

	-- start at 0 / middle C
	k.on_pitch()

	local midi_devices_by_name = {}
	for vport = 1, #midi.vports do
		local device = midi.connect(vport)
		midi_devices_by_name[device.name] = device
	end
	touche = midi_devices_by_name['TOUCHE 1'] or {}
	function touche.event(data)
		local message = midi.to_msg(data)
		if message.ch == 1 and message.type == 'cc' then
			-- back = 16, front = 17, left = 18, right = 19
			if message.cc == 17 then
				tip = message.val / 126
				engine.tip(tip)
			elseif message.cc == 16 then
				palm = message.val / 126
				engine.palm(palm)
			elseif message.cc == 18 then
				k:bend(-math.min(1, message.val / 126)) -- TODO: not sure why 126 is the max value I'm getting from Touche...
				send_pitch()
			elseif message.cc == 19 then
				k:bend(math.min(1, message.val / 126))
				send_pitch()
			end
		end
	end

	uc4 = midi_devices_by_name['Faderfox UC4'] or {}
	function uc4.event(data)
		local message = midi.to_msg(data)
		if message.ch == 1 then
			if message.type == 'note_on' then
				if message.note >= 12 and message.note < 18 then
					if message.note == params:get('echo_jump_trigger') + 10 then
						params:set('echo_jump_trigger', 1) -- none
						uc4:note_off(message.note, 127)
					else
						params:set('echo_jump_trigger', message.note - 10)
					end
				elseif message.note == 18 or message.note == 19 then
					-- manual jump trigger
					params:set('echo_jump_trigger', 1)
					echo:jump()
				end
			elseif message.type == 'note_off' then
				if message.note >= 12 and message.note < 18 then
					if message.note == params:get('echo_jump_trigger') + 10 then
						-- turn UC4 note light back on
						uc4:note_on(message.note, 127)
					end
				end
			end
		end
	end

	xvi = midi_devices_by_name['MiSW XVI-M'] or {}
	local xvi_autoselect_time = 0
	function xvi.event(data)
		local message = midi.to_msg(data)
		if message.type == 'pitchbend' then
			local fader = message.ch
			local new_value = message.val
			local old_value = xvi_values[fader] or new_value
			-- scale to [0, 1]. 16383 = max 14-bit pitchbend value
			local delta_raw = (new_value - old_value) / 16383
			local source_held = false
			for source = 1, #editor.source_names do
				if source_menu.held[source] then
					local prefix = editor.source_names[source] .. '_'
					local param = params:lookup_param(prefix .. xvi_mappings[fader])
					param:set_raw(param.raw + delta_raw)
					source_held = true
				end
			end
			if not source_held then
				local param = params:lookup_param(xvi_mappings[fader])
				param:set_raw(param.raw + delta_raw)
			end
			xvi_values[fader] = new_value
			local now = util.time()
			-- TODO: do you need a more sophisticated way of debouncing?
			if now - xvi_autoselect_time > 0.3 then
				editor.selected_dest = fader
				xvi_autoselect_time = now
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

	-- TODO: icons

	local voice = voice_states[k.selected_voice]
	local source_name = editor.source_names[source_menu.value]

	screen.level(source_menu:is_selected(1) and 15 or 3)
	screen.move(0, 5)
	screen.text('Am')

	screen.level(source_menu:is_selected(2) and 15 or 3)
	screen.move_rel(6, 0)
	screen.text('Hd')

	screen.level(source_menu:is_selected(3) and 15 or 3)
	screen.move_rel(6, 0)
	screen.text('En')

	screen.level(source_menu:is_selected(4) and 15 or 3)
	screen.move_rel(6, 0)
	screen.text('En2')

	screen.level(source_menu:is_selected(5) and 15 or 3)
	screen.move_rel(6, 0)
	screen.text('La')
	screen.level(voice.lfoA_gate and 15 or 3)
	screen.text('.')

	screen.level(source_menu:is_selected(6) and 15 or 3)
	screen.move_rel(6, 0)
	screen.text('Lb')
	screen.level(voice.lfoB_gate and 15 or 3)
	screen.text('.')

	screen.level(source_menu:is_selected(7) and 15 or 3)
	screen.move_rel(6, 0)
	screen.text('Lc')
	screen.level(voice.lfoC_gate and 15 or 3)
	screen.text('.')

	screen.level(source_menu:is_selected(8) and 15 or 3)
	screen.move_rel(6, 0)
	screen.text('Sh')
	screen.level(voice.lfoC_gate and 15 or 3)
	screen.text('.')

	-- TODO: fix this
	for d = 1, #editor.dests do

		local dest = editor.dests[d].name
		local active = editor.selected_dest == d
		local dest_slider = dest_sliders[dest]

		if dest_slider.x >= -4 and dest_slider.x <= 132 then
			local source_slider = source_sliders[dest][source_name]
			source_slider.x = dest_slider.x - 1
			source_slider:redraw(active and 2 or 1, active and 15 or 4)

			dest_slider:redraw(active and 1 or 0, active and 3 or 1)

			screen.level(active and 10 or 1)
			screen.text_rotate(dest_slider.x - 3, 63, editor.dests[d].label, -90)
			screen.stroke()
		end
	end

	screen.update()
end

function refresh()
	redraw()
end

function enc(n, d)
	if n == 1 then
		source_menu:select_value(util.wrap(source_menu.value + d, 1, #editor.source_names))
	elseif n == 2 then
		editor.selected_dest = util.wrap(editor.selected_dest + d, 1, #editor.dests)
	elseif n == 3 then
		local dest = editor.dests[editor.selected_dest]
		if not held_keys[3] then
			params:delta(editor.source_names[source_menu.value] .. '_' .. dest.name, d)
		elseif dest.voice_param then
			params:delta(dest.voice_param .. '_' .. k.selected_voice, d)
		else
			params:delta(dest.name, d)
		end
	end
end

function key(n, z)
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
		'lfoA_gate',
		'lfoB_gate',
		'lfoC_gate'
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
	if uc4 then
		for n = 12, 19 do
			uc4:note_off(n)
		end
	end
end
