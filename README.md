# GitHub 分发 SQL Server 2025 Express

上传 Install-SqlServer.ps1 和 Start-SqlServer2025.ps1 到公开仓库 shangchuanji/kabuto 的 main 分支根目录。将本说明作为新版 README.md 上传，覆盖旧版说明。

管理员 Windows PowerShell 中执行：

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; IEX (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/shangchuanji/kabuto/main/Start-SqlServer2025.ps1')
```

输入 YES 接受许可，随后输入并确认 sa 密码，再自动下载和安装。脚本来自 GitHub，SQL Server 2025 Express 英文安装介质来自微软官方；不用参考脚本的 FTP 凭据或旧版 install.bat。

## 配置

- 支持 Windows Server 2019 / 2022 / 2025，管理员 64 位 Windows PowerShell 5.1。
- 默认实例 MSSQLSERVER，与参考脚本一致。
- 混合身份验证；sa 登录，sysadmin 角色，保留当前 Windows 账户的 SQL 管理员权限。
- 最大服务器内存配置 4096 MB，与参考脚本一致；Express 自身资源限制仍适用。
- 默认关闭 sa 的 CHECK_POLICY、CHECK_EXPIRATION，与参考脚本一致；脚本自身要求密码 12～128 字符，至少含大小写、数字、符号中的三类，隐藏输入并二次确认。
- 随机选取 20000～49000 的可用固定端口，排除此前完整禁用列表，包括范围内的 22222、27374、33333，绝不选择 1433。
- 开启 TCP，关闭动态端口；重启此 SQL 服务并验证 sa 的 TCP 登录及 sysadmin 权限。
- 启用 Windows 防火墙三种配置文件并放行该 SQL 服务和端口，默认允许任意来源。
- 不自动重启 Windows。待重启标记只提示，不删除；SQL Setup 自身仍可能要求重启。

连接地址：tcp:服务器IP,实际端口，SQL Server 身份验证，账号 sa，密码使用客户设置的值。
连接信息：C:\ProgramData\SqlServerInstallLogs\MSSQLSERVER-connection.json，不保存密码。
脚本日志：C:\ProgramData\SqlServerInstallLogs。
SQL 安装日志：C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log。
安装介质保留在 C:\ProgramData\SqlServer2025ExpressMedia。

## 恢复和参数

启动器显示主脚本在临时目录的实际保存位置。配置失败后用该路径执行主脚本 -ConfigureOnly；会重新询问 sa 密码并重启实例服务。SQL Setup 返回 3010 时网络配置尚未完成，需安排重启后再运行 ConfigureOnly，不能保证所有服务器免重启完成。

旧版默认实例是 SQLEXPRESS；恢复旧实例必须加 -InstanceName SQLEXPRESS。新版不迁移旧实例，不覆盖已有实例。

主脚本支持 -MediaPath 指定离线介质、-RemoteAddress 限制来源、-MaxServerMemoryMB 修改内存配置、-EnforceSaPasswordPolicy 启用 SQL 密码策略、-CheckOnly 仅本机预检查。

本机验证连接启用加密并信任本机证书；外部客户端应配置实际证书信任。云安全组、网络防火墙和域策略仍会影响访问。

文件仅在本地生成，尚未上传 GitHub。未在三个 Windows Server 系统实际安装，真实下载安装和数据库登录仍需验证。
