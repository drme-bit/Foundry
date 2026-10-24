--!nonstrict
return function(Foundry)
	local cases = {}
	local function fails(callback, text)
		local ok, message = pcall(callback)
		assert(not ok and tostring(message):find(text, 1, true), tostring(message))
	end
	cases["Boot runs features out of order, keeps internals private and tears down dependents first"] = function()
		local destroyed = {}
		local app = Foundry.Boot({
			Features = {
				{
					Name = "Orders",
					Imports = { "Player" },
					Exports = { "Orders" },
					Providers = {
						{
							Name = "Orders",
							Inject = { Wallet = "Wallet" },
							Create = function(d)
								return {
									Wallet = d.Wallet,
									Destroy = function()
										table.insert(destroyed, "Orders")
									end,
								}
							end,
						},
					},
				},
				{
					Name = "Player",
					Exports = { "Wallet" },
					Providers = {
						{
							Name = "Internal",
							Create = function()
								return {}
							end,
						},
						{
							Name = "Wallet",
							Inject = { Internal = "Internal" },
							Create = function(d)
								assert(d.Internal)
								return {
									Destroy = function()
										table.insert(destroyed, "Wallet")
									end,
								}
							end,
						},
					},
				},
			},
		})
		app:Start()
		assert(app:Get("Orders").Wallet == app:Get("Wallet"))
		fails(function()
			app:Get("Internal")
		end, "Private feature binding")
		app:Destroy()
		assert(table.concat(destroyed, ",") == "Orders,Wallet")
	end
	cases["feature validation fails before all factories"] = function()
		local invalid = {
			{ { Name = "A", Imports = { "Missing" } } },
			{ { Name = "A", Imports = { "B" } }, { Name = "B", Imports = { "A" } } },
			{ { Name = "A", Exports = { "Missing" } } },
			{ { Name = "A" }, { Name = "A" } },
		}
		for _, features in invalid do
			local created = false
			local app = Foundry.Boot({
				Features = features,
				Providers = {
					{
						Name = "Root",
						Create = function()
							created = true
							return {}
						end,
					},
				},
			})
			assert(not pcall(function()
				app:Start()
			end))
			assert(not created and app:GetState() == "Failed")
			fails(function()
				app:RegisterValue("Late", {})
			end, "before Start")
			app:Destroy()
			assert(app:GetState() == "Stopped")
		end
	end
	cases["private injections and undeclared imports are rejected"] = function()
		for _, fromRoot in { false, true } do
			for _, exported in { false, true } do
				local created = false
				local consumer = {
					Name = "Consumer",
					Inject = { Source = "Source" },
					Create = function()
						created = true
						return {}
					end,
				}
				local features = {
					{
						Name = "SourceFeature",
						Values = { Source = {} },
						Exports = if exported then { "Source" } else {},
					},
				}
				if not fromRoot then
					table.insert(features, { Name = "ConsumerFeature", Providers = { consumer } })
				end
				local app = Foundry.Boot({ Features = features, Providers = if fromRoot then { consumer } else {} })
				if fromRoot and exported then
					app:Start()
					assert(created)
				else
					assert(not pcall(function()
						app:Start()
					end) and not created)
				end
				app:Destroy()
			end
		end
	end
	cases["descriptors snapshot metadata and borrow values"] = function()
		local external = {}
		local descriptor = { Name = "Feature", Values = { Token = external }, Exports = { "Token" } }
		local snapshot = Foundry.Feature(descriptor)
		assert(table.isfrozen(snapshot) and table.isfrozen(snapshot.Exports))
		descriptor.Exports[1], descriptor.Values.Token = "Other", {}
		local app = Foundry.Boot({ Features = { snapshot } })
		app:Start()
		assert(app:Get("Token") == external)
		app:Destroy()
	end
	cases["default scope releases partial factories and retries without rebuilding healthy branches"] = function()
		local attempts, cleaned, healthy, healthyCleaned = 0, 0, 0, 0
		local app = Foundry.Boot({
			Features = {
				{
					Name = "Retry",
					Exports = { "Unstable" },
					Providers = {
						{
							Name = "Unstable",
							Create = function(_, scope)
								attempts += 1
								scope:Add(function()
									cleaned += 1
								end)
								assert(attempts > 1, "transient")
								return {}
							end,
						},
					},
				},
			},
			Providers = {
				{
					Name = "Healthy",
					Create = function(_, scope)
						healthy += 1
						scope:Add(function()
							healthyCleaned += 1
						end)
						return {}
					end,
				},
			},
		})
		app:Start()
		assert(attempts == 2 and cleaned == 1 and healthy == 1)
		assert(app:GetStatus().Alive == 2)
		app:RetryFailed()
		app:Destroy()
		app:Destroy()
		assert(cleaned == 2 and healthyCleaned == 1)
	end
	cases["root registrations, false values, Config and legacy Run remain supported"] = function()
		local config = { Limit = 3 }
		local app = Foundry.Boot({ Config = config, Values = { Flag = false } })
		app:Register({
			Name = "Module",
			Inject = { Settings = "Config", Flag = "Flag", Port = "Port" },
			Create = function(d)
				assert(d.Settings == config and d.Flag == false and d.Port == 4)
				return {}
			end,
		}):RegisterValue("Port", 4)
		assert(app:Run() == app and app:GetState() == "Running")
		fails(function()
			app:Start()
		end, "only once")
		fails(function()
			app:RegisterValue("Late", {})
		end, "before Start")
		app:Destroy()
		assert(app:GetState() == "Stopped")
	end
	cases["missing provider and bean cycles still fail before side effects"] = function()
		for _, cycle in { false, true } do
			local created = false
			local providers = {
				{
					Name = "A",
					Inject = { Value = "B" },
					Create = function()
						created = true
						return {}
					end,
				},
			}
			if cycle then
				table.insert(providers, {
					Name = "B",
					Inject = { Value = "A" },
					Create = function()
						return {}
					end,
				})
			end
			local app = Foundry.Boot({ Providers = providers })
			assert(not pcall(function()
				app:Start()
			end))
			assert(not created and app:GetState() == "Failed")
			app:Destroy()
		end
	end
	cases["scope supports default and explicit cleanup in reverse order"] = function()
		local scope, order = Foundry.Scope.new(), {}
		local a = {
			Destroy = function()
				table.insert(order, "destroy")
			end,
		}
		assert(scope:Add(a) == a)
		scope:Add({
			Disconnect = function()
				table.insert(order, "disconnect")
			end,
		})
		scope:Add({
			Stop = function()
				table.insert(order, "stop")
			end,
		}, "Stop")
		scope:Add("resource", function(value)
			assert(value == "resource")
			table.insert(order, "custom")
		end)
		scope:Add(function()
			table.insert(order, "function")
		end)
		scope:Destroy()
		scope:Destroy()
		assert(table.concat(order, ",") == "function,custom,stop,disconnect,destroy")
		fails(function()
			scope:Add(function() end)
		end, "destroyed scope")
	end
	cases["scope replacement and removal dispose once and validate candidates before replacing"] = function()
		local scope, cleaned = Foundry.Scope.new(), 0
		scope:Add(function()
			cleaned += 1
		end, nil, false)
		fails(function()
			scope:Add({}, nil, false)
		end, "Missing cleanup method")
		assert(cleaned == 0)
		scope:Add(function()
			cleaned += 10
		end, nil, false)
		assert(cleaned == 1)
		scope:Remove(false)
		scope:Remove(false)
		scope:Destroy()
		assert(cleaned == 11)
	end
	cases["scope cleanup continues through errors and nested scopes tolerate early destruction"] = function()
		local scope, cleaned = Foundry.Scope.new(), 0
		local child = scope:Extend()
		child:Add(function()
			cleaned += 1
		end)
		child:Destroy()
		scope:Add(function()
			cleaned += 10
		end)
		scope:Add(function()
			error("cleanup failure")
		end)
		scope:Add(function()
			scope:Destroy()
		end)
		fails(function()
			scope:Destroy()
		end, "cleanup failure")
		scope:Destroy()
		assert(cleaned == 11)
	end
	cases["scope replacement cannot add to a scope destroyed by cleanup"] = function()
		local scope, cleaned = Foundry.Scope.new(), false
		scope:Add(function()
			scope:Destroy()
		end, nil, "key")
		fails(function()
			scope:Add(function()
				cleaned = true
			end, nil, "key")
		end, "destroyed during replacement")
		assert(not cleaned)
	end
	cases["builtin scope cleanup failures block unsafe retry"] = function()
		local attempts, cleaned = 0, false
		local app = Foundry.Boot({
			Providers = {
				{
					Name = "A",
					Create = function(_, scope)
						attempts += 1
						scope:Add(function()
							cleaned = true
						end)
						scope:Add(function()
							error("cannot release")
						end)
						error("create failed")
					end,
				},
			},
		})
		app:Start()
		assert(attempts == 1 and cleaned and app:GetStatus().Beans.A.CleanupFailed)
		app:RetryFailed()
		assert(attempts == 1)
		app:Destroy()
	end
	return cases
end
