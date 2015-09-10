--
-- Copyright (C) Spyderj
--

local log = require 'log'
local tasklet = require 'tasklet.util'

local string, os, table = string, os, table
local tonumber = tonumber

local CHAIN_OUTGOING = 'wifidog_outgoing'
local CHAIN_TO_INTERNET = 'wifidog_2internet'
local CHAIN_INCOMING = 'wifidog_incoming'
local CHAIN_SERVERS = 'wifidog_servers'
local CHAIN_GLOBAL = 'wifidog_global'
local CHAIN_KNOWN = 'wifidog_known'
local CHAIN_UNKNOWN = 'wifidog_unknown'
local CHAIN_LOCKED  = 'wifidog_locked'
local CHAIN_TRUSTED = 'wifidog_trusted'

local MARK_NONE = '0x0/0x7'
local MARK_KNOWN = '0x1/0x7'
local MARK_LOCKED = '0x2/0x7'

local servers = {}
local green_ip = {}
local authed_mac = {}
local white_mac = {}
local black_mac = {}
local tmpbuf = tmpbuf

local fw = {}

local function execute(cmd)
	local pid = os.fork()
	if pid == 0 then
		os.close(2)
		os.execl('/bin/sh', '/bin/sh', '-c', cmd)
		os.exit(1)
	end
	
	local _, status = os.waitpid(pid)
	if os.WEXITSTATUS(status) == 0 then
		log.info('executed: ', cmd)
		return true
	else
		log.error('execution failed: ', cmd)
		return false
	end
end

local function iptables_do_command(...)
	execute(tmpbuf:rewind():putstr('iptables ', ...):str())
end

local action_modes = {
	block = 'REJECT',
	drop = 'DROP',
	allow = 'ACCEPT',
	log = 'LOG',
	ulog = 'ULOG',
}

local function iptables_do_rule(table, chain, rules, idx)
	local action, protocol, port, mask = rules[idx], rules[idx + 1], rules[idx + 2], rules[idx + 3]
	
	tmpbuf:rewind():putstr('iptables -t ', table, ' -A ', chain)
	if mask then
		tmpbuf:putstr(' -d ', mask)
	end
	if protocol then
		tmpbuf:putstr(' -p ', protocol)
	end
	if port then
		tmpbuf:putstr(' --dport ', port)
	end
	tmpbuf:putstr(' -j ', action_modes[action])
	
	execute(tmpbuf:str())
end

local function iptables_load_ruleset(conf, table, setname, chain)
	local rules = conf.rulesets[setname]
	if rules then
		local len = #rules
		local idx = 1
		while idx <= len do 
			iptables_do_rule(table, chain, rules, idx)
			idx = idx + 4
		end
	end
end


function fw.allow(client)
	local mac = client.mac
	if not authed_mac[mac] then
		iptables_do_command(string.format('-t mangle -A %s -s %s -m mac --mac-source %s -j MARK --set-mark %s', 
				CHAIN_OUTGOING, client.ip, client.mac, MARK_KNOWN))
				
		iptables_do_command('-t mangle -A ', CHAIN_INCOMING, ' -d ', client.ip, ' -j ACCEPT')
	
		authed_mac[mac] = true
	end
end

function fw.deny(client)
	local mac = client.mac
	if authed_mac[mac] then
		iptables_do_command(string.format('-t mangle -D %s -s %s -m mac --mac-source %s -j MARK --set-mark %s', 
			CHAIN_OUTGOING, client.ip, mac, MARK_KNOWN))
			
		iptables_do_command('-t mangle -D ', CHAIN_INCOMING, ' -d ', client.ip, ' -j ACCEPT')
		
		authed_mac[mac] = nil
	end
end

function fw.update_white_maclist(action, maclist)
	if action == '=' then
		iptables_do_command('-t mangle -F ', CHAIN_TRUSTED)
		white_mac = {}
		for _, mac in pairs(maclist) do 
			iptables_do_command(string.format(
				'-t mangle -A %s -m mac --mac-source %s -j MARK --set-mark %s', 
				CHAIN_TRUSTED, mac, MARK_KNOWN))
			white_mac[mac] = true
		end
	elseif action == '+' then
		for _, mac in pairs(maclist) do 
			if not white_mac[mac] then
				iptables_do_command(string.format(
					'-t mangle -A %s -m mac --mac-source %s -j MARK --set-mark %s', 
					CHAIN_TRUSTED, mac, MARK_KNOWN))
				white_mac[mac] = true
			end
		end
	elseif action == '-' then
		for _, mac in pairs(maclist) do 
			if white_mac[mac] then
				iptables_do_command(string.format(
					'-t mangle -D %s -m mac --mac-source %s -j MARK --set-mark %s', 
					CHAIN_TRUSTED, mac, MARK_KNOWN))
				white_mac[mac] = nil
			end
		end
	end
end

function fw.update_black_maclist(action, maclist)
	if action == '=' then
		iptables_do_command('-t mangle -F ', CHAIN_LOCKED)
		black_mac = {}
		for _, mac in pairs(maclist) do 
			iptables_do_command(string.format(
				'-t mangle -A %s -m mac --mac-source %s -j MARK --set-mark %s', 
				CHAIN_LOCKED, mac, MARK_LOCKED))
			black_mac[mac] = true
		end
	elseif action == '+' then
		for _, mac in pairs(maclist) do 
			if not black_mac[mac] then
				iptables_do_command(string.format(
					'-t mangle -A %s -m mac --mac-source %s -j MARK --set-mark %s', 
					CHAIN_LOCKED, mac, MARK_LOCKED))
				black_mac[mac] = true
			end
		end
	elseif action == '-' then
		for _, mac in pairs(maclist) do 
			if black_mac[mac] then
				iptables_do_command(string.format(
					'-t mangle -D %s -m mac --mac-source %s -j MARK --set-mark %s', 
					CHAIN_LOCKED, mac, MARK_LOCKED))
				black_mac[mac] = nil
			end
		end
	end
end

function fw.update_server(hostname)
	if hostname:is_ipv4() and not green_ip[hostname] then
		green_ip[hostname] = true
		iptables_do_command('-t filter -A ', CHAIN_SERVERS, ' -d ', hostname, ' -j ACCEPT')
		iptables_do_command('-t nat -A ', CHAIN_SERVERS, ' -d ', hostname, ' -j ACCEPT')
		return {hostname}
	else
		local iplist = tasklet.getaddrbyname(hostname)
		local old_iplist = servers[hostname]
		for _, ip in pairs(iplist) do 
			if not old_iplist or table.find(old_iplist, ip) and not green_ip[ip] then
				iptables_do_command('-t filter -A ', CHAIN_SERVERS, ' -d ', ip, ' -j ACCEPT')
				iptables_do_command('-t nat -A ', CHAIN_SERVERS, ' -d ', ip, ' -j ACCEPT')
				green_ip[ip] = true
			end
		end
		if old_iplist then
			for _, ip in pairs(old_iplist) do
				if not table.find(iplist, ip) and green_ip[ip] then
					iptables_do_command('-t filter -D ', CHAIN_SERVERS, ' -d ', ip, ' -j ACCEPT')
					iptables_do_command('-t nat -D ', CHAIN_SERVERS, ' -d ', ip, ' -j ACCEPT')
					green_ip[ip] = nil
				end
			end
		end
		servers[hostname] = iplist
		return iplist
	end
end

function fw.init(conf)
	-----------------------------------------------------------------------------------------------
	-- { MANGLE 
	iptables_do_command('-t mangle -N ', CHAIN_TRUSTED)
	iptables_do_command('-t mangle -N ', CHAIN_LOCKED)
	iptables_do_command('-t mangle -N ', CHAIN_OUTGOING)
	iptables_do_command('-t mangle -N ', CHAIN_INCOMING)
	iptables_do_command('-t mangle -I PREROUTING 1 -i ', conf.gw_interface, ' -j ', CHAIN_OUTGOING)
	iptables_do_command('-t mangle -I PREROUTING 1 -i ', conf.gw_interface, ' -j ', CHAIN_TRUSTED)
	iptables_do_command('-t mangle -I PREROUTING 1 -i ', conf.gw_interface, ' -j ', CHAIN_LOCKED)
	iptables_do_command('-t mangle -I POSTROUTING 1 -o ', conf.gw_interface, ' -j ', CHAIN_INCOMING)
	-- }
	-----------------------------------------------------------------------------------------------

	
	
	-----------------------------------------------------------------------------------------------
	-- { NAT
	iptables_do_command('-t nat -N ', CHAIN_OUTGOING)
	iptables_do_command('-t nat -N ', CHAIN_UNKNOWN)
	iptables_do_command('-t nat -N ', CHAIN_GLOBAL)
	iptables_do_command('-t nat -N ', CHAIN_SERVERS)

	iptables_do_command('-t nat -A PREROUTING -i ', conf.gw_interface, ' -j ', CHAIN_OUTGOING)

	iptables_do_command('-t nat -A ', CHAIN_OUTGOING, ' -d ', conf.gw_address, ' -j ACCEPT')
	iptables_do_command('-t nat -A ', CHAIN_OUTGOING, ' -m mark --mark ', MARK_KNOWN, ' -j ACCEPT')
	iptables_do_command('-t nat -A ', CHAIN_OUTGOING, ' -j ', CHAIN_UNKNOWN)
	iptables_do_command('-t nat -A ', CHAIN_UNKNOWN, ' -j ', CHAIN_SERVERS)
	iptables_do_command('-t nat -A ', CHAIN_UNKNOWN, ' -j ', CHAIN_GLOBAL)
	iptables_do_command('-t nat -A ', CHAIN_UNKNOWN, ' -p tcp --dport 80 -j REDIRECT --to-ports ', conf.gw_port)
	-- }
	-----------------------------------------------------------------------------------------------
	
	
	
	-----------------------------------------------------------------------------------------------
	-- { FILTER
	iptables_do_command('-t filter -N ', CHAIN_TO_INTERNET)
	iptables_do_command('-t filter -N ', CHAIN_SERVERS)
	iptables_do_command('-t filter -N ', CHAIN_LOCKED)
	iptables_do_command('-t filter -N ', CHAIN_GLOBAL)
	iptables_do_command('-t filter -N ', CHAIN_KNOWN)
	iptables_do_command('-t filter -N ', CHAIN_UNKNOWN)

	iptables_do_command('-t filter -I FORWARD -i ', conf.gw_interface, ' -j ', CHAIN_TO_INTERNET)
	iptables_do_command('-t filter -A ', CHAIN_TO_INTERNET, ' -m state --state INVALID -j DROP')

	iptables_do_command('-t filter -A ', CHAIN_TO_INTERNET, ' -j ', CHAIN_SERVERS)

	iptables_do_command('-t filter -A ', CHAIN_TO_INTERNET, ' -m mark --mark ', MARK_LOCKED, ' -j ', CHAIN_LOCKED)
	iptables_load_ruleset(conf, 'filter', 'locked-users', CHAIN_LOCKED)

	iptables_do_command('-t filter -A ', CHAIN_TO_INTERNET, ' -j ', CHAIN_GLOBAL)
	iptables_load_ruleset(conf, 'filter', 'global', CHAIN_GLOBAL)
	iptables_load_ruleset(conf, 'nat', 'global', CHAIN_GLOBAL)

	iptables_do_command('-t filter -A ', CHAIN_TO_INTERNET, ' -m mark --mark ', MARK_KNOWN, ' -j ', CHAIN_KNOWN)
	iptables_load_ruleset(conf, 'filter', 'known-users', CHAIN_KNOWN)

	iptables_do_command('-t filter -A ', CHAIN_TO_INTERNET, ' -j ', CHAIN_UNKNOWN)
	iptables_load_ruleset(conf, 'filter', 'unknown-users', CHAIN_UNKNOWN)
	iptables_do_command('-t filter -A ', CHAIN_UNKNOWN, ' -j REJECT --reject-with icmp-port-unreachable')
	-- }
	-----------------------------------------------------------------------------------------------
end


local function destroy_mention(table, chain, mention)
	local file = io.popen(string.format('iptables -t %s -L %s -n --line-numbers -v 2>/dev/null', table, chain), 'r')
	if not file then
		return
	end
	
	local deleted = false
	file:read('*line')
	file:read('*line')
	local line = file:read('*line')
	while line do 
		if line:find(mention) then
			local num = tonumber(line:match('%d+'))
			if num then
				iptables_do_command('-t ', table, ' -D ', chain, ' ', num)
				deleted = true
				break
			end
		end
		line = file:read('*line')
	end
	file:close()
	
	if deleted then
		destroy_mention(table, chain, mention)
	end
end

function fw.destroy(conf)
	destroy_mention('mangle', 'PREROUTING', CHAIN_TRUSTED)
	destroy_mention('mangle', 'PREROUTING', CHAIN_LOCKED)
	destroy_mention('mangle', 'PREROUTING', CHAIN_OUTGOING)
	destroy_mention('mangle', 'POSTROUTING', CHAIN_INCOMING)
	iptables_do_command('-t mangle -F ', CHAIN_TRUSTED)
	iptables_do_command('-t mangle -F ', CHAIN_OUTGOING)
	iptables_do_command('-t mangle -F ', CHAIN_LOCKED)
	iptables_do_command('-t mangle -F ', CHAIN_INCOMING)
	iptables_do_command('-t mangle -X ', CHAIN_TRUSTED)
	iptables_do_command('-t mangle -X ', CHAIN_OUTGOING)
	iptables_do_command('-t mangle -X ', CHAIN_LOCKED)
	iptables_do_command('-t mangle -X ', CHAIN_INCOMING)

	destroy_mention('nat', 'PREROUTING', CHAIN_OUTGOING)
	iptables_do_command('-t nat -F ', CHAIN_SERVERS)
	iptables_do_command('-t nat -F ', CHAIN_OUTGOING)
	iptables_do_command('-t nat -F ', CHAIN_GLOBAL)
	iptables_do_command('-t nat -F ', CHAIN_UNKNOWN)
	iptables_do_command('-t nat -X ', CHAIN_SERVERS)
	iptables_do_command('-t nat -X ', CHAIN_OUTGOING)
	iptables_do_command('-t nat -X ', CHAIN_GLOBAL)
	iptables_do_command('-t nat -X ', CHAIN_UNKNOWN)

	destroy_mention('filter', 'FORWARD', CHAIN_TO_INTERNET)
	iptables_do_command('-t filter -F ', CHAIN_TO_INTERNET)
	iptables_do_command('-t filter -F ', CHAIN_SERVERS)
	iptables_do_command('-t filter -F ', CHAIN_LOCKED)
	iptables_do_command('-t filter -F ', CHAIN_GLOBAL)
	iptables_do_command('-t filter -F ', CHAIN_KNOWN)
	iptables_do_command('-t filter -F ', CHAIN_UNKNOWN)
	iptables_do_command('-t filter -X ', CHAIN_TO_INTERNET)
	iptables_do_command('-t filter -X ', CHAIN_SERVERS)
	iptables_do_command('-t filter -X ', CHAIN_LOCKED)
	iptables_do_command('-t filter -X ', CHAIN_GLOBAL)
	iptables_do_command('-t filter -X ', CHAIN_KNOWN)
	iptables_do_command('-t filter -X ', CHAIN_UNKNOWN)
end

function fw.update_counters(clients_bymac)
	local clients_byip = {}
	for mac, c in pairs(clients_bymac) do 
		clients_byip[c.ip] = c
	end
	
	local function update_bytes(chain, field, pattern)
		local file = io.popen('iptables -v -n -x -t mangle -L ' .. chain .. ' 2>/dev/null', 'r')
		if not file then
			return false
		end
		
		file:read('*line')
		file:read('*line')
		local line = file:read('*line')
		while line do 
			local bytes, ip = line:match(pattern)
			if bytes and ip then
				local client = clients_byip[ip]
				if client then
					client[field] = tonumber(bytes) or 0
				else
					log.error('update_counters(): ', ip, ' is missing in the clients, destroy mangle mention')
					destroy_mention("mangle", CHAIN_OUTGOING, ip)
					destroy_mention("mangle", CHAIN_INCOMING, ip)
				end
			end
			line = file:read('*line')
		end
		file:close()
		return true
	end
	return update_bytes(CHAIN_OUTGOING, 'outgoing', '^%s*%d+%s*(%d+).-(%d+%.%d+%.%d+%.%d+)') 
		and update_bytes(CHAIN_INCOMING, 'incoming', '^%s*%d+%s*(%d+).-%d+%.%d+%.%d+%.%d+.-(%d+%.%d+%.%d+%.%d+)')
end
	
return fw

