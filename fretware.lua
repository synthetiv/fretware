-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'
Lattice = require 'lattice'

SliderMapping = include 'lib/slidermapping'

n_voices = 3

grid_controls = {}

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)
table.insert(grid_controls, 1, k.stepper)

Menu = include 'lib/menu'

arp_menu = Menu.new(4, 5, 10, 2, {
	_, 1,  2, 3,  4,  5,  6, 7, 8, 9,
	_, _, 14, _, 10, 11, 12 -- value number 11 can be set to 13 when direction is set to 3
})
arp_menu.is_toggle = true
arp_menu.on_select = function(source, old_source)
	-- enable arp when a source is selected, disable when toggled off
	if source and not k.arping then
		k.arping = true
		k.gliding = false
	elseif not source then
		k:arp(false)
		k.arping = false
		handle_synced_voice_loops(true) -- just in case we had a loop start/end cued up
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
table.insert(grid_controls, 1, arp_menu)

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
table.insert(grid_controls, 1, arp_direction_menu)

source_menu = Menu.new(5, 1, 11, 2, {
	-- map of source numbers (in editor.source_names) to keys
	-- TODO: add trackball dx, dy?
	 2, _, 3, _, 5, _, 7,  8, 9, _, 1,
	 _, _, 4, _, 6, _, _, 10
})
source_menu.is_multi = true
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
table.insert(grid_controls, 1, source_menu)

link_peers = 0

Echo = include 'lib/echo'
echo = Echo.new()

redraw_metro = nil

-- TODO NEXT: handle when grid gets disconnected!!
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
			mode_param = 'opHardA',
			modes = { 'soft', 'hard' },
			default = -0.4167 -- 1/1 (4th out of 12 harmonics)
		},
		{
			name = 'detuneA',
			label = 'detune A',
			neutral_value = 0.5,
			default = 0
		},
		{
			name = 'indexA',
			label = 'index A',
			mode_param = 'opTypeA',
			modes = { 'fm', 'fb', 'sp', 'wv' },
			default = -1,
			source_defaults = {
				amp = 0.2
			}
		},
		{
			name = 'opMix',
			label = 'mix A:B',
			neutral_value = 0.5,
			default = -1
		},
		{
			name = 'ratioB',
			label = 'ratio B',
			mode_param = 'opHardB',
			modes = { 'soft', 'hard' },
			default = -0.25 -- 2/1 (5th out of 12 harmonics)
		},
		{
			name = 'detuneB',
			label = 'detune B',
			neutral_value = 0.5,
			default = 0
		},
		{
			name = 'indexB',
			label = 'index B',
			mode_param = 'opTypeB',
			modes = { 'fm', 'fb', 'sp', 'wv' },
			default = -1,
			source_defaults = {
				amp = 0.2
			},
			has_divider = true
		},
		{
			name = 'fxA',
			label = 'fx A',
			mode_param = 'fxTypeA',
			modes = { 'squiz', 'tanh' },
			default = -1
		},
		{
			name = 'fxB',
			label = 'fx B',
			mode_param = 'fxTypeB',
			modes = { 'loss', 'chorus' },
			default = -1
		},
		{
			name = 'hpCutoff',
			label = 'hp cutoff',
			mode_param = 'hpQ',
			modes = { 'lo', 'mid', 'hi' },
			mode_values = { 1, 1.414, 5 },
			default = -1
		},
		{
			name = 'lpCutoff',
			label = 'lp cutoff',
			neutral_value = 1,
			mode_param = 'lpQ',
			modes = { 'lo', 'mid', 'hi' },
			mode_values = { 1, 1.414, 5 },
			default = 0.8,
			source_defaults = {
				amp = 0.2
			},
			has_divider = true
		},
		{
			name = 'attack',
			label = 'attack',
			mode_param = 'amp_mode',
			modes = { 'mod', '*', 'amp' },
			default = 0
		},
		{
			name = 'release',
			label = 'release',
			mode_param = 'eg_type',
			modes = { 'gate', 'trig' },
			default = 0,
			has_divider = true
		},
		{
			name = 'lfoAFreq',
			label = 'lfo a',
			mode_param = 'lfoTypeA',
			modes = { 'tri', 'sy', 'rx', 'd', '/' },
			default = 0
		},
		{
			name = 'lfoBFreq',
			label = 'lfo b',
			mode_param = 'lfoTypeB',
			modes = { 'tri', 'sy', 'rx', 'd', '/' },
			default = -0.2
		},
		{
			name = 'lfoCFreq',
			label = 'lfo c',
			mode_param = 'lfoTypeC',
			modes = { 'tri', 'sy', 'rx', 'd', '/' },
			default = -0.4,
			has_divider = true
		},
		{
			name = 'loopRate',
			label = 'loop rate',
			neutral_value = 0.5,
			voice_param = 'loopRate',
			voice_dest = true
		},
		{
			name = 'loopPosition',
			label = 'loop position',
			neutral_value = 0.5,
			voice_param = 'loopPosition',
			voice_dest = true
		},
		{
			name = 'pan',
			label = 'pan',
			neutral_value = 0.5,
			voice_param = 'pan'
		},
		{
			name = 'amp',
			label = 'amp',
			neutral_value = 0.5,
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

patch_param_mappings = {
	-- [dest number] = slider mapping
}
voice_param_mappings = {
	-- [dest number][voice index] = slider mapping
}
patch_mod_mappings = {
	-- [dest number][source number] = slider mapping
}
voice_mod_mappings = {
	-- [dest number][source number][voice index] = slider mapping
}

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
		loop_playing = false,
		loop_length = 0,
		loop_play_next = false,
		loop_record_started = false,
		loop_record_next = false,
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

arp_divs = { 1/2, 3/8, 1/4, 3/16, 1/8, 1/12, 1/16, 1/24, 1/32 }
arp_gates = {}
arp_gates_inverted = {}
arp_lattice = Lattice.new {
	ppqn = 24 -- this is all the resolution we need for the divisions above
}
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
			if arp_gates[d] then
				handle_synced_voice_loops()
			end
			k:arp(arp_gates[d])
		end
	end
end
-- update peer count and sync SC clock every quarter note
arp_lattice:new_sprocket {
	division = 1/4,
	action = function()
		engine.downbeat()
		link_peers = clock.link.get_number_of_peers()
	end
}

clock.transport.start = function()
	arp_lattice:hard_restart()
end

function voice_loop_clear(v)
	local voice = voice_states[v]
	if not voice.loop_playing then
		return
	end
	engine.clearLoop(v)
	params:lookup_param('loopRate_' .. v):set_default()
	params:lookup_param('loopPosition_' .. v):set_default()
	for s = 1, #editor.source_names do
		params:lookup_param(editor.source_names[s] .. '_loopRate_' .. v):set_default()
		params:lookup_param(editor.source_names[s] .. '_loopPosition_' .. v):set_default()
	end
	voice.loop_playing = false
	voice.loop_length = 0
	-- clear pitch shift, because it only confuses things when loop isn't engaged
	voice.shift = 0
	engine.shift(v, 0)
end

function voice_loop_record(v)
	-- start recording (set loop start time here)
	local voice = voice_states[v]
	if k.arping then
		voice.loop_record_next = true
	else
		voice.loop_record_started = util.time()
	end
end

function voice_loop_play(v)
	local voice = voice_states[v]
	-- TODO: limit loop length on Lua side by auto-stopping recording
	local length = (util.time() - voice.loop_record_started) / clock.get_beat_sec()
	local div = 0
	-- round to appropriate beat division
	local div_index = arp_menu.value
	-- TODO NEXT: do something special to handle clocking by synced LFOs:
	-- send the computed tempo multiple from LFO synth to a poll?
	if div_index and div_index <= #arp_divs then
		-- arp_divs are in measures, we need beats
		div = arp_divs[div_index] * 4
	end
	engine.playLoop(v, length, div)
	params:lookup_param('loopRate_' .. v):set_default()
	params:lookup_param('loopPosition_' .. v):set_default()
	voice.loop_playing = true
	voice.loop_record_started = false
	voice.loop_length = length
end

function voice_loop_set_end(v)
	-- stop recording, start looping
	local voice = voice_states[v]
	if k.arping then
		voice.loop_play_next = true
	else
		voice_loop_play(v, false)
	end
end

function g.key(x, y, z)
	local handled = false
	-- special-case keys
	-- TODO: incorporate these into new or existing grid controls
	if z == 1 then
		if x == 6 and y == 8 then
			k.stepper:toggle()
			arp_menu:close()
			arp_direction_menu:close()
			source_menu:close()
			handled = true
		elseif x == 7 and y == 8 then
			arp_menu:toggle()
			if arp_menu.is_open then
				arp_direction_menu:open()
			else
				arp_direction_menu:close()
			end
			k.stepper:close()
			source_menu:close()
			handled = true
		elseif x == 9 and y == 8 then
			source_menu:toggle()
			arp_menu:close()
			arp_direction_menu:close()
			k.stepper:close()
			handled = true
		elseif arp_menu.is_open and y == 3 and z == 1 then
			-- TODO NEXT: handle nudges by less than 1 ppq
			if x == 12 then
				-- nudge back: pause for one pulse worth of time
				clock.run(function()
					arp_lattice:stop()
					clock.sleep(clock.get_beat_sec() / arp_lattice.ppqn)
					arp_lattice:start()
				end)
			elseif x == 13 then
				-- nudge forward: skip forward by one pulse, instantaneously
				arp_lattice:pulse()
			elseif x == 15 then
				-- nudge tempo down
				params:set('clock_tempo', params:get('clock_tempo') / 1.04)
			elseif x == 16 then
				-- nudge tempo up
				params:set('clock_tempo', params:get('clock_tempo') * 1.04)
			end
			handled = true
		elseif x == 1 and y == 1 and source_menu.is_open and (source_menu.n_held > 0 or held_keys[1]) then
			-- mod reset key
			-- TODO: move this into a :delete_key() handler
			if source_menu.n_held > 0 then
				-- if there are any held sources, reset all routes involving them
				for source = 1, #editor.source_names do
					if source_menu.held_values[source] then
						local source_name = editor.source_names[source]
						for d = 1, #editor.dests do
							local dest = editor.dests[d]
							local dest_name = dest.name
							if dest.voice_dest then
								dest_name = dest_name .. '_' .. k.selected_voice
							end
							local defaults = dest.source_defaults
							local param = params:lookup_param(source_name .. '_' .. dest_name)
							if defaults and defaults[source_name] then
								param:set(defaults[source_name])
							else
								param:set_default()
							end
						end
					end
				end
				handled = true
			end
			if held_keys[1] then
				-- if K1 is held, reset all routes involving the selected dest
				local dest = editor.dests[editor.selected_dest]
				local dest_name = dest.name
				if dest.voice_dest then
					dest_name = dest_name .. '_' .. k.selected_voice
				end
				local defaults = dest.source_defaults
				for source = 1, #editor.source_names do
					local source_name = editor.source_names[source]
					local param_name = source_name .. '_' .. dest_name
					local param = params:lookup_param(param_name)
					if defaults and defaults[source_name] then
						param:set(defaults[source_name])
					else
						param:set_default()
					end
				end
				handled = true
			end
		end
	end
	-- if any menus or other controls are open, see if those will handle the key
	local c = 1
	while not handled and c <= #grid_controls do
		handled = grid_controls[c]:key(x, y, z, k.held_keys.shift)
		c = c + 1
	end
	-- last stop: keyboard handles all other key events
	if not handled then
		k:key(x, y, z)
	end
	grid_redraw()
	screen.ping()
end

function send_pitch()
	engine.pitch(k.active_pitch, k.bent_pitch - k.active_pitch)
end

-- TODO: debounce here
function grid_redraw()
	g:all(0)
	k:draw()
	if arp_menu.is_open or arp_direction_menu.is_open or source_menu.is_open then
		for x = 3, 16 do
			for y = 1, 7 do
				g:led(x, y, 0)
			end
		end
	end
	if k.stepper.is_open then
		g:led(6, 8, 15)
	else
		local level = 2
		if arp_menu.value then
			level = 5
			if k.stack[k.arp_index] and k.stack[k.arp_index].gate then
				level = level + 2
			end
		end
		g:led(6, 8, level)
	end
	k.stepper:draw()
	if arp_menu.is_open then
		g:led(7, 8, 15)
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
		g:led(7, 8, level)
	else
		-- no source selected; go dark
		g:led(7, 8, 2)
	end
	arp_menu:draw()
	arp_direction_menu:draw()
	if arp_menu.is_open then
		-- lattice phase nudge keys
		g:led(12, 3, 5)
		g:led(13, 3, 5)
		-- tempo nudge keys
		g:led(15, 3, 4)
		g:led(16, 3, 4)
	end
	g:led(9, 8, source_menu.is_open and 7 or 2)
	source_menu:draw()
	if source_menu.is_open and (source_menu.n_held > 0 or held_keys[1]) then
		g:led(1, 1, 7)
	end
	local blink = arp_gates[5] -- 1/8 notes
	for v = 1, n_voices do
		local voice = voice_states[v]
		local level = voice.amp
		if voice.loop_record_next then
			level = level * 0.5 + (blink and 0.2 or 0)
		elseif voice.loop_play_next then
			level = level * 0.5 + (blink and 0.35 or 0.25)
		elseif voice.loop_record_started then
			level = level * 0.5 + (blink and 0.5 or 0)
		elseif voice.loop_playing then
			level = level * 0.75 + 0.25
		end
		level = math.floor(level * 15)
		g:led(1, 8 - v, level)
	end
	g:refresh()
end

function handle_synced_voice_loops(immediate)
	-- if we're playing a sequence straight (not randomized order),
	-- wait until the first step to either start or stop
	if not immediate and k.arp_direction == 1 and k.arp_index > 1 then
		-- TODO NEXT: in this situation, switching the selected voice should ALSO be delayed!
		-- or something else needs to happen to ensure that we're still
		-- sending user input to the voice that's actually recording
		return
	end
	for v = 1, n_voices do
		local voice = voice_states[v]
		if voice.loop_record_next then
			-- get ready to loop (set loop start time here)
			voice.loop_record_started = util.time()
			voice.loop_record_next = false
		elseif voice.loop_play_next then
			-- start looping
			voice_loop_play(v)
			voice.loop_playing = true
			voice.loop_play_next = false
			voice.loop_record_started = false
			-- stop arpeggiating!
			arp_menu:select(false)
			k.held_keys.latch = false
			k:maybe_clear_stack()
		end
	end
end

function init()

	norns.enc.accel(1, false)
	norns.enc.sens(1, 8)

	k.on_select_voice = function(v)
		-- if any other voice is recording, stop recording & start looping it
		for ov = 1, n_voices do
			if ov ~= v and voice_states[ov].loop_record_started then
				voice_loop_set_end(ov)
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

	k.on_stack_change = function()
		engine.heldKeys(#k.stack)
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
						if gate then
							handle_synced_voice_loops()
						end
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
		options = { 'FM', 'FB', 'rompler', 'raw' --[[, 'saw', 'pluck', 'comb', 'comb ext' ]] },
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
			set_dest_mode('indexA', value)
		end
	}

	params:add {
		name = 'op hard A',
		id = 'opHardA',
		type = 'option',
		options = { 'no', 'yes' },
		default = 1,
		action = function(value)
			engine.opHardA(value - 1)
			set_dest_mode('ratioA', value)
		end
	}

	params:add {
		name = 'op type B',
		id = 'opTypeB',
		type = 'option',
		options = { 'FM', 'FB', 'rompler', 'raw' --[[, 'saw', 'pluck', 'comb', 'comb ext' ]] },
		default = 2,
		action = function(value)
			local raw_value = value
			if value == 1 then
				engine.opTypeB(8) -- and use delayed FM for FM
			else
				engine.opTypeB(value - 1)
			end
			if value == 3 then
				editor.dests[7].source_defaults.amp = 0
				params:set('amp_indexB', 0)
			else
				editor.dests[7].source_defaults.amp = 0.2
				params:set('amp_indexB', 0.2)
			end
			set_dest_mode('indexB', raw_value)
		end
	}

	params:add {
		name = 'op hard B',
		id = 'opHardB',
		type = 'option',
		options = { 'no', 'yes' },
		default = 1,
		action = function(value)
			engine.opHardB(value - 1)
			set_dest_mode('ratioB', value)
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
			set_dest_mode('fxA', value)
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
			set_dest_mode('fxB', value)
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
			set_dest_mode('lfoAFreq', value)
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
			set_dest_mode('lfoBFreq', value)
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
			set_dest_mode('lfoCFreq', value)
		end
	}

	echo:add_params()

	params:add_group('filter settings', 2)

	params:add {
		name = 'lp q',
		id = 'lpQ',
		type = 'control',
		controlspec = controlspec.new(1, 5, 'exp', 0, 1.414),
		action = function(value)
			engine.lpRQ(1 / value)
			set_dest_mode('lpCutoff', value <= 1.25 and 1 or (value <= 2.5 and 2 or 3))
		end
	}

	params:add {
		name = 'hp q',
		id = 'hpQ',
		type = 'control',
		controlspec = controlspec.new(1, 5, 'exp', 0, 1.414),
		action = function(value)
			engine.hpRQ(1 / value)
			set_dest_mode('hpCutoff', value <= 1.25 and 1 or (value <= 2.5 and 2 or 3))
		end
	}

	params:add_group('patch params', #editor.dests - 9)

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
				controlspec = controlspec.new(0.001, 7, 'exp', 0, 0.003, 's'),
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
					set_dest_mode('release', value)
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
					set_dest_mode('attack', value)
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

		-- create a dead zone near 0.0
		local scale_value = function(value, squared)
			local sign = (value > 0 and 1 or -1)
			value = 1 - math.min(1, (1 - math.abs(value)) * 1.1)
			if squared then
				-- create a less-sensitive zone around the dead zone
				value = value * value
			end
			return sign * value
		end

		for d = 1, #editor.dests do
			local dest = editor.dests[d]
			local engine_command = engine[source .. '_' .. dest.name]
			if dest.voice_dest then
				for v = 1, n_voices do
					local action = function(value)
						engine_command(v, scale_value(value))
					end
					params:add {
						name = source .. ' -> ' .. dest.label .. ' ' .. v,
						id = source .. '_' .. dest.name .. '_' .. v,
						type = 'control',
						controlspec = controlspec.new(-1, 1, 'lin', 0, (dest.source_defaults and dest.source_defaults[source]) or 0),
						action = action
					}
				end
			else
				local action = function(value)
					engine_command(scale_value(value))
				end
				if dest.name == 'detuneA' or dest.name == 'detuneB' then
					-- set detune modulation on a curve
					action = function(value)
						engine_command(scale_value(value, true))
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
			default = 0.269,
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
				engine.loopRate(v, value)
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
		local neutral_value = dest.neutral_value or 0
		if dest.voice_param then
			local voice_param = dest.voice_param
			local mappings = {}
			for v = 1, n_voices do
				mappings[v] = SliderMapping.new(voice_param .. '_' .. v, neutral_value, 'primary')
			end
			voice_param_mappings[d] = mappings
		else
			patch_param_mappings[d] = SliderMapping.new(dest_name, neutral_value, 'primary')
		end
		if dest.voice_dest then
			voice_mod_mappings[d] = {}
		else
			patch_mod_mappings[d] = {}
		end
		for s = 1, #editor.source_names do
			if dest.voice_dest then
				local mappings = {}
				for v = 1, n_voices do
					mappings[v] = SliderMapping.new(editor.source_names[s] .. '_' .. dest_name .. '_' .. v, 0.5, 'secondary')
				end
				voice_mod_mappings[d][s] = mappings
			else
				patch_mod_mappings[d][s] = SliderMapping.new(editor.source_names[s] .. '_' .. dest_name, 0.5, 'secondary')
			end
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

	clock.run(function()
		clock.sync(4)
		arp_lattice:start()
	end)

	redraw_metro = metro.init {
		time = 1 / 30,
		event = function(n)
			-- calculate slider positions on screen
			local y = 66
			for p = 1, editor.selected_dest - 1 do
				if editor.dests[p].has_divider then
					y = y - 18
				else
					y = y - 14
				end
			end
			for p = 1, #editor.dests do
				local dest = editor.dests[p]
				local slider = nil
				if dest.voice_param then
					slider = voice_param_mappings[p][k.selected_voice].slider
				elseif patch_param_mappings[p] then
					slider = patch_param_mappings[p].slider
				end
				if slider.y ~= y then
					slider.y = math.floor(slider.y + (y - slider.y) * 0.6)
				end
				if dest.has_divider then
					y = y + 18
				else
					y = y + 14
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
				k:bend(-math.min(1, message.val / 126))
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
				if source_menu.held_values[source] then
					patch_mod_mappings[fader][source]:delta(new_value - old_value)
					changed_source = true
				end
			end
			if not changed_source then
				patch_param_mappings[fader]:move(old_value, new_value)
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
					print('autoselect by fader', fader)
				end
			end
			screen.ping()
		elseif message.type == 'cc' then
			local button = message.ch
			local dest = editor.dests[button]
			if dest.mode_param then
				local new_mode = dest.mode % #dest.modes + 1
				if dest.mode_values then
					params:set(dest.mode_param, dest.mode_values[new_mode])
				else
					params:set(dest.mode_param, new_mode)
				end
			end
			screen.ping()
		end
	end

	edrum = midi_devices_by_name['eDrumIn BLACK'] or {}
	function edrum.event(data)
		if arp_menu.value == 14 then
			local message = midi.to_msg(data)
			if message.type == 'note_on' then
				k:arp(true)
			elseif message.type == 'note_off' then
				k:arp(false)
			end
		end
	end

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
			clock.sleep(0.1) -- TODO: fine tune rate
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

	-- inform SC of future tempo changes
	clock.tempo_change_handler = function(tempo)
		engine.beatSec(clock.get_beat_sec())
	end
	-- set initial tempo
	-- TODO: this still doesn't seem to work consistently...
	-- engine often seems to think the tempo is different on script start.
	-- there must be a race condition somewhere...
	engine.beatSec(clock.get_beat_sec())

	grid_redraw()
end

function ampdb(amp)
	return math.log(amp) / 0.05 / math.log(10)
end

function set_dest_mode(dest_name, mode)
	for d = 1, #editor.dests do
		if editor.dests[d].name == dest_name then
			editor.dests[d].mode = mode
			editor.selected_dest = d
			editor.autoselect_time = util.time()
			print('autoselect by dest mode', dest_name)
			return
		end
	end
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
			dest_slider = voice_param_mappings[d][k.selected_voice].slider
		else
			dest_slider = patch_param_mappings[d].slider
		end

		if dest_slider.y >= -4 and dest_slider.y <= 132 then

			if (dest.name == 'loopRate' or dest.name == 'loopPosition') and not voice.loop_playing then
				-- draw blank dummy sliders for loop controls when not looping
				dest_slider:redraw(1, 0)
			else
				local source_slider
				if dest.voice_dest then
					source_slider = voice_mod_mappings[d][source_menu.value][k.selected_voice].slider
				else
					source_slider = patch_mod_mappings[d][source_menu.value].slider
				end
				source_slider.y = dest_slider.y + 1

				local source_level = (source_slider.value == source_slider.neutral_value) and 0 or 2
				local dest_level = active and 15 or 4
				if d <= 16 then
					local xvi_value = xvi_state[d].value
					if xvi_value and not (xvi_value == dest_slider.value) then
						dest_slider:draw_point(xvi_value, dest_level)
						dest_level = 4
					end
				else
				end
				if source_menu.n_held > 0 then
					source_level = active and 15 or 4
					dest_level = 2
				end
				source_slider:redraw(0, source_level)
				dest_slider:redraw(1, dest_level)
			end

			screen.level(active and 10 or 1)
			screen.move(0, dest_slider.y - 3)
			screen.text(dest.label:upper())
			if dest.modes then
				local mode = dest.mode or 1
				screen.move_rel(2, 0)
				for m = 1, #dest.modes do
					local this_mode = (m == mode)
					screen.level(active and (this_mode and 10 or 1) or (this_mode and 1 or 0))
					screen.text(dest.modes[m])
					screen.move_rel(2, 0)
				end
			end
			screen.stroke()
		end
	end

	screen.rect(0, 0, 64, 8)
	screen.level(0)
	screen.fill()

	screen.level(3)
	screen.move(0, 5)
	if arp_menu.is_open then
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
		local param_index = 15 + n -- n>=2 and voice params start at dest index 17
		if not held_keys[2] then
			param_index = param_index + 2
		end
		local changed_source = false
		-- params 17 and 18 are loop-related, so don't modify them unless a loop is playing
		if param_index >= 19 or voice_states[k.selected_voice].loop_playing then
			local d_scaled
			-- if modifying loop position, scale according to loop length
			if editor.dests[param_index].name == 'loopPosition' then
				d_scaled = d / math.max(1, voice_states[k.selected_voice].loop_length) / 8
			else
				d_scaled = d / 128
			end
			for source = 1, #editor.source_names do
				if source_menu.held_values[source] then
					if editor.dests[param_index].voice_dest then
						voice_mod_mappings[param_index][source][k.selected_voice]:delta(d_scaled)
					else
						patch_mod_mappings[param_index][source]:delta(d_scaled)
					end
					changed_source = true
				end
			end
			if not changed_source then
				voice_param_mappings[param_index][k.selected_voice]:delta(d_scaled)
			end
		end
		-- maybe auto-select the affected dest
		local now = util.time()
		editor.encoder_autoselect_deltas[n] = editor.encoder_autoselect_deltas[n] + math.abs(d)
		if editor.selected_dest == param_index then
			editor.autoselect_time = now
			editor.encoder_autoselect_deltas[n] = 0
		else
			local t = math.min(0.3, now - editor.autoselect_time) / 0.3
			if editor.encoder_autoselect_deltas[n] * t > 0.05 then
				editor.encoder_autoselect_deltas[n] = 0
				editor.selected_dest = param_index
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
			for v = 1, n_voices do
				if k.held_keys.voices[v] then
					local voice_state = voice_states[v]
					local lock = not voice_state.timbre_lock
					engine.timbreLock(v, lock and 1 or 0)
					voice_state.timbre_lock = lock
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
	if uc4 then
		for n = 12, 19 do
			uc4:note_off(n)
		end
	end
end
