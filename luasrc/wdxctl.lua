#!/usr/bin/lua

--
-- Copyright (C) Spyderj
--

local help = [[
wdxctl command [arguments ...]

Avaiable commands:
  logcapture    Capture logging output
  logreopen     Reopen log file(for log file splitting)
  reset         Reset a client by its mac or ip
  clients       Show clients
  jclients      Show clients in json format
  help          Show this tip
  exit          Quit
]]

local appctl = require 'appctl'

appctl.APPNAME = 'wifidogx'
appctl.HELP = help

if #arg > 0 then
	appctl.dispatch(arg)
else
	appctl.interact()
end
