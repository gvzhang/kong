return {
  fields = {
    host = { required = true, type = "string" },
    port = { default = 6379, type = "number" },
    database = { default = 0, type = "number" },
    password = { required = true, type = "string" },
    key = { required = true, type = "string" },
    timeout = { default = 2000, type = "number" }
  }
}
