local helpers = require "spec.helpers"
local cjson = require "cjson"


local json_encode = cjson.encode


local status_api_port = helpers.get_available_port()
local fixtures = {
  dns_mock = helpers.dns_mock.new({
    mocks_only = true
  }),
  http_mock = {},
  stream_mock = {}
}

fixtures.dns_mock:A({
  name = "mock.io",
  address = "127.0.0.1"
})

fixtures.dns_mock:A({
  name = "status.io",
  address = "127.0.0.1"
})

local rt_config = json_encode({
  append = {
    headers = {
      "X-Added-Header: true",
    },
  },
  pw_metrics = {
    label_patterns = {
      { label = "service", pattern = "(_s_id=([0-9a-z%-]+))" },
      { label = "route", pattern = "(_r_id=([0-9a-z%-]+))" },
    }
  }
})


for _, strategy in helpers.each_strategy() do
  describe("Plugin: prometheus (metrics) [#" .. strategy .. "]", function()
    local admin_client
    local proxy_client

    setup(function()
      require("kong.runloop.wasm").enable({
        { name = "tests",
          path = helpers.test_conf.wasm_filters_path .. "/tests.wasm",
        },
        { name = "response_transformer",
          path = helpers.test_conf.wasm_filters_path .. "/response_transformer.wasm",
        },
      })

      local bp = helpers.get_db_utils(strategy, {
        "services",
        "routes",
        "plugins",
        "filter_chains",
      })

      local function service_and_route(name, path)
        local service = assert(bp.services:insert({
          name = name,
          url = helpers.mock_upstream_url,
        }))

        local route = assert(bp.routes:insert({
          name = name .. "-route",
          service = { id = service.id },
          paths = { path },
          hosts = { name },
          protocols = { "https" },
        }))

        return service, route
      end

      local service, _ = service_and_route("mock", "/")
      local service2, _ = service_and_route("mock2", "/v2")
      service_and_route("status.io", "/metrics")

      local filters = {
        { name = "tests", enabled = true, config = "metrics=c1,g1,h1" },
        { name = "response_transformer", enabled = true, config = rt_config },
      }

      assert(bp.filter_chains:insert({
        service = { id = service.id },
        filters = filters,
      }))

      assert(bp.filter_chains:insert({
        service = { id = service2.id },
        filters = filters,
      }))

      bp.plugins:insert({
        name = "prometheus",
        config = {
          status_code_metrics = true,
          latency_metrics = true,
          bandwidth_metrics = true,
          upstream_health_metrics = true,
        },
      })

      assert(helpers.start_kong({
        nginx_conf = "spec/fixtures/custom_nginx.template",
        wasm = true,
        plugins = "bundled,prometheus",
        status_listen = '127.0.0.1:' .. status_api_port .. ' ssl', -- status api does not support h2
        status_access_log = "logs/status_access.log",
        status_error_log = "logs/status_error.log"
      }, nil, nil, fixtures))
    end)

    teardown(function()
      if admin_client then
        admin_client:close()
      end
      if proxy_client then
        proxy_client:close()
      end

      helpers.stop_kong()
    end)

    before_each(function()
      admin_client = helpers.admin_client()
      proxy_client = helpers.proxy_ssl_client()
    end)

    after_each(function()
      if admin_client then
        admin_client:close()
      end
      if proxy_client then
        proxy_client:close()
      end
    end)

    it("expose WasmX metrics by admin API #a1.1", function()
      local res = proxy_client:get("/", {
        headers = { host = "mock" },
      })
      assert.res_status(200, res)

      res = proxy_client:get("/v2", {
        headers = { host = "mock2" },
      })
      assert.res_status(200, res)

      res = assert(admin_client:send{
        method = "GET",
        path = "/metrics"
      })
      local body = assert.res_status(200, res)

      local expected_c = '# HELP pw_tests_c1\n'
                      .. '# TYPE pw_tests_c1 counter\n'
                      .. 'pw_tests_c1 0'

      local expected_g = '# HELP pw_tests_g1\n'
                      .. '# TYPE pw_tests_g1 gauge\n'
                      .. 'pw_tests_g1 0'

      local expected_h = '# HELP pw_tests_h1\n'
                      .. '# TYPE pw_tests_h1 histogram\n'
                      .. 'pw_tests_h1{le="+Inf"} 0'

      local expected_labeled = '# HELP pw_response_transformer_append\n'
          .. '# TYPE pw_response_transformer_append counter\n'
          .. 'pw_response_transformer_append{service="mock",route="mock-route"} 1\n'
          .. 'pw_response_transformer_append{service="mock2",route="mock2-route"} 1'

      local expected_labeled_histogram = '# HELP pw_response_transformer_processing_time\n'
          .. '# TYPE pw_response_transformer_processing_time histogram\n'
          .. 'pw_response_transformer_processing_time{service="mock",route="mock-route",le="1"} 1\n'
          .. 'pw_response_transformer_processing_time{service="mock",route="mock-route",le="+Inf"} 1\n'
          .. 'pw_response_transformer_processing_time{service="mock2",route="mock2-route",le="1"} 1\n'
          .. 'pw_response_transformer_processing_time{service="mock2",route="mock2-route",le="+Inf"} 1'

      assert.matches(expected_c, body, nil, true)
      assert.matches(expected_g, body, nil, true)
      assert.matches(expected_h, body, nil, true)
      assert.matches(expected_labeled, body, nil, true)
      assert.matches(expected_labeled_histogram, body, nil, true)
    end)
  end)
end
