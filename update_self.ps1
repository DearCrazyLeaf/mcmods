param(
    [string]$targetRoot = $null,
    [switch]$SkipUpdate = $false,
    [ValidateSet('Auto','Gitee','GitHub')]
    [string]$Source = 'Auto'
)

$Config = @{
    GitHubRepo  = "https://raw.githubusercontent.com/DearCrazyLeaf/mcmods/main"
    GiteeRepo   = "https://gitee.com/deercrazyleaf/mymcmods/raw/main"
    ReleaseDir  = "Releases"
    VersionFile = "versions.json"  # 修正后的版本文件名称
    LogFile     = "changelog.log"  # 更新日志文件
    Timeout     = 15
    RetryCount  = 3
}

# 以下函数与 logic.txt 中的同名函数逻辑相同
function Test-RepoAccess {
    param([string]$TestUrl)
    try {
        $versionUrl = "$TestUrl/$($Config.VersionFile)"
        $response = Invoke-WebRequest -Uri $versionUrl -Method Head -TimeoutSec 5
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Get-BestSource {
    $githubTest = Test-RepoAccess -TestUrl $Config.GitHubRepo
    $giteeTest = Test-RepoAccess -TestUrl $Config.GiteeRepo

    if ($Source -eq 'Auto') {
        if ($giteeTest) { return $Config.GiteeRepo }
        if ($githubTest) { return $Config.GitHubRepo }
        return $null
    }
    return @{'Gitee' = $Config.GiteeRepo; 'GitHub' = $Config.GitHubRepo}[$Source]
}

function Get-RemoteVersion {
    param([string]$BaseUrl)
    try {
        $versionUrl = "$BaseUrl/$($Config.VersionFile)"
        $response = Invoke-RestMethod -Uri $versionUrl -TimeoutSec $Config.Timeout
        # 假设 versions.json 文件中包含一个 JSON 对象，其中 MainProgram 是主程序的版本
        return $response.MainProgram
    } catch {
        Write-Host " [错误] 获取远程版本失败: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Get-RemoteLog {
    param([string]$BaseUrl)
    try {
        $logUrl = "$BaseUrl/$($Config.LogFile)"
        $response = Invoke-RestMethod -Uri $logUrl -TimeoutSec $Config.Timeout
        return $response
    } catch {
        Write-Host " [警告] 获取更新日志失败: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Update-Self {
    param([string]$BaseUrl)
    try {
        # 确保BaseUrl以斜杠结尾，避免路径拼接问题
        if (-not $BaseUrl.EndsWith('/')) {
            $BaseUrl += '/'
        }

        $remoteFiles = @{
            "logic.txt" = "logic.ps1"
            "开始安装.txt" = "开始安装.bat"
            "update.bat" = "update.bat"
            "update_self.ps1" = "update_self.ps1"
        }

        foreach ($file in $remoteFiles.GetEnumerator()) {
            $remoteFileUrl = "$BaseUrl$($file.Value)"
            $localFilePath = Join-Path $PSScriptRoot $file.Key

            try {
                Invoke-WebRequest -Uri $remoteFileUrl -OutFile $localFilePath -TimeoutSec $Config.Timeout
                Write-Host " [成功] 已下载: $($file.Key)" -ForegroundColor Green
            } catch {
                Write-Host " [错误] 下载 $($file.Key) 失败: $($_.Exception.Message)" -ForegroundColor Red
                throw  # 终止更新过程
            }
        }

        Write-Host " [成功] 主程序已更新到最新版本！" -ForegroundColor Green
        return $true
    } catch {
        Write-Host " [错误] 主程序更新失败: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ====================== 自我更新检查 ======================
$BaseUrl = Get-BestSource
if (-not $BaseUrl) {
    Write-Host " [警告] 无法连接到任何更新源，跳过主程序更新检查" -ForegroundColor Yellow
    exit 1
}

# 添加 Releases 路径
if ($BaseUrl -match "github.com") {
    $BaseUrl = "$BaseUrl/$($Config.ReleaseDir)"
}

$remoteVersion = Get-RemoteVersion -BaseUrl $BaseUrl
if (-not $remoteVersion) {
    Write-Host " [警告] 无法获取远程版本信息，跳过主程序更新检查" -ForegroundColor Yellow
    exit 1
}

$localVersionPath = Join-Path $PSScriptRoot "versions.json"  # 修正后的本地版本文件路径
$localVersion = if (Test-Path -LiteralPath $localVersionPath) {
    try {
        $versionContent = Get-Content -LiteralPath $localVersionPath -Raw
        $versionObject = $versionContent | ConvertFrom-Json
        $versionObject.MainProgram
    } catch {
        Write-Host " [警告] 本地版本文件格式错误，默认使用 0.0.0" -ForegroundColor Yellow
        "0.0.0"
    }
} else { "0.0.0" }

if ([version]$remoteVersion -gt [version]$localVersion) {
    Write-Host "`n=== 主程序更新检查 ===" -ForegroundColor Magenta
    Write-Host "发现新版本：v$remoteVersion（当前版本：v$localVersion）" -ForegroundColor Cyan

    $updateLog = Get-RemoteLog -BaseUrl $BaseUrl
    if ($updateLog) {
        Write-Host "`n=== 更新日志 ===`n$($updateLog)`n" -ForegroundColor Cyan
    }

    $choice = Read-Host "是否立即更新主程序？[Y/N]"
    if ($choice -match "[Yy]") {
        Write-Host "`n正在更新主程序..."
        if (Update-Self -BaseUrl $BaseUrl) {
            # 保存新版本号到本地 versions.json 文件
            $newVersionObject = @{
                mods = $versionObject.mods
                gunpaks = $versionObject.gunpaks
                MainProgram = $remoteVersion
            } | ConvertTo-Json
            Set-Content -Path $localVersionPath -Value $newVersionObject -Force

            # 重新启动程序
            Write-Host "更新完成，正在重新启动程序..."
            Start-Sleep -Seconds 2
            Start-Process -FilePath "$PSScriptRoot\开始安装.txt"
            exit 0
        } else {
            Write-Host "更新失败，请手动检查更新！"
            exit 1
        }
    } else {
        Write-Host "跳过主程序更新，继续执行当前版本..."
        exit 2
    }
} else {
    Write-Host "`n主程序已是最新版本：v$localVersion" -ForegroundColor Green
    exit 0
}