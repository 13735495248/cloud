服务器: 101.201.236.30
密码: dbb975154286..

ssh root@101.201.236.30

执行脚本: 
ssh root@101.201.236.30 "CSV_STDOUT=1 bash -s" < nginx_version_inventory.sh > nginx_inventory.csv

.sh里面用column做表格
.bat兼容性比ps1好,ps1能力更强



Get-CimInstance Win32_Process -Filter "Name='nginx.exe'" | Select-Object -Unique ExecutablePath | ForEach-Object { $p=$_.ExecutablePath; $v=&$p -V 2>&1; [PSCustomObject]@{ NginxExe=$p; VersionRaw=$v; Version=(($v|Select-String 'nginx/(\d+\.\d+\.\d+)').Matches.Groups[1].Value) } }

补充说明: 
上述自动盘点脚本仅适用于 Linux 系统；
Windows 系统可能包含 WSL 环境，暂无法通过脚本完成统一盘点，请采用手动方式盘点。
如有需要,可参考下述操作盘点：
1.盘点Windows宿主机Nginx版本,使用Power Shell运行:
$nginxList = Get-CimInstance Win32_Process -Filter "Name='nginx.exe'" | Select-Object -Unique ExecutablePath
if (-not $nginxList) {
    Write-Host "未检测到运行中的Nginx"
} else {
    $nginxList | ForEach-Object {
        $p = $_.ExecutablePath
        $v = & $p -V 2>&1
        [PSCustomObject]@{
            NginxExe    = $p
            VersionRaw  = $v
            Version     = (($v | Select-String 'nginx/(\d+\.\d+\.\d+)').Matches.Groups[1].Value)
        }
    }
}

2.盘点WSL中Nginx版本:
请将脚本 xxx 上传到服务器的 WSL 目录中并执行。

手动盘点完成后，请将盘点结果保存至文档，文件命名规范：姓名_服务器ip.txt，并上传至目录：xxx。

注意:
Nginx版本分为稳定版和开发版,
版本号中间段数字为偶数即为稳定版（例：1.28.1），奇数为主线开发版（例：1.31.1）；
偶数版本统一升级至 1.30.7，奇数版本统一升级至 1.31.9。
 
