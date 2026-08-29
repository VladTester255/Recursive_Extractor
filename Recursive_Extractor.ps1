param (
	[string]$directory
)

function Extract-Archive {
	param (
		[string]$filePath,
		[string]$tempDir,
		[string]$password = $null
	)

	# Относительный путь: ищет UniExtract.exe в папке UniExtract2 прямо рядом со скриптом
	$UniExtractPath = Join-Path $PSScriptRoot "UniExtract2\UniExtract.exe" 
	
	if (-not (Test-Path $UniExtractPath)) {
		Write-Error "Критическая ошибка: Файл UniExtract.exe не найден рядом со скриптом по пути: $UniExtractPath"
		return "FatalError"
	}

	# Формируем аргументы на основе официальной справки UniExtract 3.0.4:
	$arguments = @("`"$filePath`"", "`"$tempDir`"", "/silent")

	try {
		$process = Start-Process -FilePath $UniExtractPath -ArgumentList $arguments -Wait -NoNewWindow -PassThru -ErrorAction Stop
		
		if ($process.ExitCode -eq 0) {
			if (Test-Path $tempDir) {
				$files = Get-ChildItem -Path $tempDir
				if ($files.Count -gt 0) {
					return $true
				}
			}
			return "ExtractionError"
		} elseif ($process.ExitCode -eq 1 -or $process.ExitCode -eq 2) {
			return "PasswordError"
		} else {
			return "ExtractionError"
		}
	} catch {
		return "FatalError"
	}
}

function Get-FileNameAndExtension {
	param (
		[System.IO.FileInfo]$fileItem
	)

	$fullName = $fileItem.Name

	if ($fullName -match '^(?<base>.+?)(?<ext>\.(tar|cpio|u-boot)\.[a-z0-9]+)$') {
		return [PSCustomObject]@{
			Name      = $Matches['base']
			Extension = $Matches['ext']
		}
	}

	if (-not [string]::IsNullOrEmpty($fileItem.Extension)) {
		return [PSCustomObject]@{
			Name      = $fileItem.BaseName
			Extension = $fileItem.Extension
		}
	}
	
	return [PSCustomObject]@{
		Name      = $fullName
		Extension = "Без расширения"
	}
}

function Write-LogToTop {
	param (
		[string]$csvPath,
		[string]$reason,
		[string]$dirPath,
		[string]$fileName,
		[string]$extension
	)

	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$newLine = "$timestamp;$reason;$dirPath;$fileName;$extension"

	if (Test-Path $csvPath) {
		$oldContent = Get-Content -Path $csvPath
		$header = "Время;Результат/Причина;ПутьКПапке;ИмяФайла;Расширение"
		
		$oldData = $oldContent | Where-Object { $_ -ne $header -and $_ -notlike ";;*" -and $_ -ne "" }
		
		$newContent = @($header, $newLine) + $oldData
		$newContent | Out-File -FilePath $csvPath -Force -Encoding utf8
	} else {
		$header = "Время;Результат/Причина;ПутьКПапке;ИмяФайла;Расширение"
		@($header, $newLine) | Out-File -FilePath $csvPath -Force -Encoding utf8
	}
}

function Process-Directory {
	param (
		[string]$directory,
		[string]$password = $null,
		[ref]$passwordErrors,
		[string]$baseDirectory,
		[string]$csvPath
	)

	$items = Get-ChildItem -Path $directory

	foreach ($item in $items) {
		if ($item.PSIsContainer) {
			if ($item.Name -like "++*") { continue }
			Process-Directory -directory $item.FullName -password $password -passwordErrors $passwordErrors -baseDirectory $baseDirectory -csvPath $csvPath
		} else {
			$filePath = $item.FullName
			$relativePath = $filePath.Replace($baseDirectory, "").TrimStart("\")
			
			$dirPath = $item.DirectoryName
			$fileInfo = Get-FileNameAndExtension -fileItem $item

			if ($item.Length -eq 0) {
				$passwordErrors.Value += $relativePath
				Write-LogToTop -csvPath $csvPath -reason "Пустой файл (0 байт)" -dirPath $dirPath -fileName $fileInfo.Name -extension $fileInfo.Extension
				continue
			}

			$unpackedDir = [System.IO.Path]::Combine($item.DirectoryName, "++" + $item.Name)

			if (-not (Test-Path $unpackedDir)) {
				$result = Extract-Archive -filePath $filePath -tempDir $unpackedDir -password $password

				if ($result -eq $true) {
					if (Test-Path $unpackedDir) {
						$extractedItems = Get-ChildItem -Path $unpackedDir
						if ($extractedItems.Count -gt 0) {
							Write-Host "Распаковано через UniExtract: $relativePath" -ForegroundColor Green
							Write-LogToTop -csvPath $csvPath -reason "Успешно распаковано" -dirPath $dirPath -fileName $fileInfo.Name -extension $fileInfo.Extension
							Process-Directory -directory $unpackedDir -password $password -passwordErrors $passwordErrors -baseDirectory $baseDirectory -csvPath $csvPath
						} else {
							Remove-Item -Path $unpackedDir -Force -Recurse -ErrorAction SilentlyContinue
						}
					}
				} else {
					$reason = "Не архив / Сбой распаковки"
					if ($result -eq "PasswordError") {
						$reason = "Требуется пароль / Неверный пароль"
					}

					if (Test-Path $unpackedDir) { Remove-Item -Path $unpackedDir -Force -Recurse -ErrorAction SilentlyContinue }

					$passwordErrors.Value += $relativePath
					Write-LogToTop -csvPath $csvPath -reason $reason -dirPath $dirPath -fileName $fileInfo.Name -extension $fileInfo.Extension
				}
			}
		}
	}
}

# ====================================================================
# СТАРТ И ОБРАБОТКА ЗАВЕРШЕНИЯ СКРИПТА
# ====================================================================
try {
	if (-not $directory) {
		$directory = Read-Host "Введите путь к папке, в которой нужно провести распаковку"
	}

	if (-not (Test-Path $directory)) {
		Write-Host "`n[ОШИБКА] Указанный путь не существует: $directory" -ForegroundColor Red
		Read-Host "Нажмите Enter для закрытия окна..."
		Exit
	}

	$baseDirNormalized = $directory
	if (-not $baseDirNormalized.EndsWith("\")) { $baseDirNormalized += "\" }

	$csvPath = Join-Path $PSScriptRoot "Pass.csv"
	$passwordErrors = @()

	Write-Host "Запуск глобальной распаковки через Universal Extractor..." -ForegroundColor Cyan
	Process-Directory -directory $directory -passwordErrors ([ref]$passwordErrors) -baseDirectory $baseDirNormalized -csvPath $csvPath

	Write-Host "`n[УСПЕХ] Работа успешно завершена! Лог находится в файле: $csvPath" -ForegroundColor Green
	Read-Host "Нажмите Enter для завершения..."

} catch {
	Write-Host "`n[КРИТИЧЕСКИЙ СБОЙ СКРИПТА]: $_" -ForegroundColor Red
	Read-Host "Произошла фатальная ошибка. Нажмите Enter для закрытия..."
}
