"""Standalone receiver for FPGA microphone scores, without GUI dependencies.

Wire record: index high24 middle24 low16, each printed as six ASCII hex digits.
Indices 0..191 form one map; F0..F7 are per-microphone powers.
"""
import re
import time

HEX6 = re.compile(rb'^[0-9a-fA-F]{6}$')


class ScoreDecoder:
    def __init__(self):
        self.buffer = bytearray()
        self.pending = []
        self.last_map = None
        self.map_sequence = 0
        self.mic_powers = {}
        self.invalid = 0

    def feed(self, data):
        self.buffer.extend(data)
        while b'\n' in self.buffer:
            line, _, tail = self.buffer.partition(b'\n')
            self.buffer = bytearray(tail)
            fields = line.strip().split()
            if len(fields) != 4 or any(not HEX6.fullmatch(word) for word in fields):
                self._reject()
                continue
            index, high, middle, low = (int(word, 16) for word in fields)
            if low > 0xFFFF:
                self._reject()
                continue
            value = (high << 40) | (middle << 16) | low
            if 240 <= index <= 247:
                self.mic_powers[index-240] = (value, time.monotonic())
            elif 0 <= index < 192:
                if index == 0:
                    self.pending = []
                if index != len(self.pending):
                    self._reject()
                    continue
                self.pending.append(value)
                if len(self.pending) == 192:
                    self.last_map = list(self.pending)
                    self.map_sequence += 1
                    self.pending = []
            else:
                self._reject()
        if len(self.buffer) > 4096:
            self.buffer.clear()
            self._reject()

    def _reject(self):
        self.pending = []
        self.invalid += 1
