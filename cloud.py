import json
import os
import time
import hmac
import hashlib
import threading
from typing import Any, Dict, Iterable, Optional

import requests

# Configuración base; permite sobrescribir con variables de entorno si es necesario.
ACCESS_ID = os.getenv("TUYA_ACCESS_ID", "dgfdghfhjj")              ### access id tuya 
ACCESS_SECRET = os.getenv("TUYA_ACCESS_SECRET", "768528371872")    ### clave secreta tuya 
ENDPOINT = os.getenv("TUYA_ENDPOINT", "https://openapi.tuyaus.com").rstrip("/")


class TuyaAPIError(RuntimeError):
    """Error enviado por la API de Tuya."""


class TuyaClient:
    _TOKEN_INVALID_CODES = {
        "1010",
        "1011",
        "1012",
        "1013",
        "1014",
        "1015",
        "1100",
        "1102",
        "1104",
    }

    def __init__(
        self,
        access_id: str = ACCESS_ID,
        access_secret: str = ACCESS_SECRET,
        endpoint: str = ENDPOINT,
        refresh_margin: float = 60.0,
        session: Optional[requests.Session] = None,
    ) -> None:
        self.access_id = access_id
        self.access_secret = access_secret
        self.endpoint = endpoint.rstrip("/")
        self.refresh_margin = max(0.0, refresh_margin)
        self.session = session or requests.Session()

        self._token_lock = threading.Lock()
        self._token_payload: Optional[Dict[str, Any]] = None
        self._token_expires_at: float = 0.0

    # ------------------------- utilidades internas -------------------------
    def _make_sign(self, string_to_sign: str) -> str:
        return hmac.new(
            self.access_secret.encode("utf-8"),
            string_to_sign.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest().upper()

    def _hash_body(self, body: str) -> str:
        return hashlib.sha256(body.encode("utf-8")).hexdigest()

    def _request_new_token(self) -> Dict[str, Any]:
        method = "GET"
        path = "/v1.0/token?grant_type=1"
        body = ""
        content_sha256 = self._hash_body(body)
        string_to_sign = f"{method}\n{content_sha256}\n\n{path}"

        timestamp = str(int(time.time() * 1000))
        sign_str = self.access_id + timestamp + string_to_sign
        sign = self._make_sign(sign_str)

        headers = {
            "client_id": self.access_id,
            "sign": sign,
            "t": timestamp,
            "sign_method": "HMAC-SHA256",
        }

        url = f"{self.endpoint}{path}"
        response = self.session.get(url, headers=headers, timeout=10)
        response.raise_for_status()
        payload = response.json()

        if not payload.get("success"):
            raise TuyaAPIError(f"Token request failed: {json.dumps(payload, ensure_ascii=False)}")

        result = payload.get("result") or {}
        expire_time = result.get("expire_time")
        with self._token_lock:
            self._token_payload = result
            if isinstance(expire_time, (int, float)):
                expires_at = time.time() + float(expire_time)
            else:
                expires_at = time.time() + 3600.0
            self._token_expires_at = max(expires_at - self.refresh_margin, time.time())
        return payload

    def _token_still_valid(self) -> bool:
        with self._token_lock:
            return self._token_payload is not None and time.time() < self._token_expires_at

    def _get_cached_token(self) -> Optional[str]:
        with self._token_lock:
            if self._token_payload:
                return self._token_payload.get("access_token")
        return None

    def _command_body(self, commands: Iterable[Dict[str, Any]]) -> str:
        return json.dumps({"commands": list(commands)}, separators=(",", ":"))

    def _post_commands(
        self,
        device_id: str,
        commands: Iterable[Dict[str, Any]],
        access_token: str,
    ) -> Dict[str, Any]:
        method = "POST"
        path = f"/v1.0/devices/{device_id}/commands"
        body = self._command_body(commands)
        content_sha256 = self._hash_body(body)
        string_to_sign = f"{method}\n{content_sha256}\n\n{path}"
        timestamp = str(int(time.time() * 1000))
        sign_str = self.access_id + access_token + timestamp + string_to_sign
        sign = self._make_sign(sign_str)

        headers = {
            "client_id": self.access_id,
            "access_token": access_token,
            "sign": sign,
            "t": timestamp,
            "sign_method": "HMAC-SHA256",
            "Content-Type": "application/json",
        }

        url = f"{self.endpoint}{path}"
        response = self.session.post(url, headers=headers, data=body, timeout=10)
        response.raise_for_status()
        return response.json()

    # ------------------------------ API pública ------------------------------
    def request_token(self) -> Dict[str, Any]:
        """Solicita un token nuevo y actualiza la caché."""
        return self._request_new_token()

    def get_token_details(self, force_refresh: bool = False) -> Dict[str, Any]:
        with self._token_lock:
            cached = self._token_payload
        if force_refresh or not cached or not self._token_still_valid():
            self._request_new_token()
        with self._token_lock:
            if not self._token_payload:
                raise TuyaAPIError("Token cache unavailable after refresh.")
            return dict(self._token_payload)

    def get_access_token(self, force_refresh: bool = False) -> str:
        details = self.get_token_details(force_refresh=force_refresh)
        token = details.get("access_token")
        if not token:
            raise TuyaAPIError("Access token missing from payload.")
        return token

    def send_commands(
        self,
        device_id: str,
        commands: Iterable[Dict[str, Any]],
        retry_on_expired: bool = True,
    ) -> Dict[str, Any]:
        commands_list = list(commands)
        attempt = 0
        token = self.get_access_token()

        while True:
            response = self._post_commands(device_id, commands_list, token)

            if response.get("success"):
                return response

            if not retry_on_expired:
                return response

            code = response.get("code")
            if attempt >= 1:
                return response

            attempt += 1
            if code is None or str(code) not in self._TOKEN_INVALID_CODES:
                # Realiza un refresco forzado aunque el código sea desconocido,
                # por si acaso el token caducó sin reportar explícitamente.
                pass

            token = self.get_access_token(force_refresh=True)

    def send_command(self, device_id: str, code: str, value: Any) -> Dict[str, Any]:
        return self.send_commands(device_id, [{"code": code, "value": value}])


def get_token() -> Dict[str, Any]:
    client = TuyaClient()
    return client.request_token()


if __name__ == "__main__":
    try:
        token_payload = get_token()
    except Exception as exc:
        print("❌ Token request failed.")
        print(exc)
    else:
        print(json.dumps(token_payload, indent=2, ensure_ascii=False))
        if token_payload.get("success"):
            print("✅ Access token obtained successfully.")
        else:
            print("❌ Token request failed.")
