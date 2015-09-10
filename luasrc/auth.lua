--
-- Copyright (C) Spyderj
--

local log = require 'log'
local urlparse = require 'urlparse'
local http = require 'http'
local tasklet = require 'tasklet'
local cjson = require 'cjson'
local zlib = require 'zlib'

-- If length of http-request-message-body is larger than this, we use gzip(to save bandwidth).
local GZIP_THRESHOLD = 4000

local tostring, tonumber = tostring, tonumber

require 'tasklet.service'
require 'tasklet.util'
require 'tasklet.channel.stream'

local auth = {
	https = false,
	port = 80,
	hostname = false,
	urlpath = false,
	neterr = true,
}

-------------------------------------------------------------------------------
-- core variables {

local ch_auth
local ch_netdown = tasklet.create_stream_channel()
local buf = buffer.new()	
local resp = http.response.new()
local ip_list = NULL
local ip_index = 1
local n_failed = 0
local seq = 0

local started_time = tasklet.now

local reqdata = {
	version = VERSION,
	uptime = false,
	sys_uptime = false,
	seq = 0,
	clients = false,
	status = false,
	id = false,
}

local tmpbuf = tmpbuf

-- }
-------------------------------------------------------------------------------

local function init_url(url)
	local urlinfo = urlparse.split(url) or log.fatal(url, ' is not a valid URL')
	local urlpath = urlinfo.path
	if urlinfo.query then
		urlpath = urlpath .. '?' .. urlinfo.query
	end
	
	local https = urlinfo.scheme == 'https'
	if https then
		require 'tasklet.channel.sslstream'
		tasklet.sslstream_channel.ctx = require('ssl').context.new('sslv23')
		ch_auth = tasklet.create_sslstream_channel()
	else
		ch_auth = tasklet.create_stream_channel()
	end
	
	auth.https = https
	auth.port = urlinfo.port or (https and 443 or 80)
	auth.hostname = urlinfo.host
	auth.urlpath = urlpath
end

local function make_reqdata(reqarr, n)
	local clients = {}
	local synced = false
	
	reqdata.seq = seq
	reqdata.clients = false
	reqdata.status = false
	reqdata.uptime = math.floor(tasklet.now - started_time)
	reqdata.sys_uptime = math.floor(tasklet.now)
	
	for i = 1, n do 
		local req = reqarr[i]
		if req == 'sync' then
			if not synced then
				for mac, c in pairs(clients_bymac) do 
					if c.state == 'authed' or c.state == 'logout' then
						table.insert(clients, c)
					end
				end
				synced = true
			end
		elseif req.mac then
			table.insert(clients, req)
		else
			reqdata.status = req
		end
	end
	
	reqdata.clients = clients
end

local updating_config = false
local function process_respdata(data, reqarr, resparr, errarr, n)
	local config = data.config
	if config and not updating_config then
		updating_config = true

		-- Config updating may concern with ip resolving, so we have to start a new
		-- task to do this.
		-- More updating requests are ignored until the previous is finished.
		tasklet.start_task(function ()
			for _, cb in pairs(conf_update_callbacks) do 
				cb(config)
			end
			updating_config = false
		end)
	end
	
	local clients = data.clients
	if clients and #clients > 0 then
		local c_bymac = {}
		for _, c in pairs(clients) do 
			c_bymac[c.mac] = c
		end
		clients = c_bymac
	end
	
	for i = 1, n do 
		local req = reqarr[i]
		if req == 'sync' then
			resparr[i] = clients
		elseif req.mac then
			local c = clients and clients[req.mac]
			log.debug('auth server response for ', req.mac, ': ', c and c.auth or tostring(c))
			resparr[i] = tonumber(c and c.auth) or -1
		else
			resparr[i] = true
		end
	end
end

local function is_netdown()
	for _, pop_server in pairs({
		'www.baidu.com',
		'www.taobao.com'
	}) do 
		local iplist = tasklet.getaddrbyname(pop_server) or NULL
		for _, ip in pairs(iplist) do 
			if ch_netdown:connect(ip, 80) == 0 then
				ch_netdown:close()
				return false
			end
		end
	end
	return true
end

local function resolve_auth_server()
	ip_list = fw.update_server(auth.hostname)
	if #ip_list == 0 then
		local neterr = auth.neterr
		if is_netdown() then
			if neterr ~= 'netdown' then			
				log.error('internet unaccessible')
				auth.neterr = 'netdown'
			end
		elseif neterr ~= 'serverunreach' then
			auth.neterr = 'serverunreach'
			log.error('auth server(', auth.hostname, ') unreachable')
		end
		return false
	end
	return true
end

local function connect_auth_server()
	if #ip_list == 0 and not resolve_auth_server() then
		return false
	end
	
	local ip_start = ip_index
	local ip = ip_list[ip_index]
	if not ip then
		return false
	end
	
	local err = ch_auth:connect(ip, auth.port)
	while err ~= 0 do
		ip_index = ip_index + 1
		if ip_index > #ip_list then
			ip_index = 1
		end
		if ip_index == ip_start then
			break
		end
		ip = ip_list[ip_index]
		err = ch_auth:connect(ip, auth.port)
	end
	
	if err == 0 then
		n_failed = 0
		auth.neterr = false
		return true
	else
		if auth.neterr ~= 'serverunreach' then
			auth.neterr = 'serverunreach'
			log.error('auth server unreachable')
		end
		n_failed = n_failed + 1
		if n_failed == 10 then
			ip_list = NULL
			n_failed = 0
		end
		return false
	end
end

local function svc_handler(reqarr, resparr, errarr, n)
	local err = -1
	
	for i = 1, 2 do 
		if not auth.neterr then
			if ch_auth.ch_state <= 0 then
				if ch_auth.ch_fd >= 0 then
					ch_auth:close()
				end
				connect_auth_server()
			end
			
			if not auth.neterr then
				if #buf == 0 then
					local encoding = 'identity'
					make_reqdata(reqarr, n)
					cjson.encodeb(reqdata, tmpbuf:rewind())
					if #tmpbuf > GZIP_THRESHOLD then
						assert(zlib.compress(tmpbuf) == 0)
						encoding = 'gzip'
					end
					buf:putstr(
						'POST ', auth.urlpath, ' HTTP/1.1\r\n', 
						'Host: ', auth.hostname, '\r\n',
						'User-Agent: Wifidogx ', VERSION, '\r\n',
						'Content-Type: application/json\r\n',
						'Content-Encoding: ', encoding, '\r\n',
						'Connection: keep-alive\r\n',
						'Content-Length: ', #tmpbuf, '\r\n\r\n')
					buf:putreader(tmpbuf:reader())
				end
				
				if ch_auth:write(buf) == 0 then
					err = resp:read(ch_auth, 5)
				else
					err = ch_auth.ch_err
				end
				
				if err == 0 then
					break
				end
			end
		end
	end
	buf:rewind()
			
	if err == 0 then
		local content = resp.content
		if content then
			content:putc(0)
			local ok, data = pcall(cjson.decodeb, content)
			if ok then
				process_respdata(data, reqarr, resparr, errarr, n)
				seq = seq + 1
			else
				local len = #content
				if len > 500 then
					log.error('cjson.decodeb failed: ', data, '\n>>>\n', content:getlstr(500), ' ... ...')
				else
					log.error('cjson.decodeb failed: ', data, '\n>>>\n', content:str())
				end
			end
		end
	else
		log.error('I/O error with auth server: ', errno.strerror(err))
		for i = 1, n do 
			errarr[i] = err
		end
	end
			
	if resp.conn_close then
		ch_auth:close()
	end
end

function auth.init()
	init_url(conf.auth_url)
	reqdata.id = conf.gw_id
	
	tasklet.start_task(function ()
		while true do 
			while not auth.neterr do 
				tasklet.sleep(1)
			end
			if connect_auth_server() then
				ch_auth:close()
			end
			tasklet.sleep(5)
		end
	end)
	
	tasklet.create_multi_service('auth', svc_handler, 20, 0.5)
end

function auth.get_result(req)
	return tasklet.request('auth', req, 10)
end

return auth
