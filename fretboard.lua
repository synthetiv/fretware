musicutil = require 'musicutil'

Keyboard = include 'lib/keyboard'
keyboard = Keyboard.new(1, 1, 16, 8)

sc = softcut
edit_loop = 1
rec_loop = 1
loop_lengths = { 11, 17, 19 }
slew = 1
amp = 0
silence_counter = 20
silent = true

redraw_metro = nil
amp_poll = nil

g = grid.connect()

touche = midi.connect(2)

amp_volts = 0
damp_volts = 0
pitch_volts = 0
bend = 0
bend_volts = 0

function g.key(x, y, z)
	keyboard:key(x, y, z)
	grid_redraw()
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

function crow.add()
	for o = 1, 2 do
		crow.output[o].shape = 'linear'
		crow.output[o].slew = 0.01
	end
end

function init()

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
	
	audio.level_cut(1.0)
	audio.level_adc_cut(1)
	audio.level_cut_rev(0)
	-- 3 mutually prime loops, switch when silent for n seconds
	for c = 1, 3 do
		local loop_start = 1 + (c - 1) * 40
		local loop_end = loop_start + loop_lengths[c]
		print(loop_start, loop_end)
		sc.buffer(c, 1)
		sc.loop_start(c, loop_start)
		sc.loop_end(c, loop_end)
		sc.loop(c, 1)
		sc.level(c, 1)
		sc.level_slew_time(c, slew)
		sc.level_input_cut(1, c, 1)
		sc.pan(c, 0)
		sc.recpre_slew_time(c, slew)
		sc.rec_level(c, c == 1 and 1 or 0)
		sc.fade_time(c, slew)
		sc.rate(c, 1)
		sc.rate_slew_time(c, 0.01)
		sc.rec(c, 1)
		sc.play(c, 1)
		sc.position(c, loop_start)
		sc.enable(c, 1)
		sc.filter_dry(c, 1)
		
		params:add {
			name = string.format('loop %d level', c),
			id = string.format('loop_%d_level', c),
			type = 'control',
			controlspec = controlspec.new(-math.huge, 6, 'db', 0, 0, "dB"),
			action = function(value)
				sc.level(c, util.dbamp(value))
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
				loop_lengths[c] = value
				sc.loop_end(c, loop_start + value)
			end
		}
		
		params:add {
			name = string.format('loop %d clear', c),
			id = string.format('loop_%d_clear', c),
			type = 'trigger',
			action = function()
				sc.buffer_clear_region_channel(1, loop_start, 39)
			end
		}
	end
	
	params:add {
		name = 'pre level',
		id = 'pre_level',
		type = 'control',
		controlspec = controlspec.new(-math.huge, 6, 'db', 0, -1, "dB"),
		action = function(value)
			value = util.dbamp(value)
			for c = 1, 3 do
				sc.pre_level(c, value)
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
				sc.rec_level(rec_loop, 0)
				rec_loop = rec_loop % 3 + 1
				sc.rec_level(rec_loop, 1)
				edit_loop = rec_loop
			end
		end
	end)
	amp_poll:start()
	
	redraw_metro = metro.init {
		time = 1 / 12,
		event = function()
			redraw()
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
end