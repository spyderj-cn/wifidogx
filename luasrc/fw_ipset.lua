--
-- Copyright (C) Spyderj
--


local log = require 'log'
local tasklet = require 'tasklet.util'

local string, os, table = string, os, table
local tonumber = tonumber

local IPSET_WHITEMAC = 'wifidog_whitemac'
local IPSET_BLACKMAC = 'wifidog_blackmac'
local IPSET_GREENIP = 'wifidog_greenip'
local IPSET_AUTHEDMAC = 'wifidog_authedmac'

local CHAIN_MARK = 'wifidog_mark'
local CHAIN_NAT = 'wifidog_nat'
local CHAIN_FILTER = 'wifidog_filter'
local CHAIN_KNOWN = 'wifidog_known'
local CHAIN_UNKNOWN = 'wifidog_unknown'
local CHAIN_LOCKED = 'wifidog_blocked'

local MARK_KNOWN = '0x1/0x3'
local MARK_LOCKED = '0x2/0x3'
local MARK_NONE = '0x0/0x3'

local servers = {}

local fw = {}

local tmpbuf = tmpbuf

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

local function iptables_load_ruleset(rules, table, chain)
	if rules then
		local len = #rules
		local idx = 1
		while idx <= len do 
			iptables_do_rule(table, chain, rules, idx)
			idx = idx + 4
		end
	end
end

local function ipset_do_command(...)
	execute(tmpbuf:rewind():putstr('ipset ', ...):str())
end

local function update_maclist(setname, action, maclist)
	if action == '=' then
		ipset_do_command('-F ', setname)
		for _, mac in pairs(maclist) do 
			ipset_do_command('-A ', setname, ' ', mac)
		end
	elseif action == '+' then
		for _, mac in pairs(maclist) do 
			ipset_do_command('-A ', setname, ' ', mac)
		end
	elseif action == '-' then
		for _, mac in pairs(maclist) do 
			ipset_do_command('-D ', setname, ' ', mac)
		end
	end
end

function fw.update_white_maclist(action, maclist)
	update_maclist(IPSET_WHITEMAC, action, maclist)
end

function fw.update_black_maclist(action, maclist)
	update_maclist(IPSET_BLACKMAC, action, maclist)
end

function fw.update_server(hostname)
	if hostname:is_ipv4() and not servers[hostname] then
		servesr[hostname] = true
		ipset_add(IPSET_GREENIP, hostname)
		return {hostname}
	else
		local iplist = tasklet.getaddrbyname(hostname)
		local old_iplist = servers[hostname]
		for _, ip in pairs(iplist) do 
			if not old_iplist or not table.find(old_iplist, ip) then
				ipset_do_command('-A ', IPSET_GREENIP, ' ', ip)
			end
		end
		if old_iplist then
			for _, ip in pairs(old_iplist) do
				if not table.find(iplist, ip) then
					ipset_do_command('-D ', IPSET_GREENIP, ' ', ip)
				end
			end
		end
		servers[hostname] = iplist
		return iplist
	end
end

function fw.allow(c)
	ipset_do_command('-A ', IPSET_AUTHEDMAC, ' ', c.mac)
end

function fw.deny(c)
	ipset_do_command('-D ', IPSET_AUTHEDMAC, ' ', c.mac)
end

-- TODO:
function fw.update_counters(clients_bymac)
	return true
end

function fw.init(conf)
	ipset_do_command('-N ', IPSET_WHITEMAC, ' hash:mac')
	ipset_do_command('-N ', IPSET_BLACKMAC, ' hash:mac')
	ipset_do_command('-N ', IPSET_AUTHEDMAC, ' hash:mac')
	ipset_do_command('-N ', IPSET_GREENIP, ' hash:ip')
	
	-----------------------------------------------------------------------------------------------
	-- { MANGLE 
	iptables_do_command('-t mangle -N ', CHAIN_MARK)
	iptables_do_command('-t mangle -I PREROUTING -i ', conf.gw_interface, ' -j ', CHAIN_MARK)
	iptables_do_command('-t mangle -A ', CHAIN_MARK, 
		' -m mark --mark ', MARK_NONE, 
		' -m set --match-set ', IPSET_GREENIP, ' dst',
		' -j MARK --set-mark ', MARK_KNOWN)
	iptables_do_command('-t mangle -A ', CHAIN_MARK, 
		' -m mark --mark ', MARK_NONE, 
		' -m set --match-set ', IPSET_AUTHEDMAC, ' src',
		' -j MARK --set-mark ', MARK_KNOWN)
	iptables_do_command('-t mangle -A ', CHAIN_MARK, 
		' -m mark --mark ', MARK_NONE, 
		' -m set --match-set ', IPSET_WHITEMAC, ' src',
		' -j MARK --set-mark ', MARK_KNOWN)
	iptables_do_command('-t mangle -A ', CHAIN_MARK, 
		' -m mark --mark ', MARK_NONE, 
		' -m set --match-set ', IPSET_BLACKMAC, ' src',
		' -j MARK --set-mark ', MARK_LOCKED)
	-- }
	-----------------------------------------------------------------------------------------------
	
	
	
	-----------------------------------------------------------------------------------------------
	-- { NAT
	iptables_do_command('-t nat -N ', CHAIN_NAT)
	iptables_do_command('-t nat -I PREROUTING', ' -i ', conf.gw_interface, ' -j ', CHAIN_NAT)
	iptables_do_command('-t nat -A ', CHAIN_NAT, ' -d ', conf.gw_address, ' -j ACCEPT')
	iptables_do_command('-t nat -A ', CHAIN_NAT, ' -m mark --mark ', MARK_KNOWN, ' -j ACCEPT')
	iptables_do_command('-t nat -A ', CHAIN_NAT, ' -p tcp --dport 80 -j REDIRECT --to-ports ', conf.gw_port)
	-- }
	-----------------------------------------------------------------------------------------------
	
	
	
	-----------------------------------------------------------------------------------------------
	-- { FILTER
	iptables_do_command('-t filter -N ', CHAIN_FILTER)
	iptables_do_command('-t filter -N ', CHAIN_LOCKED)
	iptables_do_command('-t filter -N ', CHAIN_KNOWN)
	iptables_do_command('-t filter -N ', CHAIN_UNKNOWN)

	iptables_do_command('-t filter -I FORWARD -i ', conf.gw_interface, ' -j ', CHAIN_FILTER)
	iptables_do_command('-t filter -A ', CHAIN_FILTER, ' -m state --state INVALID -j DROP')
	
	iptables_do_command('-t filter -A ', CHAIN_FILTER, ' -m mark --mark ', MARK_LOCKED, ' -j ', CHAIN_LOCKED)
	iptables_load_ruleset(conf.rulesets['locked-users'], 'filter', CHAIN_LOCKED)

	iptables_do_command('-t filter -A ', CHAIN_FILTER, ' -m mark --mark ', MARK_KNOWN, ' -j ', CHAIN_KNOWN)
	iptables_load_ruleset(conf.rulesets['known-users'], 'filter', CHAIN_KNOWN)

	iptables_do_command('-t filter -A ', CHAIN_FILTER, ' -m mark --mark ', MARK_NONE, ' -j ', CHAIN_UNKNOWN)
	iptables_load_ruleset(conf.rulesets['unknown-users'], 'filter', CHAIN_UNKNOWN)
	
	iptables_do_command('-t filter -A ', CHAIN_UNKNOWN, ' -p tcp -j REJECT --reject-with tcp-reset')
	iptables_do_command('-t filter -A ', CHAIN_UNKNOWN, ' -j REJECT --reject-with icmp-port-unreachable')
	-- }
	-----------------------------------------------------------------------------------------------
end

function fw.destroy(conf)
	iptables_do_command('-t mangle -D PREROUTING -i ', conf.gw_interface, ' -j ', CHAIN_MARK)
	iptables_do_command('-t mangle -F ', CHAIN_MARK)
	iptables_do_command('-t mangle -X ', CHAIN_MARK)
	
	iptables_do_command('-t nat -D PREROUTING -i ', conf.gw_interface, ' -j ', CHAIN_NAT)
	iptables_do_command('-t nat -F ', CHAIN_NAT)
	iptables_do_command('-t nat -X ', CHAIN_NAT)

	iptables_do_command('-t filter -D FORWARD -i ', conf.gw_interface, ' -j ', CHAIN_FILTER)
	iptables_do_command('-t filter -F ', CHAIN_FILTER)
	iptables_do_command('-t filter -F ', CHAIN_LOCKED)
	iptables_do_command('-t filter -F ', CHAIN_KNOWN)
	iptables_do_command('-t filter -F ', CHAIN_UNKNOWN)
	iptables_do_command('-t filter -X ', CHAIN_FILTER)
	iptables_do_command('-t filter -X ', CHAIN_LOCKED)
	iptables_do_command('-t filter -X ', CHAIN_KNOWN)
	iptables_do_command('-t filter -X ', CHAIN_UNKNOWN)
	
	ipset_do_command('-F ', IPSET_WHITEMAC)
	ipset_do_command('-F ', IPSET_BLACKMAC)
	ipset_do_command('-F ', IPSET_AUTHEDMAC)
	ipset_do_command('-F ', IPSET_GREENIP)
	ipset_do_command('-X ', IPSET_WHITEMAC)
	ipset_do_command('-X ', IPSET_BLACKMAC)
	ipset_do_command('-X ', IPSET_AUTHEDMAC)
	ipset_do_command('-X ', IPSET_GREENIP)
end

return fw

