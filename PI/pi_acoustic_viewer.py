"""Pi/PC: two independent USB-UART inputs, grayscale camera + FPGA sound scores.

Edit SETTINGS below, then run: python pi_acoustic_viewer.py
"""
from types import SimpleNamespace
import argparse
from contextlib import ExitStack
from pathlib import Path
import sys
import threading
import time

import cv2
import numpy as np
import serial

from score_protocol import ScoreDecoder

# SETTINGS: edit hardware/display values here. Only demo uses a command-line flag.
# Replace after checking the camera board's port.
CAMERA_PORT = '/dev/serial/by-path/platform-xhci-hcd.1-usb-0:1:1.1-port0'
# Replace after checking the microphone board's port.
MIC_PORT = '/dev/serial/by-path/platform-xhci-hcd.0-usb-0:1:1.1-port0'
CAMERA_BAUD = 12_000_000
MIC_BAUD = 2000000
FULLSCREEN = False
DISPLAY_WIDTH = 960
CAMERA_ROTATE_CLOCKWISE_90 = True
CAMERA_FLIP_LEFT_RIGHT = True  # Camera only, after the 90-degree rotation.
# Camera only; heatmap orientation is independent.
CAMERA_FLIP_UP_DOWN = True
HEATMAP_OPACITY = 0.40
HEATMAP_COLOR = 'jet'  # 'red' or 'jet' (blue -> green -> red).
HEATMAP_SCORE_FLOOR = 0.0  # Relative to this map's peak; display only.
STALE_SECONDS = 3.0
FLIP_HEATMAP_LEFT_RIGHT = False
FLIP_HEATMAP_UP_DOWN = True
# True: print serial ports and exit, without opening a window.
LIST_PORTS_ONLY = False
SAVE_DEMO_PREVIEW = None   # Example: 'preview.png'; only valid with --demo.


def configured_options(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--demo', action='store_true', default=False,
                        help='Use simulated inputs without opening either UART')
    cli = parser.parse_args(argv)
    return SimpleNamespace(
        demo=cli.demo, camera_port=CAMERA_PORT, mic_port=MIC_PORT,
        camera_baud=CAMERA_BAUD, mic_baud=MIC_BAUD, fullscreen=FULLSCREEN,
        width=DISPLAY_WIDTH, opacity=HEATMAP_OPACITY, stale_seconds=STALE_SECONDS,
        camera_rotate_cw90=CAMERA_ROTATE_CLOCKWISE_90,
        camera_flip_lr=CAMERA_FLIP_LEFT_RIGHT, camera_flip_ud=CAMERA_FLIP_UP_DOWN,
        score_floor=HEATMAP_SCORE_FLOOR,
        color=HEATMAP_COLOR,
        flip_lr=FLIP_HEATMAP_LEFT_RIGHT, flip_ud=FLIP_HEATMAP_UP_DOWN,
        list=LIST_PORTS_ONLY,
        save_preview=Path(SAVE_DEMO_PREVIEW) if SAVE_DEMO_PREVIEW else None,
    )


def fail(message):
    raise SystemExit(message)


W, H, LINE_LEN = 320, 240, 323


class CameraDecoder:
    """Publish only 240 consecutive complete lines; never fill gaps with old pixels."""

    def __init__(self):
        self.buffer = bytearray()
        self.work = np.zeros((H, W), np.uint8)
        self.next_line = 0
        self.bad = 0
        self.overflow = False
        self.frame_status = 0xA5
        self.sequence = 0
        self.last_frame = None
        self.last_status = 0xA5

    def feed(self, data):
        self.buffer.extend(data)
        cursor = 0
        while True:
            start = self.buffer.find(b'\xff', cursor)
            if start < 0:
                cursor = len(self.buffer)
                break
            if len(self.buffer)-start < LINE_LEN:
                cursor = start
                break
            row, status = self.buffer[start+1:start+3]
            pixels = self.buffer[start+3:start+LINE_LEN]
            if row >= H or status not in (0xA4, 0xA5, 0xA6) or 255 in pixels:
                self.bad += 1
                self.next_line = 0
                cursor = start+1
                continue
            cursor = start+LINE_LEN
            if row == 0:
                self.next_line = 0
                self.overflow = False
                self.frame_status = 0xA5
            if row != self.next_line:
                self.bad += 1
                self.next_line = 0
                continue
            self.overflow |= status == 0xA6
            if status != 0xA5:
                self.frame_status = status
            self.work[row] = np.frombuffer(pixels, np.uint8)
            self.next_line += 1
            if self.next_line == H:
                if not self.overflow:
                    self.last_frame = self.work.copy()
                    self.last_status = self.frame_status
                    self.sequence += 1
                else:
                    self.bad += 1
                self.next_line = 0
        del self.buffer[:cursor]


def orient_camera(gray, options):
    """Orient the camera before overlay; never transform the heatmap here."""
    if options.camera_rotate_cw90:
        gray = cv2.rotate(gray, cv2.ROTATE_90_CLOCKWISE)
    if options.camera_flip_lr and options.camera_flip_ud:
        gray = cv2.flip(gray, -1)
    elif options.camera_flip_lr:
        gray = cv2.flip(gray, 1)
    elif options.camera_flip_ud:
        gray = cv2.flip(gray, 0)
    return gray


def overlay_red(gray, scores, opacity=0.25, flip_lr=False, flip_ud=False, score_floor=0.0, color='red'):
    """Display only: no delay estimation or beamforming on Pi. BGR output."""
    background = np.repeat(np.asarray(gray, np.uint8)[..., None], 3, axis=2)
    if scores is None:
        return background
    if len(scores) != 192 or not 0 <= opacity <= 1 or not 0 <= score_floor < 1:
        raise ValueError(
            'Expected 192 scores, opacity in [0, 1], score_floor in [0, 1)')
    peak = max(scores)
    if peak <= 0 or opacity == 0:
        return background
    # Keep raw scores as Python integers; floats are used only for display.
    strength = np.array([value/peak for value in scores],
                        np.float32).reshape(12, 16)
    strength = np.clip((strength-score_floor)/(1-score_floor), 0, 1)
    if flip_lr:
        strength = np.fliplr(strength)
    if flip_ud:
        strength = np.flipud(strength)
    strength = cv2.resize(
        strength, (gray.shape[1], gray.shape[0]), interpolation=cv2.INTER_LINEAR)
    strength[strength < 1/32] = 0
    alpha = (strength * opacity)[..., None]
    if color == 'jet':
        tint = cv2.applyColorMap(
            np.rint(strength*255).astype(np.uint8), cv2.COLORMAP_JET).astype(np.float32)
    elif color == 'red':
        tint = np.array([0, 0, 255], np.float32)
    else:
        raise ValueError("color must be 'red' or 'jet'")
    return np.rint(background*(1-alpha)+tint*alpha).clip(0, 255).astype(np.uint8)


def demo_data(t):
    y, x = np.indices((H, W))
    gray = ((x+y)//3 % 255).astype(np.uint8)
    # Explicit simulation, microphone-map update about 2 Hz like current UART.
    tick = int(t*2)
    cx, cy = 3+(tick % 10), 6
    scores = [max(0, 255-48*(abs(i % 16-cx)+abs(i//16-cy)))
              << 32 for i in range(192)]
    return gray, scores


class Inputs:
    def __init__(self):
        self.lock = threading.Lock()
        self.frame = self.scores = None
        self.camera_time = self.score_time = 0.0
        self.frames = self.maps = 0
        self.camera_status = 0xA5
        self.error = None


def read_input(device, kind, shared, stop):
    decoder = CameraDecoder() if kind == 'camera' else ScoreDecoder()
    previous = 0
    try:
        while not stop.is_set():
            decoder.feed(device.read(max(1, min(device.in_waiting, 65536))))
            sequence = decoder.sequence if kind == 'camera' else decoder.map_sequence
            if sequence != previous:
                with shared.lock:
                    if kind == 'camera':
                        shared.frame = decoder.last_frame
                        shared.camera_time = time.monotonic()
                        shared.frames = sequence
                        shared.camera_status = decoder.last_status
                    else:
                        shared.scores = decoder.last_map
                        shared.score_time = time.monotonic()
                        shared.maps = sequence
                previous = sequence
    except (OSError, serial.SerialException) as error:
        with shared.lock:
            shared.error = f'{kind}: {error}'
        stop.set()


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    args = configured_options()
    if args.demo:
        print("SIMULATED INPUTS: --demo; no camera or microphone UART is opened.")
    if args.list:
        from serial.tools.list_ports import comports
        ports = list(comports())
        if not ports:
            print('No serial ports found. A USB mouse is HID, not a USB-UART device.')
        for port in ports:
            print(port.device, port.description, port.serial_number)
        return
    if not 0 <= args.opacity <= 1 or args.stale_seconds <= 0 or args.width <= 0:
        fail('Invalid opacity, stale-seconds or width')
    if args.save_preview and not args.demo:
        fail('SAVE_DEMO_PREVIEW requires --demo')
    if args.save_preview:
        gray, scores = demo_data(0)
        gray = orient_camera(gray, args)
        image = overlay_red(gray, scores, args.opacity, args.flip_lr,
                            args.flip_ud, args.score_floor, args.color)
        cv2.putText(image, 'SIMULATED INPUTS', (8, 20),
                    cv2.FONT_HERSHEY_SIMPLEX, .5, (0, 255, 0), 1)
        args.save_preview.parent.mkdir(parents=True, exist_ok=True)
        if not cv2.imwrite(str(args.save_preview), image):
            fail('Could not save preview')
        return
    if not args.demo:
        if not args.camera_port or not args.mic_port:
            fail(
                'Set CAMERA_PORT and MIC_PORT in SETTINGS; use LIST_PORTS_ONLY to inspect ports')
        if args.camera_port.casefold() == args.mic_port.casefold():
            fail('Camera and microphone board require separate serial ports')
    shared, stop = Inputs(), threading.Event()
    workers = []
    start = tick_time = time.monotonic()
    old_count, fps, visible, rotate = 0, 0.0, True, False
    fullscreen = args.fullscreen
    window = 'Acoustic Camera - Pi overlay'
    try:
        with ExitStack() as stack:
            if not args.demo:
                devices = []
                for port, baud, kind in ((args.camera_port, args.camera_baud, 'camera'),
                                         (args.mic_port, args.mic_baud, 'microphone')):
                    device = stack.enter_context(
                        serial.Serial(port, baud, timeout=.05))
                    try:
                        device.set_buffer_size(rx_size=1 << 20)
                    except (AttributeError, OSError, serial.SerialException):
                        pass  # Not supported by every OS/driver.
                    device.reset_input_buffer()
                    devices.append((device, kind))
                    print(f'{kind}: {port} @ {baud}')
                # Start only after both ports opened successfully, so an open
                # failure cannot leave a reader using an already closed port.
                for device, kind in devices:
                    worker = threading.Thread(target=read_input, args=(
                        device, kind, shared, stop), daemon=True)
                    worker.start()
                    workers.append(worker)
            try:
                cv2.namedWindow(window, cv2.WINDOW_NORMAL)
                cv2.setWindowProperty(window, cv2.WND_PROP_FULLSCREEN,
                                      cv2.WINDOW_FULLSCREEN if fullscreen else cv2.WINDOW_NORMAL)
                while not stop.is_set():
                    now = time.monotonic()
                    if args.demo:
                        gray, scores = demo_data(now-start)
                        camera_time = score_time = now
                        count, maps, status = int(
                            (now-start)*15), int((now-start)*2), 0xA5
                    else:
                        with shared.lock:
                            gray, scores = shared.frame, shared.scores
                            camera_time, score_time = shared.camera_time, shared.score_time
                            count, maps, status = shared.frames, shared.maps, shared.camera_status
                    if now-tick_time >= 1:
                        fps = (count-old_count)/(now-tick_time)
                        old_count, tick_time = count, now
                    fresh = scores is not None and now-score_time <= args.stale_seconds
                    camera_fresh = gray is not None and now-camera_time <= args.stale_seconds
                    camera_image = gray if gray is not None else np.zeros(
                        (H, W), np.uint8)
                    camera_image = orient_camera(camera_image, args)
                    scene = overlay_red(camera_image,
                                        scores if fresh and camera_fresh and visible else None,
                                        args.opacity, args.flip_lr, args.flip_ud, args.score_floor, args.color)
                    if rotate:
                        scene = cv2.rotate(scene, cv2.ROTATE_180)
                    view = cv2.resize(
                        scene, (args.width, args.width*scene.shape[0]//scene.shape[1]))
                    age = f'{now-score_time:.1f}s' if scores is not None else 'N/A'
                    label = f'{fps:.1f}fps maps={maps} age={age}'
                    if scores is not None and max(scores) > 0:
                        spread = (max(scores)-min(scores))/max(scores)*100
                        label += f' spread={spread:.1f}%'
                    if not fresh:
                        label += ' NO FRESH SCORES'
                    if not camera_fresh:
                        label += ' NO FRESH CAMERA'
                    if status == 0xA4:
                        label += ' CAMERA NACK'
                    if args.demo:
                        label = 'SIMULATED INPUTS '+label
                    cv2.putText(view, label, (8, 25),
                                cv2.FONT_HERSHEY_SIMPLEX, .55, (0, 255, 0), 1)
                    cv2.imshow(window, view)
                    key = cv2.waitKey(1) & 255
                    if key in (27, ord('q')):
                        break
                    if key == ord('h'):
                        visible = not visible
                    if key == ord('r'):
                        rotate = not rotate
                    if key == ord('f'):
                        fullscreen = not fullscreen
                        cv2.setWindowProperty(window, cv2.WND_PROP_FULLSCREEN,
                                              cv2.WINDOW_FULLSCREEN if fullscreen else cv2.WINDOW_NORMAL)
                    if key == ord('s'):
                        name = f'acoustic_{time.time_ns()}.png'
                        cv2.imwrite(name, scene)
                        print(name)
                    if cv2.getWindowProperty(window, cv2.WND_PROP_VISIBLE) < 1:
                        break
                    stop.wait(1/30)
            finally:
                stop.set()
                for worker in workers:
                    worker.join(timeout=.5)
    except (OSError, serial.SerialException) as error:
        fail(
            f'Cannot open/read serial: {error}\nClose other serial monitors and verify the ports.\n')
    finally:
        cv2.destroyAllWindows()
    if shared.error:
        fail(shared.error+'\n')


if __name__ == '__main__':
    main()
