#Requires -Version 7
[CmdletBinding()]
param([string]$Executable = (Join-Path (Split-Path $PSScriptRoot -Parent) 'NexoBar.exe'), [switch]$OpenUI, [switch]$TestConPty, [switch]$QueryClaude, [string]$ClaudeFolder)
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'Este smoke exige Windows nativo, não WSL.' }
if (!(Test-Path $Executable)) { $Executable = Join-Path $PSScriptRoot 'NexoBar.exe' }
if (!(Test-Path $Executable)) { throw 'Informe -Executable com o NexoBar.exe extraído.' }
$Executable = [IO.Path]::GetFullPath($Executable)
$context = Join-Path ([IO.Path]::GetTempPath()) 'NexoBar/windows-native-smoke'
New-Item -ItemType Directory -Force $context | Out-Null
$output = Join-Path $context 'sensors.json'
$process = Start-Process $Executable -ArgumentList @('--diagnose','--output',('"' + $output + '"')) -PassThru
if (!$process.WaitForExit(30000)) { $process.Kill($true); throw 'Diagnóstico excedeu 30s.' }
if ($process.ExitCode -ne 0 -or !(Test-Path $output)) { throw 'Diagnóstico nativo falhou.' }
$data = Get-Content $output -Raw | ConvertFrom-Json
$cpu = $data.readings | Where-Object Id -eq 'cpu'
$memory = $data.readings | Where-Object Id -eq 'memory'
if ($null -eq $cpu.Percent -or $cpu.Percent -lt 0 -or $cpu.Percent -gt 100) { throw 'CPU não forneceu delta válido.' }
if (!$memory.TotalBytes -or $memory.UsedBytes -gt $memory.TotalBytes) { throw 'RAM física inválida.' }
$data.readings | Select-Object Id, Name, Percent, Temperature, UsedBytes, TotalBytes, Unavailable | Format-Table -AutoSize
Write-Host "Evidência nativa: $output"
Write-Host 'Temperatura ausente é permitida sem elevação. Compare quantidade/nomes/IDs das GPUs com o Gerenciador de Dispositivos; não declarar essa cobertura só pelo script.'
if ($TestConPty) {
    $harness = Join-Path (Split-Path $Executable -Parent) 'native-tests/NexoBar.ConPty.Tests.exe'
    if (!(Test-Path $harness)) { throw 'Harness ConPTY ausente do pacote.' }
    $lifecycle = Join-Path $context 'conpty-lifecycle'
    & $harness $lifecycle
    if ($LASTEXITCODE -ne 0) { throw 'Lifecycle ConPTY falhou; não declarar transporte validado.' }
}
if ($QueryClaude) {
    if (!$ClaudeFolder -or ![IO.Path]::IsPathFullyQualified($ClaudeFolder) -or !(Test-Path -LiteralPath $ClaudeFolder -PathType Container)) {
        throw '-QueryClaude exige -ClaudeFolder absoluta, já confiável no cliente. Nenhum login/trust será respondido.'
    }
    $claudeData = Join-Path $context 'claude-opt-in-data'
    New-Item -ItemType Directory -Force $claudeData | Out-Null
    @{ SchemaVersion=1; ClaudeWorkingDirectory=$ClaudeFolder; Indicators=@(@{Id='claude'; Label='Claude'; Enabled=$true; ShowTemperature=$false}) } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $claudeData 'indicators.json') -Encoding utf8
    $claudeOutput = Join-Path $context 'claude-opt-in-result.json'
    $query = Start-Process $Executable -ArgumentList @('--data-directory', ('"' + $claudeData + '"'), '--diagnose-claude', '--output', ('"' + $claudeOutput + '"')) -PassThru
    if (!$query.WaitForExit(60000)) { $query.Kill($true); throw 'Consulta Claude excedeu 60s.' }
    if (!(Test-Path $claudeOutput)) { throw 'Diagnóstico Claude não gerou resultado.' }
    Get-Content $claudeOutput
    if ($query.ExitCode -ne 0) { throw 'Consulta Claude indisponível; ver resultado sanitizado.' }
}
if ($OpenUI) { Start-Process $Executable -ArgumentList @('--data-directory', ('"' + (Join-Path $context 'isolated-data') + '"'), '--settings') }
Write-Host 'QA manual: tema claro/escuro; monitores e escala/DPI; clique em cada indicador; menu direito; ocultar e recuperar pela bandeja; quotas semanal única/dupla; GPU desconectar/reconectar; RAM/gráfico; nenhum foco roubado a cada 3s; taskbar e fullscreen; Sair encerra subprocessos próprios.'

Write-Host 'ConPTY: -TestConPty executa apenas filhos sintéticos; -QueryClaude -ClaudeFolder <pasta> é opt-in explícito da consulta real. Nunca executados automaticamente no smoke.'
