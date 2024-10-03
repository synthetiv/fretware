-- hi

engine.name = 'Cule'
musicutil = require 'musicutil'

Slider = include 'lib/slider'

n_voices = 6

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

Menu = include 'lib/menu'

arp_menu = Menu.new(6, 6, 6, 2)
arp_menu.toggle = true
arp_menu.on_select = function(source)
	-- enable arp when a source is selected, disable when toggled off
	if source and not k.arping then
		k.arping = true
	elseif not source then
		k.arping = false
	end
end
arp_menu.get_key_level = function(value, selected)
	local level = 0
	if value <= 6 then
		if arp_clocks[value].gate then
			level = 2
		end
	elseif voice_states[k.selected_voice][lfo_gate_names[value - 6]] then
		level = 2
	end
	return level + (selected and 11 or 4)
end

arp_direction_menu = Menu.new(6, 4, 6, 1)
arp_direction_menu.on_select = function(value)
	params:set('arp_randomness', (value - 1) / 5 * 100)
end
arp_direction_menu.selected = 1 -- param doesn't exist yet

source_menu = Menu.new(3, 6, 14, 2, {
	-- map of source numbers (in editor.source_names) to keys
	 _,  2,  _,  _,  3,  _,  4,  5,  6,  _,  _,  _,  _,  1,
	 _,  _,  _,  _,  _,  _,  7,  8,  9,  _,  _,  _,  _,  _,
})
source_menu:select(1)
source_menu.get_key_level = function(value, selected, held)
	local level = 0
	if value == 1 then
		level = voice_states[k.selected_voice].amp >= 0.1 and 2 or 0
	elseif value == 2 then
		-- TODO: hand
	elseif value == 3 then
		-- TODO: env
	else
		level = voice_states[k.selected_voice][lfo_gate_names[value - 3]] and 2 or 0
	end
	return level + (held and 11 or 4)
end

dest_menu = Menu.new(3, 3, 14, 3, {
	-- map of dest numbers (in editor.dests) to keys
	 1,  2,  3,  _,  4,  _,  5,  6,  7,  _,  8,  9, 10, 11,
	 _,  _,  _,  _,  _,  _,  _,  _,  _,  _,  _,  _,  _,  _,
	 _,  _,  _, 12, 13,  _, 14, 15, 16,  _,  _, 17,  _, 18,
})
dest_menu:select(1)
dest_menu.get_key_level = function(value, selected, held)
	local level = 0
	local source_name = editor.source_names[source_menu.value]
	local dest = editor.dests[value]
	local mod_amount = params:get(source_name .. '_' .. dest.name)
	level = (math.abs(mod_amount) >= 0.1) and 3 or 0
	return level + (held and 11 or 3)
end

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
		'lfoC',
		'lfoAB',
		'lfoBC',
		'lfoCA'
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
			name = 'fmIndex',
			label = 'fm index',
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
			name = 'fbB',
			label = 'feedback B',
			default = -1,
			has_divider = true
		},
		{
			name = 'squiz',
			label = 'squiz',
			default = -1
		},
		{
			name = 'loss',
			label = 'loss',
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
	held_keys = {
		inc = false,
		dec = false
	}
}

dest_sliders = {
	ratioA   = Slider.new(82, 8, 2, 55),
	detuneA  = Slider.new(101, 8, 2, 55, 0),
	fmIndex  = Slider.new(120, 8, 2, 55),

	opMix    = Slider.new(196, 8, 2, 55, 0),

	ratioB   = Slider.new(139, 8, 2, 55),
	detuneB  = Slider.new(158, 8, 2, 55, 0),
	fbB      = Slider.new(177, 8, 2, 55),

	squiz    = Slider.new(215, 8, 2, 55),
	loss     = Slider.new(234, 8, 2, 55),
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
		amp   = Slider.new(82, 7, 4, 57, 0),
		hand  = Slider.new(82, 7, 4, 57, 0),
		eg    = Slider.new(82, 7, 4, 57, 0),
		lfoA  = Slider.new(82, 7, 4, 57, 0),
		lfoB  = Slider.new(82, 7, 4, 57, 0),
		lfoC  = Slider.new(82, 7, 4, 57, 0),
		lfoAB = Slider.new(82, 7, 4, 57, 0),
		lfoBC = Slider.new(82, 7, 4, 57, 0),
		lfoCA = Slider.new(82, 7, 4, 57, 0)
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
		lfoC_gate = false,
		lfoAB_gate = false,
		lfoBC_gate = false,
		lfoCA_gate = false,
		polls = {},
	}
end

lfo_gate_names = {
	'lfoA_gate',
	'lfoB_gate',
	'lfoC_gate',
	'lfoAB_gate',
	'lfoBC_gate',
	'lfoCA_gate'
}

tip = 0
palm = 0
expo_scaling = false
gate_in = false

arp_divs = { 1, 3/4, 1/2, 3/8, 1/4, 1/8 }
arp_clocks = {}
for d = 1, #arp_divs do
	local rate = arp_divs[d]
	local arp_clock = {}
	arp_clock.coro = clock.run(function()
		while true do
			clock.sync(rate)
			arp_clock.gate = true
			if arp_menu.value == d then
				k:arp(true)
			end
			clock.sync(rate / 2)
			arp_clock.gate = false
			if arp_menu.value == d then
				k:arp(false)
			end
		end
	end)
	arp_clocks[d] = arp_clock
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
	if x == 6 and y == 8 then
		-- TODO: this could lead to stuck keys, since the menu will steal key input from the
		-- keyboard. how could you work around that? examine keyboard's held keys and give
		-- first priority in key handler to keyboard keyoffs, then menu keyon, then keyboard
		-- keyon?
		if z == 1 then
			arp_menu.open = true
			arp_direction_menu.open = true
			source_menu.open = false
			dest_menu.open = false
		else
			arp_menu.open = false
			arp_direction_menu.open = false
		end
	elseif x == 9 and y == 8 then
		if z == 1 then
			source_menu.open = not source_menu.open
			dest_menu.open = source_menu.open
			arp_menu.open = false
			arp_direction_menu.open = false
		end
	elseif arp_menu.open then
		if not arp_direction_menu:key(x, y, z) then
			arp_menu:key(x, y, z)
		end
	elseif source_menu.open then
		if y == 1 and x >= 15 then
			editor.held_keys[x == 16 and 'inc' or 'dec'] = z == 1
			if z == 1 then
				local do_reset = editor.held_keys.dec and editor.held_keys.inc
				local did_reset_route = false
				local delta = (x - 15) * 2 - 1
				for source = 1, #editor.source_names do
					if source_menu.held[source] then
						local source_name = editor.source_names[source]
						for dest = 1, #editor.dests do
							if dest_menu.held[dest] then
								local dest_name = editor.dests[dest].name
								if do_reset then
									params:lookup_param(source_name .. '_' .. dest_name):set_default()
									did_reset_route = true
								else
									params:delta(source_name .. '_' .. dest_name, delta * 10)
								end
							end
						end
					end
				end
				if do_reset and not did_reset_route then
					for source = 1, #editor.source_names do
						if source_menu.held[source] then
							local source_name = editor.source_names[source]
							for dest = 1, #editor.dests do
								local dest_name = editor.dests[dest].name
								params:lookup_param(source_name .. '_' .. dest_name):set_default()
							end
						end
					end
					for dest = 1, #editor.dests do
						if dest_menu.held[dest] then
							local dest_name = editor.dests[dest].name
							for source = 1, #editor.source_names do
								local source_name = editor.source_names[source]
								params:lookup_param(source_name .. '_' .. dest_name):set_default()
							end
						end
					end
				end
			end
		elseif not source_menu:key(x, y, z) then
			dest_menu:key(x, y, z)
		end
	else
		k:key(x, y, z)
	end
	-- TODO: sync the whole note stack with TT
	-- I think you'll need to trigger events from the keyboard class, and... urgh...
	-- it's more information than you can easily send to TT
	grid_redraw()
	screen.ping()
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
	if arp_menu.open or arp_direction_menu.open or source_menu.open or dest_menu.open then
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
		if v <= 6 then
			if arp_clocks[v].gate then
				level = level + 2
			end
		elseif voice_states[k.selected_voice][lfo_gate_names[v - 6]] then
			level = level + 2
		end
		g:led(6, 8, level)
	else
		-- no source selected; go dark
		g:led(6, 8, 2)
	end
	arp_menu:draw()
	arp_direction_menu:draw()
	g:led(9, 8, source_menu.open and 7 or 2)
	source_menu:draw()
	dest_menu:draw()
	if source_menu.open then
		g:led(15, 1, editor.held_keys.dec and 15 or 2)
		g:led(16, 1, editor.held_keys.inc and 15 or 2)
	end
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
-- 		if arp_menu.value == ?? and k.n_sustained_keys > 0 then
-- 			k:arp(gate)
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
	norns.enc.accel(2, false)
	norns.enc.sens(2, 8)

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
		dest_sliders.amp:set_value(params:get_raw('outLevel_' .. v) * 2 - 1)
		dest_sliders.pan:set_value(params:get_raw('pan_' .. v) * 2 - 1)
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

	params:add_group('tuning', 7)

	-- TODO: add params for tt and crow transposition
	-- ...and yeah, control from keyboard. you'll want that again

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
		name = 'harmonic fade size A',
		id = 'fadeSizeA',
		type = 'control',
		controlspec = controlspec.new(0.01, 1, 'lin', 0, 0.8),
		action = function(value)
			engine.fadeSizeA(value)
		end
	}

	params:add {
		name = 'harmonic fade size B',
		id = 'fadeSizeB',
		type = 'control',
		controlspec = controlspec.new(0.01, 1, 'lin', 0, 0.8),
		action = function(value)
			engine.fadeSizeB(value)
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
		name = 'lp on',
		id = 'lpOn',
		type = 'option',
		options = { 'off', 'on' },
		default = 2,
		action = function(value)
			engine.lpOn(value - 1)
		end
	}

	params:add {
		name = 'lp q',
		id = 'lpQ',
		type = 'control',
		controlspec = controlspec.new(1, 5, 'exp', 0, 1.414),
		action = function(value)
			engine.lpQ(value)
		end
	}

	params:add {
		name = 'hp on',
		id = 'hpOn',
		type = 'option',
		options = { 'off', 'on' },
		default = 2,
		action = function(value)
			engine.hpOn(value - 1)
		end
	}

	params:add {
		name = 'hp q',
		id = 'hpQ',
		type = 'control',
		controlspec = controlspec.new(1, 5, 'exp', 0, 1.414),
		action = function(value)
			engine.hpQ(value)
		end
	}

	params:add_group('eg settings', 3)

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
				controlspec = controlspec.new(0.001, 3, 'exp', 0, 0.001, 's'),
				action = function(value)
					dest_sliders.attack:set_value(params:get_raw('attack') * 2 - 1)
					engine.attack(value)
				end
			}
			params:add {
				name = 'release',
				id = 'release',
				type = 'control',
				controlspec = controlspec.new(0.001, 12, 'exp', 0, 1, 's'),
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
			params:add {
				name = source .. ' -> ' .. dest.label,
				id = source .. '_' .. dest.name,
				type = 'control',
				controlspec = controlspec.new(-1, 1, 'lin', 0, (dest.source_defaults and dest.source_defaults[source]) or 0),
				action = function(value)
					source_sliders[dest.name][source]:set_value(value)
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
					dest_sliders.amp:set_value(params:get_raw('outLevel_' .. v) * 2 - 1)
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
					dest_sliders.pan:set_value(params:get_raw('pan_' .. v) * 2 - 1)
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
	params:set('cut_input_eng', -8) -- feed echo from internal synth (this can also be MIDI mapped)
	params:set('cut_input_tape', -math.huge) -- do NOT feed echo from tape
	params:set('monitor_level', -math.huge) -- monitor off (ext. echo fully wet)

	reset_loop_clock()

	redraw_metro = metro.init {
		time = 1 / 30,
		event = function(n)
			blink = (n % 7 < 3)
			local x = 82
			for p = 1, dest_menu.value do
				local dest = editor.dests[p]
				if dest.has_divider then
					x = x - 23
				else
					x = x - 16
				end
			end
			for p = 1, #editor.dests do
				local dest = editor.dests[p]
				local slider = dest_sliders[dest.name]
				if slider.x ~= x then
					slider.x = math.floor(slider.x + (x - slider.x) * 0.6)
				end
				if dest.has_divider then
					x = x + 23
				else
					x = x + 16
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

	local midi_devices_by_name = {}
	for vport = 1, #midi.vports do
		local device = midi.connect(vport)
		midi_devices_by_name[device.name] = device
	end
	touche = midi_devices_by_name['TOUCHE 1'] or {}
	xvi = midi_devices_by_name['MiSW XVIM'] or {}
	uc4 = midi_devices_by_name['Faderfox UC4'] or {}

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

	function xvi.event(data)
		-- when k2 is held and a fader is moved, select that parameter for editing
		if held_keys[2] then
			local message = midi.to_msg(data)
			if message.cc == 9 then -- fader moved
				dest_menu:select_value(message.ch)
			end
		end
	end

	function uc4.event(data)
		local message = midi.to_msg(data)
		if message.ch == 1 then
			if message.type == 'note_on' then
				if message.note == 12 then
					if params:get('echo_jump_trigger') == 2 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 2)
						uc4:note_on(message.note, 127)
					end
				elseif message.note == 13 then
					if params:get('echo_jump_trigger') == 3 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 3)
						uc4:note_on(message.note, 127)
					end
				elseif message.note == 14 then
					if params:get('echo_jump_trigger') == 4 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 4)
						uc4:note_on(message.note, 127)
					end
				elseif message.note == 15 then
					if params:get('echo_jump_trigger') == 5 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 5)
						uc4:note_on(message.note, 127)
					end
				elseif message.note == 16 then
					if params:get('echo_jump_trigger') == 6 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 6)
						uc4:note_on(message.note, 127)
					end
				elseif message.note == 17 then
					if params:get('echo_jump_trigger') == 7 then
						params:set('echo_jump_trigger', 1)
					else
						params:set('echo_jump_trigger', 7)
						uc4:note_on(message.note, 127)
					end
				elseif message.note == 18 or message.note == 19 then
					params:set('echo_jump_trigger', 1)
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

	-- TODO: icons
	
	local voice = voice_states[k.selected_voice]
	local source_name = editor.source_names[source_menu.value]

	screen.level('amp' == source_name and 15 or 3)
	screen.move(0, 5)
	screen.text('Am')

	screen.level('hand' == source_name and 15 or 3)
	screen.move_rel(4, 0)
	screen.text('Hd')

	screen.level('eg' == source_name and 15 or 3)
	screen.move_rel(4, 0)
	screen.text('En')

	screen.level('lfoA' == source_name and 15 or 3)
	screen.move_rel(4, 0)
	screen.text('La')
	screen.level(voice.lfoA_gate and 15 or 3)
	screen.text('.')

	screen.level('lfoB' == source_name and 15 or 3)
	screen.move_rel(4, 0)
	screen.text('Lb')
	screen.level(voice.lfoB_gate and 15 or 3)
	screen.text('.')

	screen.level('lfoC' == source_name and 15 or 3)
	screen.move_rel(4, 0)
	screen.text('Lc')
	screen.level(voice.lfoC_gate and 15 or 3)
	screen.text('.')

	screen.level('lfoAB' == source_name and 15 or 3)
	screen.move_rel(4, 0)
	screen.text('Ab')
	screen.level(voice.lfoAB_gate and 15 or 3)
	screen.text('.')

	screen.level('lfoBC' == source_name and 15 or 3)
	screen.move_rel(4, 0)
	screen.text('Bc')
	screen.level(voice.lfoBC_gate and 15 or 3)
	screen.text('.')

	screen.level('lfoCA' == source_name and 15 or 3)
	screen.move_rel(4, 0)
	screen.text('Ca')
	screen.level(voice.lfoCA_gate and 15 or 3)
	screen.text('.')

	for d = 1, #editor.dests do

		local dest = editor.dests[d].name
		local dest_slider = dest_sliders[dest]
		local source_slider = source_sliders[dest][source_name]
		local active = dest_menu.value == d
		local active_and_held = active and held_keys[3]

		source_slider.x = dest_slider.x - 1
		source_slider:redraw(active and 2 or 1, active_and_held and 5 or (active and 15 or 4))

		dest_slider:redraw(active and 1 or 0, active_and_held and 15 or (active and 3 or 1))

		screen.level(active and 10 or 1)
		screen.text_rotate(dest_slider.x - 3, 63, editor.dests[d].label, -90)
		screen.stroke()
	end

	screen.update()
end

function enc(n, d)
	if n == 1 then
		source_menu:select_value(util.wrap(source_menu.value + d, 1, #editor.source_names))
	elseif n == 2 then
		dest_menu:select_value(util.wrap(dest_menu.value + d, 1, #editor.dests))
	elseif n == 3 then
		local dest = editor.dests[dest_menu.value]
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
	if n == 1 then
		if z == 1 and held_keys[3] then
			-- reset modulation from source
			local source = editor.source_names[source_menu.value]
			for d = 1, #editor.dests do
				params:lookup_param(source .. '_' .. editor.dests[d].name):set_default()
			end
		end
	elseif n == 2 then
		if z == 1 and held_keys[3] then
			local dest = editor.dests[dest_menu.value]
		end
	elseif n == 3 then
		-- only used as a modifier
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
		'lfoA_gate',
		'lfoB_gate',
		'lfoC_gate',
		'lfoAB_gate',
		'lfoBC_gate',
		'lfoCA_gate'
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
