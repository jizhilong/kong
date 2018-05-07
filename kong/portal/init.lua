local lapis       = require "lapis"
local api_helpers = require "kong.api.api_helpers"
local app_helpers = require "lapis.application"
local singletons  = require "kong.singletons"
local responses   = require "kong.tools.responses"


local _M = {}


_M.app = lapis.Application()


_M.app:before_filter(function(self)
  api_helpers.filter_body_content_type(self)
end)


-- Register application defaults
_M.app.handle_404 = function(self)
  return responses.send_HTTP_NOT_FOUND()
end


_M.app.handle_error = function(self, err, trace)
  if err and string.find(err, "don't know how to respond to", nil, true) then
    return responses.send_HTTP_METHOD_NOT_ALLOWED()
  end

  ngx.log(ngx.ERR, err, "\n", trace)

  -- We just logged the error so no need to give it to responses and log it
  -- twice
  return responses.send_HTTP_INTERNAL_SERVER_ERROR()
end


function _M.on_error(self)
  local err = self.errors[1]

  if type(err) ~= "table" then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(tostring(err))
  end

  if err.db then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err.message)
  end

  if err.unique then
    return responses.send_HTTP_CONFLICT(err.tbl)
  end

  if err.foreign then
    return responses.send_HTTP_NOT_FOUND(err.tbl)
  end

  return responses.send_HTTP_BAD_REQUEST(err.tbl or err.message)
end


-- Instantiate a single helper object for wrapped methods
local handler_helpers = {
  responses = responses,
  yield_error = app_helpers.yield_error
}


function _M.attach_routes(routes, app)
  for route_path, methods in pairs(routes) do
    methods.on_error = methods.on_error or _M.on_error

    methods.resource = nil

    for method_name, method_handler in pairs(methods) do
      local wrapped_handler = function(self)
        return method_handler(self, singletons.dao, handler_helpers)
      end

      methods[method_name] = api_helpers.parse_params(wrapped_handler)
    end

    app:match(route_path, route_path, app_helpers.respond_to(methods))
  end
end

-- Load core routes
for _, v in ipairs({"api"}) do
  local routes = require("kong.portal." .. v)
  _M.attach_routes(routes, _M.app)
end


return _M.app
