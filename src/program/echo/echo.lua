module(..., package.seeall)

local echo = require("apps.echo.echo")
local intel = require("apps.intel.intel_app")

function run(parameters)
  print("running echo")

  if #parameters > 3 then
    print("Usage: echo <pci-addr> [chain-length] [duration]\nexiting...")
    main.exit(1)
  end

  local pciaddr = parameters[1]
  local chainlen = tonumber(parameters[2]) or 1

  if chainlen < 1 then
    print("chain-length < 1, defaulting to 1")
    chainlen = 1
  end

  local c = config.new()

  config.app(c, "intel", intel.Intel82599, {pciaddr = pciaddr})

  for i = 1, chainlen do
    config.app(c, "echo" .. i, echo.Echo)
  end

  for i = 1, chainlen - 1 do
    config.link(c, string.format("echo%d.output -> echo%d.input", i, i + 1))
  end

  config.link(c, "intel.tx -> echo1.input")
  config.link(c, string.format("echo%d.output -> intel.rx", chainlen))

  engine.configure(c)
  engine.busywait = true
  engine.main{duration = tonumber(parameters[3])}
end
