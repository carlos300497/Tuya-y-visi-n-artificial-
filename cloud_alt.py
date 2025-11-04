import json
import os
from typing import Any, Iterable, List

from cloud import TuyaAPIError, TuyaClient

DEVICE_ID = os.getenv("TUYA_DEVICE_ID", "jsbdjasda,")

_client = TuyaClient()


def send_command(code: str, value: Any, device_id: str = DEVICE_ID) -> dict:
    response = _client.send_command(device_id, code, value)
    print(f"📡 {code} → {value}")
    print(json.dumps(response, indent=2, ensure_ascii=False))
    return response


def send_commands(commands: Iterable[dict], device_id: str = DEVICE_ID) -> dict:
    commands_list: List[dict] = list(commands)
    response = _client.send_commands(device_id, commands_list)
    print(f"📡 Enviando {len(commands_list)} comandos")
    print(json.dumps(response, indent=2, ensure_ascii=False))
    return response


def activate_alarm(device_id: str = DEVICE_ID) -> dict:
    commands = [
        {"code": "switch_alarm_sound", "value": True},
        {"code": "switch_alarm_light", "value": True},
    ]
    return send_commands(commands, device_id=device_id)


def deactivate_alarm(device_id: str = DEVICE_ID) -> dict:
    commands = [
        {"code": "switch_alarm_sound", "value": False},
        {"code": "switch_alarm_light", "value": False},
    ]
    return send_commands(commands, device_id=device_id)


if __name__ == "__main__":
    try:
        send_command("master_mode", "disarmed")
    except TuyaAPIError as exc:
        print(f"[ERROR] {exc}")
