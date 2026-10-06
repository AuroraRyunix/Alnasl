"""Sit between DGT LiveChess and a real serial port, forward every byte both
ways, and log it with timestamps - a capture of the DGT bus with one adapter.

    LiveChess -> COM10 (com0com) <=> COM11 -> serial_proxy.py -> COM3 -> boards

    py -3 tools/serial_proxy.py --app COM11 --board COM3 --out capture.log

Needs `pip install pyserial`. The log has one line per chunk read:

    12.345678  APP>BRD  42
    12.351002  BRD>APP  86 00 43 00 00 ...

APP>BRD is what LiveChess sent to the boards, BRD>APP what came back. Bytes
are hex. A line `# ...` is a note you typed into the console while it runs
(press Enter on an empty line to stop): use it to mark what you just did on
the boards - "e2e4 on board 1", "lifted the knight on g1", "knocked over".
"""

import argparse
import sys
import threading
import time

import serial


def pump(src, dst, tag, log, lock, t0, stop):
    while not stop.is_set():
        try:
            data = src.read(src.in_waiting or 1)
        except serial.SerialException as e:
            with lock:
                log.write(f"# {tag} read error: {e}\n")
            stop.set()
            return
        if not data:
            continue
        dst.write(data)
        with lock:
            log.write(f"{time.perf_counter() - t0:12.6f}  {tag}  {data.hex(' ')}\n")
            log.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--app", required=True, help="the com0com end LiveChess does NOT use, e.g. COM11")
    ap.add_argument("--board", required=True, help="the real port of the DGT loop, e.g. COM3")
    ap.add_argument("--baud", type=int, default=9600, help="DGT boards: 9600")
    ap.add_argument("--out", default="capture.log")
    args = ap.parse_args()

    settings = dict(baudrate=args.baud, bytesize=8, parity="N", stopbits=1, timeout=0.05)
    app = serial.Serial(args.app, **settings)
    board = serial.Serial(args.board, **settings)
    stop = threading.Event()
    lock = threading.Lock()
    t0 = time.perf_counter()

    with open(args.out, "a", encoding="utf-8") as log:
        log.write(f"# capture started {time.strftime('%Y-%m-%d %H:%M:%S')} "
                  f"app={args.app} board={args.board} baud={args.baud}\n")
        threads = [
            threading.Thread(target=pump, args=(app, board, "APP>BRD", log, lock, t0, stop), daemon=True),
            threading.Thread(target=pump, args=(board, app, "BRD>APP", log, lock, t0, stop), daemon=True),
        ]
        for t in threads:
            t.start()

        print(f"Forwarding {args.app} <-> {args.board}, logging to {args.out}.")
        print("Type a note and press Enter to mark the log; an empty line stops.")
        try:
            for line in sys.stdin:
                note = line.strip()
                if not note:
                    break
                with lock:
                    log.write(f"# {time.perf_counter() - t0:12.6f}  NOTE  {note}\n")
                    log.flush()
                print("  marked.")
        except KeyboardInterrupt:
            pass
        stop.set()
        for t in threads:
            t.join(timeout=1)
        log.write("# capture stopped\n")
    print("Stopped.")


if __name__ == "__main__":
    main()
