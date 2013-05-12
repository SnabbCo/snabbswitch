local abi = require "syscall.abi"

local os = abi.os

if os == "osx" or os == "netbsd" then os = "bsd" end -- use same tests for now

require("test.ctest-" .. os)

