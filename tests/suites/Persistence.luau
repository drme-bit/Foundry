--!nonstrict
return function(F)
	local cases = {}
	local function fixture(adapter, config)
		local memory = adapter or F.Persistence.Memory.new()
		local clock = { now = 0, wall = 1000 }
		local options = {
			Adapter = memory,
			Clock = function()
				return clock.now
			end,
			WallClock = function()
				return clock.wall
			end,
			Wait = function(seconds)
				clock.now += seconds
				clock.wall += seconds
			end,
			Random = function()
				return 0.5
			end,
			Stores = { Profiles = config or { Defaults = { Coins = 10, Inventory = {} } } },
		}
		return F.Persistence.new(options), memory, clock, options
	end
	local function must(value, reason)
		assert(value, tostring(reason))
		return value
	end
	local function denied(callback)
		local ok, reason = callback()
		assert(not ok and reason, "Expected explicit failure")
		return reason
	end
	cases["new profiles, isolated snapshots, validation and release"] = function()
		local m, memory = fixture()
		local store = m:GetStore("Profiles")
		local p = must(store:LoadPlayer({ UserId = 7 }))
		assert(p:Get().Coins == 10)
		local copy = p:Get()
		copy.Coins = 900
		assert(p:Get().Coins == 10)
		must(p:Update(function(data)
			data.Coins += 20
			return data
		end))
		assert(p:GetStatus().Dirty)
		must(p:Save())
		assert(not p:GetStatus().Dirty and memory:Read("Profiles", "User_7").Data.Coins == 30)
		denied(function()
			return p:Update(function(data)
				data.Coins = "wrong"
				return data
			end)
		end)
		assert(p:Get().Coins == 30)
		must(p:Release())
		must(p:Release())
		assert(memory:Read("Profiles", "User_7").Lock == nil)
		local ok = pcall(function()
			p:Get()
		end)
		assert(not ok)
		m:Destroy()
		m:Destroy()
	end
	cases["automatic additive schema upgrades preserve data and increment schema revision"] = function()
		local first, memory = fixture()
		local p = must(first:GetStore("Profiles"):Load("one"))
		must(p:Update(function(d)
			d.Coins = 123
			d.Inventory = { "Pizza" }
			return d
		end))
		must(p:Release())
		first:Destroy()
		local second =
			fixture(memory, { Defaults = { Coins = 0, Inventory = {}, Reputation = 0, Settings = { Sound = true } } })
		local upgraded = must(second:GetStore("Profiles"):Load("one"))
		local data = upgraded:Get()
		assert(data.Coins == 123 and data.Inventory[1] == "Pizza" and data.Reputation == 0 and data.Settings.Sound)
		assert(upgraded:GetStatus().SchemaRevision == 2)
		second:Destroy()
	end
	cases["renames are explicit and older schemas cannot overwrite upgraded records"] = function()
		local first, memory = fixture(nil, { Defaults = { Money = 10 } })
		must(first:GetStore("Profiles"):Load("one")):Release()
		first:Destroy()
		local nextApp = fixture(memory, { Defaults = { Coins = 0 }, RenamedFrom = { Coins = "Money" } })
		local p = must(nextApp:GetStore("Profiles"):Load("one"))
		assert(p:Get().Coins == 10)
		must(p:Release())
		nextApp:Destroy()
		local previous = memory:Read("Profiles", "one")
		local old = fixture(memory, { Defaults = { Money = 10 } })
		denied(function()
			return old:GetStore("Profiles"):Load("one")
		end)
		assert(memory:Read("Profiles", "one").Revision == previous.Revision)
		old:Destroy()
	end
	cases["invalid records and incompatible schemas are never replaced with defaults"] = function()
		local m, memory = fixture()
		local p = must(m:GetStore("Profiles"):Load("one"))
		must(p:Release())
		m:Destroy()
		local before = memory:Read("Profiles", "one")
		for _, config in
			{
				{ Defaults = { Coins = "zero", Inventory = {} } },
				{ Defaults = { Inventory = {} } },
				{
					Defaults = { Coins = 2000, Inventory = {} },
					Schema = function(d)
						return d.Coins > 1000, "need more"
					end,
				},
			}
		do
			local other = fixture(memory, config)
			denied(function()
				return other:GetStore("Profiles"):Load("one")
			end)
			assert(memory:Read("Profiles", "one").Revision == before.Revision)
			other:Destroy()
		end
		memory:Update("Profiles", "one", function(d)
			d.Data.Coins = nil
			return d
		end)
		local corrupt = fixture(memory)
		denied(function()
			return corrupt:GetStore("Profiles"):Load("one")
		end)
		assert(memory:Read("Profiles", "one").Data.Coins == nil)
		corrupt:Destroy()
	end
	cases["leases exclude a second server and fence stale owners after takeover"] = function()
		local a, memory, clockA = fixture()
		local b, _, clockB = fixture(memory)
		local p = must(a:GetStore("Profiles"):Load("one"))
		denied(function()
			return b:GetStore("Profiles"):Load("one")
		end)
		clockA.wall, clockB.wall = 2000, 2000
		local newer = must(b:GetStore("Profiles"):Load("one"))
		must(newer:Update(function(d)
			d.Coins = 80
			return d
		end))
		must(newer:Save())
		denied(function()
			return p:Save()
		end)
		assert(p:GetStatus().State == "Lost" and memory:Read("Profiles", "one").Data.Coins == 80)
		b:Destroy()
		local ok = pcall(function()
			a:Destroy()
		end)
		assert(not ok)
	end
	cases["transient failures retry with backoff, permanent failures do not"] = function()
		local memory = F.Persistence.Memory.new()
		local calls, failure = 0, "transient"
		local adapter = {
			Update = function(_, ...)
				calls += 1
				if calls <= 2 then
					error(failure)
				end
				return memory:Update(...)
			end,
			IsRetryable = function(_, reason)
				return reason:find("transient", 1, true) ~= nil
			end,
		}
		local m, _, clock = fixture(adapter)
		local p = must(m:GetStore("Profiles"):Load("one"))
		assert(calls == 3 and clock.now >= 0.75)
		calls, failure = 0, "permanent"
		denied(function()
			return p:Save()
		end)
		assert(calls == 1 and p:GetStatus().Dirty == false)
		failure, calls = "transient", 9
		must(p:Save())
		m:Destroy()
	end
	cases["budget exhaustion and failed loads never create writable fallback profiles"] = function()
		local memory = F.Persistence.Memory.new()
		local calls, available = 0, false
		local adapter = {
			CanRequest = function()
				return available
			end,
			Update = function(_, ...)
				calls += 1
				return memory:Update(...)
			end,
		}
		local m, _, clock = fixture(adapter)
		denied(function()
			return m:GetStore("Profiles"):Load("one")
		end)
		assert(calls == 0 and clock.now >= 10 and memory:Read("Profiles", "one") == nil)
		available = true
		must(m:GetStore("Profiles"):Load("one"))
		m:Destroy()
	end
	cases["unknown committed outcomes replay safely across exhausted calls"] = function()
		local memory = F.Persistence.Memory.new()
		local fail = false
		local adapter = {
			Update = function(_, ...)
				local written = memory:Update(...)
				if fail then
					error("transient response lost")
				end
				return written
			end,
			IsRetryable = function()
				return true
			end,
		}
		local m = fixture(adapter)
		local p = must(m:GetStore("Profiles"):Load("one"))
		must(p:Update(function(d)
			d.Coins = 20
			return d
		end))
		fail = true
		denied(function()
			return p:Save()
		end)
		local revision = memory:Read("Profiles", "one").Revision
		must(p:Update(function(d)
			d.Coins = 30
			return d
		end))
		fail = false
		must(p:Save())
		assert(memory:Read("Profiles", "one").Revision == revision)
		assert(p:GetStatus().Dirty) -- confirmed the old snapshot, newer edit still pending
		must(p:Release())
		assert(memory:Read("Profiles", "one").Data.Coins == 30)
		m:Destroy()
	end
	cases["unknown load outcomes reuse acquisition tokens"] = function()
		local memory = F.Persistence.Memory.new()
		local fail = true
		local m = fixture({
			Update = function(_, ...)
				local written = memory:Update(...)
				if fail then
					error("lost")
				end
				return written
			end,
			IsRetryable = function()
				return true
			end,
		})
		denied(function()
			return m:GetStore("Profiles"):Load("one")
		end)
		local revision = memory:Read("Profiles", "one").Revision
		fail = false
		local p = must(m:GetStore("Profiles"):Load("one"))
		assert(p:GetStatus().Revision == revision)
		m:Destroy()
	end
	cases["edits during yielding saves remain dirty and per-key writes stay ordered"] = function()
		local memory = F.Persistence.Memory.new()
		local yieldNext = false
		local m = fixture({
			Update = function(_, ...)
				if yieldNext then
					yieldNext = false
					coroutine.yield()
				end
				return memory:Update(...)
			end,
		})
		local p = must(m:GetStore("Profiles"):Load("one"))
		must(p:Update(function(d)
			d.Coins = 20
			return d
		end))
		yieldNext = true
		local thread = coroutine.create(function()
			must(p:Save())
		end)
		must(coroutine.resume(thread))
		must(p:Update(function(d)
			d.Coins = 30
			return d
		end))
		denied(function()
			return p:Save()
		end) -- waits for the in-flight write, then times out
		must(coroutine.resume(thread))
		assert(p:GetStatus().Dirty and memory:Read("Profiles", "one").Data.Coins == 20)
		must(p:Release())
		assert(memory:Read("Profiles", "one").Data.Coins == 30)
		m:Destroy()
	end
	cases["autosave renews clean leases and shutdown flushes dirty profiles"] = function()
		local m, memory, clock = fixture()
		local p = must(m:GetStore("Profiles"):Load("one"))
		local old = memory:Read("Profiles", "one")
		clock.now, clock.wall = 60, 1060
		m:Step()
		assert(memory:Read("Profiles", "one").Lock.Expires > old.Lock.Expires)
		must(p:Update(function(d)
			d.Coins = 55
			return d
		end))
		m:Destroy()
		assert(memory:Read("Profiles", "one").Data.Coins == 55 and memory:Read("Profiles", "one").Lock == nil)
		denied(function()
			return m:GetStore("Profiles"):Load("two")
		end)
	end
	cases["yielding transforms, invalid values and cyclic snapshots are rejected"] = function()
		local m = fixture()
		local p = must(m:GetStore("Profiles"):Load("one"))
		denied(function()
			return p:Update(function()
				coroutine.yield()
			end)
		end)
		for _, bad in { 0 / 0, math.huge, function() end } do
			denied(function()
				return p:Update(function(d)
					d.Inventory = { bad }
					return d
				end)
			end)
		end
		denied(function()
			return p:Update(function(d)
				d.Inventory = d
				return d
			end)
		end)
		denied(function()
			return p:Update(function(d)
				d.Inventory = { [2] = "sparse" }
				return d
			end)
		end)
		assert(p:Get().Coins == 10)
		m:Destroy()
	end
	cases["context injects stores, exposes diagnostics and enforces server-only ownership"] = function()
		local memory = F.Persistence.Memory.new()
		local app = F:ServerContext({
			Persistence = { Adapter = memory, Stores = { Profiles = { Defaults = { Coins = 0 } } } },
			Providers = {
				{
					Name = "Test",
					Inject = { Store = "Profiles" },
					Create = function(d)
						return { Profile = must(d.Store:Load("one")) }
					end,
				},
			},
		}):Start()
		local p = app:Get("Test").Profile
		must(p:Update(function(d)
			d.Coins = 6
			return d
		end))
		local snapshot = app:Inspect().Persistence
		assert(#snapshot.Sessions == 1 and snapshot.Sessions[1].Dirty and snapshot.Sessions[1].Data == nil)
		assert(#app:Destroy() == 0 and memory:Read("Profiles", "one").Data.Coins == 6)
		local ok = pcall(function()
			F:ClientContext({ Persistence = { Stores = {} } })
		end)
		assert(not ok)
	end

	cases["release retries retain their identity after a committed response is lost"] = function()
		local memory = F.Persistence.Memory.new()
		local fail = false
		local m = fixture({
			Update = function(_, ...)
				local result = memory:Update(...)
				if fail then
					error("response lost")
				end
				return result
			end,
			IsRetryable = function()
				return true
			end,
		})
		local p = must(m:GetStore("Profiles"):Load("one"))
		must(p:Update(function(d)
			d.Coins = 99
			return d
		end))
		fail = true
		denied(function()
			return p:Release()
		end)
		assert(p:GetStatus().State == "Closing" and memory:Read("Profiles", "one").Lock == nil)
		denied(function()
			return p:Update(function(d)
				return d
			end)
		end)
		fail = false
		must(p:Release())
		assert(memory:Read("Profiles", "one").Data.Coins == 99)
		m:Destroy()
	end
	cases["shutdown reports unsaved data and can be retried after recovery"] = function()
		local memory = F.Persistence.Memory.new()
		local available = true
		local m = fixture({
			CanRequest = function()
				return available
			end,
			Update = function(_, ...)
				return memory:Update(...)
			end,
		})
		local p = must(m:GetStore("Profiles"):Load("one"))
		must(p:Update(function(d)
			d.Coins = 200
			return d
		end))
		available = false
		local ok = pcall(function()
			m:Destroy()
		end)
		assert(not ok and p:GetStatus().Dirty and memory:Read("Profiles", "one").Data.Coins == 10)
		available = true
		m:Destroy()
		assert(memory:Read("Profiles", "one").Data.Coins == 200 and p:GetStatus().State == "Closed")
	end
	cases["one blocked autosave does not stall other keys"] = function()
		local memory = F.Persistence.Memory.new()
		local blocked = false
		local tasks = {}
		local adapter = {
			Update = function(_, store, key, ...)
				if blocked and key == "one" then
					blocked = false
					coroutine.yield()
				end
				return memory:Update(store, key, ...)
			end,
		}
		local _, _, clock, options = fixture(adapter)
		options.Spawn = function(callback)
			local thread = coroutine.create(callback)
			local ok, reason = coroutine.resume(thread)
			assert(ok, tostring(reason))
			if coroutine.status(thread) ~= "dead" then
				table.insert(tasks, thread)
			end
		end
		local m = F.Persistence.new(options)
		must(m:GetStore("Profiles"):Load("one"))
		local second = must(m:GetStore("Profiles"):Load("two"))
		must(second:Update(function(d)
			d.Coins = 88
			return d
		end))
		clock.now = 61
		blocked = true
		m:Step()
		assert(memory:Read("Profiles", "two").Data.Coins == 88 and #tasks == 1)
		must(coroutine.resume(tasks[1]))
		m:Destroy()
	end

	cases["updates cannot reset omitted fields or reenter mutation and saving"] = function()
		local m, memory = fixture()
		local p = must(m:GetStore("Profiles"):Load("one"))
		denied(function()
			return p:Update(function(d)
				d.Coins = nil
				return d
			end)
		end)
		local revision = memory:Read("Profiles", "one").Revision
		must(p:Update(function(d)
			denied(function()
				return p:Update(function(other)
					other.Coins = 999
					return other
				end)
			end)
			denied(function()
				return p:Save()
			end)
			denied(function()
				return p:Release()
			end)
			return d
		end))
		assert(p:Get().Coins == 10 and memory:Read("Profiles", "one").Revision == revision)
		m:Destroy()
	end
	cases["shutdown waits for a load that finishes after shutdown started"] = function()
		local memory = F.Persistence.Memory.new()
		local yieldLoad = true
		local m, _, clock, options = fixture({
			Update = function(_, ...)
				if yieldLoad then
					yieldLoad = false
					coroutine.yield()
				end
				return memory:Update(...)
			end,
		})
		local load = coroutine.create(function()
			local profile, reason = m:GetStore("Profiles"):Load("one")
			assert(profile == nil and reason == "Profile load cancelled")
		end)
		must(coroutine.resume(load))
		m._wait = function(seconds)
			clock.now += seconds
			if coroutine.status(load) ~= "dead" then
				must(coroutine.resume(load))
			end
		end
		m:Destroy()
		assert(memory:Read("Profiles", "one").Lock == nil and #m:GetSnapshot().Sessions == 0)
	end
	return cases
end
