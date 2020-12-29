musicutil = require 'musicutil'

Keyboard = include 'lib/keyboard'
keyboard = Keyboard.new(1, 1, 16, 8)

Loop = include 'lib/loop'

loops = {}
edit_loop = 1
rec_loop = 1
loop_lengths = { 11, 17, 21 }
slew = 1
amp = 0
silence_counter = 0
silent = true

redraw_metro = nil
amp_poll = nil

g = grid.connect()
a = arc.connect()

touche = midi.connect(1)

amp_volts = 0
damp_volts = 0
pitch_volts = 0
bend = 0
bend_volts = 0

function g.key(x, y, z)
	keyboard:key(x, y, z)
	grid_redraw()
end

function a.delta(r, d)
	local loop = loops[r]
	if loop ~= nil then
		loop.position = loop._position + (d * loop._length / 1024)
	end
end

function send_pitch_volts()
	crow.output[1].volts = pitch_volts + bend_volts
	crow.output[4].volts = (pitch_volts + bend_volts) * params:get('pitch_tracking')
end

function touche.event(data)
	local message = midi.to_msg(data)
	if message.ch == 1 and message.type == 'cc' then
		-- back = 16, front = 17, left = 18, right = 19
		if message.cc == 17 then
			amp_volts = message.val * 10 / 126
			crow.output[2].volts = amp_volts
		elseif message.cc == 16 then
			damp_volts = message.val * params:get('damp_range') / 126 + params:get('damp_base')
			crow.output[3].volts = damp_volts
		elseif message.cc == 18 then
			bend = message.val / 126 -- TODO: not sure why that's the max value I'm getting from Touche...
			bend = bend * bend
			bend_volts = -bend * params:get('bend_range') / 12
			send_pitch_volts()
		elseif message.cc == 19 then
			bend = message.val / 126
			bend = bend * bend
			bend_volts = bend * params:get('bend_range') / 12
			send_pitch_volts()
		end
	end
end

function grid_redraw()
	g:all(0)
	keyboard:draw()
	g:refresh()
end

function arc_redraw()
	a:all(0)
	for c = 1, 3 do
		local loop = loops[c]
		for x = 1, 64 do
			a:led(c, x, math.min(15, loop.levels[x] + (c == rec_loop and 4 or 0)))
		end
		a:led(c, math.floor(loop.x + 0.5), 15)
	end
	a:refresh()
end

function crow.add()
	for o = 1, 2 do
		crow.output[o].shape = 'linear'
		crow.output[o].slew = 0.01
	end
end

function init()

	Loop.init()
	softcut.poll_start_phase()

	params:add {
		name = 'bend range',
		id = 'bend_range',
		type = 'number',
		min = 1,
		max = 24,
		default = 2
	}
	
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
		name = 'pitch tracking',
		id = 'pitch_tracking',
		type = 'control',
		controlspec = controlspec.new(-2, 2, 'lin', 0, 1)
	}
	
	for c = 1, 3 do
		loops[c] = Loop.new(loop_lengths[c])
		
		params:add {
			name = string.format('loop %d level', c),
			id = string.format('loop_%d_level', c),
			type = 'control',
			controlspec = controlspec.new(-math.huge, 6, 'db', 0, 0, "dB"),
			action = function(value)
				loops[c].level = util.dbamp(value)
			end
		}
		
		params:add {
			name = string.format('loop %d length', c),
			id = string.format('loop_%d_length', c),
			type = 'number',
			default = loop_lengths[c],
			min = 1,
			max = 39,
			action = function(value)
				loops[c].length = value
			end
		}
		
		params:add {
			name = string.format('loop %d clear', c),
			id = string.format('loop_%d_clear', c),
			type = 'trigger',
			action = function()
				loops[c]:clear()
			end
		}
	end
	
	params:add {
		name = 'drift leak',
		id = 'drift_leak',
		type = 'control',
		controlspec = controlspec.new(0, 1, 'lin', 0, 0.05),
	}
	
	params:add {
		name = 'drift rand',
		id = 'drift_rand',
		type = 'control',
		controlspec = controlspec.new(0, 10, 'lin', 0, 0.8),
	}
	
	params:add {
		name = 'pre level',
		id = 'pre_level',
		type = 'control',
		controlspec = controlspec.new(-math.huge, 6, 'db', 0, -1, "dB"),
		action = function(value)
			value = util.dbamp(value)
			for c = 1, 3 do
				loops[c].pre_level = value
			end
		end
	}
	
	params:add {
		name = 'rec level',
		id = 'rec_level',
		type = 'control',
		controlspec = controlspec.new(-math.huge, 6, 'db', 0, -3, "dB"),
		action = function(value)
			value = util.dbamp(value)
			audio.level_adc_cut(value)
		end
	}

	params:bang()
	
	amp_poll = poll.set('amp_in_l', function(value)
		amp = ampdb(value * 4)
		if amp > -60 then
			silent = false
			silence_counter = 20
		elseif silence_counter > 0 then
			silence_counter = silence_counter - 1
			if silence_counter == 0 then
				silent = true
				loops[rec_loop].rec = false
				rec_loop = rec_loop % 3 + 1
				loops[rec_loop].rec = true
				edit_loop = rec_loop
			end
		end
	end)
	amp_poll:start()
	
	loops[rec_loop].rec = true
	
	redraw_metro = metro.init {
		time = 1 / 12,
		event = function()
			local leak = params:get('drift_leak')
			local rand = params:get('drift_rand')
			for c = 1, 3 do
				loops[c]:update_drift(leak, rand)
			end
			print(loops[1].drift, loops[2].drift, loops[3].drift)
			redraw()
			grid_redraw()
			arc_redraw()
		end
	}
	redraw_metro:start()
	
	crow.add()

	grid_redraw()
end

function ampdb(amp)
	return math.log(amp) / 0.05 / math.log(10)
end

function redraw()
	screen.clear()
	screen.aa(1)
	for c = 0, 3 do
		screen.level((c == edit_loop) and 15 or 3)
		local x = 64 + (c - 1.5) * 24
		local level = (c == 0) and amp or params:get(string.format('loop_%d_level', c))
		level = util.clamp(level, -24, 0)
		screen.rect(x - 2, 42, 4, -24 - level)
		screen.fill()
		screen.move(x, 50)
		screen.text_center(c == 0 and 'i' or c)
		if c == rec_loop then
			screen.circle(x, 57, 1.7)
			screen.fill()
		end
	end
	screen.update()
end

function enc(n, d)
	if n == 1 then
		edit_loop = util.clamp(edit_loop + d, 1, 3)
	elseif n == 2 then
		params:delta(string.format('loop_%d_level', edit_loop), d)
	end
end

function key(n, z)
	if z == 1 then
		if n == 2 then
			params:set(string.format('loop_%d_clear', edit_loop))
		elseif n == 3 then
			loops[rec_loop].rec = false
			rec_loop = edit_loop
			loops[rec_loop].rec = true
		end
	end
end

function cleanup()
	if redraw_metro ~= nil then
		redraw_metro:stop()
	end
	if amp_poll ~= nil then
		amp_poll:stop()
	end
	softcut.poll_stop_phase()
end