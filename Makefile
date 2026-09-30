all: lint

lint: format check

format:
	ruff format *.py

check:
	ruff check *.py

psanalyze: .powershell/pwsh
	.powershell/pwsh -Command "if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force }"
	.powershell/pwsh -Command "Get-ChildItem -Path . -Filter *.ps1 | Invoke-ScriptAnalyzer"

.powershell/pwsh:
	rm -rf .powershell
	mkdir .powershell
	wget -O .powershell/powershell.tgz https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-x64.tar.gz
	cd .powershell && tar -xavf powershell.tgz
	rm -f .powershell/powershell.tgz

.PHONY: all lint format check powershell
