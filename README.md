[README.md](https://github.com/user-attachments/files/33795029/README.md)
# SQL Server 2025 Express 自动安装

适用 Windows Server 2019 / 2022 / 2025，管理员运行 64 位 Windows PowerShell 5.1。
客户只需拿到 Install-SqlServer.ps1，以管理员身份运行。默认从微软官方下载 2025 Express 引导程序，再下载英文完整安装包，校验微软数字签名后解压并安装。无需预装 PowerShell 7、winget 或准备 ISO。客户机器需要能访问微软下载服务器，证书链验证需正常。

```powershell
# 仅检查
.\Install-SqlServer.ps1 -CheckOnly
# 接受许可后安装
.\Install-SqlServer.ps1 -AcceptLicenseTerms
# 可选：限制允许连接的来源网段
.\Install-SqlServer.ps1 -AcceptLicenseTerms -RemoteAddress '192.168.1.0/24'
```

默认实例 SQLEXPRESS，混合身份验证。默认 SQL 登录账号 sa，角色 sysadmin；安装后交互输入并确认密码。当前执行账户保留 Windows SQL 管理员权限；使用 -SqlSysAdminAccounts 添加其他 Windows 管理员。

安装后验证版本为 2025 Express，从 20000～49000 随机选择可绑定的端口，关闭动态端口并将随机结果保存为固定端口，绝不使用 1433。启用所有 IP 的 TCP 监听并重启 SQL 服务，验证对应进程正在监听。

启用 Windows 防火墙 Domain、Private、Public 配置文件，创建所选 TCP 端口及 SQL 服务的入站规则。默认允许任意来源，使用 -RemoteAddress 限定来源。不会修改其他已有规则。

终端显示连接地址，并保存 C:\ProgramData\SqlServerInstallLogs\SQLEXPRESS-connection.json。客户端使用 tcp:服务器IP,实际端口，选择 SQL Server 身份验证，以 sa 和自行设置的密码连接；无需 SQL Browser 查找端口。

若安装返回 3010，需手动重启后完成端口和防火墙配置：

```powershell
.\Install-SqlServer.ps1 -ConfigureOnly
```

配置失败也可排除原因后使用 ConfigureOnly 重试；保留已配置的范围内端口并重启 SQL 服务。自定义实例需同时提供 -InstanceName。来源限制需再次传入 -RemoteAddress。

退出码 0 表示安装及本机配置完成；3010 表示需重启并运行 ConfigureOnly；其他退出码表示失败。配置失败时实例可能已经安装，请不要重复新装。

日志：C:\ProgramData\SqlServerInstallLogs；SQL 安装日志：C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log。

脚本不自动下载补丁、不安装 SSMS、不自动重启、不用于升级或群集，不支持域控制器。数据目录、排序规则、内存使用安装默认值。已有宽泛防火墙规则、域组策略、网络防火墙和云安全组仍会影响实际访问；本机监听检查不等于外部 SQL 登录已验证。

已做语法与端口选择逻辑检查，未在上述三个 Windows Server 上执行实际安装。

官方依据：
- https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/install/windows/use-sql-server-in-windows
- https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-a-server-to-listen-on-a-specific-tcp-port
- https://learn.microsoft.com/en-us/sql/sql-server/install/configure-the-windows-firewall-to-allow-sql-server-access

## 客户运行方式

在脚本所在目录打开管理员 PowerShell，运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SqlServer.ps1 -AcceptLicenseTerms
```

此命令仅对当前 PowerShell 进程设置执行策略；组织组策略仍然有效。AcceptLicenseTerms 表示接受 SQL Server 的许可条款。

默认下载目录：C:\ProgramData\SqlServer2025ExpressMedia。下载和解压文件保留，便于故障排查和再次利用；每次自动下载使用独立目录。

如已准备好完整离线介质，可用 -MediaPath 指定包含 setup.exe 的目录，跳过网络下载。

DownloadUrl 可指定自有 HTTPS 镜像上的 SQL2025-SSEI-Expr.exe 原始微软签名引导程序；该参数不接受完整 SQLEXPR 包。引导程序随后仍从微软获取完整介质。默认官方地址已内置，无需修改。

CheckOnly 仅检查本机前置条件，不下载、不执行安装程序，也不验证下载连通性。失败时查看日志；安装若要求重启，按前文运行 ConfigureOnly。

验证范围：脚本语法检查通过。当前执行环境限制了网络下载，尚未完成真实下载安装测试，也没有在本机安装 SQL Server。

官方下载安装入口：https://www.microsoft.com/en-us/download/details.aspx?id=108836

## 网络禁用端口排除

已完整加入客户提供的禁用 TCP 端口：135-139、445、593、1024-1030、1080、1214、1363-1364、1368、1373、1377、1433、2222、2283、2535、2745、3127-3128、3333、3410、4444、5554、8866、9898、10000、10080、12345、14444、17300、22222、27374、33333。

随机候选范围仍为 20000～49000，排除其中的 22222、27374、33333；其余禁用端口本来就不在候选范围。ConfigureOnly 若发现已有端口被禁用，会重新选择允许的可用端口并更新本脚本的防火墙规则。实际监听验证也会检查禁用列表。

## sa 密码

安装完成后提示输入并确认 sa 密码；输入隐藏。要求 12～128 字符，至少包含大写、小写、数字、符号中的三类，并需满足客户机器的密码策略。

启用混合身份验证及 sa 登录，角色 sysadmin，启用密码策略检查，禁用自动密码过期。密码不会放入安装命令行、脚本日志或连接信息 JSON。脚本通过本机共享内存以 Windows 管理员身份设置密码；重启服务后验证 sa 能通过随机 TCP 端口登录并具备 sysadmin 权限。

每次运行 ConfigureOnly 都会要求重新设置 sa 密码；请使用具有该实例 SQL 管理员权限的 Windows 账户执行。若安装要求系统重启，将在重启后运行 ConfigureOnly 时设置密码。

本机验证连接启用加密并信任本机服务器证书；外部客户端应根据实际部署配置证书信任。

本次通过脚本语法检查，尚未执行真实数据库安装和 sa 登录验证。
