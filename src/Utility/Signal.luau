--!strict
-- Synchronous owned notifications. Listener failures never stop sibling listeners.
local Signal = {}
Signal.__index = Signal
export type Signal = typeof(setmetatable(
	{} :: { _listeners: { any }, _destroyed: boolean, _onError: ((string) -> ())? },
	Signal
))
function Signal.new(onError: ((string) -> ())?): Signal
	return setmetatable({ _listeners = {}, _destroyed = false, _onError = onError }, Signal)
end
function Signal.Connect(self: Signal, callback: (...any) -> ()): any
	assert(not self._destroyed and type(callback) == "function", "Signal is destroyed or callback is invalid")
	local entry: any = { Connected = true, Callback = callback }
	local listeners = self._listeners
	function entry:Disconnect()
		if not self.Connected then
			return
		end
		self.Connected, self.Callback = false, nil
		local index = table.find(listeners, self)
		if index then
			table.remove(listeners, index)
		end
	end
	table.insert(listeners, entry)
	return entry
end
function Signal.Fire(self: Signal, ...: any)
	for _, entry in table.clone(self._listeners) do
		if self._destroyed then
			break
		end
		if entry.Connected then
			local ok, reason = pcall(entry.Callback, ...)
			if not ok and self._onError then
				pcall(self._onError, tostring(reason))
			end
		end
	end
end
function Signal.Destroy(self: Signal)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, entry in table.clone(self._listeners) do
		entry:Disconnect()
	end
	table.clear(self._listeners)
	self._onError = nil
end
return Signal
