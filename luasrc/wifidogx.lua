#!/usr/bin/lua

-- 
-- Copyright (C) Spyderj
--

require 'std'
local log = require 'log'
local tasklet = require 'tasklet'

-------------------------------------------------------------------------------
-- variables {

local ARGV = arg

VERSION = '1.0.1'

fw = require 'wifidogx.fw_iptables'  -- fw_ipset is altnernative.
conf = require 'wifidogx.conf'
auth = require 'wifidogx.auth'
http = require 'wifidogx.http'

clients_bymac = {}
conf_update_callbacks = {}

local clients_bymac = clients_bymac
local tmpbuf = tmpbuf

-- }
-------------------------------------------------------------------------------

local function get_clients_text()
	local count = 0
	
	tmpbuf:rewind():putstr(string.format('%-16s %-20s %-10s %s\n', 'IPAddr', 'MacAddr', 'State', 'Online'))
	for _, c in pairs(clients_bymac) do 
		count = count + 1
		tmpbuf:putstr(string.format('%-16s %-20s %-10s %d\n',
			c.ip, c.mac, c.state, math.floor(tasklet.now - c.starttime)))
	end
	
	if count == 0 then
		tmpbuf:putstr('(No clients online)')
	end
	
	return tmpbuf:str()
end  

local function init_ping_task()
	local function get_memfree()
		local value = 0
		local file = io.open('/proc/meminfo', 'r')
		for line in file:lines('/proc/meminfo') do 
			value = tonumber(line:match('MemFree:%s*(%d+)'))
			if value then
				break
			end
		end
		file:close()
		return value or 0
	end
	
	local function get_loadavg()
		local value = 0
		local file = io.open('/proc/loadavg', 'r')
		if file then
			local line = file:read('*line')
			if line then
				value = tonumber(line:match('([%.%d]+)')) or 0
			end
			file:close()
		end
		return value or 0
	end
	
	tasklet.start_task(function ()
		tasklet.sleep(math.floor(5 * math.random() + 5))
		while true do 
			while auth.neterr do 
				tasklet.sleep(1)
			end
			
			local succeed = auth.get_result({
				sys_memfree = get_memfree(),
				sys_load = string.format('%.2f', get_loadavg()),
			})
			
			log[succeed and 'debug' or 'error']('Ping ', succeed and 'succeed' or 'failed')
			tasklet.sleep(conf.ping_interval)
		end
	end)
end

local function init_client_timeout_check_task()	
	tasklet.start_task(function ()
		tasklet.sleep(math.floor(30 * math.random() + 30))
		while true do 
			tasklet.sleep(conf.check_interval)
			
			local client_timeout = conf.client_timeout
			local now = tasklet.now
			local state, starttime
			
			if fw.update_counters(clients_bymac) then
				for mac, c in pairs(clients_bymac) do 
					state = c.state
					starttime = c.starttime
					if state == 'login' then
						if starttime + 300 <= tasklet.now then
							log.debug('delete timedout client ', mac, ' in login state')
							clients_bymac[mac] = nil
						end
					elseif state == 'authed' then
						if starttime + client_timeout <= tasklet.now then
							log.info('client ', mac, ' timedout, firewall denied')
							fw.deny(c)
							c.state = 'logout'
							c.starttime = now
						end
					elseif state == 'logout' then
						if starttime + 900 <= tasklet.now then
							clients_bymac[mac] = nil
						end
					end
				end
				
				if not auth.neterr then
					local ret = auth.get_result('sync') or NULL
					
					now = tasklet.now
					for mac, c in pairs(clients_bymac) do 
						state = c.state
						if state == 'logout' then
							clients_bymac[mac] = nil
						elseif state == 'authed' then
							local code = tonumber((ret[mac] or NULL).code) or -1
							if code == 0 then
								fw.deny(c)
								clients_bymac[mac] = nil
							end
						end
					end
					log.debug('sync finished')
				else
					log.warn('sync delayed because net error')
				end
			end
		end
	end)
end

local commands = {
	clients = function ()
		return 0, get_clients_text()
	end,
	
	jclients = function ()
		require('cjson').encodeb(clients_bymac, tmpbuf:rewind())
		return 0, tmpbuf:str()
	end,

	reset = function (argv)
		local val = argv and argv[1]
		
		local function find_byip(ip)
			for _, c in pairs(clients_bymac) do 
				if c.ip == ip then
					return c
				end
			end
		end
		
		local c = val and (clients_bymac[val] or find_byip(val))
		
		if c then
			fw.deny(c)
			clients_bymac[c.mac] = nil
			return 0
		else
			return errno.ENOENT
		end
	end,
}

local function main()
	local usage = [[
Usage: wifidogx [options]
  -c            Config file path
  -d            Debug mode
  -a            Authentication URL(will override value in the config file)
  -f            Run in foreground
  -o <path>     Log output, default to /tmp/wifidogx.log(stdout in debug mode)
  -l <level>    Log level. default to 'info'('debug' in debug mode)
  -h            Print usage
  -v            Print version information
  -t            Test the legacy of config file
  -I            Initialize firewall rules
  -D            Destroy firewall rules
]]
	local opts = getopt(ARGV, 'dc:fp:l:hvtID')
	
	if not opts or opts.h then
		print(usage)
		os.exit(0)
	end
	if opts.v then
		print(VERSION)
		os.exit(0)
	end
	
	if opts.c then
		conf.config_file = opts.c 
	end
	if fs.access(conf.config_file, fs.R_OK) ~= 0 then
		log.fatal('failed to access ', conf.config_file)
	end
	if opts.t then
		log.fatal = function (...) 
			tmpbuf:rewind():putstr(...)
			error('')
		end
		local ok = pcall(conf.init)
		if ok then
			io.stderr:write('[Succeed]\n')
			dump(conf) -- TODO: the output is not good-looking.
			os.exit(0)
		else
			print(tmpbuf:str())
			os.exit(1)
		end
	end
	conf.init()
	
	if opts.I then
		fw.init(conf)
		os.exit(0)
	end
	if opts.D then
		fw.destroy(conf)
		os.exit(0)
	end
	
	if opts.a then
		conf.auth_url = opts.a
	end
	
	if opts.f then
		conf.daemon = false
	end
	
	local app = require 'app'
	app.APPNAME = 'wifidogx'
	local exitcode = app.run(opts, function ()
		app.start_ctlserver_task(commands)
		auth.init()
		http.init()
		fw.init(conf)
		init_ping_task()
		init_client_timeout_check_task()
	end)
	
	fw.destroy(conf)
	os.exit(exitcode)
end

main()
