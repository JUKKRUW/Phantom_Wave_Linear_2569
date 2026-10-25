"""Generate the FPGA delay table step by step using only the standard library."""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Hardware settings must match the audio receiver and physical microphone positions.
CLOCK_HZ = 50_000_000
TARGET_RATE = 32_000
HALF_DIV = (CLOCK_HZ + TARGET_RATE * 64) // (2 * TARGET_RATE * 64)
RATE = CLOCK_HZ / (2 * HALF_DIV * 64)
SOUND_SPEED = 343
FRACTION_SCALE = 256
POSITIONS = [(-.05, -.05), (0, -.05), (.05, -.05), (-.05, 0),
             (.05, 0), (-.05, .05), (0, .05), (.05, .05)]

# Always calculate every direction; show decimal intermediate values for one example.
SHOW_STEPS = True
EXAMPLE_ROW = 4
EXAMPLE_COL = 11


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    assert 0 <= EXAMPLE_ROW < 12 and 0 <= EXAMPLE_COL < 16
    entries = []
    rows = []

    if SHOW_STEPS:
        print('Step 0: Set microphone positions and actual sample rate')
        print(f'fs = {CLOCK_HZ} / (2 * {HALF_DIV} * 64) = {RATE:.12f} samples/s')
        for mic, (x, y) in enumerate(POSITIONS):
            print(f'Mic {mic}: x={x:.3f}, y={y:.3f}, z=0.000 m')

    for row in range(12):
        for col in range(16):
            direction_index = row * 16 + col
            show_direction = SHOW_STEPS and row == EXAMPLE_ROW and col == EXAMPLE_COL

            # Step 1: Choose a candidate direction from the array center (Chapter 1).
            # sx and sy are horizontal/vertical ratios to depth, not measured source coordinates.
            sy = (2 * row / 11 - 1) * math.tan(math.radians(22.5))
            sx = (2 * col / 15 - 1) * math.tan(math.radians(30))  
            if show_direction:
                print(f'\nExample direction k={direction_index}: row={row}, col={col}')
                print('Step 1: Calculate horizontal and vertical slopes')
                print(f'sx = (2*{col}/15-1)*tan(30 degrees) = {sx:.12f}')
                print(f'sy = (2*{row}/11-1)*tan(22.5 degrees) = {sy:.12f}')

            # Step 2: Normalize v = [sx, sy, 1] to obtain unit vector u (Chapter 1).
            norm = math.sqrt(1 + sx*sx + sy*sy)
            ux = sx / norm
            uy = sy / norm
            uz = 1 / norm
            if show_direction:
                print('\nStep 2: Calculate the unit direction vector')
                print(f'v = [{sx:.12f}, {sy:.12f}, 1.000000000000]')
                print(f'Length of v = {norm:.12f}')
                print(f'u = [{ux:.12f}, {uy:.12f}, {uz:.12f}]')

            # Step 3: Project all eight microphone positions onto this direction (Chapters 1-2, 4).
            # l = r^T u; every microphone has z=0, leaving x*ux + y*uy.
            projections = []
            for x, y in POSITIONS:
                projection = x * ux + y * uy
                projections.append(projection)
            if show_direction:
                print('\nStep 3: Calculate projected distances using dot products')
                for mic, projection in enumerate(projections):
                    print(f'Mic {mic}: l = {projection:.12f} m')

            # Step 4: Convert projected distance to relative arrival time, tau = -l/c (physics).
            arrival = []
            for projection in projections:
                arrival_time = -projection / SOUND_SPEED
                arrival.append(arrival_time)
            if show_direction:
                print('\nStep 4: Calculate relative arrival times (not source distances)')
                for mic, arrival_time in enumerate(arrival):
                    print(f'Mic {mic}: tau = {arrival_time:.12f} s')

            # Step 5: Use the latest arrival as the reference and convert delays to samples.
            latest_arrival = max(arrival)
            delays = []
            for arrival_time in arrival:
                delay_seconds = latest_arrival - arrival_time
                delay_samples = delay_seconds * RATE
                delays.append(delay_samples)
            if show_direction:
                print('\nStep 5: Calculate delays d = (latest arrival - microphone arrival) * fs')
                print(f'Reference arrival time = {latest_arrival:.12f} s')
                for mic, delay_samples in enumerate(delays):
                    print(f'Mic {mic}: d = {delay_samples:.12f} samples')

            # Step 6: Quantize to 1/256 sample and split into integer D and fractional F.
            q = []
            integer_delays = []
            fractional_delays = []
            for delay_samples in delays:
                scaled_delay = delay_samples * FRACTION_SCALE
                quantized_delay = int(math.floor(scaled_delay + .5))
                integer_delay = quantized_delay // FRACTION_SCALE
                fractional_delay = quantized_delay % FRACTION_SCALE
                q.append(quantized_delay)
                integer_delays.append(integer_delay)
                fractional_delays.append(fractional_delay)
            assert all(0 <= value < 21 * FRACTION_SCALE for value in q)
            if show_direction:
                print('\nStep 6: q=floor(256*d+0.5), D=q//256, F=q%256, beta=F/256')
                print('mic | q | D | F | beta | stored delay (samples)')
                for mic in range(8):
                    beta = fractional_delays[mic] / FRACTION_SCALE
                    stored_delay = q[mic] / FRACTION_SCALE
                    print(f'{mic} | {q[mic]} | {integer_delays[mic]} | '
                          f'{fractional_delays[mic]} | {beta:.9f} | {stored_delay:.9f}')

            # Step 7: Pack fields and append ROM entries; address = direction*8 + microphone.
            # D uses 5 bits per mic and F uses 8; packing does not change the delay values.
            integer = 0
            fraction = 0
            for mic in range(8):
                integer += integer_delays[mic] << (5 * mic)
                fraction += fractional_delays[mic] << (8 * mic)
            entries.extend(q)
            rows.append(dict(index=direction_index, row=row, col=col,
                             slope_x=sx, slope_y=sy, q8=q,
                             integer_flat=f'{integer:010X}', fraction_flat=f'{fraction:016X}'))
            if show_direction:
                print('\nStep 7: Calculate ROM addresses for the example direction')
                for mic in range(8):
                    print(f'Address {direction_index * 8 + mic}: Mic {mic}, q={q[mic]}')

    # Step 8: Write all 192 directions x 8 microphones to VHDL and JSON files.
    words = ',\n'.join(f'        {i} => to_unsigned({v}, 13)' for i, v in enumerate(entries))
    source = f'''-- Generated by generate_delay_table.py; do not hand edit.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
package acoustic_delay_pkg is
    constant AUDIO_HALF_DIV : positive := {HALF_DIV};
    constant AUDIO_ACTUAL_RATE : real := {RATE:.12f};
    type delay_rom_type is array(0 to 1535) of unsigned(12 downto 0);
    constant DELAY_ROM : delay_rom_type := (
{words}
    );
end package;
'''
    (ROOT/'vivado'/'acoustic_delay_pkg.vhd').write_text(source, encoding='utf-8')
    (ROOT/'data'/'delay_table.json').write_text(json.dumps(dict(clock_hz=CLOCK_HZ,
        target_rate=TARGET_RATE, half_div=HALF_DIV, actual_rate=RATE,
        sound_speed=SOUND_SPEED, positions=POSITIONS, directions=rows), indent=2), encoding='utf-8')
    if SHOW_STEPS:
        print(f'\nStep 8: Write {len(rows)} directions x 8 microphones = {len(entries)} entries')
        print('VHDL:', ROOT / 'vivado' / 'acoustic_delay_pkg.vhd')
        print('JSON:', ROOT / 'data' / 'delay_table.json')
    print(f'Generated 192 directions; actual sample rate {RATE:.9f} Hz; half divider {HALF_DIV}')


if __name__ == '__main__':
    main()
