import os
from bitwarden_sdk import BitwardenClient, ClientSettings

# IDs de los secretos en Bitwarden Secrets Manager (proyecto partidos-vigentes-pipeline).
SECRET_IDS = {
    "SHEET_WEBAPP_URL": "b0e42658-fbc6-44d9-b996-b4cc00e76821",
    "SHEET_WEBAPP_TOKEN": "930a999e-8847-407f-a3f1-b4cc00e79121",
}


def load_secrets() -> None:
    """
    Recupera los secretos del pipeline desde Bitwarden Secrets Manager
    y los inyecta en os.environ, para que refresh_sheet.py siga leyendo
    os.environ.get(...) sin cambios.
    """
    token = os.environ.get("BWS_ACCESS_TOKEN")
    if not token:
        raise PermissionError("Acceso denegado: Computadora no validada.")

    client = BitwardenClient(ClientSettings())
    client.auth().login_access_token(token)

    for env_name, secret_id in SECRET_IDS.items():
        if not secret_id:
            print(f"AVISO: {env_name} no tiene ID de secreto configurado, se omite.")
            continue

        response = client.secrets().get(secret_id)
        if not response.success or response.data is None:
            raise RuntimeError(
                f"No se pudo recuperar {env_name} desde Bitwarden: "
                f"{response.error_message or 'error desconocido'}"
            )
        os.environ[env_name] = response.data.value
        print(f"OK: {env_name} recuperado exitosamente desde Bitwarden.")


if __name__ == "__main__":
    load_secrets()
    for env_name, secret_id in SECRET_IDS.items():
        if not secret_id:
            continue
        assert os.environ.get(env_name), f"{env_name} no se cargó"
    print("Todas las variables configuradas se cargaron correctamente.")
