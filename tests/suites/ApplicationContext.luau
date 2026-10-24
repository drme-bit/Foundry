--!nonstrict
return function(Context)
	local function equal(actual, expected)
		assert(actual == expected, `Expected {expected}, got {actual}`)
	end
	local function fails(callback, fragment)
		local ok, message = pcall(callback)
		assert(not ok, "Expected failure")
		assert(string.find(tostring(message), fragment, 1, true), tostring(message))
	end
	local function create(log)
		return Context.new({
			Name = "Test",
			RetryAttempts = 0,
			CreateScope = function()
				local tasks = {}
				return {
					Add = function(_, callback)
						table.insert(tasks, callback)
						return callback
					end,
					Destroy = function()
						for i = #tasks, 1, -1 do
							tasks[i]()
						end
						if log then
							table.insert(log, "scope")
						end
					end,
				}
			end,
		})
	end
	return {
		["dependency order, singleton identity and lifecycle barriers"] = function()
			local log, context, constructed = {}, create(), 0
			context:Register({
				Name = "B",
				Dependencies = { "A" },
				Create = function(d)
					table.insert(log, "create B")
					return {
						A = d.A,
						Init = function()
							table.insert(log, "init B")
						end,
						Start = function()
							table.insert(log, "start B")
						end,
						Destroy = function()
							table.insert(log, "destroy B")
						end,
					}
				end,
			})
			context:Register({
				Name = "A",
				Create = function()
					constructed += 1
					table.insert(log, "create A")
					return {
						Init = function()
							table.insert(log, "init A")
						end,
						Start = function()
							table.insert(log, "start A")
						end,
						Destroy = function()
							table.insert(log, "destroy A")
						end,
					}
				end,
			})
			context:Run()
			equal(context:Get("B").A, context:Get("A"))
			equal(constructed, 1)
			context:Destroy()
			equal(table.concat(log, ","), "create A,create B,init A,init B,start A,start B,destroy B,destroy A")
		end,
		["missing dependencies fail before constructing anything"] = function()
			local count, context = 0, create()
			context:Register({
				Name = "A",
				Dependencies = { "Missing" },
				Create = function()
					count += 1
					return {}
				end,
			})
			fails(function()
				context:Run()
			end, "Missing dependency: Missing")
			equal(count, 0)
			equal(context:GetState(), "Failed")
		end,
		["cycles report their path before side effects"] = function()
			local count, context = 0, create()
			for _, pair in { { "A", "B" }, { "B", "A" } } do
				context:Register({
					Name = pair[1],
					Dependencies = { pair[2] },
					Create = function()
						count += 1
						return {}
					end,
				})
			end
			fails(function()
				context:Run()
			end, "A -> B -> A")
			equal(count, 0)
		end,
		["duplicate names and repeated dependencies are rejected"] = function()
			local context = create():RegisterValue("Flag", false)
			fails(function()
				context:RegisterValue("Flag", true)
			end, "Duplicate bean")
			fails(function()
				context:Register({
					Name = "B",
					Dependencies = { "Flag", "Flag" },
					Create = function()
						return {}
					end,
				})
			end, "Repeated dependency")
		end,
		["borrowed values are injected, including false, and not destroyed"] = function()
			local context = create()
			context:RegisterValue("Flag", false):RegisterValue("External", {
				Destroy = function()
					error("borrowed destroyed")
				end,
			})
			context:Register({
				Name = "Bean",
				Dependencies = { "Flag" },
				Create = function(d)
					equal(d.Flag, false)
					return {}
				end,
			})
			context:Run()
			equal(context:Get("Flag"), false)
			equal(#context:Destroy(), 0)
		end,
		["factory failure releases partially constructed scopes"] = function()
			local log, context = {}, create()
			context:Register({
				Name = "A",
				Create = function(_, scope)
					scope:Add(function()
						table.insert(log, "scope A")
					end)
					return {
						Destroy = function()
							table.insert(log, "destroy A")
						end,
					}
				end,
			})
			context:Register({
				Name = "B",
				Dependencies = { "A" },
				Create = function(_, scope)
					scope:Add(function()
						table.insert(log, "scope B")
					end)
					error("factory failed")
				end,
			})
			context:Run()
			equal(context:GetStatus().Failed, 1)
			equal(context:GetStatus().Alive, 1)
			equal(table.concat(log, ","), "scope B")
			context:Destroy()
			equal(table.concat(log, ","), "scope B,destroy A,scope A")
		end,
		["Init failure preserves independent beans"] = function()
			local log, context = {}, create()
			context:Register({
				Name = "A",
				Create = function()
					return {
						Init = function()
							error("init failed")
						end,
						Start = function()
							error("must not start")
						end,
						Destroy = function()
							table.insert(log, "A")
						end,
					}
				end,
			})
			context:Register({
				Name = "B",
				Create = function()
					return {
						Destroy = function()
							table.insert(log, "B")
						end,
					}
				end,
			})
			context:Run()
			equal(context:GetStatus().Failed, 1)
			equal(context:GetStatus().Alive, 1)
			equal(table.concat(log, ","), "A")
			context:Destroy()
			equal(table.concat(log, ","), "A,B")
		end,
		["Start failure preserves running dependencies"] = function()
			local log, context = {}, create()
			context:Register({
				Name = "A",
				Create = function()
					return {
						Start = function()
							table.insert(log, "start A")
						end,
						Destroy = function()
							table.insert(log, "destroy A")
						end,
					}
				end,
			})
			context:Register({
				Name = "B",
				Dependencies = { "A" },
				Create = function()
					return {
						Start = function()
							error("start failed")
						end,
						Destroy = function()
							table.insert(log, "destroy B")
						end,
					}
				end,
			})
			context:Run()
			equal(context:GetStatus().Failed, 1)
			equal(context:GetStatus().Alive, 1)
			equal(table.concat(log, ","), "start A,destroy B")
			context:Destroy()
			equal(table.concat(log, ","), "start A,destroy B,destroy A")
		end,
		["teardown continues after errors and Destroy is idempotent"] = function()
			local count, context = 0, create()
			context:Register({
				Name = "A",
				Create = function()
					return {
						Destroy = function()
							count += 1
						end,
					}
				end,
			})
			context:Register({
				Name = "B",
				Create = function(_, scope)
					scope:Add(function()
						count += 1
					end)
					return {
						Destroy = function()
							error("destroy failed")
						end,
					}
				end,
			})
			context:Run()
			equal(#context:Destroy(), 1)
			equal(count, 2)
			equal(#context:Destroy(), 0)
			equal(count, 2)
			equal(context:GetState(), "Stopped")
		end,
		["definitions are copied and injected dependencies frozen"] = function()
			local context, dependencies = create(), { "Config" }
			context:RegisterValue("Config", 5)
			context:Register({
				Name = "A",
				Dependencies = dependencies,
				Create = function(d)
					equal(d.Config, 5)
					assert(table.isfrozen(d))
					return {}
				end,
			})
			dependencies[1] = "Missing"
			context:Run()
			context:Destroy()
		end,
		["contexts isolate beans and forbid rerun or late registration"] = function()
			local first, second = create(), create()
			for _, context in { first, second } do
				context
					:Register({
						Name = "A",
						Create = function()
							return {}
						end,
					})
					:Run()
			end
			assert(first:Get("A") ~= second:Get("A"))
			fails(function()
				first:Run()
			end, "only once")
			fails(function()
				first:RegisterValue("Late", 1)
			end, "before Run")
			first:Destroy()
			second:Destroy()
			fails(function()
				first:Get("A")
			end, "successful Run")
		end,
	}
end
