import os
import sys
import urllib.error
import urllib.request

# Las URLs y el token viven en refresh_config.py (versionado en git) o, como
# alternativa, en variables de entorno.
try:
    from refresh_config import URLS, TOKEN
except ImportError:
    TOKEN = os.environ.get("SHEET_WEBAPP_TOKEN", "")
    # Fallback: una o varias URLs separadas por coma en SHEET_WEBAPP_URL.
    _urls = os.environ.get("SHEET_WEBAPP_URL", "")
    URLS = {u.strip(): u.strip() for u in _urls.split(",") if u.strip()}

# Única respuesta que devuelve el Apps Script cuando la actualización anduvo.
# Cualquier otra ("no autorizado", la página de login de Google, un error) es falla.
RESPUESTA_OK = "OK: datos actualizados"


def refrescar(nombre, url) -> bool:
    try:
        with urllib.request.urlopen(f"{url}?token={TOKEN}", timeout=180) as resp:
            texto = resp.read().decode()
    except (urllib.error.URLError, TimeoutError) as e:
        print(f"ERROR: {nombre} -> {e}")
        return False

    if texto.startswith(RESPUESTA_OK):
        print(f"OK: {nombre} -> {texto}")
        return True

    # Se recorta: si es la página de login de Google, es HTML largo.
    print(f"ERROR: {nombre} -> {texto[:200]}")
    return False


def main():
    if not URLS or not TOKEN:
        print("Falta configurar URLS/TOKEN (refresh_config.py o variables de entorno).")
        sys.exit(1)

    # Se intentan todas las hojas aunque falle alguna; al final se informa cuáles.
    fallas = [nombre for nombre, url in URLS.items() if not refrescar(nombre, url)]

    if fallas:
        print(f"Fallo el refresh de: {', '.join(fallas)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
