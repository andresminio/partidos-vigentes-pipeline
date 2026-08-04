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

# 1) Ingesta
Set-Location (Join-Path $raiz "src")

$o = Correr "Upload (carpeta -> bucket)" { & $py upload.py }
Write-Host ("   subidos: {0} | ya en bucket: {1}" -f (Contar $o "\[UPLOAD\]"), (Contar $o "\[SKIP\]")) -ForegroundColor Green

$o = Correr "Ingest (bucket -> BigQuery)" { & $py ingest.py }
Write-Host ("   cargados: {0} | ya cargados: {1}" -f (Contar $o "\[LOAD\]"), (Contar $o "\[SKIP\]")) -ForegroundColor Green

# 2) Transformacion + tests
Set-Location (Join-Path $raiz "dbt")

$o = Correr "dbt build (transformacion + tests)" { & $dbt build }
$resumen = Linea $o "Done\. PASS="
if ($resumen) { Write-Host ("   " + $resumen) -ForegroundColor Green }
foreach ($w in ($o -split "`n" | Select-String "WARN \d")) {
    Write-Host ("   warning: " + $w.ToString().Trim()) -ForegroundColor Yellow
}

# 3) Publicacion
Set-Location (Join-Path $raiz "src")

$o = Correr "Export (Excel de publicacion)" { & $py export.py }
Write-Host ("   " + (Linea $o "Escrito ")) -ForegroundColor Green

$o = Correr "Refresh (Google Sheet BI)" { & $py refresh_sheet.py }
Write-Host ("   " + (Linea $o "OK:")) -ForegroundColor Green

Set-Location $raiz
Write-Host "`nCierre completo OK." -ForegroundColor Green
