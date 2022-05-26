-- hi

musicutil = require 'musicutil'

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

-- tt_chord = 0

-- IIRC, this is a curve that allows some overshoot in the bend, so you can bend up a full 2 st or
-- octave or whatever and still apply some vibrato
-- TODO: is it uneven or something, though? bend seems to rest at just above 0, rather than at 0
-- TODO: internal poly engine -- SinOscFB, VarSaw, __
bend_lut = {}
for i = 0, 127 do
	local x = i * 1.2 / 127
	bend_lut[i] = x * x * x * (x * (x * 6 - 15) + 10)
end

redraw_metro = nil

g = grid.connect()

touche = midi.connect(1)

amp_volts = 0
damp_volts = 0
pitch_volts = 0
-- TODO: reintroduce 'drone' pitch CV or just an alternate 'voice'
bent_pitch_volts = 0
bend = 0
bend_volts = 0
gate = false

function g.key(x, y, z)

	k:key(x, y, z)

	update_pitch_from_keyboard()
	local old_gate = gate
	gate = k.n_held_keys > 0
	if old_gate ~= gate or params:get('env_retrig') == 2 then
		crow.output[4](gate)
	end

	if k.mask_edit then
		crow.output[1].scale(k.mask_notes)
	end

	-- TODO: sync the whole note stack with TT
	grid_redraw()
end

function update_pitch_from_keyboard()
	pitch_volts = k.last_pitch / 12 + k.octave
	send_pitch_volts()
end

function send_pitch_volts()
	bent_pitch_volts = pitch_volts + bend_volts
	crow.output[1].volts = bent_pitch_volts
	-- TODO: removing drone frees up an extra Crow output! do something with it
end

function touche.event(data)
	local message = midi.to_msg(data)
	if message.ch == 1 and message.type == 'cc' then
		-- back = 16, front = 17, left = 18, right = 19
		if message.cc == 17 then
			local amp = message.val / 126
			amp = math.sqrt(amp) -- fast attack
			amp_volts = 10 * amp
			crow.output[2].volts = amp_volts
		elseif message.cc == 16 then
			damp_volts = message.val * params:get('damp_range') / 126 + params:get('damp_base')
			crow.output[3].volts = damp_volts
		elseif message.cc == 18 then
			bend = bend_lut[message.val] -- TODO: not sure why 126 is the max value I'm getting from Touche...
			bend_volts = -bend * params:get('bend_range') / 12
			send_pitch_volts()
		elseif message.cc == 19 then
			bend = bend_lut[message.val]
			bend_volts = bend * params:get('bend_range') / 12
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
	crow.output[4].action = [[
		adsr(
			dyn { a = 0.01 },
			dyn { d = 0.1 },
			dyn { s = 6 },
			dyn { r = 0.3 }
		)
	]]
end

function init()

	-- TODO: why doesn't crow.add() work anymore?
	crow_init()

	params:add {
		name = 'bend range',
		id = 'bend_range',
		type = 'number',
		min = 1,
		max = 24,
		default = 2
	}
	
	-- TODO: damp base + range are a way to avoid using an extra attenuator + offset,
	-- but is that worth it?
	params:add {
		name = 'damp range',
		id = 'damp_range',
		type = 'control',
		controlspec = controlspec.new(-10, 10, 'lin', 0, -5)
	}
	
	params:add {
		name = 'damp base',
		id = 'damp_base',
		type = 'control',
		controlspec = controlspec.new(-10, 10, 'lin', 0, 0)
	}
	
	params:add {
		name = 'pitch slew',
		id = 'pitch_slew',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.01),
		action = function(value)
			crow.output[1].slew = value
		end
	}
	
	params:add {
		name = 'amp/damp slew',
		id = 'amp_slew',
		type = 'control',
		controlspec = controlspec.new(0.001, 1, 'exp', 0, 0.05),
		action = function(value)
			crow.output[2].slew = value
			crow.output[3].slew = value
		end
	}

	-- TODO: dyn variables don't seem to affect Crow envelopes *as they change*, they only take
	-- effect the next time the envelope fires. any way around that?
	-- well, you can use a CV EG module like Stages, and send only a gate from Crow

	params:add {
		name = 'env attack',
		id = 'env_attack',
		type = 'control',
		controlspec = controlspec.new(0.001, 2, 'exp', 0, 0.01),
		action = function(value)
			crow.output[4].dyn.a = value
		end
	}

	params:add {
		name = 'env decay',
		id = 'env_decay',
		type = 'control',
		controlspec = controlspec.new(0.001, 2, 'exp', 0, 0.2),
		action = function(value)
			crow.output[4].dyn.d = value
		end
	}

	params:add {
		name = 'env sustain',
		id = 'env_sustain',
		type = 'control',
		controlspec = controlspec.new(0, 10, 'lin', 0, 6),
		action = function(value)
			crow.output[4].dyn.s = value
		end
	}

	params:add {
		name = 'env release',
		id = 'env_release',
		type = 'control',
		controlspec = controlspec.new(0.001, 4, 'exp', 0, 0.25),
		action = function(value)
			crow.output[4].dyn.r = value
		end
	}

	params:add {
		name = 'env retrig',
		id = 'env_retrig',
		type = 'option',
		options = { 'off', 'on' },
		default = 2
	}

	-- TODO: global transpose, for working with oscillators that aren't tuned to C
	-- TODO: quantize lock on/off: apply post-bend quantization to keyboard notes
	
	params:bang()
	
	redraw_metro = metro.init {
		time = 1 / 12,
		event = function()
			redraw()
			grid_redraw()
		end
	}
	redraw_metro:start()
	
	-- start at 0 / middle C
	update_pitch_from_keyboard()

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
end

function key(n, z)
	if z == 1 then
	end
end

function cleanup()
	if redraw_metro ~= nil then
		redraw_metro:stop()
	end
end
