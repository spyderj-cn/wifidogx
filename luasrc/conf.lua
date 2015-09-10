--
-- Copyright (C) Spyderj
--

local log = require 'log'
local type, tonumber = type, tonumber

local conf = {
	GZ_PATH = '/tmp/wifidogx-static.gz',
	WWW_FLASH = '/etc/wifidogx-www',
	WWW_ROOT = '/tmp/wifidogx-www',
	WWW_STATIC_PREFIX = 'wifidogx-static',

	daemon = true,
	external_interface = false,
	config_file = '/etc/wifidogx.conf',
	gw_id = false,
	gw_interface = false,
	gw_address = false,
	gw_port = 2060,
	client_timeout = 3600,
	check_interval = 300,
	ping_interval = 15,
	auth_url = false,
	redirect_hostname = false,
	redirect_port = 80,
	message_path = false,
	login_path = false,
	portal_path = false,
	rulesets = {},
}

local function conf_update(data, firsttime)
	if data.CheckInterval then
		conf.check_interval = tonumber(data.CheckInterval) or conf.check_interval
	end
	if data.PingInterval then
		conf.ping_interval = tonumber(data.PingInterval) or conf.ping_interval
	end
	if data.ClientTimeout then
		conf.client_timeout = tonumber(data.ClientTimeout) or conf.client_timeout
	end
	if data.MessagePath then
		conf.message_path = data.MessagePath
	end
	if data.LoginPath then
		conf.login_path = data.LoginPath
	end
	if data.PortalPath then
		conf.portal_path = data.PortalPath
	end
	if data.RedirectPort then
		conf.redirect_port = tonumber(data.RedirectPort) or 80
	end
	if data.RedirectHostname then
		conf.redirect_hostname = data.RedirectHostname
		fw.update_server(conf.redirect_hostname)
	end
	
	if type(data.SetWhiteMaclist) == 'table' then
		fw.update_white_maclist('=', data.SetWhiteMaclist)
	else
		if type(data.AddWhiteMaclist) == 'table' then
			fw.update_white_maclist('+', data.AddWhiteMaclist)
		end
		if type(data.DelWhiteMaclist) == 'table' then
			fw.update_white_maclist('-', data.DelWhiteMaclist)
		end
	end
	if type(data.SetBlackMaclist) == 'table' then
		fw.update_black_maclist('=', data.SetBlackMaclist)
	else
		if type(data.AddBlackMaclist) == 'table' then
			fw.update_black_maclist('+', data.AddBlackMaclist)
		end
		if type(data.DelBlackMaclist) == 'table' then
			fw.update_black_maclist('-', data.DelBlackMaclist)
		end
	end
	
	if type(data.GreenHostname) == 'table' then
		for _, hostname in pairs(data.GreenHostname) do 
			fw.update_server(hostname)
		end
	end
end

local function conf_validate()
	local err
	
	if conf.external_interface then
		_, err = iface.getmac(conf.external_interface)
		if err ~= 0 then
			log.fatal('ExternalInterface', conf.external_interface, ' error: ', errno.strerror(err))
		end
	else
		conf.external_interface = iface.getext()
	end
	
	if not conf.gw_interface then
		log.fatal('Configuaration option GatewayInterface is a must')
	end
	_, err = iface.getmac(conf.gw_interface)
	if err ~= 0 then
		log.fatal('GatewayInterface ', conf.gw_interface, ' error: ', errno.strerror(err))
	end
	
	if not conf.gw_address then
		conf.gw_address = iface.getip(conf.gw_interface)
	end
	
	local port = conf.gw_port
	if port < 0 or port > 65535 then
		log.warn('invalid gw_port(', port, '), fallback to default value(2060)')
		conf.gw_port = 2060
	end
	
	local fd, err = socket.tcpserver(conf.gw_address, conf.gw_port)
	if fd < 0 and err ~= errno.EADDRINUSE then
		log.fatal('failed to listen on ', conf.gw_address, ':', conf.gw_port, ', errno: ', errno.strerror(err))
	end
	os.close(fd)
	
	if not conf.gw_id then
		conf.gw_id = iface.getmac(conf.gw_interface)
	end
end

local function conf_loadfile()
	local name2field = {
		Daemon = 'daemon',
		ExternalInterface = 'external_interface',
		GatewayID = 'gw_id',
		GatewayInterface= 'gw_interface',
		GatewayAddress = 'gw_address',
		GatewayPort = 'gw_port',
		ClientTimeout = 'client_timeout',
		CheckInterval = 'check_interval',
		AuthURL = 'auth_url',
		RedirectHostname = 'redirect_hostname',
		RedirectPort = 'redirect_port',
		LoginPath = 'login_path',
		PortalPath = 'portal_path',
		MessagePath = 'message_path',
	}
	local booleans = {
		daemon = true,
	}
	local numbers = {
		client_timeout = true,
		check_interval = true,
		gw_port = true,
		redirect_port = true,
	}
	local actions = {
		block = true,
		log = true,
		ulog = true,
		allow = true,
		drop = true,
	}
	local protocols = {
		tcp = true,
		icmp = true,
		udp = true
	}
	
	local obj = conf
	local is_ruleset = false
	local line_pos = 0
	local lbrace_line_pos
	
	local function extract_kvpair(line)
		local name, value = line:match('%s*(%S+)%s*(%S*)')
		if name and value and #value > 0 then
			local field = name2field[name]
			if field then
				if booleans[field] then
					if value == 'yes' or value == 'y' or value == '1'then
						value = true
					elseif value == 'no' or value == 'n' or value == '0' then
						value = false
					else
						log.fatal('illegal value ', value, ' at line ', line_pos, ', must be yes/y/1/no/n/0')
					end
				elseif numbers[field] then
					value = tonumber(value:match('^(%-?%d+)$'))
					if not value then
						log.fatal('illegal value ', value, ' at line ', line_pos, ' must be an interger')
					end
				end
				conf[field] = value
			end
		end
	end
	
	local function extract_rule(line)
		local action, detail = line:match('FirewallRule (%a+) (%a.*)')
		local protocol, port, mask = false, false, false
		local msg = 'syntax error for FirewallRule at line '
		
		if not action or not detail or not actions[action] then
			log.fatal(msg, line_pos)
		end
		
		table.insert(obj, action)
		
		if detail:find('port') then
			protocol, port, detail = detail:match('(%a+) port (%d+)(.*)')
			port = tonumber(port)
			if not detail or not protocols[protocol] or not port then
				log.fatal(msg, line_pos)
			end	
		end
		table.insert(obj, protocol)
		table.insert(obj, port)
		
		if detail:find('to') then
			mask = detail:match('to (%d+%.%d+%.%d+%.%d+/?%d*)')
			if not mask then
				log.fatal(msg, line_pos)
			end
		end
		table.insert(obj, mask)
	end
	
	for line in io.lines(conf.config_file) do 
		line_pos = line_pos + 1
		if not line:match('^%s*#') and line:find('%S') then -- skip commentary and empty lines
			local sectype, secname = line:match('^%s*(%S+)%s*(%S*)%s*{')
			
			if sectype then
				if obj ~= conf then
					log.fatal('bracet \'{\' at line ', lbrace_line_pos, ' is not closed')
				end
				lbrace_line_pos = line_pos
			end
			
			if sectype == 'FirewallRuleSet' then
				obj = {}
				conf.rulesets[secname] = obj
				is_ruleset = true
			elseif line:find('}') then
				if obj == conf then
					log.fatal('unmatched \'}\' at line ', line_pos)
				end
				obj = conf
				is_ruleset = false
			else
				(is_ruleset and extract_rule or extract_kvpair)(line)
			end
		end
	end
	
	if obj ~= conf then
		log.fatal('bracet \'{\' at line ', lbrace_line_pos, ' is not closed')
	end
	conf_validate()
end

function conf.init()
	conf_loadfile()
	table.insert(conf_update_callbacks, conf_update)
end

return conf
