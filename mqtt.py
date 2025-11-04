"""
Simple MQTT subscriber for the `alarma` topics.

Connects to the broker used by the iOS client and prints every payload it
receives on the console so you can monitor alarm state changes.
"""

import ssl
from typing import Any

import paho.mqtt.client as mqtt
from cloud_alt import send_command,TuyaAPIError

# Default connection settings (mirroring the iOS configuration)
TCP_HOST = "broker.qubitro.com"
TCP_PORT = 8883
TCP_USE_TLS = True
MQTT_CLIENT_ID = "Alarma-python-listener"
MQTT_USERNAME = "hhsdjahsgdjaadj"
MQTT_PASSWORD = (
    "ndmnasbmdasbdjkwhk7512761t81jkhdskdjhqi"
)


def _on_connect(
    client: mqtt.Client,
    userdata: Any,
    flags: dict[str, Any],
    reason_code: int,
    properties: Any = None,
) -> None:
    """Subscribe to `alarma/#` once connected."""
    if reason_code == mqtt.MQTT_ERR_SUCCESS:
        print("Connected to MQTT broker")
        client.subscribe("alarma/#")
    else:
        print(f"Failed to connect (reason code: {reason_code})")


def _on_message(
    client: mqtt.Client,
    userdata: Any,
    message: mqtt.MQTTMessage,
) -> None:
    """Procesa solo los mensajes de `alarma/negocio`."""
    topic = message.topic or ""
    if topic.lower() != "alarma/negocio":
        # Ignorar otros tópicos
        return

    payload = message.payload.decode("utf-8", errors="replace")
    print(f"[{topic}] {payload}")

    payload_trimmed = payload.strip()
    value_str = None
    if "=" in payload_trimmed:
        _, _, rhs = payload_trimmed.partition("=")
        value_str = rhs.strip()
    elif payload_trimmed:
        value_str = payload_trimmed

    if value_str in {"0", "1"}:
        area = "negocio"  # fijo
        if value_str == "1":
            print(f"[INFO] {area.capitalize()} salio.")
            send_command("master_mode", "disarmed")
        else:
            print(f"[INFO] {area.capitalize()} entro.")
            send_command("master_mode", "arm")

def main() -> None:
    client = mqtt.Client(client_id=MQTT_CLIENT_ID, protocol=mqtt.MQTTv5)
    client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
    if TCP_USE_TLS:
        # Use default system certificates. Adjust if the broker requires custom CA.
        client.tls_set(tls_version=ssl.PROTOCOL_TLS_CLIENT)

    client.on_connect = _on_connect
    client.on_message = _on_message

    client.connect(TCP_HOST, TCP_PORT, keepalive=60)
    print(f"Listening for MQTT messages on alarma/# at {TCP_HOST}:{TCP_PORT} ...")
    client.loop_forever()


if __name__ == "__main__":
    main()
