local pl_file = require "pl.file"
local pl_path = require "pl.path"

local function validate_file(value)
  -- create file in case it doesn't exist
  if not pl_path.exists(value) then
    local ok, err = pl_file.write(value, "")
    if not ok then
      return false, string.format("Cannot create file: %s", err)
    end
  end

  return true
end

return {
  fields = {
    host = { required = true, type = "string" },
    port = { default = 6379, type = "number" },
    database = { default = 0, type = "number" },
    password = { required = true, type = "string" },
    key = { required = true, type = "string" },
    timeout = { default = 2000, type = "number" },
    path = { required = true, type = "string", func = validate_file },
    reopen = { type = "boolean", default = false },
    broken_timeout = {default = 5, type = "number"}
  }
}
