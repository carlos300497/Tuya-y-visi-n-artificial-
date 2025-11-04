# Tuya Guard Toolkit

Herramientas para integrar detección visual, monitoreo MQTT y control de dispositivos Tuya en un mismo proyecto. El módulo principal (`src/tuya_guard/main.py`) realiza inferencia YOLO en un stream RTSP y dispara alertas locales y comandos Tuya; los módulos `mqtt.py`, `cloud.py` y `cloud_alt.py` permiten observar el broker original y enviar comandos a la nube de Tuya desde scripts independientes.

## Requisitos
- Python 3.10 o superior.
- Dependencias Python:
  ```bash
  pip install ultralytics opencv-python numpy simpleaudio paho-mqtt requests
  ```
  `simpleaudio` es opcional pero recomendado en sistemas sin `afplay`, `ffplay` o `aplay` para reproducir audio.
- GPU opcional; YOLOv8n funciona con CPU pero ajustar `YOLO_IMGSZ` puede mejorar el rendimiento.

## Estructura principal
```
src/tuya_guard/
│── main.py        # Detección por visión y alertas locales
│── mqtt.py        # Monitor MQTT que sincroniza con Tuya
│── cloud.py       # Cliente directo de la API Tuya (token + comandos)
└── cloud_alt.py   # Accesos directos a comandos Tuya de uso común
assets/audio/      # Alertas wav (por defecto `alerta.wav`)
models/            # Modelos YOLO (descargados automáticamente por ultralytics)
```

## `main.py`: detección por visión
1. **Variables de entorno clave**
   - `RTSP_URL`: URL del stream. Default: `rtsp://admin:vnvhhj@192.168.100.200:554/Streaming/Channels/701`.
   - `CONF_THRES`: confianza mínima YOLO (default `0.6`).
   - `MIN_PERSON_AREA`: área mínima (px²) para aceptar una persona (default `6000`).
   - `ROI_PERSISTENCE_FRAMES`: cuadros consecutivos dentro del ROI antes de disparar (default `3`).
   - `YOLO_MODEL_PATH`: ruta al modelo YOLO (default `models/yolov8n.pt`).
   - `SOUND_FILE`: wav a reproducir (default `assets/audio/alerta.wav`).
   - `HEADLESS=1`: desactiva la ventana de OpenCV.
   - Otros: `FRAME_SCALE`, `COOLDOWN`, `YOLO_IMGSZ`, `AUTO_HIDE_WINDOW`.

2. **Ejecución**
   ```bash
   python3 src/tuya_guard/main.py
   ```
   - Presiona `s` para seleccionar un ROI rectangular; clic izquierdo traza, clic derecho cierra polígonos.
   - `c` borra el ROI, `q` termina la sesión.
   - Al confirmar presencia en el ROI, se imprime `[ALERTA]` y se reproduce `alerta.wav`. El script intenta usar `afplay`, `ffplay`, `aplay` o `simpleaudio`.

3. **Tuya / API**
   - Si se definen `TUYA_ACCESS_ID`, `TUYA_ACCESS_SECRET` y `TUYA_DEVICE_ID`, las llamadas internas usarán `cloud.py`/`cloud_alt.py` para activar o desactivar la alarma según la lógica del ROI.

## `mqtt.py`: monitor de tópicos
- Se conecta vía TLS al broker `broker.qubitro.com` usando las credenciales de la app iOS y escucha `alarma/#`.
- Sólo responde a `alarma/negocio`. Según el payload (`0` o `1`) envía comandos `master_mode` (`arm`/`disarmed`) mediante `cloud_alt.send_command`.
- Ejecuta:
  ```bash
  python3 src/tuya_guard/mqtt.py
  ```
- Variables opcionales: `TUYA_ACCESS_ID`, `TUYA_ACCESS_SECRET`, `TUYA_DEVICE_ID` (compartidas con `cloud.py`).

## `cloud.py`: cliente Tuya OpenAPI
- Implementa firma HMAC y cacheo de tokens para el endpoint (default `https://openapi.tuyaus.com`).
- Variables soportadas:
  - `TUYA_ACCESS_ID`, `TUYA_ACCESS_SECRET`
  - `TUYA_ENDPOINT`
- Uso rápido:
  ```bash
  python3 src/tuya_guard/cloud.py
  ```
  Devuelve un token de acceso y muestra el resultado. También expone:
  ```python
  from tuya_guard.cloud import TuyaClient
  TuyaClient().send_command(device_id, "master_mode", "arm")
  ```

## `cloud_alt.py`: atajos de comandos
- Reexporta `TuyaClient` y `TuyaAPIError` y define funciones utilitarias:
  - `send_command(code, value)`
  - `send_commands([...])`
  - `activate_alarm()` / `deactivate_alarm()`
- Usa `TUYA_DEVICE_ID` por defecto, pero acepta sobreescritura al invocar.
- Ejemplo CLI:
  ```bash
  python3 -m tuya_guard.cloud_alt
  ```

## Consejos de operación
- **Modelos YOLO**: la primera ejecución descarga `yolov8n.pt` automáticamente. Puedes reemplazarlo por otro modelo de la familia YOLOv8 ajustando `YOLO_MODEL_PATH`.
- **Audio**: si no oyes alertas, confirma que `SOUND_FILE` exista y que haya un reproductor disponible (`ffplay`, `afplay`, `aplay`) o instala `simpleaudio`.
- **RTSP**: reduce `YOLO_IMGSZ` o `FRAME_SCALE` cuando el hardware sea limitado. Comprueba que `opencv-python` tenga soporte FFMPEG en tu plataforma.
- **Seguridad**: las credenciales Tuya se cargan desde variables; evita versionarlas. Configura `.env` si usas herramientas como `direnv`.

Con estos scripts puedes monitorizar tu flujo RTSP, recibir eventos MQTT y controlar tu panel Tuya desde un solo repositorio. Ajusta los parámetros según tu instalación para mejorar la precisión y la latencia.
