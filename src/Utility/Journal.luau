--!strict
-- Bounded journal. Records contain scalar fields and, optionally, one flat Fields map.
local Journal = {}
Journal.__index = Journal
export type Journal = typeof(setmetatable(
	{} :: {
		_capacity: number,
		_sequence: number,
		_count: number,
		_records: { any },
	},
	Journal
))
local function copy(record: any): any
	local result = table.clone(record)
	if result.Fields then
		result.Fields = table.clone(result.Fields)
	end
	return result
end
function Journal.new(capacity: number): Journal
	assert(capacity >= 0 and capacity <= 4096 and capacity % 1 == 0, "Capacity must be an integer from 0 to 4096")
	return setmetatable({ _capacity = capacity, _sequence = 0, _count = 0, _records = {} }, Journal)
end
function Journal.Push(self: Journal, record: any): any
	self._sequence += 1
	local snapshot = copy(record)
	snapshot.Sequence = self._sequence
	if self._capacity > 0 then
		self._records[(self._sequence - 1) % self._capacity + 1] = snapshot
		self._count = math.min(self._count + 1, self._capacity)
	end
	return copy(snapshot)
end
function Journal.Snapshot(self: Journal): { any }
	local result = {}
	for sequence = self._sequence - self._count + 1, self._sequence do
		table.insert(result, copy(self._records[(sequence - 1) % self._capacity + 1]))
	end
	return result
end
return Journal
