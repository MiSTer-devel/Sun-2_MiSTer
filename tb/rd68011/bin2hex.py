#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Source location: https://github.com/MelkhiorVintageComputing/RD68011
"""Flat MC68010 image to one big-endian word per line, for $readmemh.

    python3 tools/bin2hex.py build/programs/p01_flow.bin > p01_flow.hex

The memory model in sim/models/rd68011_slave.sv is word-wide and indexed by
the address's upper bits, so its contents are exactly this file: word zero
first, most significant byte first inside each word, which is the order an
MC68010 reads them in.

The image is padded to a whole number of words and rejected if it will not fit
the model, because a program that silently wrapped round would be a very
confusing failure.
"""

import sys

WORDS = 1 << 14          # rd68011_slave's ADDR_BITS in the core harness


def main():
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    with open(sys.argv[1], 'rb') as f:
        data = f.read()
    if len(data) % 2:
        data += b'\x00'
    if len(data) // 2 > WORDS:
        sys.stderr.write('error: %s is %d words, and the model has %d\n'
                         % (sys.argv[1], len(data) // 2, WORDS))
        return 1
    out = []
    for i in range(0, len(data), 2):
        out.append('%04x' % ((data[i] << 8) | data[i + 1]))
    # Padded to the whole model, so that $readmemh fills it and a program runs
    # from defined memory rather than from x.
    out += ['0000'] * (WORDS - len(out))
    sys.stdout.write('\n'.join(out) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
