
# Wifidogx

Wifidogx是一款新的无线认证客户端，最早出于spyderj做无线营销时碰到的wifidog各种稳定性问题。经过一段时间的发展后，其功能和优点已经大幅超出了wifidog：


####**更稳定**
- 解决了Wifidog频繁退出和死锁的问题。

####**更高效**
- 采用epoll来支持并发。
- 新的认证通信协议可支持批量认证。

####**更强大**
- 提供以ipset的方式进行防火墙规则管理(需要6.22及以上版本)。
- 支持与认证服务器之间采用https通信。
- 支持简单的静态文件服务。
- 更好的集中管理：认证服务器应答报文中可随时携带要下发的配置信息，wifidogx检测到有配置信息后会立刻予以生效。

####**更便捷**
- 单线程架构，无需再小心翼翼的加锁。
- 全部由lua编码，即改即得，快的有点狠的二次开发效率。

> 目前Wifiodgx已被业内多家公司用于商场wifi，厂区wifi等领域，在最高在线用户近500人， 最大并发超过3000的状态下其各项性能指标仍然非常优异。

### 下载，编译，运行


wifidogx依赖[lask](https://github.com/spyderj-cn/lask)。lask导出了常用的posix api，并提供了一个异步通信框架。

####**下载**
git clone https://github.com/spyderj-cn/wifidogx.git

####**编译**
Wifidogx中(只)包含了支持openwrt的makefile文件，将源码包放在某个src-link的的目录下即可。
同wifidog一样，wifidogx也在menuconfig的/Network/Captive Portals栏目下。

> 本质上wifidogx不需要编译，其编译实际上是安装过程。


####**运行**
#####**启动**
 /etc/init.d/wifidogx start
 
#####**停止**
/etc/init.d/wifidogx stop

>目前不支持restart

-----

#####**Wifidogx详细的启动参数**
| 选项 |含义|
|-------|------|
| -a  | 认证路径，会覆盖配置文件中的AuthURL|
|-c |配置文件路径，默认为/etc/wifidogx.conf|
|-d| 调试模式|
|-f|  不要以守护进程的方式运行|
|-o|  日志路径，默认为/tmp/wifidogx.log|
|-l | 日志等级，默认为info|
|-t | 测试配置文件是否正确|
|-I|  初始化防火墙规则后退出|
|-D| 销毁防火墙规则后退出|
|-h|  帮助信息|
|-v|  显示版本|

>调试模式下，Wifidogx自动开启-f选项，日志输出到标准输出，日志级别为debug。建议在初次接触wifidogx时使用调试模式。

#####**Wifidogx运行时生成的文件**
以下文件默认在/tmp目录下(其中日志文件所在目录可另行指定)

| 文件名 |作用|
|-------|------|
|wifidogx.log|  日志文件|
|wifidogx.pid| 文件中包含wifidogx的pid|
|wifidogx.sock| 和wdxctl通信的unix域套接字服务端文件|
|wifidogx.death| 异常退出后的lua栈信息|

#####**wdxctl(对应wdctl)工具**
| 命令 | 作用 |
|----|-----|
|clients|获取连接了wifi的用户信息|
|jclients|获取连接了wifi的用户信息(json输出)|
|logcapture|截获日志|


------
###文件服务
wifidogx启动后检查/tmp/wifidogx-www是否存在，如果不存在则将/etc/wifidogx-www下的所有内容
复制到/tmp/wifidogx-www，并以/tmp/wifidogx-www为docroot开启文件服务。
如果来访的URL是“/wifidogx-static/*”格式则视其为请求静态文件。
当错误发生时，wifidogx自动回送/tmp/wifidogx-www目录下的以下文件:

| 文件名 | 错误原因 |
|-------|----------|
|netdown.htm|外网不通|
|serverunreach.htm|有外网但认证服务器连不上|
|servererror.htm |服务器返回的数据不对|
|internalerror.htm |路由器系统/wifidogx 内部错误，如arp表中根据来访的ip找不到mac|

在后续和服务器的通信中，如果服务器的应答配置了StaticGZ, 则wifidogx根据StaticGZ指定的URL下载该压缩包，并将压缩包的内容解压到/tmp/wifidogx-www中。

>一些典型的StaticGZ用法：
>
> -  替换wifidogx的错误提示页面。
> -  缓存login等页面上的图片。
> -  指定RedirectHostname为GatewayAddress，完全进行本地推送认证页面。



------
###配置文件
配置文件中的选项，大部分都可以由认证服务器动态修改，除了以下几项：
AuthURL 
GatewayID   (可选）
GatewayPort (可选）
GatewayAddress 
GatewayInterface
ExternalInterface (可选)
Firewall Rules 

####**一些改动**

- 不再支持AuthServer块和多个认证服务器，只支持单个AuthURL。
> (如有特殊字符请先编码，wifidogx不自动进行url编码。) 
> 示例：
AuthURL    https://mysite.com:8888/index.php?s=/Wifidogx/auth

- 重定向服务器可以和认证服务器不同，由RedirectHostname指定。
> RedirectPort指定跳转端口，默认为80。
几个跳转路径分别由PortalPath/MessagePath/LoginPath指定。
（PortalPath/MessagePath/LoginPath尾部的&(或?)是必要的；并且如有特殊字符请先编码）。
示例：
RedirectHostname www.mysite2.com
PortalPath        /index.php?s=/Wifidogx/portal
MessagePath       /index.php?s=/Wifidogx/message
LoginPath         /index.php?s=/Wifidogx/login
   
   
- ClientTimeout的意义改为认证后能上网的时间(秒)。
> 示例：
ClientTimeout   7200


- 添加PingInterval字段，意义是和服务器的心跳间隔(秒)。
> 示例：
PingInterval    30


- 配置文件中的黑白MAC名单将被忽略。

------
###通信协议

####**技术特点**
通信过程是wifidogx和wifidog区别最大的一块：

* 能进行批量认证，数据采用json编码，使用post方法发送http请求。
* 数据量比较大的时候使用gzip压缩。
* 最多只和认证服务器建一条tcp连接，所有认证都通过这条连接进行。
* 报文的发送间隔和远程控制的延时成正比。因此心跳间隔不适合太大，并且双方的http报文应启用keep-alive。
> 请在http应答中指定Content-Length为实际长度，或者启用Chunked的传输编码，wifidogx无法自动探测消息体的结束。

####**请求**
#####**报文示例**
``` javascript
{
	"id": "11:11:11:11:11:11"
	"version": "1.0.0",
	"clients": [
		{
			"mac" : "11:11:11:11:11:12"
			"ip" : "192.168.1.123",
			"token" : "whateverthetokenis",
			"state" : "authed",
			"incoming" : 1111,
			"outgoing" : 2222,
			"starttime" : 1234,
		},
		{
			"mac" : "11:11:11:11:11:13"
			...
		},
		...
	],
	"uptime": 333,
	"seq": 20,
	"sys_uptime" : 123132,
	"status": {
		"sys_memfree":9284,
		"sys_load":"0.03"
	},	
}
```

#####**字段意义详解**
> *表示必需的，非必需项的属性名可以不存在，也可能其值为false或者{} 

|字段名|说明|
|------|----|
|id*|即GatewayID，若无指定则是GatewayInterface的mac地址|
|version*|wifidogx版本号|
|uptime*|wifidogx启动后经过的秒数|
|sys_uptime*|系统启动后经过的秒数（即/proc/uptime）|
|seq*|报文序号，每成功完成一次http交互后加一，初始为0|
|clients|需要认证处理的用户信息|
|status|当前系统状态|
<br/>
clients为用户信息数组，每个元素的各字段意义是：

|字段名|说明|
|------|----|
|mac|用户mac|
|ip|用户使用的ip|
|token|token|
|state|当前状态|
|starttime|进入此状态的时间戳（自系统启动），即sys_uptime - starttime为状态已持续时间|
|outgoing|发送的流量|
|incoming|接收的流量|

<br/>
几种状态：

|状态名称|解释|
|---------|-----|
|login|用户还未认证，防火墙规则未放行|
|authed|已认证，已放行|
|logout|认证期已过，规则已关，通知了认证服务器后此用户信息会被删除|

####**应答**
#####**报文示例**
``` javascript
{
	"config":{
		"ClientTimeout":7200,
		"PingInterval":20,
		"CheckInterval":300,
		"StaticGZ":"http://mysite.com/Public/wifidogx.tar.gz",
		"SetWhiteMaclist":["9c:c1:72:5e:51:49","11:11:11:11:11:12"],
		"SetBlackMaclist":["11:11:11:11:11:13","11:11:11:11:11:14"],
		"GreenHostname" : ["www.baidu.com", "1.2.3.4"]
	},
	"clients":[
		{"mac":"08:7a:4c:8a:c1:62","auth":1}
	]
}
```

#####**配置项**
当应答中指定了config时，wifidogx将立即接受这样配置并予以生效。
这些是wifidogx新增的配置项：

|配置名|解释|
|-------|----|
|StaticGZ|见文件服务部分|
|SetWhiteMaclist|设置白名单|
|AddWhiteMaclist|添加白名单|
|DelWhiteMaclist|删除白名单|
|SetBlackMaclist|设置黑名单|
|AddBlackMaclist|添加黑名单|
|DelBlackMaclist|删除黑名单|
|GreenHostname|无论是否认证都可直接访问的主机名|


#####**认证结果**
wifidogx不支持wifidog的试用期功能，认证结果只能是1或者0，其他值不合法。

### 附录

####**服务端开发示例**
#####**PHP版本(基于ThinkPHP)**

*wifidogx的AuthURL指定为 http://mysite.com/index.php?s=/Wifidogx/auth*
``` php
class WifidogxAction extends Action
{
	public function auth()
	{
		$resp = array();
		$req = false;
		$content = file_get_contents('php://input');

		if ($content && $_SERVER['CONTENT_ENCODING'] && strpos($_SERVER['CONTENT_ENCODING'], 'gzip') !== false)
			$content = gzdecode($content);
		if ($content)
			$req = json_decode($content);
		if (!$req || !$req->id)
			return;

		if ($req->seq == 0) {
			$resp['config'] = array(
				'ClientTimeout' => 7200,
				'PingInterval' => 20,
				'CheckInterval' => 300,
				'StaticGZ' => 'http://mysite.com/Public/wifidogx.tar.gz',
				'SetWhiteMaclist' => array('9c:c1:72:5e:51:49', '11:11:11:11:11:12'),
				'SetBlackMaclist' => array('11:11:11:11:11:13', '11:11:11:11:11:14'),
				'RedirectHostname' => 'mysite.com',
				'LoginPath' => '/index.php?s=/Wifidogx/login&',
				'MessagePath' => '/index.php?s=/Wifidogx/message&'
				'PortalPath' => '/index.php?s=/Wifidogx/portal&'
			);
		}

		if ($req->clients) {
			$clients = array();
			foreach ($req->clients as $client) {
				$clients[] = array(
					'mac' => $client->mac,
					'auth' => 1,
				);
			}
			$resp['clients'] = $clients;
		}

		$json_resp = json_encode($resp);
		header('Content-Length: ' . strlen($json_resp));
		header('Content-Type: application/json');
		echo $json_resp;
	}
	
	public function login()
	{
		// ...
	}
	
	public function message()
	{
		// ...
	}
	
	public function portal()
	{
		// ...
	}
}
```
