# Cierre mensual de punta a punta, con salida RESUMIDA. Se detiene si algo falla.
# Uso: poner el Excel nuevo en data\ y ejecutar  .\run_cierre.ps1  desde la raiz.

$ErrorActionPreference = "Stop"
$raiz = $PSScriptRoot
$py  = Join-Path $raiz ".venv\Scripts\python.exe"
$dbt = Join-Path $raiz ".venv\Scripts\dbt.exe"

function Correr($titulo, $accion) {
    Write-Host "`n> $titulo ..." -ForegroundColor Cyan
    $salida = & $accion 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host $salida
        Write-Host "FALLO en: $titulo (codigo $LASTEXITCODE). Proceso detenido." -ForegroundColor Red
        exit 1
    }
    return $salida
}

function Contar($texto, $patron) { ([regex]::Matches($texto, $patron)).Count }

function Linea($texto, $patron) {
    $m = $texto -split "`n" | Select-String $patron | Select-Object -First 1
    if ($m) { $m.ToString().Trim() } else { "" }
}

# Cantidad de cambios de nombre sin validar, leída del warning del dbt build
# (linea "WARN <n> warn_cambios_nombre_pendientes"). 0 si no hubo warning.
function Pendientes($texto) {
    $m = [regex]::Match($texto, "WARN (\d+) warn_cambios_nombre_pendientes")
    if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }
}

# Pregunta s/n con tiempo limite. Si nadie responde (o no hay consola
# interactiva, p.ej. corrida programada), devuelve "n".
function PreguntarConTiempo($texto, $segundos) {
    Write-Host -NoNewline $texto
    try {
        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }  # descarta teclas previas
        $fin = (Get-Date).AddSeconds($segundos)
        while ((Get-Date) -lt $fin) {
            if ([Console]::KeyAvailable) {
                $tecla = [Console]::ReadKey($true).KeyChar.ToString().ToLower()
                Write-Host $tecla
                return $tecla
            }
            Start-Sleep -Milliseconds 200
        }
    } catch { }
    Write-Host "(sin respuesta)"
    return "n"
}

# 0) Garantia de version: el cierre corre SOLO con el codigo exacto de GitHub.
# El codigo, los modelos y los seeds se comparten por git y todos escriben en las
# mismas tablas de BigQuery: procesar con otra version pisaria esas tablas.
# Tres controles; si alguno falla, el cierre no arranca:
#   a) sin cambios locales sin commitear (ni archivos nuevos sin agregar a git);
#   b) git pull (baja lo nuevo de GitHub);
#   c) el commit local es exactamente el de GitHub (ni atrasado ni con commits
#      sin pushear).
# --quiet: git escribe su progreso en stderr y eso PowerShell lo trataria como error.
Set-Location $raiz
Write-Host "`n> Verificar version (git) ..." -ForegroundColor Cyan

$sucios = git status --porcelain
if ($sucios) {
    Write-Host ($sucios -join "`n")
    Write-Host "FALLO: hay cambios sin commitear (lista de arriba). Commitealos y pushealos, o descartalos, antes del cierre. Proceso detenido." -ForegroundColor Red
    exit 1
}

$antes = (git rev-parse --short HEAD).Trim()
$o = Correr "Actualizar repo (git pull)" { git pull --ff-only --quiet }

$local  = (git rev-parse HEAD).Trim()
$remoto = (git rev-parse "@{u}").Trim()
if ($local -ne $remoto) {
    Write-Host "FALLO: el repo local no coincide con GitHub (local $($local.Substring(0,7)), GitHub $($remoto.Substring(0,7))). Si tenes commits sin pushear, hace git push. Proceso detenido." -ForegroundColor Red
    exit 1
}

$despues = $local.Substring(0,7)
if ($antes -eq $despues) {
    Write-Host "   version al dia con GitHub ($despues)" -ForegroundColor Green
} else {
    Write-Host "   actualizado: $antes -> $despues (al dia con GitHub)" -ForegroundColor Green
}

# 1) Ingesta
Set-Location (Join-Path $raiz "src")

$o = Correr "Upload (carpeta -> bucket)" { & $py upload.py }
Write-Host ("   subidos: {0} | reemplazados: {1} | sin cambios: {2}" -f (Contar $o "\[UPLOAD\]"), (Contar $o "\[REEMPLAZO\]"), (Contar $o "\[SKIP\]")) -ForegroundColor Green
foreach ($a in ($o -split "`n" | Select-String "\[AVISO\]")) {
    Write-Host ("   " + $a.ToString().Trim()) -ForegroundColor Yellow
}

$o = Correr "Ingest (bucket -> BigQuery)" { & $py ingest.py }
Write-Host ("   cargados: {0} | reemplazados: {1} | sin cambios: {2}" -f (Contar $o "\[LOAD\]"), (Contar $o "\[REEMPLAZO\]"), (Contar $o "\[SKIP\]")) -ForegroundColor Green

# 2) Transformacion + tests
Set-Location (Join-Path $raiz "dbt")

$o = Correr "dbt build (transformacion + tests)" { & $dbt build }
$pendientes = Pendientes $o
$resumen = Linea $o "Done\. PASS="
if ($resumen) { Write-Host ("   " + $resumen) -ForegroundColor Green }
foreach ($w in ($o -split "`n" | Select-String "WARN \d")) {
    Write-Host ("   warning: " + $w.ToString().Trim()) -ForegroundColor Yellow
}

# 3) Publicacion
Set-Location (Join-Path $raiz "src")

$o = Correr "Refresh (Google Sheets BI)" { & $py refresh_sheet.py }
foreach ($l in ($o -split "`n" | Select-String "OK:")) {
    Write-Host ("   " + $l.ToString().Trim()) -ForegroundColor Green
}

Set-Location $raiz
Write-Host "`nCierre completo OK." -ForegroundColor Green

# 4) Validacion de cambios de nombre (opcional, despues del cierre)
# El cierre ya termino: si no se valida ahora, los cambios quedan pendientes
# y se avisan de nuevo en el proximo build.
if ($pendientes -gt 0) {
    Write-Host "`nHay $pendientes cambios de nombre pendientes de validacion." -ForegroundColor Yellow
    $r = PreguntarConTiempo "Validar ahora? (s/n) [60 s para responder, por defecto n]: " 60

    if ($r -eq "s") {
        Set-Location (Join-Path $raiz "src")
        & $py validar.py          # interactivo: no se captura la salida

        Set-Location (Join-Path $raiz "dbt")
        $o = Correr "dbt build (aplica las decisiones)" { & $dbt build }
        $resumen = Linea $o "Done\. PASS="
        if ($resumen) { Write-Host ("   " + $resumen) -ForegroundColor Green }
        $pendientes = Pendientes $o

        Set-Location (Join-Path $raiz "src")
        $o = Correr "Refresh (Google Sheets BI)" { & $py refresh_sheet.py }
        foreach ($l in ($o -split "`n" | Select-String "OK:")) {
            Write-Host ("   " + $l.ToString().Trim()) -ForegroundColor Green
        }

        Set-Location $raiz
        Write-Host "`nValidacion aplicada." -ForegroundColor Green
    }

    if ($pendientes -gt 0) {
        Write-Host "Quedan $pendientes cambios de nombre pendientes. Para validar despues:" -ForegroundColor Yellow
        Write-Host "   cd src ; python validar.py ; cd ..\dbt ; dbt build ; cd ..\src ; python refresh_sheet.py"
    }
}
