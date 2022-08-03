-- hi

engine.name = 'Analyst'
musicutil = require 'musicutil'

Keyboard = include 'lib/keyboard'
k = Keyboard.new(1, 1, 16, 8)

-- tt_chord = 0

-- TODO: internal poly engine -- SinOscFB, VarSaw, SmoothFoldS
-- with envelope(s) + mod matrix (sources: EG1, EG2, touche tip, touche heel)

redraw_metro = nil
relax_metro = nil

g = grid.connect()

touche = midi.connect(1)

amp_volts = 0
damp_volts = 0
pitch_volts = 0
bent_pitch_volts = 0
pitch_poll = nil
detected_pitch = 0
gate_in = false

poll_names = {
	'pitch',
	'amp',
	'clarity',
}
polls = {}
poll_values = {}

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
	crow.output[1].volts = bent_pitch_volts + (k.quantizing and 1/24 or 0)
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

	crow.input[1].change = function(gate)
		gate_in = gate
		if k.arping and k.n_sustained_keys > 0 then
			k:arp(gate)
		else
			if gate then
				detected_pitch = poll_values.pitch - 1
				k.on_pitch()
			end
			-- forward gates w/delay to avoid pitch jump during attack
			crow.output[4](gate)
		end
	end
	crow.input[1].mode('change', 1, 0.01, 'both')

	crow.input[2].stream = function(v)
		k:transpose(v)
	end
	crow.input[2].mode('stream', 0.01)
end

function init()

	for p = 1, #poll_names do
		local name = poll_names[p]
		poll_values[name] = 0
		local new_poll = poll.set(name, function(value)
			poll_values[name] = value
		end)
		new_poll.time = 1 / 10
		new_poll:start()
		polls[name] = new_poll
	end

	k.on_pitch = function()
		local pitch = (k.n_sustained_keys > 0) and (k.active_pitch + k.octave) or util.clamp(detected_pitch + k.transposition, -5, 5)
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
			crow.output[4](gate)
		elseif gate then
			crow.output[4]()
		end
		if gate then
			-- crow.ii.tt.script_v(1, pitch_volts + transpose_volts)
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
		default = -3,
		formatter = function(param)
			local value = param:get()
			if value < 1 then
				return string.format('%.2f', k.bend_range)
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

	params:add{
		type = 'file',
		id = 'tuning_file',
		name = 'tuning_file',
		path = '/home/we/dust/data/fretwork/scales/stefan4.scl',
		action = function(value)
			k.scale:read_scala_file(value)
			k.scale:apply_edits()
		end
	}

	-- TODO: global transpose, for working with oscillators that aren't tuned to C
	-- TODO: quantize lock on/off: apply post-bend quantization to keyboard notes
	
	params:bang()
	
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
	for p = 1, #poll_names do
		local name = poll_names[p]
		if polls[name] ~= nil then
			polls[name]:stop()
		end
	end
end
