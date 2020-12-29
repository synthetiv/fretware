local Loop = {}
Loop.__index = Loop
Loop.loops = {}

local sc = softcut

local max_fade = 1
local max_length = 39

local next_id = 1

local rendering_id = 0

function Loop.init()

	audio.level_cut(1)
	params:set('softcut_level', 0)
	params:set('cut_input_adc', 0)
	params:set('rev_cut_input', -math.huge)

	sc.event_render(function(buffer, start, sec_per_sample, samples)
		if buffer == 1 then
			local loop = Loop.loops[rendering_id]
			if loop ~= nil then
				local x = math.floor((start - loop._start) * 64 / loop._length + 0.5)
				for s = 1, #samples do
					loop.levels[x + s - 1] = math.floor(samples[s] * samples[s] * 2 * 15 + 0.5)
				end
			end
		end
		rendering_id = 0
	end)

	sc.event_phase(function(voice, phase)
		local loop = Loop.loops[voice]
		if loop ~= nil then
			phase = phase - loop._start
			if rendering_id == 0 then
				rendering_id = voice
				sc.render_buffer(1, loop._start + loop._position, loop._phase_quant, 1)
			end
			loop._position = phase
			loop._x = phase * 64 / loop._length
		end
	end)
end

function Loop.new(length)
	local id = next_id
	next_id = next_id + 1
	local loop = {
		id = id,
		drift = 0,
		levels = {}
	}
	sc.buffer(id, 1)
	sc.level_slew_time(id, max_fade)
	sc.level_input_cut(1, id, 1)
	sc.pan(id, 0)
	sc.recpre_slew_time(id, max_fade)
	sc.fade_time(id, max_fade)
	sc.rate_slew_time(id, 0.1)
	sc.filter_dry(id, 1)
	setmetatable(loop, Loop)
	loop.level = 1
	loop.start = max_fade + (id - 1) * (max_length + max_fade)
	loop.length = length
	loop.position = 0
	loop.rec = false
	loop.rate = 1
	loop.pre_level = 1
	sc.loop(id, 1)
	sc.play(id, 1)
	sc.rec(id, 1)
	sc.enable(id, 1)
	for x = 1, 64 do
		loop.levels[x] = 0
	end
	Loop.loops[id] = loop
	return loop
end

function Loop:__newindex(index, value)
	-- print('index', self.id, index, value)
	if index == 'level' then
		self._level = value
		sc.level(self.id, value)
	elseif index == 'start' then
		self._start = value
		sc.loop_start(self.id, value)
		sc.phase_offset(self.id, 0)
	elseif index == 'position' then
		self._position = value
		self._x = value * 64 / self._length
		sc.position(self.id, self._start + value)
	elseif index == 'length' then
		self._length = value
		self._end = self._start + value
		sc.loop_end(self.id, self._end)
		self._phase_quant = self._length / 64
		sc.phase_quant(self.id, self._phase_quant)
	elseif index == 'rec' then
		self._rec = value
		self._rec_level = value and 1 or 0
		sc.rec_level(self.id, self._rec_level)
	elseif index == 'pre_level' then
		self._pre_level = value
		sc.pre_level(self.id, value)
	elseif index == 'rate' then
		self._rate = value
		sc.rate(self.id, value)
	elseif string.sub(index, 1, 1) == '_' then
		rawset(self, index, value)
	end
end

function Loop:__index(index)
	if Loop[index] ~= nil then
		return Loop[index]
	elseif string.sub(index, 1, 1) ~= '_' then
		-- check protected indices
		index = '_' .. index
		if self[index] ~= nil then
			return self[index]
		end
	end
end

function Loop:update_drift(leak, rand)
	self.drift = self.drift * leak + (math.random() - 0.5) * rand
	self.rate = self._rate * math.pow(2, self.drift / 1000)
end

function Loop:clear()
	sc.buffer_clear_region_channel(1, self.start, max_length)
	for x = 1, 64 do
		self.levels[x] = 0
	end
end

return Loop