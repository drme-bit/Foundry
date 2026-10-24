--!nonstrict
return function(Foundry)
	local cases = {}
	local function signal()
		local callbacks = {}
		return {
			Connect = function(_, callback)
				callbacks[callback] = true
				return {
					Disconnect = function()
						callbacks[callback] = nil
					end,
				}
			end,
			Fire = function(_, ...)
				for callback in table.clone(callbacks) do
					if callbacks[callback] then
						callback(...)
					end
				end
			end,
		}
	end
	local function adapter()
		local bus, sent = {}, {}
		return {
			On = function(_, name, callback)
				if not bus[name] then
					bus[name] = signal()
				end
				return bus[name]:Connect(callback)
			end,
			Send = function(_, name, payload, target)
				table.insert(sent, { Name = name, Values = payload, Target = target })
			end,
		},
			bus,
			sent
	end
	local function quiet()
		return Foundry.Logger.new("Test", { Level = "OFF" })
	end
	cases["scheduler yields cooperative work fairly and respects hard step limit"] = function()
		local scheduler = Foundry.Scheduler.new({
			Clock = function()
				return 0
			end,
			MaxStepsPerTick = 1,
		})
		local order, count = {}, 0
		scheduler:Enqueue("A", function()
			table.insert(order, "A")
			count += 1
			return count >= 2
		end)
		scheduler:Enqueue("B", function()
			table.insert(order, "B")
		end)
		scheduler:Step()
		scheduler:Step()
		scheduler:Step()
		assert(table.concat(order) == "ABA" and #scheduler:GetSnapshot().Active == 0)
		scheduler:Destroy()
	end
	cases["scheduler enforces time budget and defers newly enqueued jobs"] = function()
		local stamp, calls = 0, 0
		local scheduler = Foundry.Scheduler.new({
			Clock = function()
				return stamp
			end,
			FrameBudgetMs = 1,
		})
		scheduler:Enqueue("A", function()
			calls += 1
			stamp += 0.002
			scheduler:Enqueue("New", function()
				calls += 1
			end)
			scheduler:Step() -- Reentrant Step must not overlap.
		end)
		scheduler:Enqueue("B", function()
			calls += 1
		end)
		scheduler:Step()
		assert(calls == 1)
		scheduler:Step()
		assert(calls == 3)
		scheduler:Destroy()
	end
	cases["scheduler interval skips missed ticks, false After result does not repeat"] = function()
		local stamp, calls, once = 0, 0, 0
		local scheduler = Foundry.Scheduler.new({
			Clock = function()
				return stamp
			end,
		})
		scheduler:Every("Repeat", 2, function()
			calls += 1
		end)
		scheduler:After("Once", 1, function()
			once += 1
			return false
		end)
		stamp = 10
		scheduler:Step()
		assert(calls == 1 and once == 1)
		scheduler:Step()
		assert(calls == 1 and once == 1)
		stamp = 12
		scheduler:Step()
		assert(calls == 2 and once == 1)
		scheduler:Destroy()
	end
	cases["scheduler scope cancellation and errors release jobs without stopping siblings"] = function()
		local scheduler = Foundry.Scheduler.new({
			Clock = function()
				return 0
			end,
			HistoryLimit = 2,
			Logger = quiet(),
		})
		local scope, calls = Foundry.Scope.new(), 0
		local cancelled = scheduler:Enqueue("Cancelled", function()
			error("must not run")
		end, scope)
		scope:Destroy()
		local failed = scheduler:Enqueue("Failed", function()
			error("job failure")
		end)
		scheduler:Enqueue("Healthy", function()
			calls += 1
		end)
		scheduler:Step()
		assert(cancelled:GetStatus().State == "Cancelled" and failed:GetStatus().State == "Failed" and calls == 1)
		local snapshot = scheduler:GetSnapshot()
		assert(#snapshot.History == 2 and #snapshot.Active == 0)
		snapshot.History[1].State = "Corrupt"
		assert(scheduler:GetSnapshot().History[1].State == "Failed")
		scheduler:Destroy()
		assert(not pcall(function()
			scheduler:Enqueue("Late", function() end)
		end))
	end
	cases["scheduler queue capacity, bad owners and shutdown are bounded"] = function()
		local pulse = signal()
		local scheduler = Foundry.Scheduler.new({
			Clock = function()
				return 0
			end,
			MaxPending = 1,
			Pulse = pulse,
		})
		local called = false
		local job = scheduler:Enqueue("A", function()
			called = true
		end)
		assert(not pcall(function()
			scheduler:Enqueue("Full", function() end)
		end))
		job:Cancel()
		local owner = Foundry.Scope.new()
		owner:Destroy()
		assert(not pcall(function()
			scheduler:Enqueue("BadOwner", function() end, owner)
		end))
		assert(#scheduler:GetSnapshot().Active == 0)
		scheduler:Destroy()
		pulse:Fire()
		assert(not called)
	end
	cases["contracts validate bounds, finite coordinates and stable manifests"] = function()
		local Contract = Foundry.Network.Contract
		local definition = Contract.new({
			Name = "Place",
			ReceiveOn = "Server",
			Fields = { { Type = "String", MaxLength = 3 }, "F64", "U8", "Boolean" },
		})
		assert(Contract.Validate(definition, table.pack("abc", 1.2, 255, false)))
		for _, values in
			{
				table.pack("abcd", 1, 1, true),
				table.pack("abc", 0 / 0, 1, true),
				table.pack("abc", math.huge, 1, true),
				table.pack("abc", 0, 256, true),
				table.pack("abc", 0, 1.5, true),
				table.pack("abc", 0, 1),
			}
		do
			assert(not Contract.Validate(definition, values))
		end
		local other = { Name = "Other", ReceiveOn = "Client", Fields = {} }
		local a = Contract.Manifest(Contract.Registry({ definition, other }))
		local b = Contract.Manifest(Contract.Registry({ other, definition }))
		assert(a == b)
		assert(not pcall(function()
			Contract.Registry({ definition, definition })
		end))
	end
	cases["network validates and rate limits once per message, not per listener"] = function()
		local wire, bus = adapter()
		local stamp, a, b = 0, 0, 0
		local host = Foundry.Network.Host.new({
			Side = "Server",
			Adapter = wire,
			Clock = function()
				return stamp
			end,
			Logger = quiet(),
			Contracts = {
				{ Name = "Command", ReceiveOn = "Server", Fields = { "U8" }, RateLimit = { 2, 1 } },
			},
		})
		local first = host:On("Command", function(_, value)
			a += value
		end)
		host:On("Command", function()
			b += 1
			error("handler")
		end)
		local peer = {}
		bus.Command:Fire(peer, 1)
		bus.Command:Fire(peer, 1)
		bus.Command:Fire(peer, 1)
		bus.Command:Fire(peer, -1)
		assert(a == 2 and b == 2)
		local metrics = host:GetSnapshot().Channels[1]
		assert(metrics.Received == 4 and metrics.Rejected == 2 and metrics.Errors == 2)
		first:Disconnect()
		stamp = 1
		bus.Command:Fire(peer, 1)
		assert(a == 2 and b == 3)
		host:Destroy()
		bus.Command:Fire(peer, 1)
		assert(b == 3)
	end
	cases["network direction, targeting, payload validation and detached metrics"] = function()
		local wire, _, sent = adapter()
		local contracts = { { Name = "Result", ReceiveOn = "Client", Fields = { "Boolean", "String" } } }
		local server = Foundry.Network.Host.new({ Side = "Server", Adapter = wire, Contracts = contracts })
		local peer = {}
		server:GetPackets().Result:FireClient(peer, true, "ok")
		assert(sent[1].Target == peer and sent[1].Values.n == 2)
		assert(not pcall(function()
			server:On("Result", function() end)
		end))
		assert(not pcall(function()
			server:Send("Result", table.pack("bad", "ok"))
		end))
		local client = Foundry.Network.Host.new({ Side = "Client", Adapter = wire, Contracts = contracts })
		assert(not pcall(function()
			client:Send("Result", table.pack(true, "bad"))
		end))
		assert(client:IsCompatible(server:GetManifest()) and not client:IsCompatible("wrong"))
		local snapshot = server:GetSnapshot()
		snapshot.Channels[1].Sent = 99
		assert(server:GetSnapshot().Channels[1].Sent == 1)
		server:Destroy()
		client:Destroy()
	end
	cases["SwiftPacket adapter preserves positional calls, policies and subscriptions"] = function()
		local records, library = {}, { String = "string", U8 = "u8" }
		setmetatable(library, {
			__call = function(_, name, ...)
				local packet = { Name = name, Types = { ... }, OnServerEvent = signal(), OnClientEvent = signal() }
				packet.RateLimit = function(self, count, interval)
					self.Limit = { count, interval }
					return self
				end
				packet.Validate = function(self, callback)
					self.Validator = callback
					return self
				end
				packet.FireClient = function(_, ...)
					records.Target = table.pack(...)
				end
				packet.Fire = function(_, ...)
					records.Broadcast = table.pack(...)
				end
				return packet
			end,
		})
		local raw = Foundry.Network.SwiftPacket.Define(library, {
			{ Name = "Command", ReceiveOn = "Server", Fields = { "U8" }, RateLimit = { 3, 1 } },
			{ Name = "Result", ReceiveOn = "Client", Fields = { "String" } },
		})
		assert(raw.Command.Types[1] == "u8" and raw.Command.Limit[1] == 3 and raw.Result.Validator() == false)
		local instance = Foundry.Network.SwiftPacket.new(raw, "Server")
		local count = 0
		local connection = instance:On("Command", function()
			count += 1
		end)
		raw.Command.OnServerEvent:Fire({}, 1)
		connection:Disconnect()
		raw.Command.OnServerEvent:Fire({}, 1)
		assert(count == 1)
		instance:Send("Result", table.pack("ok"), "peer")
		assert(records.Target[1] == "peer" and records.Target[2] == "ok")
	end
	cases["Boot auto configures optional modules and feature contracts with cleanup"] = function()
		local pulse, stamp, called = signal(), 0, 0
		local wire = adapter()
		local app = Foundry.Boot({
			Logger = quiet(),
			Clock = function()
				return stamp
			end,
			Scheduler = { Pulse = pulse },
			Inspector = { Enabled = true },
			Network = {
				Side = "Server",
				CreateAdapter = function()
					return wire
				end,
			},
			Features = {
				{
					Name = "Feature",
					Contracts = { { Name = "Command", ReceiveOn = "Server", Fields = {} } },
					Providers = {
						{
							Name = "Module",
							Inject = { Scheduler = "Scheduler" },
							Create = function(d, scope)
								d.Scheduler:Every("Work", 1, function()
									called += 1
								end, scope)
								pulse:Fire() -- Work cannot run while the application is starting.
								return {}
							end,
						},
					},
				},
			},
		})
		assert(app:GetState() == "New")
		app:Start()
		assert(called == 0)
		stamp = 1
		pulse:Fire()
		assert(called == 1)
		local snapshot = app:Get("Inspector"):GetSnapshot()
		assert(snapshot.Network.Channels[1].Name == "Command" and snapshot.Scheduler.Active[1].Name == "Work")
		snapshot.Graph[1].Dependencies[1] = "corrupt"
		assert(app:GetGraph()[1].Dependencies[1] ~= "corrupt")
		app:Destroy()
		stamp = 2
		pulse:Fire()
		assert(called == 1)
	end
	cases["completed jobs release their indexed owner entries"] = function()
		local active = {}
		local owner = {
			Add = function(_, value, _, index)
				active[index] = value
			end,
			Remove = function(_, index)
				local handle = active[index]
				active[index] = nil
				if handle then
					handle:Destroy()
				end
			end,
		}
		local scheduler = Foundry.Scheduler.new({
			Clock = function()
				return 0
			end,
		})
		scheduler:After("Once", 0, function() end, owner)
		scheduler:Step()
		assert(next(active) == nil and #scheduler:GetSnapshot().Active == 0)
		scheduler:Destroy()
	end
	cases["network disposal during dispatch prevents later callbacks"] = function()
		local wire, bus = adapter()
		local host = Foundry.Network.Host.new({
			Side = "Server",
			Adapter = wire,
			Contracts = {
				{ Name = "Command", ReceiveOn = "Server", Fields = {} },
			},
		})
		local calls = 0
		host:On("Command", function()
			host:Destroy()
		end)
		host:On("Command", function()
			calls += 1
		end)
		bus.Command:Fire({})
		assert(calls == 0)
	end
	cases["Boot compiles SwiftPacket transport from the library automatically"] = function()
		local emitted = 0
		local library = { String = "string" }
		setmetatable(library, {
			__call = function(_, name)
				emitted += 1
				return {
					Validate = function(self)
						return self
					end,
					Fire = function() end,
				}
			end,
		})
		local app = Foundry.Boot({
			Logger = quiet(),
			Network = {
				Transport = "SwiftPacket",
				Library = library,
				Side = "Server",
				Contracts = { { Name = "Result", ReceiveOn = "Client", Fields = { "String" } } },
			},
		})
		assert(emitted == 0)
		app:Start()
		assert(emitted == 1)
		app:Get("Network"):GetPackets().Result:Fire("ready")
		assert(app:Inspect().Network.Channels[1].Sent == 1)
		app:Destroy()
	end
	cases["Inspector includes detached warning logs from infrastructure"] = function()
		local logger = Foundry.Logger.new("Test", { Sink = function() end })
		local app = Foundry.Boot({ Logger = logger })
		app:Start()
		logger:Warn("Task warning", { Reason = "example failure" })
		local snapshot = app:Inspect()
		assert(snapshot.Logs[#snapshot.Logs].Fields.Reason == "example failure")
		snapshot.Logs[#snapshot.Logs].Fields.Reason = "corrupt"
		assert(logger:GetRecords()[#logger:GetRecords()].Fields.Reason == "example failure")
		app:Destroy()
	end
	return cases
end
