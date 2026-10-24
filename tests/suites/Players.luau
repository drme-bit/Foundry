--!nonstrict
return function(F)
	local cases = {}
	local function source()
		local s = { PlayerAdded = F.Utility.Signal.new(), PlayerRemoving = F.Utility.Signal.new(), List = {} }
		function s:GetPlayers()
			return table.clone(self.List)
		end
		function s:Add(id)
			local p = {
				UserId = id,
				Name = "Player" .. id,
				DisplayName = "Display" .. id,
				Parent = self,
				CharacterAdded = F.Utility.Signal.new(),
				CharacterRemoving = F.Utility.Signal.new(),
			}
			table.insert(self.List, p)
			self.PlayerAdded:Fire(p)
			return p
		end
		function s:Remove(p)
			self.PlayerRemoving:Fire(p)
			local i = table.find(self.List, p)
			if i then
				table.remove(self.List, i)
			end
			p.Parent = nil
		end
		return s
	end
	local function fails(fn, text)
		local ok, reason = pcall(fn)
		assert(not ok and tostring(reason):find(text, 1, true), tostring(reason))
	end
	cases["existing players, duplicate events, reconnects and character cleanup"] = function()
		local s = source()
		local p = s:Add(1)
		p.Character = {}
		local app = F:ServerContext({ Players = { Source = s }, Server = { JobId = "job" } }):Start()
		local registry = app:Get("PlayerRegistry")
		local a = registry:GetPlayer(1)
		assert(a == registry:GetPlayer(p) and a:GetStatus() == "Ready" and a.Index == 1)
		s.PlayerAdded:Fire(p)
		assert(#registry:GetPlayers() == 1)
		local old, new = p.Character, {}
		p.CharacterAdded:Fire(new)
		p.CharacterRemoving:Fire(old)
		assert(a:GetCharacter() == new)
		s:Remove(p)
		assert(a:GetStatus() == "Left" and registry:GetPlayer(1) == nil)
		local replacement = s:Add(1)
		assert(registry:GetPlayer(replacement).Index == 2)
		s.PlayerRemoving:Fire(p)
		assert(registry:GetPlayer(p) == nil and registry:GetPlayer(replacement))
		app:Destroy()
		assert(#registry:GetPlayers() == 0 and #s.PlayerAdded._listeners == 0)
		assert(#p.CharacterAdded._listeners == 0 and a:GetInstance() == nil)
	end
	cases["failed player modules roll back and siblings clean in reverse order"] = function()
		local s, cleaned = source(), {}
		local p = s:Add(1)
		s:Add(2)
		local app = F:ServerContext({
			Players = {
				Source = s,
				Modules = {
					{
						Name = "Wallet",
						Create = function(r)
							return {
								Id = r.UserId,
								Destroy = function()
									table.insert(cleaned, "Wallet" .. r.UserId)
								end,
							}
						end,
					},
					{
						Name = "Broken",
						Create = function(r, scope)
							if r.UserId == 1 then
								scope:Add(function()
									table.insert(cleaned, "rollback")
								end)
								error("cannot load")
							end
							return {}
						end,
					},
					{
						Name = "Last",
						Create = function(r)
							return {
								Destroy = function()
									table.insert(cleaned, "Last" .. r.UserId)
								end,
							}
						end,
					},
				},
			},
		}):Start()
		local registry = app:Get("PlayerRegistry")
		assert(registry:GetPlayer(1):GetStatus() == "Degraded" and registry:GetPlayer(2):GetStatus() == "Ready")
		assert(registry:GetPlayer(1):GetModule("Wallet").Id == 1 and cleaned[1] == "rollback")
		s:Remove(p)
		assert(cleaned[2] == "Last1" and cleaned[3] == "Wallet1")
		app:Destroy()
	end
	cases["yielding factories finishing after shutdown cannot publish modules"] = function()
		local s, cleaned = source(), 0
		local registry = F.Players.Registry.new({
			Source = s,
			Modules = {
				{
					Name = "Yield",
					Create = function(_, scope)
						scope:Add(function()
							cleaned += 1
						end)
						coroutine.yield()
						return {
							Destroy = function()
								cleaned += 1
							end,
						}
					end,
				},
			},
		})
		registry:Start()
		local thread = coroutine.create(function()
			s:Add(1)
		end)
		assert(coroutine.resume(thread))
		assert(registry:GetPlayer(1):GetStatus() == "Joining")
		registry:Destroy()
		assert(coroutine.resume(thread))
		assert(cleaned == 2 and registry:GetPlayer(1) == nil)
	end
	cases["server info tracks health, occupancy, draining and stopped uptime"] = function()
		local s, now = source(), 5
		s:Add(1)
		local app = F:ServerContext({
			Clock = function()
				return now
			end,
			Players = { Source = s },
			Server = { JobId = "j", MaxPlayers = 6 },
		}):Start()
		now = 10
		local info = app:Get("ServerInfo")
		local a = info:GetSnapshot()
		assert(a.Ready and a.State == "Running" and a.PlayerCount == 1 and a.Uptime == 5)
		info:SetDraining(true, "deploy")
		a = info:GetSnapshot()
		assert(not a.Ready and a.State == "Draining" and a.DrainReason == "deploy")
		info:SetDraining(false)
		assert(info:GetSnapshot().Ready)
		a.Health.Failed = 50
		a.JobId = "changed"
		assert(info:GetSnapshot().Health.Failed == 0 and info:GetSnapshot().JobId == "j")
		app:Destroy()
		now = 100
		a = info:GetSnapshot()
		assert(a.State == "Stopped" and not a.Ready and a.Uptime == 5 and a.PlayerCount == 0)
	end
	cases["failed application branches surface degraded server health"] = function()
		local app = F:ServerContext({
			Server = {},
			Providers = {
				{
					Name = "Broken",
					Create = function()
						error("fail")
					end,
				},
			},
		}):Start()
		local info = app:Get("ServerInfo"):GetSnapshot()
		assert(info.State == "Degraded" and info.Health.Failed == 1 and not info.Ready)
		app:Destroy()
	end
	cases["snapshots detach lists and cleanup survives module errors"] = function()
		local s, count = source(), 0
		local p = s:Add(1)
		local app = F:ServerContext({
			Players = {
				Source = s,
				Modules = {
					{
						Name = "Good",
						Create = function()
							return {
								Destroy = function()
									count += 1
								end,
							}
						end,
					},
					{
						Name = "Bad",
						Create = function()
							return {
								Destroy = function()
									error("cleanup")
								end,
							}
						end,
					},
				},
			},
			Server = { JobId = "j" },
		}):Start()
		local registry = app:Get("PlayerRegistry")
		local record = registry:GetPlayer(p)
		local copy = record:GetSnapshot()
		table.clear(copy.Modules)
		copy.Server.JobId = "x"
		assert(#record:GetSnapshot().Modules == 2 and record:GetServerInfo().JobId == "j")
		s:Remove(p)
		assert(count == 1 and registry:GetPlayer(1) == nil)
		fails(function()
			record:GetModule("Good")
		end, "ended")
		app:Destroy()
	end
	cases["signals isolate observers and release disconnected callbacks"] = function()
		local errors, calls = 0, 0
		local signal = F.Utility.Signal.new(function()
			errors += 1
		end)
		local later
		signal:Connect(function()
			later:Disconnect()
			error("observer")
		end)
		later = signal:Connect(function()
			calls += 100
		end)
		signal:Connect(function()
			calls += 1
		end)
		signal:Fire()
		assert(errors == 1 and calls == 1 and later.Callback == nil)
		signal:Destroy()
		signal:Fire()
		assert(calls == 1 and #signal._listeners == 0)
	end
	cases["consumers receive session lookup and server metadata through declared injection"] = function()
		local s = source()
		local player = s:Add(7)
		local app = F:ServerContext({
			Players = { Source = s },
			Server = { JobId = "injection-test" },
			Providers = {
				{
					Name = "Consumer",
					Inject = { Sessions = "PlayerRegistry", Server = "ServerInfo" },
					Create = function(deps)
						return {
							GetSession = function(_, id)
								return deps.Sessions:GetPlayer(id)
							end,
							GetServer = function()
								return deps.Server:GetSnapshot()
							end,
						}
					end,
				},
			},
		}):Start()
		local consumer = app:Get("Consumer")
		assert(consumer:GetSession(7) == app:Get("PlayerRegistry"):GetPlayer(player))
		assert(consumer:GetSession(7):GetStatus() == "Ready")
		assert(consumer:GetServer().JobId == "injection-test")
		s:Remove(player)
		assert(consumer:GetSession(7) == nil)
		app:Destroy()
	end
	cases["client contexts reject registry and server options"] = function()
		fails(function()
			F:ClientContext({ Players = { Source = source() } })
		end, "server-only")
		fails(function()
			F:ClientContext({ Server = {} })
		end, "server-only")
		fails(function()
			F.Players.Registry.new({
				Source = source(),
				Modules = {
					{
						Name = "Same",
						Create = function()
							return {}
						end,
					},
					{
						Name = "Same",
						Create = function()
							return {}
						end,
					},
				},
			})
		end, "Duplicate")
	end
	return cases
end
