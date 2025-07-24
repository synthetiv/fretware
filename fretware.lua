-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'
Lattice = require 'lattice'

Slider = include 'lib/slider'
SliderMapping = include 'lib/slidermapping'

n_voices = 3

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

Menu = include 'lib/menu'

arp_menu = Menu.new(4, 5, 10, 2, {
	_, 1, 2, 3,  4,  5,  6, 7, 8, 9,
	_, _, _, _, 10, 11, 12 -- value number 11 can be set to 13 when direction is set to 3
})
arp_menu.toggle = true
arp_menu.on_select = function(source, old_source)
	if k.held_keys.shift then
		source = source or old_source
		if source >= 1 and source <= 9 then
			-- jump arp forward by 1/2 length of the clock division whose button was pressed
			local division = arp_divs[source] / 2
			-- if we're synced to the clock, then offset all sprockets' phase
			-- by synced sprocket's cycle length in ppc (ppqn*4)
			-- that makes this sprocket's downbeats into upbeats, and keeps others in sync
			local ppc = arp_lattice.ppqn * 4
			local phase_jump = division * ppc
			for id, sprocket in pairs(arp_lattice.sprockets) do
				local div_ppc = sprocket.division * ppc
				sprocket.phase = sprocket.phase + phase_jump
				if sprocket.phase > div_ppc then
					local skipped_cycles = math.floor(sprocket.phase / div_ppc)
					sprocket.phase = sprocket.phase % div_ppc
					-- only toggle downbeat status if we've skipped an odd number of cycles for this sprocket
					if skipped_cycles % 2 == 1 then
						sprocket.downbeat = not sprocket.downbeat
					end
				end
			end
		end
		-- don't actually *select* this division
		return false
	end
	-- enable arp when a source is selected, disable when toggled off
	if source and not k.arping then
		k.arping = true
		k.gliding = false
	elseif not source then
		k:arp(false)
		k.arping = false
	end
	k.arp_plectrum = (source == 13)
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

arp_direction_menu = Menu.new(4, 3, 5, 1, {
	3, _, 2, _, 1
})
arp_direction_menu.on_select = function(value)
	k.arp_direction = value
	if value == 3 then -- plectrum selected
		arp_menu.values[11] = 13
	else
		if arp_menu.value == 13 then
			arp_menu:select(false)
		end
		arp_menu.values[11] = nil
	end
end
arp_direction_menu:select_value(1)

source_menu = Menu.new(5, 1, 11, 2, {
	-- map of source numbers (in editor.source_names) to keys
	-- TODO: add trackball dx, dy?
	 2, _, 3, _, 5, _, 7,  8, 9, _, 1,
	 _, _, 4, _, 6, _, _, 10
})
source_menu.multi = true
source_menu:select_value(1)
source_menu.get_key_level = function(value, selected, held)
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
		-- TODO: indicate velocity
	elseif value == 4 then
		-- TODO: indicate sampled velocity
	elseif value == 5 then
		-- TODO: indicate env state
		-- maybe just use gate!
	elseif value == 6 then
		-- TODO: indicate env state
		-- maybe use a fixed-length flash when gate goes high
	elseif value >= 7 and value <= 9 then
		if not voice_states[k.selected_voice][lfo_gate_names[value - 6]] then
			level = -1
		end
	elseif value == 10 then
		-- TODO: indicate S+H state?
	end
	return (held and 11 or (selected and 6 or 3)) + level
end

link_peers = 0

Echo = include 'lib/echo'
echo = Echo.new()

redraw_metro = nil

g = grid.connect()

trackball_values = {
	x = 0,
	y = 0,
	last_x = 0,
	last_y = 0,
}

editor = {
	source_names = {
		'amp',
		'hand',
		'vel',
		'svel',
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
			name = 'loopRate',
			label = 'loop rate',
			voice_param = 'loopRate'
		},
		{
			name = 'loopPosition',
			label = 'loop position',
			voice_param = 'loopPosition'
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
	selected_dest = 1,
	autoselect_time = 0,
	encoder_autoselect_deltas = {
		[2] = 0,
		[3] = 0,
		[4] = 0,
		[5] = 0
	}
}

dest_mappings = {}
voice_mappings = {}
source_mappings = {}

xvi_params = {
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
xvi_state = {}
for s = 1, #xvi_params do
	xvi_state[s] = { value = nil, delta = 0 }
end

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
		timbre_lock = false,
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
arp_gates_inverted = {}
arp_lattice = Lattice.new()
for d = 1, #arp_divs do
	local rate = arp_divs[d] / 2
	arp_gates[d] = false
	arp_gates_inverted[d] = false
	local sprocket = arp_lattice:new_sprocket {
		division = rate,
	}
	sprocket.action = function()
		if arp_gates_inverted[d] then
			arp_gates[d] = sprocket.downbeat
		else
			arp_gates[d] = not sprocket.downbeat
		end
		if arp_menu.value == d then
			k:arp(arp_gates[d])
		end
	end
end
-- update peer count and sync SC clock every quarter note
arp_lattice:new_sprocket {
	division = 1/4,
	action = function()
		link_peers = clock.link.get_number_of_peers()
		engine.downbeat()
	end
}

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
	params:lookup_param('loopRate_' .. v):set_default()
	params:lookup_param('loopPosition_' .. v):set_default()
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

-- TODO: these function names have gotten silly, refactor
-- set_ should be play_, play_ should be something like stop_recording_,
-- and some logic from loop_clock callback should be moved into the new play_
function set_voice_loop(v, length)
	engine.setLoop(v, length)
	params:lookup_param('loopRate_' .. v):set_default()
	params:lookup_param('loopPosition_' .. v):set_default()
end

function play_voice_loop(v)
	-- stop recording, start looping
	local voice = voice_states[v]
	if loop_free then
		set_voice_loop(v, util.time() - voice.loop_armed)
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
		if not arp_direction_menu:key(x, y, z) and not arp_menu:key(x, y, z) and z == 1 then
			-- keydown, not caught by a menu
			if (x == 12 or x == 13) and y == 3 then
				if x == 12 then
					-- nudge down: pause for one pulse worth of time
					clock.run(function()
						arp_lattice:stop()
						clock.sleep(clock.get_beat_sec() / arp_lattice.ppqn)
						arp_lattice:start()
					end)
				elseif x == 13 then
					-- nudge up: skip forward by one pulse, instantaneously
					arp_lattice:pulse()
				end
			elseif (x == 15 or x == 16) and y == 3 then
				-- clock tempo increase/decrease
				if x == 15 then
					params:set('clock_tempo', params:get('clock_tempo') / 1.04)
				elseif x == 16 then
					params:set('clock_tempo', params:get('clock_tempo') * 1.04)
				end
			end
		end
	elseif x == 1 and y == 1 then
		-- mod reset key
		if z == 1 then
			if source_menu.open and source_menu.n_held > 0 then
				-- if there are any held sources, reset all routes involving them
				for source = 1, #editor.source_names do
					if source_menu.held[source] then
						local source_name = editor.source_names[source]
						for dest = 1, #editor.dests do
							local dest_name = editor.dests[dest].name
							local defaults = editor.dests[dest].source_defaults
							local param = params:lookup_param(source_name .. '_' .. dest_name)
							if defaults and defaults[source_name] then
								param:set(defaults[source_name])
							else
								param:set_default()
							end
						end
					end
				end
			end
			if held_keys[1] then
				-- if K1 is held, reset all routes involving the selected dest
				for source = 1, #editor.source_names do
					local dest_name = editor.dests[editor.selected_dest].name
					local defaults = editor.dests[editor.selected_dest].source_defaults
					if source_menu.held[source] then
						local source_name = editor.source_names[source]
						local param = params:lookup_param(source_name .. '_' .. dest_name)
						if defaults and defaults[source_name] then
							param:set(defaults[source_name])
						else
							param:set_default()
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
		-- lattice phase nudge keys
		g:led(12, 3, 5)
		g:led(13, 3, 5)
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
						set_voice_loop(v, beat_sec * loop_length_beats)
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
						-- update rate so it will be adjusted to match tempo as needed
						params:lookup_param('loopRate_' .. v):bang()
					end
				end
			end
		end)
	end
end

function init()

	norns.enc.accel(1, false)
	norns.enc.sens(1, 8)

	k.on_select_voice = function(v)
		-- if any other voice is recording, stop recording & start looping it
		for ov = 1, n_voices do
			if ov ~= v and voice_states[ov].loop_armed then
				play_voice_loop(ov)
			end
		end
		engine.select_voice(v)
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

		--[[
		cpu_avg = poll.set('cpu_avg', function(value)
			print('-- cpu avg: ', value)
		end)
		cpu_avg.time = 0.5
		cpu_avg:start()
		cpu_peak = poll.set('cpu_peak', function(value)
			print('-- cpu peak: ', value)
		end)
		cpu_peak.time = 0.5
		cpu_peak:start()
		--]]
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
		action = function()
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
		formatter = function()
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
		options = { 'FM', 'FB', 'sample', 'square', 'saw', 'pluck', 'comb', 'comb ext' },
		default = 1,
		action = function(value)
			engine.opTypeA(value - 1)
			-- TODO: this is an ugly hack. do something nicer.
			if value == 3 then
				editor.dests[3].source_defaults.amp = 0
				params:set('amp_indexA', 0)
			else
				editor.dests[3].source_defaults.amp = 0.2
				params:set('amp_indexA', 0.2)
			end
		end
	}

	params:add {
		name = 'op fade A',
		id = 'opFadeA',
		type = 'option',
		options = { 'off', 'on' },
		default = 1,
		action = function(value)
			engine.opFadeA(value - 1)
		end
	}

	params:add {
		name = 'op type B',
		id = 'opTypeB',
		type = 'option',
		options = { 'FB', 'FM', 'sample', 'square', 'saw', 'pluck', 'comb', 'comb ext' },
		default = 1,
		action = function(value)
			if value == 1 then
				value = 2 -- default to FB
			elseif value == 2 then
				value = 9 -- and use delayed FM for FM
			end
			engine.opTypeB(value - 1)
			if value == 3 then
				editor.dests[7].source_defaults.amp = 0
				params:set('amp_indexB', 0)
			else
				editor.dests[7].source_defaults.amp = 0.2
				params:set('amp_indexB', 0.2)
			end
		end
	}

	params:add {
		name = 'op fade B',
		id = 'opFadeB',
		type = 'option',
		options = { 'off', 'on' },
		default = 1,
		action = function(value)
			engine.opFadeB(value - 1)
		end
	}

	params:add {
		name = 'fx type A',
		id = 'fxTypeA',
		type = 'option',
		options = { 'squiz', 'tanh' },
		default = 1,
		action = function(value)
			engine.fxTypeA(value - 1)
		end
	}

	params:add {
		name = 'fx type B',
		id = 'fxTypeB',
		type = 'option',
		options = { 'waveloss', 'chorus' },
		default = 1,
		action = function(value)
			engine.fxTypeB(value == 1 and 3 or 5)
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

	params:add_group('clock/arp', 1)

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
		action = function()
			reset_loop_clock()
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

	params:add_group('voice params', #editor.dests - 9)

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
				controlspec = controlspec.new(0.001, 7, 'exp', 0, 0.001, 's'),
				action = function(value)
					engine.attack(value - 0.0005)
				end
			}
			params:add {
				name = 'release',
				id = 'release',
				type = 'control',
				controlspec = controlspec.new(0.001, 26, 'exp', 0, 1, 's'),
				action = function(value)
					engine.release(value)
				end
			}
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
		elseif source == 'lfoA' or source == 'lfoB' or source == 'lfoC' then
			-- LFOs have extra parameters too
			params:add_group(source, 1 + #editor.dests)
			local freq_param = source .. 'Freq'
			local freq_command = engine[freq_param]
			params:add {
				name = source .. ' freq',
				id = freq_param,
				type = 'control',
				controlspec = controlspec.new(0.03, 21, 'exp', 0, 0.2, 'Hz'),
				action = function(value)
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
				-- create a dead zone near 0.0
				value = (value > 0 and 1 or -1) * (1 - math.min(1, (1 - math.abs(value)) * 1.1))
				engine_command(value)
			end
			if dest.name == 'detuneA' or dest.name == 'detuneB' then
				-- set detune modulation on a curve
				action = function(value)
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

	params:add_group('voice mix/etc', n_voices * 4)

	for v = 1, n_voices do

		local voice = voice_states[v]

		params:add {
			name = 'voice level ' .. v,
			id = 'outLevel_' .. v,
			type = 'taper',
			min = 0,
			max = 1,
			k = 2,
			default = 0.3,
			action = function(value)
				voice.mix_level = value
				engine.outLevel(v, value)
			end
		}

		params:add {
			name = 'voice pan ' .. v,
			id = 'pan_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.pan(v, value)
			end
		}

		params:add {
			name = 'loop rate',
			id = 'loopRate_' .. v,
			type = 'control',
			controlspec = controlspec.new(0.25, 4, 'exp', 0, 1),
			action = function(value)
				if params:get('loop_clock_div') == 3 then
					-- free-running loops: just set rate
					engine.loopRate(v, value)
				else
					-- synced loops: scale relative to current + initial tempo
					engine.loopRate(v, value * voice.loop_beat_sec / clock.get_beat_sec())
				end
			end,
			formatter = function(param)
				return string.format('%.2fx', param:get())
			end
		}

		params:add {
			name = 'loop position',
			id = 'loopPosition_' .. v,
			type = 'control',
			controlspec = controlspec.new(-1, 1, 'lin', 0, 0),
			action = function(value)
				engine.loopPosition(v, value)
			end,
			formatter = function(param)
				return string.format('%+.2fx', param:get())
			end
		}

	end

	for d = 1, #editor.dests do
		local dest = editor.dests[d]
		local dest_name = dest.name
		local slider_start_value = 0
		if dest_name == 'detuneA' or dest_name == 'opMix' or dest_name == 'detuneB' or dest_name == 'pan' then
			slider_start_value = 0.5
		elseif dest_name == 'lpCutoff' then
			slider_start_value = 1
		end
		if dest.voice_param then
			local voice_param = dest.voice_param
			local mappings = {}
			for v = 1, n_voices do
				mappings[v] = SliderMapping.new(voice_param .. '_' .. v, slider_start_value, 'inner')
			end
			voice_mappings[voice_param] = mappings
		else
			dest_mappings[d] = SliderMapping.new(dest_name, slider_start_value, 'inner')
		end
		source_mappings[d] = {}
		for s = 1, #editor.source_names do
			source_mappings[d][s] = SliderMapping.new(editor.source_names[s] .. '_' .. dest_name)
		end
	end

	params:bang()

	params:set('reverb', 1) -- off
	params:set('input_level', 0) -- ADC input at unity
	params:set('cut_input_adc', -math.huge) -- no ext input to echo (it will go through the engine)
	params:set('cut_input_eng', -8) -- feed echo from internal synth (this can also be MIDI mapped)
	params:set('cut_input_tape', -math.huge) -- do NOT feed echo from tape
	params:set('monitor_level', -math.huge) -- input monitoring off (it will go through the engine)

	params:set('clock_source', 3) -- always default to link clock

	reset_loop_clock()
	clock.run(function()
		clock.sync(4)
		arp_lattice:start()
	end)

	redraw_metro = metro.init {
		time = 1 / 30,
		event = function(n)
			local y = 66
			for p = 1, editor.selected_dest - 1 do
				if editor.dests[p].has_divider then
					y = y - 23
				else
					y = y - 16
				end
			end
			for p = 1, #editor.dests do
				local dest = editor.dests[p]
				local slider = nil
				if dest.voice_param then
					slider = voice_mappings[dest.voice_param][k.selected_voice].slider
				elseif dest_mappings[p] then
					slider = dest_mappings[p].slider
				end
				if slider.y ~= y then
					slider.y = math.floor(slider.y + (y - slider.y) * 0.6)
				end
				if dest.has_divider then
					y = y + 23
				else
					y = y + 16
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
	sysex_response = {}
	function xvi.event(data)
		local message = midi.to_msg(data)
		if message.type == 'pitchbend' then
			local fader = message.ch
			-- scale to [0, 1].
			-- max 14-bit pitchbend value is 16383, but xvi only returns up to 16380
			-- 12 bits of resolution is plenty
			local new_value = message.val / 16380
			local state = xvi_state[fader]
			local old_value = state.value or new_value
			local changed_source = false
			for source = 1, #editor.source_names do
				if source_menu.held[source] then
					source_mappings[fader][source]:delta(new_value - old_value)
					changed_source = true
				end
			end
			if not changed_source then
				dest_mappings[fader]:move(old_value, new_value)
			end
			state.delta = state.delta + math.abs(new_value - old_value)
			state.value = new_value
			local now = util.time()
			if editor.selected_dest == fader then
				-- as long as the currently selected fader is being moved, don't change selection
				editor.autoselect_time = now
				state.delta = 0
			else
				-- we'll scale accumulated changes by time, so that a big move over a short time is as
				-- likely to change selection as a small move after a long pause, but that small move
				-- wouldn't change selection if the selected fader was moved recently
				local t = math.min(0.3, now - editor.autoselect_time) / 0.3
				if state.delta * t > 0.05 then
					state.delta = 0
					editor.selected_dest = fader
					editor.autoselect_time = now
					screen.ping()
				end
			end
		elseif data[1] == 0xf0 then
			xvi.receiving_sysex = true
			xvi.sysex_data = data
		elseif xvi.receiving_sysex then
			for n, v in ipairs(data) do
				table.insert(xvi.sysex_data, v)
				if v == 0xf7 then
					xvi.receiving_sysex = false
					while n < #xvi.sysex_data do
						local line = ''
						for j = 1, 8 do
							line = line .. string.format('%02x%02x ', xvi.sysex_data[n] or 0, xvi.sysex_data[n + 1] or 0)
							n = n + 2
						end
						print(line)
					end
				end
			end
		end
	end

	-- trigger sysex config dump from xvi -- supposedly this SHOULD also
	-- cause it to send fader values, but it doesn't :(
	-- xvi:send { 0xf0, 0x7d, 0, 0, 0x1f, 0xf7 }

	trackball = hid.connect(1)
	function trackball.event(type, code, value)
		if type == 2 then
			if code == 0 then
				trackball_values.x = trackball_values.x - value
				k:move_plectrum(value / -16, 0)
			elseif code == 1 then
				trackball_values.y = trackball_values.y - value
				k:move_plectrum(0, value / -16)
			end
		end
	end

	clock.run(function()
		while true do
			clock.sleep(0.1) -- TODO NEXT: fine tune rate
			if trackball_values.x ~= 0 or trackball_values.last_x ~= 0 then
				engine.dx(trackball_values.x / 32)
				trackball_values.last_x = trackball_values.x
				trackball_values.x = 0
			end
			if trackball_values.y ~= 0 or trackball_values.last_y ~= 0 then
				engine.dy(trackball_values.y / 32)
				trackball_values.last_y = trackball_values.y
				trackball_values.y = 0
			end
		end
	end)

	-- inform SC of tempo changes
	clock.tempo_change_handler = function(tempo)
		engine.tempo(tempo)
	end

	grid_redraw()
end

function ampdb(amp)
	return math.log(amp) / 0.05 / math.log(10)
end

function redraw()
	-- TODO: show held pitch(es) based on how they're specified in scala file!!; indicate bend/glide
	screen.clear()
	-- screen.restore()
	screen.fill() -- prevent a flash of stroke when leaving system UI

	screen.save()
	screen.translate(0, 64)
	screen.rotate(util.degs_to_rads(-90))

	screen.font_face(68)

	local voice = voice_states[k.selected_voice]

	for d = 1, #editor.dests do

		local dest = editor.dests[d]
		local active = editor.selected_dest == d
		local dest_slider = nil
		if dest.voice_param then
			dest_slider = voice_mappings[dest.voice_param][k.selected_voice].slider
		else
			dest_slider = dest_mappings[d].slider
		end

		if dest_slider.y >= -4 and dest_slider.y <= 132 then
			-- TODO: maybe just indicate actual fader position, instead of offsetting -- it's a lil weird
			if d <= 16 and xvi_state[d].value then
				dest_slider.x = math.floor((dest_slider.value - xvi_state[d].value) * 64 + 0.5) + 1
			else
				dest_slider.x = 1
			end
			local source_slider = source_mappings[d][source_menu.value].slider
			source_slider.y = dest_slider.y - 1
			source_slider.x = dest_slider.x - 1
			source_slider:redraw(active and 2 or 1, active and 15 or 4)

			dest_slider:redraw(active and 1 or 0, active and 3 or 1)

			screen.level(active and 10 or 1)
			screen.move(0, dest_slider.y - 3)
			screen.text(editor.dests[d].label:upper())
			screen.stroke()
		end
	end

	screen.rect(0, 0, 64, 8)
	screen.level(0)
	screen.fill()

	screen.level(3)
	screen.move(0, 5)
	if arp_menu.open then
		screen.text('CLOCK: ')
		local clock_source = params:get('clock_source')
		if clock_source == 1 then
			screen.text('INT')
		elseif clock_source == 2 then
			screen.text('MIDI')
		elseif clock_source == 3 then
			screen.text('LINK: ')
			screen.text(link_peers)
		elseif clock_source == 4 then
			screen.text('CROW')
		else
			screen.text('??')
		end
	else
		screen.text(editor.source_names[source_menu.value]:upper())
		if voice_states[k.selected_voice].timbre_lock then
			screen.text('  !! VOX LOCK')
		else
			screen.text(' MOD')
		end
	end
	screen.move_rel(1, 0)
	screen.line_rel(64, 0)
	screen.level(1)
	screen.stroke()

	screen.restore()
	screen.update()
end

function refresh()
	redraw()
end

function enc(n, d)
	if n == 1 then
		editor.selected_dest = util.wrap(editor.selected_dest + d, 1, #editor.dests)
	else
		-- TODO: handle 'delta' and auto-selection stuff in SliderMapping class
		-- adjust amp, pan, loop rate, or loop pos
		if not held_keys[2] then
			n = n + 2
		end
		local param_index = 15 + n
		local changed_source = false
		local d_scaled = d / 128
		for source = 1, #editor.source_names do
			if source_menu.held[source] then
				source_mappings[param_index][source]:delta(d_scaled)
				changed_source = true
			end
		end
		if not changed_source then
			if n == 2 then
				voice_mappings.loopRate[k.selected_voice]:delta(d_scaled)
			elseif n == 3 then
				voice_mappings.loopPosition[k.selected_voice]:delta(d_scaled)
			elseif n == 4 then
				voice_mappings.pan[k.selected_voice]:delta(d_scaled)
			elseif n == 5 then
				voice_mappings.outLevel[k.selected_voice]:delta(d_scaled)
			end
		end
		-- maybe auto-select amp or pan
		local now = util.time()
		editor.encoder_autoselect_deltas[n] = editor.encoder_autoselect_deltas[n] + math.abs(d)
		if editor.selected_dest == 15 + n then
			editor.autoselect_time = now
			editor.encoder_autoselect_deltas[n] = 0
		else
			local t = math.min(0.3, now - editor.autoselect_time) / 0.3
			if editor.encoder_autoselect_deltas[n] * t > 0.05 then
				editor.encoder_autoselect_deltas[n] = 0
				editor.selected_dest = 15 + n
				editor.autoselect_time = now
			end
		end
	end
end

function key(n, z)
	held_keys[n] = z == 1 and util.time() or false
	if z == 1 then
		if n == 1 then
			-- if any voice keys are held, toggle lock state.
			-- note that this may mean locking one and unlocking another
			-- TODO NOW: test, does that Feel Right?
			for v = 1, n_voices do
				if k.held_keys.voices[v] then
					local voice_state = voice_states[v]
					local lock = not voice_state.timbre_lock
					engine.timbreLock(v, lock and 1 or 0)
					voice_state.timbre_lock.timbre_lock = lock
				end
			end
		elseif n == 2 then
			editor.selected_dest = 17 -- loop rate
			editor.autoselect_time = util.time()
		elseif n == 3 then
			editor.selected_dest = 19 -- pan
			editor.autoselect_time = util.time()
		end
	end
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
