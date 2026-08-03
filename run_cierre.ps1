# Corre el cierre mensual de punta a punta y se DETIENE si algun paso falla.
# Uso: poner el Excel nuevo en data\ y ejecutar  .\run_cierre.ps1  desde la raiz.

$ErrorActionPreference = "Stop"
$raiz = $PSScriptRoot
$py  = Join-Path $raiz ".venv\Scripts\python.exe"
$dbt = Join-Path $raiz ".venv\Scripts\dbt.exe"

function Paso($titulo, $accion) {
    Write-Host "`n=== $titulo ===" -ForegroundColor Cyan
    & $accion
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FALLO en: $titulo (codigo $LASTEXITCODE). Proceso detenido." -ForegroundColor Red
        exit 1
    }
}

# 1) Ingesta: carpeta local -> bucket -> BigQuery raw
Set-Location (Join-Path $raiz "src")
Paso "Upload (carpeta -> bucket)"          { & $py upload.py }
Paso "Ingest (bucket -> BigQuery)"         { & $py ingest.py }

# 2) Transformacion + tests
Set-Location (Join-Path $raiz "dbt")
Paso "dbt build (transformacion + tests)"  { & $dbt build }

# 3) Publicacion: Excel + refresco del Google Sheet
Set-Location (Join-Path $raiz "src")
Paso "Export (Excel de publicacion)"       { & $py export.py }
Paso "Refresh (Google Sheet BI)"           { & $py refresh_sheet.py }

Set-Location $raiz
Write-Host "`nCierre completo OK." -ForegroundColor Green
