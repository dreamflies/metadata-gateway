#Requires -Version 5.1
<#
.SYNOPSIS
  一键初始化 Javinizer 并把 API Token 写入 .env，无需打开 Web UI。
.DESCRIPTION
  幂等：可重复执行，已初始化的部分会自动跳过。
  适用于 Windows + Docker Desktop（PowerShell 5.1 及以上，无需额外安装工具）。
.EXAMPLE
  .\init.ps1
.EXAMPLE
  .\init.ps1 -AdminUser admin -AdminPassword '你的密码'
#>
[CmdletBinding()]
param(
    [string]$AdminUser = $(if ($env:JAVINIZER_ADMIN_USER) { $env:JAVINIZER_ADMIN_USER } else { 'admin' }),
    [string]$AdminPassword = $env:JAVINIZER_ADMIN_PASSWORD
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

function Write-Info { param([string]$Message) Write-Host '==> ' -ForegroundColor Cyan -NoNewline; Write-Host $Message }
function Write-Warn { param([string]$Message) Write-Host '[!] ' -ForegroundColor Yellow -NoNewline; Write-Host $Message }

function Invoke-Compose {
    # 兼容 docker compose (v2) 与 docker-compose (v1)
    & docker compose @args
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($args -join ' ') 执行失败" }
}

# .env 统一用 UTF-8 无 BOM + LF 写入。
# PowerShell 5.1 的 Out-File/> 默认写 UTF-16，Compose 无法解析；
# 这里显式指定编码，同时保持与 macOS/Linux 侧文件格式一致。
function Write-EnvFile {
    param([string[]]$Lines)
    $text = ($Lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText((Join-Path $PWD '.env'), $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-EnvValue {
    param([string]$Key)
    if (-not (Test-Path '.env')) { return $null }
    $line = Get-Content '.env' -Encoding UTF8 | Where-Object { $_ -match "^$([regex]::Escape($Key))=" } | Select-Object -Last 1
    if ($null -eq $line) { return $null }
    return $line.Substring($line.IndexOf('=') + 1)
}

function Set-EnvValue {
    param([string]$Key, [string]$Value)
    $lines = @()
    if (Test-Path '.env') { $lines = @(Get-Content '.env' -Encoding UTF8) }
    $pattern = "^$([regex]::Escape($Key))="
    if ($lines -match $pattern) {
        $lines = $lines | ForEach-Object { if ($_ -match $pattern) { "$Key=$Value" } else { $_ } }
    } else {
        $lines += "$Key=$Value"
    }
    Write-EnvFile -Lines $lines
}

function New-RandomHex {
    param([int]$ByteCount = 32)
    $bytes = New-Object byte[] $ByteCount
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-RandomPassword {
    # 只用字母数字，避免 shell 引号和 JSON 转义问题
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (($bytes | ForEach-Object { $chars[$_ % $chars.Length] }) -join '')
}

# ---------- 1. 准备 .env 和数据目录 ----------
if (-not (Test-Path '.env')) {
    Write-Info '创建 .env'
    # 直接按 UTF-8 无 BOM 重写，避免 Copy-Item 保留原始编码
    Write-EnvFile -Lines @(Get-Content '.env.example' -Encoding UTF8)
    # Windows 上 Docker Desktop 不使用 PUID/PGID 做文件属主映射，保持默认即可
    Set-EnvValue -Key 'PUID' -Value '1000'
    Set-EnvValue -Key 'PGID' -Value '1000'
}
New-Item -ItemType Directory -Force -Path 'gateway-data', 'javinizer-data' | Out-Null

$gatewayToken = Get-EnvValue 'GATEWAY_TOKEN'
if ([string]::IsNullOrWhiteSpace($gatewayToken) -or $gatewayToken -eq 'change-me') {
    Write-Info '生成随机 GATEWAY_TOKEN'
    Set-EnvValue -Key 'GATEWAY_TOKEN' -Value (New-RandomHex 32)
}

# ---------- 2. 启动 Javinizer 并等待健康 ----------
Write-Info '启动 Javinizer'
Invoke-Compose up -d javinizer

$port = Get-EnvValue 'JAVINIZER_HOST_PORT'
if ([string]::IsNullOrWhiteSpace($port)) { $port = '8765' }

Write-Info "等待 Javinizer 健康检查 (127.0.0.1:$port)"
$ready = $false
foreach ($i in 1..60) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null
        $ready = $true
        Write-Info 'Javinizer 已就绪'
        break
    } catch { Start-Sleep -Seconds 1 }
}
if (-not $ready) {
    Write-Warn "等待超时，请检查 'docker compose logs javinizer'"
    exit 1
}

# ---------- 3. 非交互创建管理员 ----------
# setup 接口只信任 localhost/可信网段，宿主机经端口映射会被判为外部地址（403），
# 因此必须在容器内部调用 127.0.0.1。
$initialized = $false
try {
    $status = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/v1/auth/status" -TimeoutSec 5
    $initialized = [bool]$status.initialized
} catch { $initialized = $false }

if ($initialized) {
    Write-Info '管理员账号已存在，跳过创建'
} else {
    $generated = $false
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        $AdminPassword = New-RandomPassword
        $generated = $true
    }
    Write-Info "创建管理员账号 ($AdminUser)"

    $body = @{ username = $AdminUser; password = $AdminPassword } | ConvertTo-Json -Compress
    # 传进容器内的 sh：JSON 整体用单引号包住，内部双引号保持原样。
    # 注意不要转义成 \" —— sh 的单引号内不做反斜杠还原，会把 \" 原样发出去导致 400。
    if ($AdminPassword -match "['\\]" -or $AdminUser -match "['\\]") {
        Write-Warn '管理员用户名/密码包含单引号或反斜杠，请改用不含这两个字符的值'
        exit 1
    }
    $inner = "wget -q -O- --header='Content-Type: application/json' --post-data='$body' http://127.0.0.1:8765/api/v1/auth/setup"

    $setupOut = & { $ErrorActionPreference = 'Continue'
                    (& docker compose exec -T javinizer sh -c $inner 2>&1 |
                      ForEach-Object { $_.ToString() }) -join "`n" }
    # wget 在 HTTP 4xx/5xx 时退出码为 8，能可靠捕获失败
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "管理员创建失败（wget 退出码 $LASTEXITCODE）：$setupOut"
        Write-Warn "如需排查请执行 'docker compose logs javinizer'"
        exit 1
    }

    Set-EnvValue -Key 'JAVINIZER_ADMIN_USER' -Value $AdminUser
    if ($generated) {
        Set-EnvValue -Key 'JAVINIZER_ADMIN_PASSWORD' -Value $AdminPassword
        Write-Warn '已生成随机管理员密码并写入 .env（JAVINIZER_ADMIN_PASSWORD），登录 Web UI 时使用'
    }
}

# ---------- 4. 生成 API Token ----------
# token create 直接写数据库，不依赖登录态。
if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue 'JAVINIZER_TOKEN'))) {
    Write-Info 'JAVINIZER_TOKEN 已存在，跳过生成'
} else {
    Write-Info '生成 Javinizer API Token'
    # 该命令会把启动日志和 JSON 混在一起输出，只截取第一个 "{" 之后的部分
    # docker -T 会把日志噪音同时送到 stdout/stderr；PowerShell 5.1 下 stderr 会变成 ErrorRecord，
    # 在 $ErrorActionPreference='Stop' 时可能中断脚本，因此显式合并并转成纯字符串。
    $raw = & { $ErrorActionPreference = 'Continue'
               (& docker compose exec -T javinizer javinizer token create --name metadata-gateway --json 2>&1 |
                 ForEach-Object { $_.ToString() }) -join "`n" }
    $braceIndex = $raw.IndexOf('{')
    $token = $null
    if ($braceIndex -ge 0) {
        try { $token = ($raw.Substring($braceIndex) | ConvertFrom-Json).token } catch { $token = $null }
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Warn 'Token 生成失败'
        exit 1
    }
    Set-EnvValue -Key 'JAVINIZER_TOKEN' -Value $token
    Write-Info 'Token 已写入 .env'
}

# ---------- 5. 启动全部服务 ----------
Write-Info '启动全部服务'
Invoke-Compose up -d --build

if ([string]::IsNullOrWhiteSpace((Get-EnvValue 'STASH_BOX_API_KEY'))) {
    Write-Warn "STASH_BOX_API_KEY 为空，western（欧美）刮削不可用；请按 README 获取后填入 .env 并重新执行 'docker compose up -d'"
}

Write-Info '完成。网关地址 http://127.0.0.1:11503，GATEWAY_TOKEN 见 .env'
