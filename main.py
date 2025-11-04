import os
import shutil
import subprocess
import time
import threading
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO

try:
    import simpleaudio as sa
except ImportError:
    sa = None

# Paths
PACKAGE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = PACKAGE_DIR.parent.parent
ASSETS_DIR = PROJECT_ROOT / "assets"
MODELS_DIR = PROJECT_ROOT / "models"
DEFAULT_MODEL_PATH = MODELS_DIR / "yolov8n.pt"
DEFAULT_SOUND_PATH = ASSETS_DIR / "audio" / "alerta.wav"

# Basic configuration
RTSP_URL = os.getenv(
    "RTSP_URL",
    "rtsp://admin:hik12345@192.168.100.200:554/Streaming/Channels/701",
)
CONF_THRES = float(os.getenv("CONF_THRES", "0.6"))
HEADLESS = os.getenv("HEADLESS", "0") == "1"
YOLO_IMGSZ = int(os.getenv("YOLO_IMGSZ", "640"))
YOLO_MODEL_PATH = os.getenv("YOLO_MODEL_PATH", str(DEFAULT_MODEL_PATH))
FRAME_SCALE = float(os.getenv("FRAME_SCALE", "1.0"))
COOLDOWN_SECONDS = float(os.getenv("COOLDOWN", "0.3"))
AUTO_HIDE_WINDOW = os.getenv("AUTO_HIDE_WINDOW", "0") == "1"
SOUND_FILE = Path(os.getenv("SOUND_FILE", str(DEFAULT_SOUND_PATH))).expanduser()
MIN_PERSON_AREA = float(os.getenv("MIN_PERSON_AREA", "6000"))
ROI_PERSISTENCE_FRAMES = max(1, int(os.getenv("ROI_PERSISTENCE_FRAMES", "3")))

# Default ROI (polygon). Leave empty to define it interactively.
ROI_POLIGONO = []  # e.g. [(100,100),(500,100),(500,400),(100,400)]

_sound_warning_logged = False


def play_alert_sound():
    global _sound_warning_logged
    if not SOUND_FILE.exists():
        if not _sound_warning_logged:
            print(f"[WARN] Archivo de sonido no disponible: {SOUND_FILE}")
            _sound_warning_logged = True
        return

    cmd = None
    if shutil.which("afplay"):
        cmd = ["afplay", str(SOUND_FILE)]
    elif shutil.which("ffplay"):
        cmd = ["ffplay", "-nodisp", "-autoexit", str(SOUND_FILE)]
    elif shutil.which("aplay"):
        cmd = ["aplay", str(SOUND_FILE)]

    if cmd:
        try:
            subprocess.Popen(cmd)
        except Exception as exc:
            if not _sound_warning_logged:
                print(f"[WARN] No se pudo reproducir sonido ({exc}).")
                _sound_warning_logged = True
        return

    if sa is not None:
        try:
            wave_obj = sa.WaveObject.from_wave_file(str(SOUND_FILE))
            wave_obj.play()
            return
        except Exception as exc:
            if not _sound_warning_logged:
                print(f"[WARN] No se pudo reproducir sonido ({exc}).")
                _sound_warning_logged = True
            return

    if not _sound_warning_logged:
        print("[WARN] No hay método disponible para reproducir sonido (instala simpleaudio o asegúrate de tener ffplay/aplay).")
        _sound_warning_logged = True


def draw_transparent_polygon(frame, pts, color=(0, 0, 255), alpha=0.25, border_thick=2):
    if len(pts) < 3:
        return frame
    overlay = frame.copy()
    cv2.fillPoly(overlay, [np.array(pts, dtype=np.int32)], color)
    cv2.addWeighted(overlay, alpha, frame, 1 - alpha, 0, frame)
    cv2.polylines(frame, [np.array(pts, dtype=np.int32)], isClosed=True, color=color, thickness=border_thick)
    return frame


def rect_to_polygon(x, y, w, h):
    return [(int(x), int(y)), (int(x + w), int(y)), (int(x + w), int(y + h)), (int(x), int(y + h))]


def point_in_polygon(point, polygon):
    if not polygon:
        return False
    return cv2.pointPolygonTest(np.array(polygon, dtype=np.int32), point, False) >= 0


def point_in_rect(point, rect_points):
    if not rect_points:
        return False
    xs = [p[0] for p in rect_points]
    ys = [p[1] for p in rect_points]
    return (min(xs) <= point[0] <= max(xs)) and (min(ys) <= point[1] <= max(ys))


def _orientation(a, b, c):
    val = (b[1] - a[1]) * (c[0] - b[0]) - (b[0] - a[0]) * (c[1] - b[1])
    if abs(val) < 1e-9:
        return 0
    return 1 if val > 0 else 2


def _on_segment(a, b, c):
    return min(a[0], c[0]) <= b[0] <= max(a[0], c[0]) and min(a[1], c[1]) <= b[1] <= max(a[1], c[1])


def segments_intersect(p1, p2, q1, q2):
    o1 = _orientation(p1, p2, q1)
    o2 = _orientation(p1, p2, q2)
    o3 = _orientation(q1, q2, p1)
    o4 = _orientation(q1, q2, p2)

    if o1 != o2 and o3 != o4:
        return True
    if o1 == 0 and _on_segment(p1, q1, p2):
        return True
    if o2 == 0 and _on_segment(p1, q2, p2):
        return True
    if o3 == 0 and _on_segment(q1, p1, q2):
        return True
    if o4 == 0 and _on_segment(q1, p2, q2):
        return True
    return False


def bbox_overlaps_polygon(bbox_rect, polygon):
    if not polygon:
        return False

    if point_in_polygon(bbox_rect[0], polygon):
        return True

    for pt in bbox_rect:
        if point_in_polygon(pt, polygon):
            return True

    for pt in polygon:
        if point_in_rect(pt, bbox_rect):
            return True

    for i in range(len(polygon)):
        a1 = polygon[i]
        a2 = polygon[(i + 1) % len(polygon)]
        for j in range(len(bbox_rect)):
            b1 = bbox_rect[j]
            b2 = bbox_rect[(j + 1) % len(bbox_rect)]
            if segments_intersect(a1, a2, b1, b2):
                return True

    return False


def main():
    print("[INFO] Inicializando detección con YOLO.")
    print(f"[INFO] Modelo: {YOLO_MODEL_PATH}")
    print(f"[INFO] Fuente RTSP: {RTSP_URL}")
    print(f"[INFO] Configuración detección -> conf >= {CONF_THRES} | área mínima {MIN_PERSON_AREA} px | persistencia {ROI_PERSISTENCE_FRAMES} frames")
    if HEADLESS:
        print("[INFO] Modo headless activo (sin ventana).")

    try:
        model = YOLO(YOLO_MODEL_PATH)
    except Exception as exc:
        print(f"[ERROR] No se pudo cargar el modelo YOLO: {exc}")
        return

    names = model.names

    roi_poly = ROI_POLIGONO.copy()
    drawing_polygon = False
    temp_polygon = []
    mouse_pos = None
    last_alert_t = 0.0

    def open_capture():
        cap_obj = cv2.VideoCapture(RTSP_URL, cv2.CAP_FFMPEG)
        if cap_obj.isOpened():
            cap_obj.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            return cap_obj
        cap_obj.release()
        return None

    initial_cap = open_capture()
    if initial_cap is None:
        print(f"[ERROR] No se pudo abrir RTSP: {RTSP_URL}")
        return

    frame_lock = threading.Lock()
    latest_frame = {"frame": None, "ts": 0.0}
    stop_event = threading.Event()
    connection_event = threading.Event()

    def capture_loop(start_cap):
        cap_local = start_cap
        first_iteration = True
        warned = False
        while not stop_event.is_set():
            if cap_local is None or not cap_local.isOpened():
                if not first_iteration and not warned:
                    print("[WARN] RTSP desconectado. Reintentando...")
                    warned = True
                cap_local = open_capture()
                if cap_local is None:
                    time.sleep(1.0)
                    continue
                if not first_iteration:
                    print("[INFO] Reconectado a RTSP.")
                warned = False
            first_iteration = False

            ok, frame_raw = cap_local.read()
            if not ok:
                connection_event.clear()
                cap_local.release()
                cap_local = None
                time.sleep(0.1)
                continue

            with frame_lock:
                latest_frame["frame"] = frame_raw
                latest_frame["ts"] = time.time()
            connection_event.set()

        if cap_local is not None and cap_local.isOpened():
            cap_local.release()

    window_name = "Detección Persona - RTSP"
    display_enabled = not HEADLESS

    if display_enabled:
        cv2.namedWindow(window_name)

        def disable_display():
            nonlocal display_enabled, drawing_polygon, temp_polygon, mouse_pos
            if display_enabled:
                cv2.destroyWindow(window_name)
                cv2.setMouseCallback(window_name, lambda *args: None)
                display_enabled = False
                drawing_polygon = False
                temp_polygon = []
                mouse_pos = None

        def mouse_callback(event, x, y, flags, param):
            nonlocal drawing_polygon, temp_polygon, roi_poly, mouse_pos

            if event == cv2.EVENT_LBUTTONDOWN:
                if not drawing_polygon:
                    drawing_polygon = True
                    temp_polygon = [(x, y)]
                    mouse_pos = (x, y)
                    print(f"[INFO] Inicio de polígono en: {(x, y)}")
                else:
                    temp_polygon.append((x, y))
                    mouse_pos = (x, y)
                    print(f"[INFO] Punto agregado: {(x, y)}")

            elif event == cv2.EVENT_MOUSEMOVE:
                if drawing_polygon:
                    mouse_pos = (x, y)
                else:
                    mouse_pos = None

            elif event == cv2.EVENT_RBUTTONDOWN:
                if drawing_polygon:
                    if len(temp_polygon) >= 3:
                        roi_poly = temp_polygon.copy()
                        print(f"[INFO] ROI actualizado (polígono): {roi_poly}")
                        if AUTO_HIDE_WINDOW:
                            disable_display()
                    else:
                        print("[WARN] Define al menos 3 puntos antes de finalizar el polígono.")
                    drawing_polygon = False
                    temp_polygon = []
                    mouse_pos = None
                else:
                    if roi_poly:
                        roi_poly = []
                        print("[INFO] ROI borrado.")
                        if AUTO_HIDE_WINDOW:
                            disable_display()
                    mouse_pos = None

        cv2.setMouseCallback(window_name, mouse_callback)

    print("[INFO] Presiona 's' para seleccionar un área rectangular (ROI). 'c' borra ROI. 'q' para salir.")
    print("[INFO] Haz clic izquierdo para comenzar un polígono; clic derecho lo cierra. Clic derecho sin polígono lo borra.")
    if AUTO_HIDE_WINDOW and display_enabled:
        print("[INFO] La ventana se cerrará automáticamente después de fijar el ROI.")

    capture_thread = threading.Thread(target=capture_loop, args=(initial_cap,), daemon=True)
    capture_thread.start()

    last_frame_ts = 0.0
    roi_hit_frames = 0

    try:
        if not connection_event.wait(timeout=3.0):
            print("[ERROR] No se reciben frames del RTSP.")
            return

        while True:
            frame = None
            frame_ts = 0.0
            with frame_lock:
                if latest_frame["frame"] is not None and latest_frame["ts"] > last_frame_ts:
                    frame = latest_frame["frame"].copy()
                    frame_ts = latest_frame["ts"]
            if frame is None:
                if not connection_event.is_set():
                    connection_event.wait(timeout=0.2)
                time.sleep(0.005)
                continue
            last_frame_ts = frame_ts

            if FRAME_SCALE != 1.0:
                interp = cv2.INTER_AREA if FRAME_SCALE < 1.0 else cv2.INTER_LINEAR
                frame = cv2.resize(frame, None, fx=FRAME_SCALE, fy=FRAME_SCALE, interpolation=interp)

            results = model.predict(frame, imgsz=YOLO_IMGSZ, conf=CONF_THRES, verbose=False)

            if roi_poly:
                draw_transparent_polygon(frame, roi_poly, color=(0, 0, 255), alpha=0.25, border_thick=2)

            person_inside = False

            for r in results:
                if r.boxes is None:
                    continue

                for box in r.boxes:
                    cls_id = int(box.cls[0])
                    cls_name = names.get(cls_id, str(cls_id))
                    if cls_name != "person":
                        continue

                    x1, y1, x2, y2 = box.xyxy[0].tolist()
                    x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
                    width = max(0, x2 - x1)
                    height = max(0, y2 - y1)
                    area = width * height
                    if MIN_PERSON_AREA > 0 and area < MIN_PERSON_AREA:
                        continue

                    cx, cy = int((x1 + x2) / 2), int((y1 + y2) / 2)
                    conf = float(box.conf[0])

                    bbox_poly = rect_to_polygon(x1, y1, width, height)

                    inside = False
                    if roi_poly:
                        inside = point_in_polygon((cx, cy), roi_poly)
                        if not inside:
                            inside = bbox_overlaps_polygon(bbox_poly, roi_poly)

                    person_inside = person_inside or inside

                    color = (0, 0, 255) if inside else (0, 255, 0)
                    cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
                    cv2.circle(frame, (cx, cy), 4, color, -1)
                    label = f"{cls_name} {conf:.2f}" + (" IN-ROI" if inside else "")
                    cv2.putText(frame, label, (x1, max(20, y1 - 10)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

            if person_inside:
                roi_hit_frames = min(roi_hit_frames + 1, ROI_PERSISTENCE_FRAMES)
            else:
                roi_hit_frames = 0

            now = time.time()
            persistent_hit = roi_hit_frames >= ROI_PERSISTENCE_FRAMES
            if persistent_hit and (now - last_alert_t >= COOLDOWN_SECONDS):
                last_alert_t = now
                print("[ALERTA] Persona confirmada dentro del área.")
                play_alert_sound()

            if display_enabled:
                display_frame = frame.copy()
                if drawing_polygon and temp_polygon:
                    cv2.polylines(display_frame, [np.array(temp_polygon, dtype=np.int32)], False, (255, 255, 0), 2)
                    for idx, pt in enumerate(temp_polygon):
                        cv2.circle(display_frame, pt, 4, (255, 255, 0), -1)
                        cv2.putText(display_frame, str(idx + 1), pt, cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 0), 1)
                    if mouse_pos:
                        cv2.line(display_frame, temp_polygon[-1], mouse_pos, (255, 255, 0), 1)

                if roi_poly:
                    status_text = f"ROI definido | {roi_hit_frames}/{ROI_PERSISTENCE_FRAMES} frames"
                else:
                    status_text = "ROI sin definir"
                if persistent_hit and person_inside:
                    status_color = (0, 0, 255)
                elif person_inside:
                    status_color = (0, 255, 255)
                else:
                    status_color = (0, 255, 0)
                cv2.putText(
                    display_frame,
                    status_text,
                    (20, display_frame.shape[0] - 20),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7,
                    status_color,
                    2,
                )

                if persistent_hit and person_inside:
                    cv2.putText(
                        display_frame,
                        "PERSONA CONFIRMADA EN EL AREA",
                        (20, 40),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        1.0,
                        (0, 0, 255),
                        3,
                    )

                cv2.imshow(window_name, display_frame)
                key = cv2.waitKey(1) & 0xFF

                if key == ord("q"):
                    break

                if key == ord("s"):
                    snap = frame.copy()
                    roi = cv2.selectROI(
                        "Selecciona area (Enter para OK, Esc para cancelar)",
                        snap,
                        fromCenter=False,
                        showCrosshair=True,
                    )
                    cv2.destroyWindow("Selecciona area (Enter para OK, Esc para cancelar)")
                    (x, y, w, h) = roi
                    if w > 0 and h > 0:
                        roi_poly = rect_to_polygon(x, y, w, h)
                        print(f"[INFO] ROI actualizado (rect): {roi_poly}")
                        if AUTO_HIDE_WINDOW:
                            disable_display()

                if key == ord("c"):
                    roi_poly = []
                    print("[INFO] ROI borrado. (Presiona 's' para volver a definir)")

    except KeyboardInterrupt:
        print("[INFO] Ejecución interrumpida por el usuario.")
    finally:
        stop_event.set()
        capture_thread.join(timeout=1.5)
        if not HEADLESS:
            cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
