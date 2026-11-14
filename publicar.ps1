<#
.SYNOPSIS
  Publica as alterações do projeto no GitHub, com verificações de segurança.

.EXAMPLE
  .\publicar.ps1 "feat: carga incremental da fato"
  .\publicar.ps1 "fix: ajusta query da fato" -Sim     # pula a confirmação
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Mensagem,

    [switch]$Sim
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot   # o script deve ficar na raiz do repositório

function Invoke-Git {
    & git.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "git $($args -join ' ') falhou (código $LASTEXITCODE)"
    }
}

# 0. Estamos dentro de um repositório?
Invoke-Git rev-parse --is-inside-work-tree | Out-Null

$branch = (git.exe branch --show-current).Trim()
Write-Host "Branch atual: $branch" -ForegroundColor Cyan
if ($branch -eq "main") {
    Write-Host "Atenção: você está na main. Prefira uma branch de feature." -ForegroundColor Yellow
}

# 1. Procura senhas nos arquivos do Pentaho (só aceita ${DB_PASSWORD} ou vazio)
$suspeitos = Get-ChildItem -Path "pdi" -Include *.ktr, *.kjb -Recurse -ErrorAction SilentlyContinue |
    Select-String -Pattern "<password>" |
    Where-Object { $_.Line -notmatch '<password>\s*(\$\{DB_PASSWORD\})?\s*</password>' }

if ($suspeitos) {
    Write-Host "ERRO: possível senha em arquivos do Pentaho. Nada foi commitado." -ForegroundColor Red
    $suspeitos | ForEach-Object { Write-Host ("  {0}, linha {1}" -f $_.Filename, $_.LineNumber) }
    Write-Host 'Use variáveis (${DB_PASSWORD}) na conexão e salve o arquivo de novo no Spoon.' -ForegroundColor Yellow
    exit 1
}

# 2. Adiciona tudo e vê o que entrou
Invoke-Git add -A
$staged = git.exe diff --cached --name-only
if (-not $staged) {
    Write-Host "Nada para commitar." -ForegroundColor Yellow
    exit 0
}

# 3. Bloqueia arquivos de configuração local
$proibidos = $staged | Where-Object { $_ -match '(^|/)(kettle\.properties|shared\.xml|\.env)$' }
if ($proibidos) {
    Invoke-Git reset | Out-Null
    Write-Host "ERRO: arquivo de configuração local na lista de commit:" -ForegroundColor Red
    $proibidos | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host "`nArquivos que serão commitados:" -ForegroundColor Cyan
git.exe status --short

# 4. Confirmação
if (-not $Sim) {
    $r = Read-Host "`nConfirmar commit e push para '$branch'? (s/n)"
    if ($r -notmatch '^[sSyY]') {
        Invoke-Git reset | Out-Null
        Write-Host "Cancelado. Nada foi commitado."
        exit 0
    }
}

# 5. Commit e push
Invoke-Git commit -m $Mensagem
Invoke-Git push -u origin $branch

Write-Host "`nPublicado em origin/$branch" -ForegroundColor Green