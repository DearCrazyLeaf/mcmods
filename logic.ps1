param(
    [string]$targetRoot = $null,
    [switch]$SkipUpdate = $false,
    [ValidateSet('Auto','Gitee','GitHub')]
    [string]$Source = 'Auto'
)

$Config = @{
    GitHubRepo  = "https://raw.githubusercontent.com/DearCrazyLeaf/mcmods/main"
    GiteeRepo   = $null
    ResourceFolders = @("mods", "gunpaks")
    VersionFile = "versions.json"
    ChangeLogFile = "changelog.log"
    ReleaseDir  = "Releases"
	MainProgramDir = ""
    Timeout     = 15
    RetryCount  = 3
}

$global:allEmpty = $true
$global:fileConflict = $false
$global:itemsCopied = 0
$global:itemsSkipped = 0
$anySourceExists = $false

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

function Get-RemoteFileList {
    param(
        [string]$BaseUrl,
        [string]$ResourceName
    )

    if ($ResourceName -eq "MainProgram") {
        $folderPath = $Config.MainProgramDir
    } else {
        $folderPath = "$($Config.ReleaseDir)/$ResourceName"
    }
	
    $allFiles = @()
    $headers = @{}
	
    # Write-Host " [调试] 资源类型: $ResourceName" -ForegroundColor DarkGray
    # Write-Host " [调试] 最终文件夹路径: '$folderPath'" -ForegroundColor DarkGray

    # 先设置 API URL
    if ($BaseUrl -match "gitee.com") {
        $owner = "deercrazyleaf"
        $repo = "mymcmods"
        $apiUrl = "https://gitee.com/api/v5/repos/$owner/$repo/contents/$folderPath"
        $headers["Authorization"] = "token TOKEN_HERE"  # Gitee 令牌
    } else {
        # GitHub API处理
		$owner = "DearCrazyLeaf"
		$repo = "mcmods"
		$folderPath = "$($Config.ReleaseDir)/$ResourceName"
		$apiUrl = "https://api.github.com/repos/$owner/$repo/contents/$folderPath"
    }
	
	# 调试输出2：显示最终请求URL
    # Write-Host " [调试] 请求API URL: $apiUrl" -ForegroundColor Cyan
    # Write-Host " [调试] 请求头: $($headers | ConvertTo-Json)" -ForegroundColor DarkGray

    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec $Config.Timeout
		# 调试输出3：显示响应摘要
        # Write-Host " [调试] 收到响应，条目数: $($response.Count)" -ForegroundColor DarkGray
		
        foreach ($item in $response) {
            if ($item.type -eq 'file' -and $item.name -match '\.(jar|zip|pak)$') {
                $allFiles += @{
                    RemotePath = $item.download_url
                    LocalPath  = $item.name
                }
				# 调试输出4：显示发现的有效文件
                # Write-Host " [调试] 发现有效文件: $($item.name)" -ForegroundColor DarkGray
            }
        }
        return $allFiles
    } catch {
       # 调试输出5：详细错误信息
		Write-Host " [详细错误] 状态码: $($_.Exception.Response.StatusCode)" -ForegroundColor Red
        Write-Host " [详细错误] 错误消息: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails) {
            Write-Host " [详细错误] 响应内容: $($_.ErrorDetails.Message)" -ForegroundColor DarkRed
        return @()
        }
	}
}

function Sync-ResourceFolder {
    param([string]$ResourceName, [string]$BaseUrl)

	Write-Host "`n [信息] 正在通过GitHub加速通道下载..." -ForegroundColor Cyan
    if ($ResourceName -eq "MainProgram") {
        $targetPath = $PSScriptRoot  # 直接更新到脚本目录
        $versionField = "MainProgram"
    } else {
        $targetPath = Join-Path $PSScriptRoot "data\$ResourceName"
        $versionField = $ResourceName
    }
	
    while ($retry -lt $Config.RetryCount) {
        try {
            $remoteVersionUrl = "$BaseUrl/$($Config.VersionFile)"
            $remoteData = Invoke-RestMethod -Uri $remoteVersionUrl -TimeoutSec $Config.Timeout
            $remoteVersion = $remoteData.$ResourceName

            $localVersionPath = Join-Path $PSScriptRoot "data\$($Config.VersionFile)"
            $localVersion = if (Test-Path -LiteralPath $localVersionPath) {
                (Get-Content -LiteralPath $localVersionPath | ConvertFrom-Json).$ResourceName
            } else { "0.0.0" }

            if ([version]$remoteVersion -gt [version]$localVersion) {
                Write-Host " [更新] 发现新版本 $ResourceName ($localVersion → $remoteVersion)" -ForegroundColor Cyan

                $files = Get-RemoteFileList -BaseUrl $BaseUrl -ResourceName $ResourceName
                if ($files.Count -eq 0) {
                    Write-Host " [警告] 未找到可下载文件，跳过同步" -ForegroundColor Yellow
                    return $false
                }

                $targetPath = Join-Path $PSScriptRoot "data\$ResourceName"
                if (-not (Test-Path $targetPath)) {
                    New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
                }

                $totalFiles = $files.Count
                $currentCount = 0
                foreach ($file in $files) {
                    $currentCount++
                    $localFile = Join-Path $targetPath $file.LocalPath
                    $localDir = [System.IO.Path]::GetDirectoryName($localFile)
                    
                    if (-not (Test-Path $localDir)) {
                        New-Item -Path $localDir -ItemType Directory -Force | Out-Null
                    }

                    try {
                        Write-Progress -Activity "下载文件" -Status "$currentCount/$totalFiles $($file.LocalPath)" -PercentComplete ($currentCount/$totalFiles*100)
                    
                        $webClient = New-Object System.Net.WebClient
                        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3")
                        $webClient.Headers.Add("Referer", $BaseUrl)
                        $webClient.Headers.Add("Accept", "*/*")
                        $webClient.DownloadFile($file.RemotePath, $localFile)
                        $webClient.Dispose()

                        Write-Host " [成功] 已下载: $($file.LocalPath)" -ForegroundColor Green
                    } catch [System.Net.WebException] {
                        if ($_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                            Write-Host " [警告] 文件未找到: $($file.LocalPath)，跳过此文件" -ForegroundColor Yellow
                            continue
                        } elseif ($_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::Forbidden) {
                            Write-Host " [错误] 无权限下载: $($file.LocalPath) - 确认是否有权限访问此文件" -ForegroundColor Red
                            if ($BaseUrl -match "gitee.com") {
                                Write-Host " [信息] 尝试切换到GitHub作为备用源" -ForegroundColor Yellow
                                $githubDownloadUrl = $file.RemotePath.Replace($Config.GiteeRepo, $Config.GitHubRepo)
                                try {
                                    $webClient = New-Object System.Net.WebClient
                                    $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3")
                                    $webClient.DownloadFile($githubDownloadUrl, $localFile)
                                    $webClient.Dispose()
                                    Write-Host " [成功] 已下载: $($file.LocalPath)（通过GitHub备用源）" -ForegroundColor Green
                                } catch {
                                    Write-Host " [错误] 备用源下载失败: $($file.LocalPath) - $($_.Exception.Message)" -ForegroundColor Red
                                }
                            }
                        } else {
                            Write-Host " [错误] 下载失败: $($file.LocalPath) - $($_.Exception.Message)" -ForegroundColor Red
                        }
                    } catch {
                        Write-Host " [错误] 下载失败: $($file.LocalPath) - $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
                Write-Progress -Completed -Activity "下载完成"

                $localVersions = if (Test-Path $localVersionPath) {
                    Get-Content $localVersionPath | ConvertFrom-Json
                } else { @{} }
                $localVersions | Add-Member -NotePropertyName $ResourceName -NotePropertyValue $remoteVersion -Force
                $localVersions | ConvertTo-Json | Out-File -LiteralPath $localVersionPath -Force

                Write-Host " [完成] $ResourceName 已同步到 v$remoteVersion" -ForegroundColor Green
                return $true
            } else {
                Write-Host " [信息] 当前已是最新版本 $ResourceName v$localVersion" -ForegroundColor Gray
            }
            return $false
        } catch [System.Net.WebException] {
            if ($_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                Write-Host " [警告] 远程资源不存在，跳过同步" -ForegroundColor Yellow
                return $false
            }
            $retry++
            Write-Host "`n [重试] 第 $retry 次尝试失败: $($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        } catch {
            $retry++
            Write-Host "`n [重试] 第 $retry 次尝试失败: $($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }
    Write-Host " [错误] 同步失败，已达最大重试次数" -ForegroundColor Red
    return $false
}

function Check-Update {
    param([string]$BaseUrl)
    try {
        $remoteVersionUrl = "$BaseUrl/$($Config.VersionFile)"
        $remoteData = Invoke-RestMethod -Uri $remoteVersionUrl -TimeoutSec $Config.Timeout
        $remoteVersion = $remoteData.MainProgram

        $localVersionPath = Join-Path $PSScriptRoot $Config.VersionFile
        $localVersion = if (Test-Path -LiteralPath $localVersionPath) {
            (Get-Content -LiteralPath $localVersionPath | ConvertFrom-Json).MainProgram
        } else { "0.0.0" }

        if ([version]$remoteVersion -gt [version]$localVersion) {
            Write-Host " [更新] 发现主程序新版本 ($localVersion → $remoteVersion)" -ForegroundColor Cyan

            $changelogUrl = "$BaseUrl/$($Config.ChangeLogFile)"
            try {
                $changelog = Invoke-RestMethod -Uri $changelogUrl -TimeoutSec $Config.Timeout
                Write-Host "`n▄▄▄▄▄▄  更新日志 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄`n" -ForegroundColor Yellow
                Write-Host $changelog
            } catch {
                Write-Host " [警告] 无法获取更新日志: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            $choice = Read-Host "是否更新到新版本？(Y/N)"
            if ($choice -eq 'Y' -or $choice -eq 'y') {
                $updateResult = Sync-ResourceFolder -ResourceName "MainProgram" -BaseUrl $BaseUrl
                if ($updateResult) {
                    Write-Host " [成功] 主程序已更新到 v$remoteVersion" -ForegroundColor Green
                } else {
                    Write-Host " [错误] 主程序更新失败" -ForegroundColor Red
                    $retryUpdate = Read-Host "是否继续启动主程序？(Y/N)"
                    if ($retryUpdate -eq 'Y' -or $retryUpdate -eq 'y') {
                        return $true
                    } else {
                        return $false
                    }
                }
            } else {
                Write-Host " [信息] 跳过主程序更新，继续启动主程序" -ForegroundColor Gray
                return $true
            }
        } else {
            Write-Host " [信息] 主程序已是最新版本 v$localVersion" -ForegroundColor Gray
            return $true
        }
    } catch {
        Write-Host " [错误] 检查更新失败: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ====================== 主流程 ======================

if (-not $targetRoot) {
    try {
        $scriptParent = (Get-Item $PSScriptRoot).Parent
        if (-not $scriptParent) {
            throw "脚本位于根目录，无法自动确定目标路径"
        }
        $targetRoot = $scriptParent.FullName
        # Write-Host " [信息] 自动检测到目标目录: $targetRoot" -ForegroundColor DarkGray
    } catch {
        Write-Host " [错误] 无法自动确定目标目录: $_" -ForegroundColor Red
        exit 1
    }
}

if (-not $SkipUpdate) {
    Write-Host "`n"
	Write-Host "   ███ \   ███\ ███ \  ███\    ███ \███\      ███ \      ████████ \ ███ \  ███ \ " -ForegroundColor Cyan
	Write-Host "   ███  |  ███ \███  | \███\  ███  |████\    ████  |    ███  __ ██ \███  \ ███  |" -ForegroundColor Cyan
	Write-Host "   ███  |  ███  ███  |  \███\███  / █████\  █████  |    ███ /  \__ |█████ \███  |" -ForegroundColor Cyan
	Write-Host "   ███████████  ███  |   \█████  /  ███\██\██ ███  |    ███ |       ███ ██\███  |" -ForegroundColor Cyan
	Write-Host "   ███   __███  ███  |    \███  /   ███ \███  ███  |    ███ |       ███  \████  |" -ForegroundColor Cyan
	Write-Host "   ███  |  ███  ███  |     ███  |   ███  \█  /███  |    ███ |   ██ \███  |\███  |" -ForegroundColor Cyan
	Write-Host "   ███  |  ███  █████████\ ███  |   ███  |\_/ ███  |██ \ ████████  |███  | \██  |" -ForegroundColor Cyan
	Write-Host "   \____|  \____\_________|\____|   \____|    \____|\__| \_______ / \____|  \___|" -ForegroundColor Cyan
    $versionInfo = (Get-Content (Join-Path $PSScriptRoot $Config.VersionFile) | ConvertFrom-Json).MainProgram
    Write-Host " 版本号: v$versionInfo" -ForegroundColor Magenta
    Write-Host " 项目主页: https://github.com/DearCrazyLeaf/mcmods" -ForegroundColor Blue
    Write-Host " 技术支持: QQ 2336758119 | 电子邮箱 crazyleaf0912@outlook.com" -ForegroundColor Green
    Write-Host "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor DarkGray

    Write-Host "`n▄▄▄▄▄▄  检查安装器更新 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor Blue
    if (-not ($BaseUrl = Get-BestSource)) {
        Write-Host " [警告] 无法连接到任何更新源，跳过更新检查" -ForegroundColor Yellow
    } else {
        Write-Host "`n [信息] 使用更新源：$([uri]$BaseUrl)"
        $mainUpdateResult = Check-Update -BaseUrl $BaseUrl
        if ($mainUpdateResult -ne $false) {
            foreach ($folder in $Config.ResourceFolders) {
                Write-Host "`n▄▄▄▄▄  检查${folder}更新 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor Magenta
                Sync-ResourceFolder -ResourceName $folder -BaseUrl $BaseUrl | Out-Null
            }
        }
    }
}

# 安装信息显示（在所有更新操作完成后）
Write-Host "`n▄▄▄▄▄▄  安装信息 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor Cyan
Write-Host "`n程序位置：$PSScriptRoot"
Write-Host "目标目录：$targetRoot`n"

$copyMap = @{
    "data\mods"    = "mods"
    "data\gunpaks" = "tacz"
}

foreach ($entry in $copyMap.GetEnumerator()) {
    $sourcePath = Join-Path $PSScriptRoot $entry.Key
    $targetPath = Join-Path $targetRoot $entry.Value

    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Host " [错误] 源目录：$($entry.Key) 不存在！" -ForegroundColor Red
        continue
    }
    $anySourceExists = $true

    $sourceItems = Get-ChildItem -LiteralPath $sourcePath -Recurse -File
    if ($sourceItems.Count -eq 0) {
        Write-Host " [警告] 源目录中：$($entry.Key) 不存在资源文件！" -ForegroundColor Yellow
        continue
    } else {
        $global:allEmpty = $false
    }

    if (-not (Test-Path -LiteralPath $targetPath)) {
        try {
            $null = New-Item -Path $targetPath -ItemType Directory -Force
            Write-Host "检测到目标目录下不存在相关文件夹：$($entry.Value)，正在创建中..." -ForegroundColor Yellow
        } catch {
            Write-Host " [错误] 目录：$($entry.Value) 创建失败！ (原因：$($_.Exception.Message))" -ForegroundColor Red
            continue
        }
    }

    Write-Host "正在处理：$($entry.Key) → $($entry.Value)"
    $fileCount = 0
    
    foreach ($file in (Get-ChildItem -LiteralPath $sourcePath -Recurse -File)) {
        $relativePath = $file.FullName.Substring($sourcePath.TrimEnd('\').Length + 1)
        $destFile = Join-Path $targetPath $relativePath

        if (Test-Path -LiteralPath $destFile) {
            Write-Host " [忽略] 目标：$($relativePath) 已存在！" -ForegroundColor Yellow
            $global:fileConflict = $true
            $global:itemsSkipped++
            continue
        }

        $destDir = [System.IO.Path]::GetDirectoryName($destFile)
        if (-not (Test-Path -LiteralPath $destDir)) {
            $null = New-Item -Path $destDir -ItemType Directory -Force
        }

        try {
            Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
            $fileCount++
            $global:itemsCopied++
        } catch {
            Write-Host " [错误] 复制：$($relativePath) 失败！ (原因：$($_.Exception.Message))" -ForegroundColor Red
        }
    }

    if ($fileCount -gt 0) {
        Write-Host " [成功] 已安装：$($fileCount)个文件！" -ForegroundColor DarkGreen
    }
}

Write-Host "`n▄▄▄▄▄▄  安装结果 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor Cyan
if (-not $anySourceExists) {
    Write-Host "`n安装失败：所有源目录均不存在！是否是缺失资源导致的？" -ForegroundColor DarkRed
}
elseif ($global:allEmpty) {
    Write-Host "`n安装失败：所有存在的源目录均为空！是否是缺失资源导致的？" -ForegroundColor DarkRed
}
else {
    $statusMsg = if ($global:fileConflict) {
        "`n部分文件已存在（跳过$($global:itemsSkipped)个），成功安装：$($global:itemsCopied)个文件！"
    } else {
        "`n成功安装：$($global:itemsCopied)个文件！"
    }
    Write-Host $statusMsg -ForegroundColor Green
}
Write-Host "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor DarkGray
Write-Host "`n请按回车键退出..."
Read-Host