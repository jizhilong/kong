-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"
local declarative = require "kong.db.declarative"

-- Note: include "off" strategy here as well
for _, strategy in helpers.all_strategies() do
  describe("db.dao #" .. strategy, function()
    local bp, db
    local consumer, service, plugin, acl
    local group = "The A Team"

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "plugins",
        "services",
        "consumers",
        "acls",
      })
      _G.kong.db = db

      consumer = bp.consumers:insert {
        username = "andru",
        custom_id = "donalds",
      }

      service = bp.services:insert {
        name = "abc",
        url = "http://localhost",
      }
  
      plugin = bp.plugins:insert {
        enabled = true,
        name = "acl",
        service = service,
        config = {
          allow = { "*" },
        },
      }
      -- Note: bp in off strategy returns service=id instead of a table
      plugin.service = {
        id = service.id
      }

      acl = bp.acls:insert {
        consumer = consumer,
        group = group,
      }
      -- Note: bp in off strategy returns consumer=id instead of a table
      acl.consumer = {
        id = consumer.id
      }

      if strategy == "off" then
        -- dc_blueprint stores entities in memory
        -- and helpers export it to file in start_kong
        -- since this test requires entities to load
        -- into current nginx's shdict instead of the
        -- Kong nginx started by start_kong, we need
        -- to manually load the config
        local cfg = bp.done()
        local dc = declarative.new_config(kong.configuration)
        local entities = assert(dc:parse_table(cfg))

        local kong_global = require("kong.global")
        local kong = _G.kong

        kong.worker_events = assert(kong_global.init_worker_events())
        kong.cluster_events = assert(kong_global.init_cluster_events(kong.configuration, kong.db))
        kong.cache = assert(kong_global.init_cache(kong.configuration, kong.cluster_events, kong.worker_events))
        kong.core_cache = assert(kong_global.init_core_cache(kong.configuration, kong.cluster_events, kong.worker_events))

        assert(declarative.load_into_cache(entities))
      end
    end)

    lazy_teardown(function()
      db.acls:truncate()
      db.consumers:truncate()
      db.plugins:truncate()
      db.services:truncate()
    end)

    it("select_by_cache_key()", function()
      local cache_key = kong.db.acls:cache_key(consumer.id, group)
      
      local read_acl, err = kong.db.acls:select_by_cache_key(cache_key)
      assert.is_nil(err)
      assert.same(acl, read_acl)

      -- cache_key = { "name", "route", "service", "consumer" },
      cache_key = kong.db.plugins:cache_key("acl", nil, service.id, nil)
      local read_plugin, err = kong.db.plugins:select_by_cache_key(cache_key)
      assert.is_nil(err)
      assert.same(plugin, read_plugin)
    end)
  end)

  describe("db.consumers #" .. strategy, function()
    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "consumers",
      })
      _G.kong.db = db

      assert(bp.consumers:insert {
        username = "gruceo@kong.com",
        custom_id = "12345",
      })
    end)

    lazy_teardown(function()
      db.consumers:truncate()
    end)

    it("consumers:select_by_username_ignore_case() ignores username case", function() 
      local consumer, err = kong.db.consumers:select_by_username_ignore_case("GRUceo@kong.com")
      assert.is_nil(err)
      assert(consumer)
      assert.same("gruceo@kong.com", consumer.username)
      assert.same("12345", consumer.custom_id)
    end)
  end)
end

