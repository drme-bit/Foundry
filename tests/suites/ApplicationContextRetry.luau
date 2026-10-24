--!nonstrict
return function(Context)
	local function make(options)
		options = options or {}
		local scopes = {}
		options.CreateScope = options.CreateScope
			or function()
				local scope = { Count = 0, Tasks = {} }
				function scope:Add(fn)
					table.insert(self.Tasks, fn)
					return fn
				end
				function scope:Destroy()
					self.Count += 1
					assert(self.Count == 1, "Each scope is destroyed once")
					for i = #self.Tasks, 1, -1 do
						self.Tasks[i]()
					end
				end
				table.insert(scopes, scope)
				return scope
			end
		return Context.new(options), scopes
	end
	local cases = {}
	for _, stage in { "Create", "Init", "Start" } do
		cases["retry recovers " .. stage .. " and rebuilds dependents"] = function()
			local context, scopes = make()
			local attempts, healthy, obsolete = 0, 0, nil
			context:Register({
				Name = "A",
				Create = function()
					attempts += 1
					if stage == "Create" and attempts == 1 then
						error("transient create")
					end
					local instance = { Generation = attempts }
					instance[stage] = function()
						if attempts == 1 then
							error("transient lifecycle")
						end
					end
					function instance:Destroy()
						self.Destroyed = true
						obsolete = self
					end
					return instance
				end,
			})
			context:Register({
				Name = "B",
				Dependencies = { "A" },
				Create = function(d)
					local reference = d.A
					return {
						A = reference,
						Start = function()
							assert(not reference.Destroyed and reference.Generation == 2, "No stale dependency")
						end,
					}
				end,
			})
			context:Register({
				Name = "Healthy",
				Create = function()
					healthy += 1
					return {}
				end,
			})
			context:Run()
			local identity = context:Get("Healthy")
			local status = context:GetStatus()
			assert(attempts == 2 and healthy == 1 and status.Alive == 3 and status.Failed == 0 and status.Skipped == 0)
			assert(status.Beans.A.Attempts == 2 and status.Retried >= 1)
			assert(context:Get("B").A == context:Get("A"))
			context:RetryFailed()
			assert(healthy == 1 and context:Get("Healthy") == identity)
			context:Destroy()
			for _, scope in scopes do
				assert(scope.Count == 1)
			end
		end
	end
	cases["bounded attempts, status summary and manual recovery"] = function()
		local waits, summary, attempts, ready = 0, "", 0, false
		local c = make({
			Wait = function(seconds)
				assert(seconds == 1)
				waits += 1
			end,
			Logger = {
				Debug = function() end,
				Error = function()
					error("logger")
				end,
				Info = function(_, text)
					summary = text
				end,
			},
		})
		c:Register({
			Name = "A",
			Create = function()
				attempts += 1
				assert(ready, "not ready")
				return {}
			end,
		})
		c:Register({
			Name = "B",
			Dependencies = { "A" },
			Create = function(d)
				assert(d.A)
				return {}
			end,
		})
		c:Register({
			Name = "Healthy",
			Create = function()
				return {}
			end,
		})
		c:Run()
		local healthy = c:Get("Healthy")
		assert(attempts == 3 and waits == 2 and c:GetStatus().Failed == 1 and c:GetStatus().Skipped == 1)
		assert(summary:find("DEGRADED") and summary:find("retried=1"))
		ready = true
		local status = c:RetryFailed()
		assert(attempts == 4 and status.Alive == 3 and status.Beans.A.Attempts == 4 and c:Get("Healthy") == healthy)
		assert(summary:find("Retry OK"))
		c:Destroy()
	end
	cases["dependents clean up before a failed dependency"] = function()
		local c = make()
		local attempts = 0
		local events = {}
		c:Register({
			Name = "A",
			Create = function()
				attempts += 1
				local generation = attempts
				return {
					Init = function()
						if generation == 1 then
							error("retry")
						end
					end,
					Destroy = function()
						table.insert(events, "A" .. generation)
					end,
				}
			end,
		})
		c:Register({
			Name = "B",
			Dependencies = { "A" },
			Create = function()
				local generation = attempts
				return {
					Destroy = function()
						table.insert(events, "B" .. generation)
					end,
				}
			end,
		})
		c:Run()
		assert(table.concat(events, ",") == "B1,A1")
		c:Destroy()
		assert(table.concat(events, ",") == "B1,A1,B2,A2")
	end
	cases["failed cleanup remains blocked through multiple dependency failures"] = function()
		local c = make()
		local created = 0
		c:Register({
			Name = "A",
			Create = function()
				return {
					Init = function()
						error("a")
					end,
				}
			end,
		})
		c:Register({
			Name = "D",
			Create = function()
				return {
					Init = function()
						error("d")
					end,
				}
			end,
		})
		c:Register({
			Name = "B",
			Dependencies = { "A", "D" },
			Create = function()
				created += 1
				return {
					Destroy = function()
						error("cleanup failed")
					end,
				}
			end,
		})
		c:Run()
		assert(created == 1 and c:GetStatus().Beans.B.CleanupFailed)
		c:RetryFailed()
		assert(created == 1 and c:GetStatus().Beans.B.CleanupFailed)
		c:Destroy()
	end
	cases["shutdown during retry wait cancels further attempts"] = function()
		local c
		local attempts = 0
		c = make({
			Wait = function()
				c:Destroy()
			end,
		})
		c:Register({
			Name = "A",
			Create = function()
				attempts += 1
				error("not ready")
			end,
		})
		c:Run()
		assert(attempts == 1 and c:GetState() == "Stopped")
		local ok = pcall(function()
			c:RetryFailed()
		end)
		assert(not ok)
	end
	cases["scope creation failure can recover and reentrant retry is rejected"] = function()
		local count = 0
		local c
		c = make({
			CreateScope = function()
				count += 1
				if count == 1 then
					error("scope unavailable")
				end
				return { Destroy = function() end }
			end,
		})
		c:Register({
			Name = "A",
			Create = function()
				assert(not pcall(function()
					c:RetryFailed()
				end))
				return {}
			end,
		})
		c:Run()
		assert(c:GetStatus().Alive == 1 and count == 2)
		c:Destroy()
	end
	cases["invalid retry options are rejected"] = function()
		for _, attempts in { -1, 1.5, math.huge, 0 / 0, 11 } do
			assert(not pcall(function()
				make({ RetryAttempts = attempts })
			end))
		end
		assert(not pcall(function()
			make({ RetryDelay = 0 / 0 })
		end))
	end
	return cases
end
