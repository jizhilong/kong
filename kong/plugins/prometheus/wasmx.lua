local buffer = require "string.buffer"
local wasm = require "kong.runloop.wasm"
local wasmx_shm = require "resty.wasmx.shm"


local fmt = string.format
local str_find = string.find
local str_match = string.match
local str_sub = string.sub
local table_insert = table.insert
local table_sort = table.sort
local buf_new = buffer.new
local ngx_say = ngx.say


local _M = {}


local function sorted_iter(ctx)
  local v = ctx.t[ctx.keys[ctx.i]]
  ctx.i = ctx.i + 1

  return v
end


local function sorted_pairs(t)
  local sorted_keys = {}

  for k, _ in pairs(t) do
    table_insert(sorted_keys, k)
  end

  table_sort(sorted_keys)

  return sorted_iter, { t = t, keys = sorted_keys, i = 1 }
end


local function parse_pw_key(key)
  local name = key
  local labels = {}
  local header_size = 3  -- pw.
  local first_match = #key

  local second_dot_pos, _ = str_find(key, "%.", header_size + 1)
  local filter_name = str_sub(key, header_size + 1, second_dot_pos - 1)

  local filter_config = wasm.filters_by_name[filter_name].config or {}
  local patterns = filter_config.pw_metrics
                   and filter_config.pw_metrics.label_patterns or {}

  for _, pair in ipairs(patterns) do
    local lkv, lv = str_match(key, pair.pattern)
    if lkv then
      local lk = str_sub(lkv, 0, str_find(lkv, "="))
      local lk_start, _ = str_find(key, lk)

      first_match = (lk_start < first_match) and lk_start or first_match

      table_insert(labels, { pair.label, lv })
    end
  end

  if first_match ~= #key then
    name = str_sub(key, 0, first_match - 1)
  end

  return name, labels
end


local function parse_key(key)
  local header = { pw = "pw." }

  local name = key
  local labels = {}

  local is_pw = #key > #header.pw and key:sub(0, #header.pw) == header.pw

  if is_pw then
    name, labels = parse_pw_key(key)
  end

  name = name:gsub("%.", "_")

  return name, labels
end


local function serialize_labels(labels)
  local buf = buf_new()

  for _, pair in ipairs(labels) do
    buf:put(fmt('%s="%s",', pair[1], pair[2]))
  end

  local slabels = buf:get()

  if #slabels > 0 then
    return slabels:sub(0, #slabels - 1)  -- discard trailing comma
  end

  return slabels
end


local function serialize_metric(m)
  local buf = buf_new()

  buf:put(fmt("# HELP %s\n# TYPE %s %s", m.name, m.name, m.type))

  for _, pair in ipairs(m.labels) do
    local labels = pair[1]
    local labeled_m = pair[2]
    local slabels = serialize_labels(labels)

    if m.type == "counter" or m.type == "gauge" then
      if #slabels > 0 then
        buf:put(fmt("\n%s{%s} %s", m.name, slabels, labeled_m.value))
      else
        buf:put(fmt("\n%s %s", m.name, labeled_m.value))
      end

    elseif m.type == "histogram" then
      local c = 0

      for _, bin in ipairs(labeled_m.value) do
        local ub = (bin.ub ~= 4294967295) and bin.ub or "+Inf"
        local ubl = fmt('le="%s"', ub)
        local llabels = (#slabels > 0) and (slabels .. "," .. ubl) or ubl

        c = c + bin.count

        buf:put(fmt("\n%s{%s} %s", m.name, llabels, c))
      end
    end
  end

  buf:put("\n")

  return buf:get()
end


_M.metric_data = function()
  local i = 0
  local flush_after = 50
  local metrics = {}
  local parsed = {}
  local buf = buf_new()

  wasmx_shm.metrics:lock()

  for key in wasmx_shm.metrics:iterate_keys() do
    table_insert(metrics, { key, wasmx_shm.metrics:get_by_name(key, { prefix = false })})
  end

  wasmx_shm.metrics:unlock()

  -- in wasmx the different labels of a metric are stored as separate metrics
  -- aggregate those separate metrics into a single one
  for _, pair in ipairs(metrics) do
    local key = pair[1]
    local m = pair[2]
    local name, labels = parse_key(key)

    parsed[name] = parsed[name] or { name = name, type = m.type, labels = {} }

    table_insert(parsed[name].labels, { labels, m })
  end

  for metric_by_label in sorted_pairs(parsed) do
    buf:put(serialize_metric(metric_by_label))

    i = i + 1

    if i % flush_after == 0 then
      ngx_say(buf:get())
    end
  end

  ngx_say(buf:get())
end


return _M
