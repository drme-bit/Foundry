--!nonstrict
return function(Foundry)
	local cases = {}
	local function silent()
		return Foundry.Logger.new("Test", { Sink = function() end, Level = "DEBUG" })
	end
	cases["structured child logs share bounded chronological storage and cannot retain objects"] = function()
		local sink = {}
		local logger = Foundry.Logger.new("App", {
			Capacity = 2,
			Clock = function()
				return 5
			end,
			Sink = function(record)
				table.insert(sink, record)
				record.Fields.Mutated = true
			end,
		})
		local child = logger:Child("Music")
		logger:Debug("filtered")
		logger:Info("one")
		child:Warn("two", { Duration = 0.5, Object = { Secret = {} } })
		child:Error("three")
		local records = logger:GetRecords()
		assert(#records == 2 and records[1].Sequence == 2 and records[2].Sequence == 3)
		assert(records[1].Name == "App/Music" and records[1].Fields.Object == "[table]")
		assert(records[1].Time == 5 and not records[1].Fields.Mutated and #sink == 3)
		records[1].Fields.Duration = 10
		assert(child:GetRecords()[1].Fields.Duration == 0.5)
		child:SetLevel("ERROR")
		logger:Info("filtered")
		assert(#sink == 3)
	end
	cases["bad logging sinks and clocks do not break startup or execution"] = function()
		local logger = Foundry.Logger.new("BrokenSink", {
			Sink = function()
				error("sink")
			end,
			Clock = function()
				error("clock")
			end,
		})
		local app = Foundry.Boot({
			Logger = logger,
			Clock = function()
				return 0 / 0
			end,
			Providers = {
				{
					Name = "A",
					Create = function()
						return {}
					end,
				},
			},
		})
		app:Start()
		assert(app:GetStatus().Alive == 1 and logger:GetSinkFailures() > 0)
		assert(app:Execute("A", "Run", function()
			return 4
		end))
		app:Destroy()
	end
	cases["lifecycle history and state cache are bounded, detached and invalidated"] = function()
		local tick = 0
		local app = Foundry.Boot({
			Logger = silent(),
			HistoryLimit = 6,
			Clock = function()
				tick += 0.1
				return tick
			end,
			Features = {
				{
					Name = "Feature",
					Exports = { "A" },
					Providers = {
						{
							Name = "A",
							Create = function()
								return {}
							end,
						},
					},
				},
			},
		})
		app:Start()
		local first, again = app:GetStatus(), app:GetStatus()
		assert(first.Revision == again.Revision and first.Beans.A.Feature == "Feature")
		assert(first.Beans.A.CreateDuration > 0 and first.Beans.A.InitDuration > 0)
		first.Beans.A.State = "Corrupted"
		first.Alive = 20
		assert(app:GetStatus().Beans.A.State == "Running" and app:GetStatus().Alive == 1)
		app:Execute("A", "Test", function() end)
		assert(app:GetStatus().Revision > again.Revision)
		local history = app:GetHistory()
		assert(#history == 6 and history[1].Sequence < history[6].Sequence)
		history[1].Event = "Corrupted"
		assert(app:GetHistory()[1].Event ~= "Corrupted")
		app:Destroy()
		assert(app:GetStatus().Alive == 0)
	end
	cases["execution preserves nil return values and contains failures without restarting providers"] = function()
		local creates = 0
		local app = Foundry.Boot({
			Logger = silent(),
			Providers = {
				{
					Name = "A",
					Create = function()
						creates += 1
						return {}
					end,
				},
			},
		})
		app:Start()
		local result = table.pack(app:Execute("A", "Values", function(a, b)
			return nil, a, b
		end, 4, nil))
		assert(result.n == 4 and result[1] == true and result[2] == nil and result[3] == 4 and result[4] == nil)
		local ok, reason = app:Execute("A", "Broken", function()
			error("operation failed")
		end)
		assert(not ok and reason:find("operation failed", 1, true))
		local status = app:GetStatus()
		assert(
			status.Alive == 1
				and status.RuntimeFailures == 1
				and status.Beans.A.LastRuntimeError:find("operation failed", 1, true)
		)
		app:RetryFailed()
		assert(creates == 1)
		app:Destroy()
		assert(not app:Execute("A", "Late", function()
			error("must not run")
		end))
	end
	cases["guard disables after consecutive errors and suppresses successful frame traffic"] = function()
		local runtime
		local app = Foundry.Boot({
			Logger = silent(),
			Providers = {
				{
					Name = "A",
					Create = function(_, _, supplied)
						runtime = supplied
						return {}
					end,
				},
			},
		})
		app:Start()
		local count, fail = 0, true
		local guard = runtime:Guard("Heartbeat", function()
			count += 1
			if fail then
				error("bad tick")
			end
		end, { FailureLimit = 2 })
		guard()
		fail = false
		guard()
		fail = true
		guard()
		guard()
		guard()
		assert(count == 4)
		assert(app:GetStatus().Beans.A.DisabledGuards == 1 and app:GetStatus().RuntimeFailures == 3)
		local before = #app:GetHistory()
		local successful = runtime:Guard("HealthyFrame", function() end)
		for _ = 1, 100 do
			successful()
		end
		assert(#app:GetHistory() == before)
		app:Destroy()
		successful()
	end
	cases["runtime guards are generation bound across retry and shutdown"] = function()
		local calls, attempts, guards = 0, 0, {}
		local app = Foundry.Boot({
			Logger = silent(),
			Providers = {
				{
					Name = "A",
					Create = function(_, _, runtime)
						attempts += 1
						table.insert(
							guards,
							runtime:Guard("Event", function()
								calls += 1
							end)
						)
						return {
							Init = function()
								assert(attempts > 1, "retry")
							end,
						}
					end,
				},
			},
		})
		app:Start()
		assert(attempts == 2)
		guards[1]()
		guards[2]()
		assert(calls == 1)
		app:Destroy()
		guards[2]()
		assert(calls == 1)
	end
	cases["validation failures use the same journal and logger"] = function()
		local logger = silent()
		local app = Foundry.Boot({ Logger = logger, Features = { { Name = "A", Imports = { "Missing" } } } })
		assert(not pcall(function()
			app:Start()
		end))
		local history = app:GetHistory()
		assert(history[#history].Event == "ValidationFailed" and app:GetState() == "Failed")
		assert(logger:GetRecords()[#logger:GetRecords()].Level == "ERROR")
		app:Destroy()
	end
	cases["private bindings cannot be accessed through execution"] = function()
		local app = Foundry.Boot({
			Logger = silent(),
			Features = {
				{
					Name = "Feature",
					Providers = {
						{
							Name = "Private",
							Create = function()
								return {}
							end,
						},
					},
				},
			},
		})
		app:Start()
		assert(not pcall(function()
			app:Execute("Private", "Call", function() end)
		end))
		app:Destroy()
	end
	cases["history can be disabled and invalid capacities reject early"] = function()
		local app = Foundry.Boot({ Logger = silent(), HistoryLimit = 0 })
		app:Start()
		assert(#app:GetHistory() == 0)
		app:Destroy()
		for _, capacity in { -1, 1.5, math.huge, 4097 } do
			assert(not pcall(function()
				Foundry.Boot({ HistoryLimit = capacity })
			end))
			assert(not pcall(function()
				Foundry.Logger.new("Test", { Capacity = capacity })
			end))
		end
	end
	cases["throwing destructor lookup cannot abort cleanup of other providers"] = function()
		local cleaned = false
		local app = Foundry.Boot({
			Logger = silent(),
			Providers = {
				{
					Name = "Healthy",
					Create = function(_, scope)
						scope:Add(function()
							cleaned = true
						end)
						return {}
					end,
				},
				{
					Name = "Poisoned",
					Create = function()
						return setmetatable({}, {
							__index = function(_, key)
								if key == "Destroy" then
									error("broken destructor lookup")
								end
								return nil
							end,
						})
					end,
				},
			},
		})
		app:Start()
		local errors = app:Destroy()
		assert(cleaned and #errors == 1 and errors[1]:find("broken destructor lookup", 1, true))
	end
	return cases
end
