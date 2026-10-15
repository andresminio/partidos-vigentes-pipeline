# Cierre mensual de punta a punta, con salida RESUMIDA. Se detiene si algo falla.
# Uso: poner el Excel nuevo en data\ y ejecutar cierre.bat (o .\run_cierre.ps1).
# Los mensajes de consola van sin tildes: la consola de Windows las muestra rotas.

$ErrorActionPreference = "Stop"
$raiz = $PSScriptRoot
$py  = Join-Path $raiz ".venv\Scripts\python.exe"
$dbt = Join-Path $raiz ".venv\Scripts\dbt.exe"
$inicio = Get-Date

function Paso($etiqueta) {
    Write-Host "`n$etiqueta" -ForegroundColor Cyan
}

function Ok($texto)    { Write-Host "      $texto" -ForegroundColor Green }
function Aviso($texto) { Write-Host "      ! $texto" -ForegroundColor Yellow }

function Detener($motivo, $queHacer) {
    Write-Host "      X $motivo" -ForegroundColor Red
    if ($queHacer) { Write-Host "        Que hacer: $queHacer" -ForegroundColor Red }
    Write-Host "`nCierre detenido." -ForegroundColor Red
    exit 1
}

# Corre un comando capturando su salida. Si falla, muestra el detalle tecnico
# completo, el motivo y que hacer, y detiene el cierre.
function Correr($accion, $queHacer) {
    $salida = & $accion 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host $salida
        Detener "Fallo este paso (codigo $LASTEXITCODE). Detalle arriba." $queHacer
    }
    return $salida
}

function Contar($texto, $patron) { ([regex]::Matches($texto, $patron)).Count }

# Cantidad de cambios de nombre sin validar, leida del warning del dbt build
# (linea "WARN <n> warn_cambios_nombre_pendientes"). 0 si no hubo warning.
function Pendientes($texto) {
    $m = [regex]::Match($texto, "WARN (\d+) warn_cambios_nombre_pendientes")
    if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }
}

# Resumen de dbt build: cantidad de pasos OK y avisos separados en dos grupos,
# lo que requiere accion y lo informativo, cada uno con que hacer.
$AVISOS = @{
    "warn_cambios_nombre_pendientes" = @{ accion = $true
        texto = "cambios de nombre pendientes de validar"
        hacer = "Se pregunta al final del cierre." }
    "warn_correccion_no_aplicada" = @{ accion = $true
        texto = "errores de carga cuya correccion no se aplico"
        hacer = "Cargar el nombre erroneo en dbt/seeds/equivalencias_nombre.csv, dbt build y commit." }
    "warn_distritos_inconsistentes" = @{ accion = $true
        texto = "distritos (jurisdicciones) con numero y nombre que no coinciden"
        hacer = "Revisar el Excel. Si el numero esta mal: cargarlo en dbt/seeds/correcciones_distrito.csv." }
    "warn_nombres_divergentes_del_nacional" = @{ accion = $false
        texto = "partidos de distrito nuevos que integran un nacional pero figuran con un nombre muy distinto al de ese nacional"
        hacer = "Normal si el partido de distrito tiene nombre propio. Si es un error de carga: cargarlo en equivalencias_nombre." }
}
function ResumenDbt($texto) {
    $m = [regex]::Match($texto, "PASS=(\d+) WARN=(\d+) ERROR=(\d+)")
    if ($m.Success) { Ok ("OK - {0} pasos (modelos y controles) sin problemas" -f $m.Groups[1].Value) }

    $accion = @(); $info = @(); $vistos = @{}
    foreach ($w in [regex]::Matches($texto, "\d+ of \d+ WARN (\d+) (\S+)")) {
        $test = $w.Groups[2].Value
        if ($vistos.ContainsKey($test)) { continue }
        $vistos[$test] = $true
        $def = $AVISOS[$test]
        if (-not $def) { $def = @{ accion = $true; texto = "avisos de $test"; hacer = "Ver el README, seccion 'Avisos y errores al procesar'." } }
        $item = @{ n = $w.Groups[1].Value; def = $def }
        if ($def.accion) { $accion += $item } else { $info += $item }
    }

    if ($accion.Count) {
        Write-Host "`n      REQUIERE ACCION:" -ForegroundColor Yellow
        foreach ($a in $accion) {
            Write-Host ("      ! {0} {1}" -f $a.n, $a.def.texto) -ForegroundColor Yellow
            Write-Host ("          -> {0}" -f $a.def.hacer) -ForegroundColor Yellow
        }
    }
    if ($info.Count) {
        Write-Host "`n      INFORMATIVO (no requiere accion):" -ForegroundColor Gray
        foreach ($a in $info) {
            Write-Host ("      i {0} {1}" -f $a.n, $a.def.texto) -ForegroundColor Gray
            Write-Host ("          -> {0}" -f $a.def.hacer) -ForegroundColor Gray
        }
    }
}

# Hojas actualizadas, una por linea (solo el nombre de la hoja).
function ResumenRefresh($texto) {
    foreach ($m in [regex]::Matches($texto, "(?m)^OK: (.+?) -> ")) { Ok ("OK - " + $m.Groups[1].Value) }
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

$QUE_HACER_GOOGLE = "revisar el detalle. Si menciona credenciales o 'Reauthentication': volver a autenticarse con gcloud y correr de nuevo."
$QUE_HACER_DBT    = "ver el detalle y el README, seccion 'Avisos y errores al procesar'."
$QUE_HACER_SHEETS = "si dice 'no autorizado': revisar el token. Si muestra una pagina de login: publicar una Nueva version del Apps Script con acceso 'Cualquier usuario'."

Write-Host "=== Cierre mensual ===" -ForegroundColor Cyan

# 1) Garantia de version: el cierre corre SOLO con el codigo exacto de GitHub.
# El codigo, los modelos y los seeds se comparten por git y todos escriben en las
# mismas tablas de BigQuery: procesar con otra version pisaria esas tablas.
# Tres controles; si alguno falla, el cierre no arranca:
#   a) sin cambios locales sin commitear (ni archivos nuevos sin agregar a git);
#   b) git pull (baja lo nuevo de GitHub);
#   c) el commit local es exactamente el de GitHub (ni atrasado ni con commits
#      sin pushear).
# --quiet: git escribe su progreso en stderr y eso PowerShell lo trataria como error.
Set-Location $raiz
Paso "[1/5] Verificando que el codigo este al dia con GitHub..."

$sucios = git status --porcelain
if ($sucios) {
    Write-Host "      X Hay cambios sin guardar en git:" -ForegroundColor Red
    foreach ($s in $sucios) { Write-Host "          $s" -ForegroundColor Red }
    Detener "No se puede procesar con codigo que no esta en GitHub." "commit + push (o descartarlos) y volver a correr."
}

$antes = (git rev-parse --short HEAD).Trim()
$o = Correr { git pull --ff-only --quiet } "revisar la conexion a internet y el acceso a GitHub."

$local  = (git rev-parse HEAD).Trim()
$remoto = (git rev-parse "@{u}").Trim()
if ($local -ne $remoto) {
    Detener ("El codigo local no coincide con GitHub (local {0}, GitHub {1})." -f $local.Substring(0,7), $remoto.Substring(0,7)) "si hay commits sin pushear, hacer git push y volver a correr."
}

$despues = $local.Substring(0,7)
if ($antes -eq $despues) { Ok "OK - al dia ($despues)" } else { Ok "OK - actualizado desde GitHub ($antes -> $despues)" }

# 2) Subida: data\ -> bucket
Set-Location (Join-Path $raiz "src")
Paso "[2/5] Subiendo Excel nuevos al bucket..."

$o = Correr { & $py upload.py } $QUE_HACER_GOOGLE
$subidos = @(($o -split "`n") | Select-String "\[(UPLOAD|REEMPLAZO)\]")
if ($subidos.Count -eq 0) {
    Ok "No hay archivos nuevos en data\ - nada para subir"
} else {
    foreach ($l in $subidos) {
        $m = [regex]::Match($l.ToString(), "\[(UPLOAD|REEMPLAZO)\] (.+?) -> ")
        $tipo = if ($m.Groups[1].Value -eq "REEMPLAZO") { "reemplaza version anterior" } else { "nuevo" }
        Ok ("Subido: {0} ({1})" -f $m.Groups[2].Value, $tipo)
    }
}
foreach ($a in (($o -split "`n") | Select-String "\[AVISO\]")) {
    Aviso (($a.ToString() -replace "^.*\[AVISO\]\s*", "").Trim())
}

# 3) Carga: bucket -> BigQuery
Paso "[3/5] Cargando meses nuevos en BigQuery..."

$o = Correr { & $py ingest.py } $QUE_HACER_GOOGLE
$sinCambios = Contar $o "\[SKIP\]"
$cargados = @(($o -split "`n") | Select-String "\[(LOAD|REEMPLAZO)\]")
if ($cargados.Count -eq 0) {
    Ok "Sin meses nuevos ($sinCambios ya cargados)"
} else {
    foreach ($l in $cargados) {
        $m = [regex]::Match($l.ToString(), "\[(LOAD|REEMPLAZO)\] .+\((\d{4})-(\d{2})-(\d{2})\)")
        $fecha = "{0}-{1}-{2}" -f $m.Groups[4].Value, $m.Groups[3].Value, $m.Groups[2].Value
        $tipo = if ($m.Groups[1].Value -eq "REEMPLAZO") { "reemplazado" } else { "cargado" }
        Ok ("Mes {0}: {1}" -f $fecha, $tipo)
    }
    Ok "($sinCambios meses ya estaban cargados)"
}

# 4) Transformacion + controles
Set-Location (Join-Path $raiz "dbt")
Paso "[4/5] Procesando datos y corriendo controles..."

$o = Correr { & $dbt build } $QUE_HACER_DBT
$pendientes = Pendientes $o
ResumenDbt $o

# 5) Publicacion
Set-Location (Join-Path $raiz "src")
Paso "[5/5] Actualizando Google Sheets..."

$o = Correr { & $py refresh_sheet.py } $QUE_HACER_SHEETS
ResumenRefresh $o

Set-Location $raiz
$dur = (Get-Date) - $inicio
Write-Host ("`nListo. Cierre completo en {0} min {1} s." -f [int][math]::Floor($dur.TotalMinutes), $dur.Seconds) -ForegroundColor Green

# Validacion de cambios de nombre (opcional, despues del cierre)
# El cierre ya termino: si no se valida ahora, los cambios quedan pendientes
# y se avisan de nuevo en el proximo build.
if ($pendientes -gt 0) {
    Write-Host "`nHay $pendientes cambios de nombre pendientes de validar." -ForegroundColor Yellow
    $r = PreguntarConTiempo "Validar ahora? (s/n) [60 s para responder, por defecto n]: " 60

    if ($r -eq "s") {
        Set-Location (Join-Path $raiz "src")
        & $py validar.py          # interactivo: no se captura la salida

        Set-Location (Join-Path $raiz "dbt")
        Paso "Aplicando las decisiones..."
        $o = Correr { & $dbt build } $QUE_HACER_DBT
        $pendientes = Pendientes $o
        ResumenDbt $o

        Set-Location (Join-Path $raiz "src")
        Paso "Actualizando Google Sheets..."
        $o = Correr { & $py refresh_sheet.py } $QUE_HACER_SHEETS
        ResumenRefresh $o

        Set-Location $raiz
        Write-Host "`nValidacion aplicada." -ForegroundColor Green
    }

    if ($pendientes -gt 0) {
        Write-Host "Quedan $pendientes cambios de nombre pendientes. Se pueden validar en el proximo cierre," -ForegroundColor Yellow
        Write-Host "o ahora con: cd src ; python validar.py ; cd ..\dbt ; dbt build ; cd ..\src ; python refresh_sheet.py" -ForegroundColor Yellow
    }
}
