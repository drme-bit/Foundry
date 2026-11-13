--!nonstrict
return function(F)
	local cases = {}
	local function fails(callback, expected)
		local ok, reason = pcall(callback)
		assert(not ok and tostring(reason):find(expected, 1, true), tostring(reason))
	end
	cases["shutdown stops dependents before providers once"] = function()
		local callback, bound, cleanup = nil, 0, {}
		local app = F:ServerContext({
			Shutdown = {
				Bind = function(fn)
					callback = fn
					bound += 1
				end,
			},
			Providers = {
				{
					Name = "Storage",
					Create = function()
						return {
							Destroy = function()
								table.insert(cleanup, "Storage")
							end,
						}
					end,
				},
				{
					Name = "Orders",
					Inject = { Storage = "Storage" },
					Create = function()
						return {
							Destroy = function()
								table.insert(cleanup, "Orders")
							end,
						}
					end,
				},
			},
		})
		assert(bound == 0)
		app:Start()
		assert(bound == 1 and type(callback) == "function")
		callback()
		callback()
		app:Destroy()
		assert(app:GetState() == "Stopped" and #cleanup == 2 and cleanup[1] == "Orders" and cleanup[2] == "Storage")
	end
	cases["manual destroy disables the bound callback"] = function()
		local callback, cleanup = nil, 0
		local app = F:ServerContext({
			Shutdown = {
				Bind = function(fn)
					callback = fn
				end,
			},
			Providers = {
				{
					Name = "Owned",
					Create = function()
						return {
							Destroy = function()
								cleanup += 1
							end,
						}
					end,
				},
			},
		}):Start()
		app:Destroy()
		assert(app._shutdownTarget == nil)
		callback()
		assert(cleanup == 1 and app:GetState() == "Stopped")
	end
	cases["shutdown is optional, server-only and validates its binder"] = function()
		local app = F:ServerContext():Start()
		app:Destroy()
		fails(function()
			F:ClientContext({ Shutdown = { Bind = function() end } })
		end, "server-only")
		fails(function()
			F:ServerContext({ Shutdown = {} })
		end, "Shutdown.Bind")
		fails(function()
			F:ServerContext({ Shutdown = { Bind = true } })
		end, "Shutdown.Bind")
	end
	cases["invalid startup and destroy before start never bind shutdown"] = function()
		local bound = 0
		local options = { Shutdown = {
			Bind = function()
				bound += 1
			end,
		} }
		local notStarted = F:ServerContext(options)
		notStarted:Destroy()
		local invalid = F:ServerContext({
			Shutdown = options.Shutdown,
			Providers = {
				{
					Name = "Missing",
					Dependencies = { "Absent" },
					Create = function()
						error("must not create")
					end,
				},
			},
		})
		fails(function()
			invalid:Start()
		end, "Absent")
		assert(bound == 0)
		invalid:Destroy()
	end
	cases["binder errors clean created beans and invalidate an already captured callback"] = function()
		local callback, cleanup = nil, 0
		local app = F:ServerContext({
			Shutdown = {
				Bind = function(fn)
					callback = fn
					error("cannot bind")
				end,
			},
			Providers = {
				{
					Name = "Owned",
					Create = function()
						return {
							Destroy = function()
								cleanup += 1
							end,
						}
					end,
				},
			},
		})
		fails(function()
			app:Start()
		end, "Shutdown.Bind failed")
		assert(cleanup == 1 and app:GetState() == "Stopped")
		callback()
		assert(cleanup == 1)
	end
	cases["binder is snapshotted and cannot register twice"] = function()
		local bound = 0
		local options = { Shutdown = {
			Bind = function()
				bound += 1
			end,
		} }
		local app = F:ServerContext(options)
		options.Shutdown.Bind = function()
			error("mutated")
		end
		app:Start()
		fails(function()
			app:Start()
		end, "only once")
		assert(bound == 1)
		app:Destroy()
	end
	cases["shutdown hooks run around cleanup and collect hook failures"] = function()
		local order = {}
		local app = F:ServerContext({
			Shutdown = {
				Bind = function() end,
				Before = function()
					table.insert(order, "Before")
				end,
				After = function(_, errors)
					assert(#errors == 0)
					table.insert(order, "After")
				end,
			},
			Providers = {
				{
					Name = "Owned",
					Create = function()
						return {
							Destroy = function()
								table.insert(order, "Destroy")
							end,
						}
					end,
				},
			},
		}):Start()
		app:Destroy()
		assert(table.concat(order, ",") == "Before,Destroy,After")
		local broken = F:ServerContext({
			Shutdown = {
				Bind = function() end,
				Before = function()
					error("before failed")
				end,
				After = function()
					error("after failed")
				end,
			},
		}):Start()
		local errors = broken:Destroy()
		assert(#errors == 2 and errors[1]:find("Shutdown.Before", 1, true) and errors[2]:find("Shutdown.After", 1, true))
	end
	return cases
end
