--!nonstrict
return function(Context)
	local function make()
		return Context.new({
			CreateScope = function()
				return {
					Add = function(_, resource)
						return resource
					end,
					Destroy = function() end,
				}
			end,
		})
	end
	local cases = {}
	cases["aliases resolve without leaking registration names or undeclared values"] = function()
		local c = make()
		c:RegisterValue("InternalName", false)
		c:RegisterValue("Secret", {})
		c:Register({
			Name = "Consumer",
			Inject = { Value = "InternalName" },
			Create = function(d)
				assert(d.Value == false and d.InternalName == nil and d.Secret == nil)
				assert(table.isfrozen(d))
				return {}
			end,
		})
		c:Run()
		assert(c:GetStatus().Alive == 1)
		c:Destroy()
	end
	cases["declarations are snapshotted and shared dependencies are created once"] = function()
		local c, count = make(), 0
		local declaration = {
			Name = "Consumer",
			Inject = { Left = "Source", Right = "Source" },
			Create = function(d)
				assert(d.Left == d.Right)
				return { Source = d.Left }
			end,
		}
		c:Register(declaration)
		declaration.Inject.Left = "Missing"
		declaration.Create = function()
			error("mutated")
		end
		c:Register({
			Name = "Source",
			Create = function()
				count += 1
				return {}
			end,
		})
		c:Run()
		assert(count == 1 and c:Get("Consumer").Source == c:Get("Source"))
		c:Destroy()
	end
	cases["alias graph errors precede every factory"] = function()
		for _, cycle in { false, true } do
			local c, created = make(), false
			c:Register({
				Name = "A",
				Inject = { Other = "B" },
				Create = function()
					created = true
					return {}
				end,
			})
			if cycle then
				c:Register({
					Name = "B",
					Inject = { Other = "A" },
					Create = function()
						return {}
					end,
				})
			end
			local ok, message = pcall(function()
				c:Run()
			end)
			assert(not ok and not created)
			assert(tostring(message):find(if cycle then "Dependency cycle" else "Missing dependency", 1, true))
		end
	end
	cases["invalid alias declarations reject registration atomically"] = function()
		for _, fields in
			{
				{ Inject = { [1] = "A" } },
				{ Inject = { Value = "" } },
				{ Inject = { [""] = "A" } },
				{ Inject = {}, Dependencies = {} },
			}
		do
			local c = make()
			fields.Name, fields.Create = "A", function()
				return {}
			end
			assert(not pcall(function()
				c:Register(fields)
			end))
			c:Register({
				Name = "A",
				Create = function()
					return {}
				end,
			})
			c:Run()
			assert(c:GetStatus().Alive == 1)
			c:Destroy()
		end
	end
	cases["autowire retries rebuild dependents and destroy them before providers"] = function()
		local c, attempts, destroyed = make(), 0, {}
		c:Register({
			Name = "Consumer",
			Inject = { Provider = "Source" },
			Create = function(d)
				return {
					Provider = d.Provider,
					Destroy = function()
						table.insert(destroyed, "Consumer")
					end,
				}
			end,
		})
		c:Register({
			Name = "Source",
			Create = function()
				attempts += 1
				assert(attempts > 1, "transient failure")
				return {
					Destroy = function()
						table.insert(destroyed, "Source")
					end,
				}
			end,
		})
		c:Run()
		assert(attempts == 2 and c:Get("Consumer").Provider == c:Get("Source"))
		assert(c:GetStatus().Alive == 2)
		c:Destroy()
		assert(table.concat(destroyed, ",") == "Consumer,Source")
	end
	return cases
end
