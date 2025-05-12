param(
    [string]$targetRoot = $null,
    [switch]$SkipUpdate = $false,
    [ValidateSet('Auto','Gitee','GitHub')]
    [string]$Source = 'Auto'
)

$Config = @{
    GitHubRepo  = "https://raw.githubusercontent.com/DearCrazyLeaf/mcmods/main"
    GiteeRepo   = "https://gitee.com/deercrazyleaf/mymcmods/raw/main"
    ResourceFolders = @("mods", "gunpaks")
    VersionFile = "versions.json"
    ReleaseDir  = "Releases"
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

    $folderPath = "$($Config.ReleaseDir)/$ResourceName"
    $allFiles = @()

    if ($BaseUrl -match "gitee.com") {
        $owner = "deercrazyleaf"
        $repo = "mymcmods"
        $apiUrl = "https://gitee.com/api/v5/repos/$owner/$repo/contents/$folderPath"
    } else {
        $owner = "DearCrazyLeaf"
        $repo = "mcmods"
        $apiUrl = "https://api.github.com/repos/$owner/$repo/contents/$folderPath"
    }

    try {
        $headers = @{}
        if ($BaseUrl -match "gitee.com") {
            # 如果是 Gitee，添加身份验证信息
            $headers.Add("Authorization", "token 77fcc2d57d180f49245990d2d33aae4d")
        }
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec $Config.Timeout
        foreach ($item in $response) {
            if ($BaseUrl -match "gitee.com") {
                $downloadUrl = $item.download_url
                $fileName = $item.name
            } else {
                $downloadUrl = $item.download_url
                $fileName = $item.name
            }

            if ($item.type -eq 'file' -and $item.name -match '\.(jar|zip|pak)$') {
                $allFiles += @{
                    RemotePath = $downloadUrl
                    LocalPath  = $fileName
                }
            }
        }
        return $allFiles
    } catch {
        Write-Host " [错误] 获取文件列表失败: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Sync-ResourceFolder {
    param([string]$ResourceName, [string]$BaseUrl)
    $retry = 0
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
# ====================== 主程序自我更新检查 ======================
& "$PSScriptRoot\update.bat"
if ($LASTEXITCODE -eq 0) {
    # 更新成功并重新启动，直接退出当前脚本
    exit 0
} elseif ($LASTEXITCODE -eq 2) {
    # 用户选择跳过更新，继续执行当前版本
    Write-Host "`n=== 跳过主程序更新 ===" -ForegroundColor Yellow
} else {
    # 更新检查失败，继续执行当前版本
    Write-Host "`n=== 主程序更新检查失败 ===" -ForegroundColor Red
}
# ====================== 主流程 ======================
if (-not $SkipUpdate) {
    Write-Host "`n=== 检查更新 ===" -ForegroundColor Blue
    if (-not ($BaseUrl = Get-BestSource)) {
        Write-Host " [警告] 无法连接到任何更新源，跳过更新检查" -ForegroundColor Yellow
    } else {
        # 修复主逻辑：添加 Releases 路径
        if ($BaseUrl -match "github.com") {
            $BaseUrl = "$BaseUrl/$($Config.ReleaseDir)"
        }
        Write-Host " [信息] 使用更新源：$([uri]$BaseUrl)"
        $updateFlag = $false
        foreach ($folder in $Config.ResourceFolders) {
            if (Sync-ResourceFolder -ResourceName $folder -BaseUrl $BaseUrl) {
                $updateFlag = $true
            }
        }
        if ($updateFlag) {
            Write-Host "`n已应用最新更新，即将开始安装..." -ForegroundColor Cyan
            Start-Sleep -Seconds 2
        }
    }
}

$copyMap = @{
    "data\mods"    = "mods"
    "data\gunpaks" = "tacz"
}

if (-not $targetRoot) {
    $targetRoot = (Get-Item $PSScriptRoot).Parent.FullName
}

Write-Host "`n=== 安装信息 ===" -ForegroundColor Cyan
Write-Host "程序位置：$PSScriptRoot"
Write-Host "目标目录：$targetRoot`n"

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

    Write-Host "`n正在处理：$($entry.Key) → $($entry.Value)"
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

Write-Host "`n=== 安装结果 ===" -ForegroundColor Cyan
if (-not $anySourceExists) {
    Write-Host "安装失败：所有源目录均不存在！是否是缺失资源导致的？" -ForegroundColor DarkRed
}
elseif ($global:allEmpty) {
    Write-Host "安装失败：所有存在的源目录均为空！是否是缺失资源导致的？" -ForegroundColor DarkRed
}
else {
    $statusMsg = if ($global:fileConflict) {
        "部分文件已存在（跳过$($global:itemsSkipped)个），成功安装：$($global:itemsCopied)个文件！"
    } else {
        "成功安装：$($global:itemsCopied)个文件！"
    }
    Write-Host $statusMsg -ForegroundColor Green
}

Write-Host "`n操作完成，按回车键退出..."
Read-Host