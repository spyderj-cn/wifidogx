--
-- Copyright (C) Spyderj
--

local log = require 'log'
local urlparse = require 'urlparse'
local http = require 'http'
local tasklet = require 'tasklet'

local os, io, string = os, io, string
local fs, stat, bit32 = fs, stat, bit32
local conf, fw, auth, fs = conf, fw, auth, fs

local type, tonumber = type, tonumber
local tmpbuf = tmpbuf 


local GZ_PATH = conf.GZ_PATH
local WWW_FLASH = conf.WWW_FLASH
local WWW_ROOT = conf.WWW_ROOT
local WWW_ROOTP = WWW_ROOT:gsub('%-', '%%%-')
local WWW_STATIC_PREFIX = conf.WWW_STATIC_PREFIX
local WWW_STATIC_PREFIXP = string.format('^/%s(.+)', WWW_STATIC_PREFIX:gsub('%-', '%%%-'))

-------------------------------------------------------------------------------
-- core variables {

-- WWW_ROOT cant not be overwritten if www_refcount > 0.
-- Incremented before reading from WWW_ROOT, and decremented after reading.
local www_refcount = 0

-- Once valid, we need to get the archive through this URL.
-- Changed back to false when we have finished the downloading.
local gz_url = false

-- Whether we are downloading the archive.
-- New archive updating request will be ignored if we are still downloading the previous one.
local gz_downloading = false

-- Whether the arhive has been downloaded(and required to be installed).
-- Changed back to false once installed.
local gz_downloaded = false

-- How many clients are authenticated since wifidogx booted up.
local n_authed = 0

-- }
-------------------------------------------------------------------------------

local function get_mac(ip)
	local mac
	local file = io.open('/proc/net/arp', 'r')
	if not file then
		log.error('failed to open /proc/net/arp, errno: ', errno.strerror())
		return
	end 
	for line in file:lines() do 
		local _ip, _mac = line:match('^(%d+%.%d+%.%d+%.%d+).*(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)')
		if _ip and _mac and _ip == ip then
			mac = _mac
			break
		end
	end
	file:close()
	return mac
end

local function may_install_gz()
	if gz_downloaded and www_refcount == 0 then
		os.execute(string.format('tar zxf %s -C %s', GZ_PATH, WWW_ROOT))
		fs.unlink(GZ_PATH)
		gz_downloaded = false
	end
end

local function update_gz()
	fs.unlink(GZ_PATH)
	gz_downloaded = false
	local cmd = string.format('wget -O %s "%s" >/dev/null', GZ_PATH, gz_url)
	for i = 1, 10 do 
		local ch = tasklet.create_execl_channel(cmd)
		ch:read()
		ch:close()
		if fs.access(GZ_PATH, fs.R_OK) == 0 then
			gz_downloaded = true
			break
		else
			tasklet.sleep(30)
		end
	end
	may_install_gz()
	gz_downloading = false
end

local function http_reply_file(ch, fd, size, mtime, mime_type)
	local buf = buffer.new()
	local status = fd >= 0 and 200 or 304
	
	buf:putstr(
		'HTTP/1.0 ', status, ' ', http.reasons[status],
		'\r\nConnection: close',
		'\r\nContent-Length: ', size,
		'\r\nContent-Type: ', mime_type,
		'\r\nDate: ', time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.time()),
		'\r\nLast-Modified: ', time.strftime("%a, %d %b %Y %H:%M:%S GMT", mtime), '\r\n\r\n')
		
	if status == 200 then
		local left = size
		while ch:write(buf) == 0 and left > 0 do
			buf:rewind()
			local n = left > 1024 and 1024 or left
			if os.readb(fd, buf, n) ~= n then
				break
			end
			left = left - n
		end
	else
		ch:write(buf)
	end
end

local function http_error(ch, status, reason, msg)
	tmpbuf:rewind():putstr(
		'HTTP/1.0 ', status, ' ', reason or http.reasons[status] or 'OK',
		'\r\nConnection: close',
		'\r\nContent-Length: ', msg and #msg or 0,
		'\r\nContent-Type: text/plain\r\n\r\n', 
		msg and msg or '')

	-- FIXME: see http_redirect
	ch:write(tmpbuf)
end

local function http_static(task, urlpath, if_modified_since)
	local wwwpath = urlpath:match(WWW_STATIC_PREFIXP)
	local ch = task.ch
	local filepath = wwwpath and fs.realpath(WWW_ROOT .. wwwpath)
	local status = 200
	local filest
	
	if not filepath then
		status = 404
	elseif filepath:find(WWW_ROOTP) ~= 1 then
		status = 403 
	else
		filest = fs.stat(filepath)
		if not filest then
			status = 404
		elseif not stat.isreg(filest.mode) or not bit32.btest(filest.mode, stat.S_IRUSR) then
			status = 403
		end
	end
	
	if status == 200 and if_modified_since then
		local tstamp = time.strptime(if_modified_since, '%a, %d %b %Y %H:%M:%S %Z')
		if not tstamp then
			http_error(ch, 400, nil, 'malformed value for If-Modified-Since header')
			return
		end
		if (tstamp + 0.1) >= filest.mtime then
			status = 304
		end	
	end
	
	if status == 200 or status == 304 then
		local fd = -1
		if status == 200 then
			local err
			fd, err = os.open(filepath, os.O_RDONLY)
			if fd < 0 then
				http_error(ch, 500, nil, 
				string.format('open(%s, O_RDONLY) failed: %s', fs.basename(filepath), errno.strerror(err)))
				return
			end
		end
	
		www_refcount = www_refcount + 1
		http_reply_file(ch, fd, filest.size, filest.mtime, http.get_content_type(filepath))
		if fd >= 0 then
			os.close(fd)
		end
		www_refcount = www_refcount - 1
		may_install_gz()
	else
		http_error(ch, status)
	end
end

local function http_show_html(ch, name)
	local filepath = string.format('%s/%s.htm', WWW_ROOT, name)
	local filest = fs.stat(filepath)
	if not filest then
		filepath = string.format('%s/%s.htm', WWW_FLASH, name)
		filest = fs.stat(filepath)
		if not filest then
			http_error(ch, 500, nil, 'core file missing: file system corrupted?')
			return
		end
	end
	
	local fd = os.open(filepath, os.O_RDONLY)
	www_refcount = www_refcount + 1
	http_reply_file(ch, fd, filest.size, filest.mtime, 'text/html')
	os.close(fd)
	www_refcount = www_refcount - 1
	may_install_gz()
end

local function http_redirect(ch, urlpath, params)
	local hostname = conf.redirect_hostname
	if not hostname or not urlpath then
		http_show_html(ch, 'internalerror')
		return
	end

	tmpbuf:rewind():putstr(
		'HTTP/1.0 302 Redirected',
		'\r\nConnection: close',
		'\r\nContent-Length: 0',
		'\r\nLocation: http://', hostname, ':', conf.redirect_port, urlpath)
	
	local tparams = type(params)
	if tparams == 'table' then
		for k, v in pairs(params) do 
			tmpbuf:putstr(urlparse.encode(k), '=', urlparse.encode(v), '&')
		end
	elseif tparams == 'string' then
		tmpbuf:putstr(params)
	end
	
	tmpbuf:putstr('\r\n\r\n')
	
	-- FIXME: The kernel always has enough space to hold tmpbuf's content, 
	-- so we saved the cost of creating and destroying a new buffer.
	-- There may be exceptions, however, but it does not cause too much danger, 
	-- so this is the price I am willing to pay.
	ch:write(tmpbuf)
end



local function http_404(task)	
	local req = task.req
	local ch = task.ch
	local org_url = 'http://' .. req.host .. req.urlpath
	if auth.neterr then
		http_show_html(ch, auth.neterr)
	else
		http_redirect(ch, conf.login_path, {
			gw_address = conf.gw_address,
			gw_port = conf.gw_port,
			gw_id = conf.gw_id,
			url = org_url,
			mac = get_mac(task.ip),
		})
	end
end

local function http_wifidog(task, urlpath)
	local ch = task.ch
	local node = urlpath:match('^/wifidogx?/(%w+)') -- Either '/wifidog/xxx' or '/wifidogx/xxx' is OK.
	if node == 'auth' then
		local token = (task.req.params or NULL).token
		local ip = task.ip
		local mac = get_mac(ip)
		if not token or not mac then
			log.error('internal error: ', token and 'token invalid' or 'mac not found for ip ' .. ip)
			http_show_html(ch, 'internalerror')
			return
		end
		
		local client = clients_bymac[mac]
		if not client then
			client = {
				ip = ip,
				mac = mac,
				token = token,
				starttime = tasklet.now,
				state = 'login',
				incoming = 0,
				outgoing = 0,
			}
			clients_bymac[mac] = client
		else
			client.token = token
		end
		
		local code = auth.get_result(client) or -1
		log.info('client ', ip, ': auth code ', code)
		if code == 0 then
			client.state = 'login'
			client.starttime = tasklet.now
			fw.deny(client)
			log.debug('client ', ip, ': redirect to ', conf.redirect_hostname, conf.message_path)
			http_redirect(ch, conf.message_path, 'message=denied')
		elseif code == 1 then
			client.state = 'authed'
			client.starttime = tasklet.now
			fw.allow(client)
			n_authed = n_authed + 1
			log.debug('client ', ip, ': redirect to ', conf.redirect_hostname, conf.portal_path)
			http_redirect(ch, conf.portal_path, 'gw_id=' .. urlparse.encode(conf.gw_id))
		else 	
			log.debug('client ', ip, ': show servererror html page')
			http_show_html(ch, 'servererror')
		end
	else
		http_404(task)
	end
end

local function http_new_connection(fd, ip)
	log.debug('connection established with ', ip)
	
	os.setcloexec(fd)
	local ch = tasklet.create_stream_channel(fd)
	local req = http.request.new()
	
	tasklet.start_task(function ()
		local task = tasklet.current_task()
		if req:read_header(ch, 10) == 0 then
			local urlpath = req.urlpath
			
			log.debug('from ', ip, ':  ', req.method, ' http://', req.host, urlpath)
			
			local branch = urlpath:match('^/([%w_%-]+)')
			if branch == 'wifidog' or branch == 'wifidogx' then
				http_wifidog(task, urlpath)
			elseif branch == WWW_STATIC_PREFIX then
				http_static(task, urlpath, req.headers['if-modified-since'])
			else
				http_404(task)
			end
		end

		-- If the connection is GOOD, we delay for a little to let the client close the connection first.
		if ch.ch_state > 0 then
			tasklet.sleep(3)
		end
		ch:close()
		log.debug('connection off with ', ip)
	end, {
		req = req,
		ch = ch,
		ip = ip
	})
end

local function http_init()
	if not fs.isdir(WWW_ROOT) then
		if not fs.isdir(WWW_FLASH) then
			log.fatal('failed to access ', WWW_FLASH, ', file system corrupted?')
		end
		os.execute(string.format('cp -r %s %s', WWW_FLASH, WWW_ROOT))
	end
	
	table.insert(conf_update_callbacks, function (data)
		if data.StaticGZ and not gz_downloading then
			gz_url = data.StaticGZ
			gz_downloading = true
			tasklet.start_task(update_gz)
		end
	end)
	require('app').start_tcpserver_task(conf.gw_address, conf.gw_port, http_new_connection)
end

return {
	init = http_init,
}
