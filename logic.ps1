param(
    [string]$targetRoot = $null,
    [switch]$SkipUpdate = $false,
    [string]$UpdateBaseUrl = "ftp://1952274855%40QQ.COM.15961:xhj2001912@mcp19.rhymc.com/Updatebase/"
)

$Config = @{
    ResourceFolders = @("mods", "gunpaks")
    VersionFile = "versions.json"
    ChangeLogFile = "changelog.log"
    ReleaseDir  = "Releases"
    MainProgramDir = "MainProgram"
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
        $request = [System.Net.FtpWebRequest]::Create($versionUrl)
        $request.Method = [System.Net.WebRequestMethods+Ftp]::GetDateTimestamp
        $request.Timeout = 5000
        $response = $request.GetResponse()
        $response.Close()
        return $true
    } catch {
        return $false
    }
}

function Get-RemoteFileList {
    param(
        [string]$BaseUrl,
        [string]$ResourceName
    )

    $BaseUrl = $BaseUrl.TrimEnd('/')

    if ($ResourceName -eq "MainProgram") {
        $folderPath = $Config.MainProgramDir
    } else {
        $folderPath = "$($Config.ReleaseDir)/$ResourceName"
    }

    $allFiles = @()
    try {
        $folderPath = $folderPath.Replace('\', '/').TrimStart('/').TrimEnd('/')
        $listUrl = "$BaseUrl/$folderPath"
        $request = [System.Net.FtpWebRequest]::Create($listUrl)
        $request.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $request.Timeout = $Config.Timeout * 1000
        $request.UsePassive = $true
        $request.UseBinary = $true
        $request.EnableSsl = $false
        $request.Credentials = New-Object System.Net.NetworkCredential("1952274855@QQ.COM.15961", "xhj2001912")
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader $response.GetResponseStream()

        while (!$reader.EndOfStream) {            $line = $reader.ReadLine()
            if ($line -match "^[\S-]+\s+\d+\s+\S+\s+\S+\s+\d+\s+(\w+\s+\d+\s+(?:\d{1,2}):?\d{2})\s+(.+)$") {
                $name = $matches[2].Trim()
                
                if ($name -match '\.(jar|zip|txt|pak)$') {                    $remotePath = "$folderPath/$name"
                    $remoteUrl = "$BaseUrl/$remotePath"
                    $allFiles += @{
                        RemotePath = $remoteUrl
                        LocalPath = $name
                    }
                }
            }
        }

        $reader.Close()
        $response.Close()
        
        Write-Host " 找到可下载文件数: $($allFiles.Count)" -ForegroundColor Cyan
        return $allFiles
    } catch {
        Write-Host " [详细错误] $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host " [详细错误] $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
        return @()
    }
}

function Test-VSCodeHost {
    return ($env:TERM_PROGRAM -eq "vscode")
}

function Get-FtpFile {
    param(
        [string]$ftpUrl,
        [string]$localPath,
        [int]$timeout = 15000
    )
    
    $response = $null
    $responseStream = $null
    $fileStream = $null
    
    try {        $request = [System.Net.FtpWebRequest]::Create($ftpUrl)
        $request.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $request.Timeout = $timeout
        $request.UseBinary = $true
        $request.UsePassive = $true
        $request.KeepAlive = $false
        $request.EnableSsl = $false
        $request.Credentials = New-Object System.Net.NetworkCredential("1952274855@QQ.COM.15961", "xhj2001912")
        
        try {
            $response = $request.GetResponse()
            Write-Host " [成功] 已连接到服务器" -ForegroundColor Green
            
            $responseStream = $response.GetResponseStream()
           #Write-Host " [调试] 创建下载流" -ForegroundColor DarkGray
            
            $targetDir = [System.IO.Path]::GetDirectoryName($localPath)
            if (-not (Test-Path -LiteralPath $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
            }
            
            $fileStream = [System.IO.File]::Open($localPath, [System.IO.FileMode]::Create)
            #Write-Host " [调试] 创建本地文件: $localPath" -ForegroundColor DarkGray
            
            $buffer = New-Object byte[] 8192
            $totalBytes = 0
            
            do {
                $read = $responseStream.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                    $totalBytes += $read
                    
                    if ($totalBytes % 1MB -eq 0) {
                        Write-Host " [进度] 已下载: $([math]::Round($totalBytes/1MB, 2)) MB" -ForegroundColor DarkGray
                    }
                }
            } while ($read -gt 0)
            
           #Write-Host " [完成] 成功下载: $([math]::Round($totalBytes/1KB, 2)) KB" -ForegroundColor Green
            return $true
            
        } catch [System.Net.WebException] {
            $errorResponse = [System.Net.FtpWebResponse]$_.Exception.Response
            Write-Host " [FTP错误] 状态码: $($errorResponse.StatusCode)" -ForegroundColor Red
            Write-Host " [FTP错误] 描述: $($errorResponse.StatusDescription)" -ForegroundColor Red
            throw
        }
    } catch {
        Write-Host " [错误] 下载失败" -ForegroundColor Red
        Write-Host " [错误详情] $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.InnerException) {
            Write-Host " [详细错误] $($_.Exception.InnerException.Message)" -ForegroundColor Red
        }
        throw $_
    } finally {
        if ($fileStream) { $fileStream.Close() }
        if ($responseStream) { $responseStream.Close() }
        if ($response) { $response.Close() }
    }
}

function Sync-ResourceFolder {
    param([string]$ResourceName, [string]$BaseUrl)

    if ($BaseUrl.EndsWith('/')) {
        $BaseUrl = $BaseUrl.TrimEnd('/')
    }

    Write-Host "`n [信息] 正在通过FTP服务器同步数据..." -ForegroundColor Cyan
    if ($ResourceName -eq "MainProgram") {
        $targetPath = Join-Path $PSScriptRoot $Config.MainProgramDir
        $versionField = "MainProgram"
    } else {
        $targetPath = Join-Path $PSScriptRoot "data\$ResourceName"
        $versionField = $ResourceName
    }

    $retry = 0
    while ($retry -lt $Config.RetryCount) {
        try {
            $remoteVersionUrl = "$BaseUrl/$($Config.VersionFile)"
            $request = [System.Net.FtpWebRequest]::Create($remoteVersionUrl)
            $request.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
            $request.Timeout = $Config.Timeout * 1000
            $request.UsePassive = $true
            $response = $request.GetResponse()
            $reader = New-Object System.IO.StreamReader $response.GetResponseStream()
            $content = $reader.ReadToEnd()
            $reader.Close()
            $response.Close()
            $remoteData = $content | ConvertFrom-Json
            $remoteVersion = $remoteData.$ResourceName
            $localVersionPath = Join-Path $PSScriptRoot "data\$($Config.VersionFile)"
            $localVersion = if (Test-Path -LiteralPath $localVersionPath) {
                (Get-Content -LiteralPath $localVersionPath | ConvertFrom-Json).$ResourceName
            } else { "0.0.0" }

            if ([version]$remoteVersion -gt [version]$localVersion) {
                Write-Host " [更新] 发现新版本 $ResourceName ($localVersion → $remoteVersion)" -ForegroundColor Cyan

                $files = Get-RemoteFileList -BaseUrl $BaseUrl -ResourceName $ResourceName                if ($files.Count -eq 0) {
                    Write-Host " [警告] 未找到可下载文件，跳过同步" -ForegroundColor Yellow
                    return $false
                }

                $targetPath = Join-Path $PSScriptRoot "data\$ResourceName"
                if (-not (Test-Path $targetPath)) {
                    New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
                }

                $totalFiles = $files.Count
                $currentCount = 0
                $successCount = 0
                $skipCount = 0
                $failCount = 0

                # 首先检查需要跳过的文件
                foreach ($file in $files) {
                    $localFile = Join-Path $targetPath $file.LocalPath
                    if (Test-Path -LiteralPath $localFile) {
                        $skipCount++
                    }
                }
                if ($skipCount -gt 0) {
                    Write-Host " [跳过] $skipCount 个文件已存在" -ForegroundColor Yellow
                }

                foreach ($file in $files) {
                    $currentCount++
                    $localFile = Join-Path $targetPath $file.LocalPath
                    $localDir = [System.IO.Path]::GetDirectoryName($localFile)

                    if (Test-Path -LiteralPath $localFile) {
                        continue
                    }

                    if (-not (Test-Path $localDir)) {
                        New-Item -Path $localDir -ItemType Directory -Force | Out-Null
                    }                    try {
                        Write-Host " [尝试] 开始下载: $($file.LocalPath)" -ForegroundColor Cyan
                       #Write-Host " [信息] 源: $($file.RemotePath)" -ForegroundColor DarkGray
                       #Write-Host " [信息] 目标: $localFile" -ForegroundColor DarkGray
                        
                        if (Get-FtpFile -ftpUrl $file.RemotePath -localPath $localFile -timeout ($Config.Timeout * 1000)) {
                            Write-Host " [成功] 已下载: $($file.LocalPath)" -ForegroundColor Green
                            $successCount++
                        } else {
                            Write-Host " [警告] 下载可能未完成: $($file.LocalPath)" -ForegroundColor Yellow
                            $failCount++
                        }
                    } catch {
                        Write-Host " [错误] 下载失败: $($file.LocalPath)" -ForegroundColor Red
                        Write-Host " [错误详情] $($_.Exception.Message)" -ForegroundColor Red
                        $failCount++
                        Start-Sleep -Seconds 1 # 添加短暂延迟，避免服务器限制
                    }
                }

                if ($failCount -eq 0) {
                    $localVersions = if (Test-Path $localVersionPath) {
                        Get-Content $localVersionPath | ConvertFrom-Json
                    } else { @{} }
                    $localVersions | Add-Member -NotePropertyName $ResourceName -NotePropertyValue $remoteVersion -Force
                    $localVersions | ConvertTo-Json | Out-File -LiteralPath $localVersionPath -Force
                    Write-Host " [完成] $ResourceName 已同步到 v$remoteVersion" -ForegroundColor Green
                    return $true
                } else {
                    Write-Host " [警告] $ResourceName 有 $failCount 个文件下载失败，未更新版本号！" -ForegroundColor Red
                    return $false
                }
            } else {
                Write-Host " [信息] 当前已是最新版本 $ResourceName v$localVersion" -ForegroundColor Green
            }
            return $false
        } catch {
            $retry++
            Write-Host " [重试] 第 $retry 次尝试失败: $($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }
    Write-Host " [错误] 同步失败，已达最大重试次数" -ForegroundColor Red
    return $false
}

function Test-Update {
    param([string]$BaseUrl)
    try {
        $remoteVersionUrl = "$BaseUrl/$($Config.VersionFile)"
        $request = [System.Net.FtpWebRequest]::Create($remoteVersionUrl)
        $request.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $request.Timeout = $Config.Timeout * 1000
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader $response.GetResponseStream()
        $content = $reader.ReadToEnd()
        $reader.Close()
        $response.Close()

        $remoteData = $content | ConvertFrom-Json
        $remoteVersion = $remoteData.MainProgram

        $localVersionPath = Join-Path $PSScriptRoot "data\$($Config.VersionFile)"
        $localVersion = if (Test-Path -LiteralPath $localVersionPath) {
            (Get-Content -LiteralPath $localVersionPath | ConvertFrom-Json).MainProgram
        } else { "0.0.0" }

        if ([version]$remoteVersion -gt [version]$localVersion) {
            Write-Host "`n发现主程序新版本 ($localVersion → $remoteVersion)！" -ForegroundColor Green

            $changelogUrl = "$BaseUrl/$($Config.ChangeLogFile)"
            try {
                $request = [System.Net.FtpWebRequest]::Create($changelogUrl)
                $request.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
                $request.Timeout = $Config.Timeout * 1000
                $response = $request.GetResponse()
                $reader = New-Object System.IO.StreamReader $response.GetResponseStream()
                $changelog = $reader.ReadToEnd()
                $reader.Close()
                $response.Close()

                Write-Host "[更新日志]" -ForegroundColor Yellow
                Write-Host $changelog
            } catch {
                Write-Host " [警告] 无法获取更新日志: $($_.Exception.Message)" -ForegroundColor Yellow
            }
			Write-Host "资源检测将会正常进行，为了您的程序能够正常进行，避免版本过旧无法运行，请：" -ForegroundColor DarkYellow
			Write-Host "前往地址：https://github.com/DearCrazyLeaf/mcmods下载最新版主程序" -ForegroundColor DarkYellow
            return $true
        } else {
            Write-Host "`n [信息] 主程序已是最新版本 v$localVersion" -ForegroundColor Green
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

    $versionFilePath = Join-Path $PSScriptRoot "data\$($Config.VersionFile)"
    if (Test-Path -LiteralPath $versionFilePath) {
        $versionInfo = (Get-Content $versionFilePath | ConvertFrom-Json).MainProgram
    } else {
        $versionInfo = "0.0.0"
    }
    Write-Host "`n 版本号: v$versionInfo" -ForegroundColor Magenta
    Write-Host " 项目主页: https://github.com/DearCrazyLeaf/mcmods" -ForegroundColor Blue
    Write-Host " 技术支持: QQ 2336758119 | 电子邮箱 crazyleaf0912@outlook.com" -ForegroundColor Green
    Write-Host "▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor DarkGray

    Write-Host "`n▄▄▄▄▄▄  检查安装器更新 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor Blue
    if (-not $UpdateBaseUrl) {
        Write-Host " [警告] 未指定更新源URL，跳过更新检查" -ForegroundColor Yellow
    } else {
        $mainUpdateResult = Test-Update -BaseUrl $UpdateBaseUrl
        if ($mainUpdateResult -ne $false) {
            foreach ($folder in $Config.ResourceFolders) {
                Write-Host "`n▄▄▄▄▄  检查${folder}更新 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄" -ForegroundColor Magenta
                Sync-ResourceFolder -ResourceName $folder -BaseUrl $UpdateBaseUrl | Out-Null
            }
        }
    }
}

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