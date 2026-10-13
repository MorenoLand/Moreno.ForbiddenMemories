"""The credits monsters' part animation, as the monster slots of the credits run it (the reference for scripts/menu/credits_monsters.gd).

A monster record of MODEL.MRG (see extract.py parse_monster) carries its animation as a libhmd-style sequence table: the
animation primitive of the first unit's block lists one GsSEQ per part (the sequence's rewrite word names the coordinate unit it
drives), the command list (the section after the handler table) holds the row starts and the interpolation commands, and the
parameter table holds the keyframes (nine halfwords each: translation, Euler angles, scale; a keyframe is named by a word offset).

The slot runs three things every VBlank (the order of the credits' model update): the controller (the active slot's state
machine: a new row every 30 ticks, the row's own clock), the draw (every part's sequence advances one step and the interpolation
writes its unit's matrix), and the row clock (the row ends, the base row is restored). Everything here is integer arithmetic as
the original does it (C division truncates toward zero, halfwords wrap); the game's rand() is replaced by the caller.

The table work (reset, row building, relinking the command jumps) is done once when the record is loaded, so the baker stores the
loaded tables and the playback in the game only runs the sequencer.
"""
import math
import struct

MODEL_RECORD_WORDS = 0x114 * 0x800 // 4
BASE_ROW = 1          # the row the parts play while the slot is idle (the slot setup's BF5 / BF4 / BF6 = 1)
SPEED = 16            # a part's rframe step per draw (the rearm of the sequences)
ROW_CLOCK = 16        # the row clock per frame (the slot setup's value times the frame step of 1)
E16_MODE = 0x3E       # the monster slots' mode (the row clock counts forward and holds at the end)


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def cdiv(a, b):
    """C integer division: truncates toward zero."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def rsin(a):
    return round(math.sin((a & 0xFFF) * 2 * math.pi / 4096) * 4096)


def rcos(a):
    return round(math.cos((a & 0xFFF) * 2 * math.pi / 4096) * 4096)


def rot_matrix_yxz(rx, ry, rz):
    """RotMatrixYXZ (the GTE library's Y, X, Z order): a 3x3 Q12 matrix (rows)."""
    sx, cx = rsin(rx), rcos(rx)
    sy, cy = rsin(ry), rcos(ry)
    sz, cz = rsin(rz), rcos(rz)
    sysx = (sy * sx) >> 12
    cysx = (cy * sx) >> 12
    m = [[0] * 3 for _ in range(3)]
    m[0][0] = s16(((cy * cz) >> 12) + ((sz * sysx) >> 12))
    m[0][1] = s16(((cz * sysx) >> 12) - ((cy * sz) >> 12))
    m[0][2] = s16((cx * sy) >> 12)
    m[1][0] = s16((sz * cx) >> 12)
    m[1][1] = s16((cz * cx) >> 12)
    m[1][2] = s16(-sx)
    m[2][0] = s16(((sz * cysx) >> 12) - ((sy * cz) >> 12))
    m[2][1] = s16(((cz * cysx) >> 12) + ((sy * sz) >> 12))
    m[2][2] = s16((cx * cy) >> 12)
    return m


def scale_matrix(m, v):
    """ScaleMatrix: column j of the matrix is multiplied by v[j] (Q12)."""
    return [[s16((m[i][j] * v[j]) >> 12) for j in range(3)] for i in range(3)]


class Coord:
    """One GsCOORDUNIT: local matrix (rows), translation, Euler angles and the parent's index (-1 for the root)."""

    def __init__(self, m, t, rot, parent):
        self.m = [list(r) for r in m]
        self.t = list(t)
        self.rot = list(rot)
        self.parent = parent


class Seq:
    """A part's GsSEQ (seven words): rewrite, size|num, ii|aframe, sid|speed|srcii, rframe|tframe, ci|ti, start|start_sid|traveling."""

    def __init__(self, W, at):
        self.rewrite = W[at]
        self.size = W[at + 1] & 0xFFFF
        self.num = W[at + 1] >> 16
        self.ii = W[at + 2] & 0xFFFF
        self.aframe = W[at + 2] >> 16
        self.sid = W[at + 3] & 0xFF
        self.speed = s16(((W[at + 3] >> 8) & 0xFF) << 8) >> 8
        self.srcii = W[at + 3] >> 16
        self.rframe = s16(W[at + 4] & 0xFFFF)
        self.tframe = W[at + 4] >> 16
        self.ci = W[at + 5] & 0xFFFF
        self.ti = W[at + 5] >> 16
        self.start = W[at + 6] & 0xFFFF
        self.start_sid = (W[at + 6] >> 16) & 0xFF
        self.traveling = W[at + 6] >> 24


class MonsterAnim:
    """The loaded tables and the slot state of one monster (the record is read from `record_bytes`, its words as a list)."""

    E16 = E16_MODE

    def __init__(self, record_bytes: bytes):
        n = len(record_bytes) // 4
        W = list(struct.unpack_from("<%dI" % n, record_bytes, 0))
        self.W = W
        groups = {}
        at = W[2]
        p = at + 1
        for _ in range(W[at]):
            k = W[p]
            groups[p] = [W[p + 1 + i] & 0x7FFFFFFF for i in range(k)]
            p += 1 + k
        self.anim = None
        coord_sec = None
        for u in range(W[3]):
            b = W[4 + u]
            while b:
                secs = groups[W[b + 1]]
                c = b + 3
                for _ in range(W[b + 2] & 0xFFFF):
                    t, sz = W[c], W[c + 1]
                    if t & 0x800000:
                        coord_sec = secs[-1]
                    if (t & 0xFFFF0000) == 0x03800000 and self.anim is None:
                        self.anim = (u, c + 1, secs)
                    c += 1 + (sz & 0xFFFF)
                if W[b] == 0xFFFFFFFF:
                    break
                b = W[b]
        if self.anim is None or coord_sec is None:
            raise ValueError("the record has no animation or no coordinate array")
        self.coords = []
        for i in range(W[coord_sec]):
            o = coord_sec + 1 + i * 20
            m = struct.unpack_from("<9h", record_bytes, o * 4 + 4)
            t = struct.unpack_from("<3i", record_bytes, o * 4 + 24)
            rot = struct.unpack_from("<3h", record_bytes, o * 4 + 68)
            sup = W[o + 19]
            parent = (sup - coord_sec - 1) // 20 if sup else -1
            self.coords.append(Coord([m[0:3], m[3:6], m[6:9]], t, rot, parent))
        self.coord_count = len(self.coords)
        self.anim_unit, dat, secs = self.anim
        self.htop, self.ctop, self.ptop = secs[1], secs[2], secs[3]
        self.E1B = (W[dat] >> 16) & 0x7FFF
        self.seqs = []
        s = dat + 1
        for _ in range(self.E1B):
            sq = Seq(W, s)
            self.seqs.append(sq)
            s += sq.size
        self.k2c8 = [[0xFFFF] * 58 for _ in range(10)]
        self.t750 = [[0] * 58 for _ in range(10)]
        self.t750_max = [0] * 10
        self.BEC = [0] * 8
        self._load_tables()

    # ---- command words (command k is word ctop + k) and the keyframe halfwords (ptop + word offset)
    def cmd(self, k):
        return s32(self.W[self.ctop + k])

    def cmd_low(self, k):
        return self.W[self.ctop + k] & 0xFFFF

    def set_low(self, k, v):
        self.W[self.ctop + k] = (self.W[self.ctop + k] & 0xFFFF0000) | (v & 0xFFFF)

    def hw(self, h):
        return (self.W[self.ptop + (h >> 1)] >> (16 * (h & 1))) & 0xFFFF

    def hw_set(self, h, v):
        i = self.ptop + (h >> 1)
        sh = 16 * (h & 1)
        self.W[i] = (self.W[i] & ~(0xFFFF << sh) & 0xFFFFFFFF) | ((v & 0xFFFF) << sh)

    def sample(self, w):
        return [s16(self.hw(2 * w + j)) for j in range(9)]

    def sample_set(self, w, vals):
        for j in range(9):
            self.hw_set(2 * w + j, vals[j])

    # ---- loading: the row tables, the relink of the command jumps, the handler flags and the rearm of the sequences
    def _load_tables(self):
        for i in range(self.E1B):
            row = 1
            self.seqs[i].start_sid = row
            key = self.seqs[i].start
            self.k2c8[1][i] = key
            cmd = key
            while True:
                word = self.cmd(cmd)
                if word < 0:
                    row = ((word & 0xFFFFFFFF) >> 16) & 0x7F
                    if row == 0:
                        break
                    if self.k2c8[row][i] != 0xFFFF:
                        cmd += 1
                    else:
                        self.k2c8[row][i] = self.cmd_low(cmd)
                        cmd = self.cmd_low(cmd)
                else:
                    self.t750[row][i] += (word >> 16) & 0xFF
                    cmd += 1
        for row in range(1, 10):
            self.t750_max[row] = max(self.t750[row][i] for i in range(self.E1B))
        self._relink()
        self.BEC = [0] * 8
        k = self.htop
        for i in range(self.W[k] & 0xFFFF):
            if self.W[k + 1 + i] & 0x100:
                self.BEC[i // 8] |= 1 << (i % 8)
        for sq in self.seqs:
            sq.ii = 0xFFFF
            sq.ti = sq.start
            sq.aframe = 0xFFFF
            sq.sid = sq.start_sid
            sq.rframe = 0
            sq.speed = SPEED

    def _relink(self):
        n = len(self.W) - self.ctop
        for i in range(self.E1B):
            g = self.k2c8[1][i]
            for j in range(1, 10):
                w = self.k2c8[j][i]
                if w == 0xFFFF:
                    continue
                a = w
                t = a - 1
                while True:
                    x = self.cmd(a)
                    if x < 0:
                        hi = ((x & 0xFFFFFFFF) >> 16) & 0x7F
                        y = self.k2c8[hi][i]
                        c = y
                        if hi == 0:
                            self.set_low(t, a - 1)
                            self.set_low(a, t + 1)
                            break
                        self.W[self.ctop + a] = ((x & 0xFFFFFFFF) & 0xC07FFFFF) | (hi << 23)
                        if y != 0xFFFF and hi >= 2:
                            hit = False
                            while c < n:
                                v = self.cmd(c)
                                if v < 0:
                                    if (((v & 0xFFFFFFFF) >> 16) & 0x7F) == hi:
                                        self.W[self.ctop + c] = ((v & 0xFFFFFFFF) & 0xFF80FFFF) | 0x10000
                                    if ((((self.cmd(c) & 0xFFFFFFFF) >> 16) & 0x7F)) == 1:
                                        hit = True
                                        break
                                c += 1
                            if hit:
                                self.set_low(c, g)
                                self.set_low(a, c)
                    a += 1
                    if a >= n:
                        break

    # ---- the part's sequence position in row `n` at `pos` (the seek of the loader and of the row changes)
    def seek(self, i, n, pos):
        sq = self.seqs[i]
        k = self.k2c8[n][i]
        if k == 0xFFFF or self.t750[n][i] == 0:
            return
        step = self.t750[n][i] * 16
        rem = pos % step
        cp = k - 1
        if rem == 0 and pos != 0 and self.E16 != 0x3C:
            rem = step
        length = self.cmd_low(cp)
        idx = 0
        if idx >= length:
            return
        q = k
        while idx < length:
            dur = ((self.W[self.ctop + q] >> 16) & 0xFF) << 4
            d = rem - dur
            if self.E16 != 0x3C:
                if d <= 0:
                    break
            elif d < 0:
                break
            rem = rem - dur
            if s32(self.W[self.ctop + q + 1]) < 0:
                break
            q += 1
            idx += 1
        if idx >= length:
            return
        v = q
        while True:
            if s32(self.W[self.ctop + v + 1]) >= 0:
                idx += 1
                v += 1
                if idx < length:
                    continue
            break
        sq.ti = q
        sq.ci = q - 1 if q != 0 else v
        y = ((self.W[self.ctop + q] >> 16) & 0xFF) << 4
        z = y - rem
        sq.tframe = y
        sq.rframe = s16(z)
        if self.E16 == 0x3C and s16(z) >= sq.tframe:
            sq.rframe = 0x6000

    def init_slot(self):
        """The slot's state after the loader (the base row, the parts seeked to it, the controller idle)."""
        self.E0F = 0
        self.BF5 = BASE_ROW
        self.BF4 = BASE_ROW
        self.BF6 = BASE_ROW
        self.E06 = 0
        self.E10 = 0
        self.E15 = 0
        self.saved = []
        for i in range(self.E1B):
            self.seek(i, self.BF5, 0)

    # ---- row change: every part to row `flag` (0 keeps the row) at `val` sixteenths
    def set_row(self, flag, val=0):
        self.E06 = (val << 4) & 0xFFFF
        for i in range(self.E1B):
            arg2 = self.BF5
            if flag != 0:
                self.seqs[i].sid = flag
                arg2 = flag
            self.seek(i, arg2, self.E06)
        if flag != 0:
            self.BF5 = flag

    # ---- the row control: -1 clears the output pointers, 0 restores the saved words, a row selects it
    def control(self, anim, flag):
        if anim == -1:
            self.E10 = 0
            for sq in self.seqs:
                sq.ii = 0xFFFF
            return
        if anim == 0:
            if self.E0F == 0:
                return
            pos = 0
            for i in range(self.E1B):
                row_key = self.k2c8[self.E0F][i]
                if row_key != 0xFFFF:
                    words = 5 if (self.BEC[i // 8] >> (i % 8)) & 1 else 3
                    src = self.cmd_low(row_key)
                    for j in range(words):
                        self.W[self.ptop + src + j] = self.saved[pos]
                        pos += 1
            self.E0F = 0
            return
        prev = self.E0F
        if self.t750_max[anim] == 0:
            return
        if prev != 0:
            if flag == 0:
                return
            self.BF6 = self.BF4
            self.control(0, 0)
        self.E0F = anim
        if prev == anim:
            self.set_row(0, 0)
            return
        self.E10 = 1
        self.saved = []
        for i in range(self.E1B):
            copy_row = self.k2c8[self.E0F][i]
            if copy_row != 0xFFFF:
                words = 5 if (self.BEC[i // 8] >> (i % 8)) & 1 else 3
                src = self.cmd_low(copy_row)
                self.seqs[i].ii = copy_row
                for j in range(words):
                    self.saved.append(self.W[self.ptop + src + j])

    # ---- the sequencer: every part advances one step (the draw of the slot)
    def sequence_step(self):
        for track in self.seqs:
            if (track.aframe & 0xFFFF) == 0:
                continue
            if (track.aframe & 0xFFFF) != 0xFFFF:
                track.aframe = (track.aframe - 1) & 0xFFFF
            direction = -1 if track.speed < 0 else 1
            if track.rframe == 0x7000:
                direction = 1
                track.rframe = 0
            elif track.rframe == 0x6000:
                direction = -1
                track.rframe = 0
            while True:
                if track.rframe == 0 or track.tframe == 0:
                    track.traveling = 0
                    stopped = False
                    found = 0
                    if direction == 1:
                        if self.cmd(track.ti) & 0x80000000:
                            found = self.scan_command(track, track.ti + 1)
                            track.ti = found & 0xFFFF
                            if (found & 0xFFFF) == 0xFFFF:
                                stopped = True
                        if not stopped:
                            track.ci = track.ti
                            found = self.scan_command(track, track.ci + direction)
                            track.ti = found & 0xFFFF
                    else:
                        if self.cmd(track.ci) & 0x80000000:
                            found = self.scan_command(track, track.ci + direction)
                            track.ci = found & 0xFFFF
                            if (found & 0xFFFF) == 0xFFFF:
                                stopped = True
                        if not stopped:
                            track.ti = track.ci
                            found = self.scan_command(track, track.ti + direction)
                            track.ci = found & 0xFFFF
                    if not stopped and (found & 0xFFFF) == 0xFFFF:
                        stopped = True
                    if stopped:
                        track.aframe = 0
                        break
                    if direction == 1:
                        track.tframe = ((self.W[self.ctop + track.ti] >> 16) & 0xFF) << 4
                        track.rframe = s16(track.tframe - (track.rframe & 0xFFFF))
                    else:
                        track.tframe = ((self.W[self.ctop + track.ti] >> 16) & 0xFF) << 4
                value = (self.W[self.ctop + track.ti] >> 24) & 0x7F
                src = self.cmd_low(track.ci)
                tgt = self.cmd_low(track.ti)
                out = self.cmd_low(track.ii) if track.ii != 0xFFFF else None
                if track.ci != track.ti:
                    if self.handler_type(value) != 0x03002119:
                        raise NotImplementedError("animation handler type %x" % self.handler_type(value))
                    result = self.interpolate(track, src, tgt, out)
                    if result == 1:
                        track.rframe = 0
                        continue
                    if ((self.W[self.ctop + track.ti] >> 16) & 0xFF) == 0:
                        continue
                    track.rframe = s16((track.rframe & 0xFFFF) - track.speed)
                    if direction == 1 and track.rframe < 0:
                        track.rframe = 0x7000
                    elif direction == -1 and track.rframe >= track.tframe:
                        track.rframe = 0x6000
                break

    def handler_type(self, value):
        """htop[value + 1]: the handler word of the command's type (the interpolation is 0x03002119)."""
        if value + 1 > (self.W[self.htop] & 0xFFFF):
            raise RuntimeError("handler index out of range")
        return self.W[self.htop + 1 + value]

    def scan_command(self, track, index):
        step = -1 if track.speed < 0 else 1
        while True:
            word = self.W[self.ctop + (index & 0xFFFF)]
            if word & 0x80000000:
                if (word & 0xC0000000) == 0x80000000:
                    cond = (word & 0x7F0000) >> 16
                    if cond == 0 or track.sid == cond:
                        action = (word & 0x3F800000) >> 23
                        if cond != 0 or action != 0:
                            track.sid = action
                        index = word
                        continue
                elif (word & 0xC0000000) == 0xC0000000:
                    cond = (word & 0x7F0000) >> 16
                    action = (word & 0x3F800000) >> 23
                    if action == 1 and (cond == 0 or track.sid == cond):
                        return 0xFFFF
                else:
                    raise RuntimeError("bad command word")
                index += step
                continue
            return index

    # ---- the interpolation (0x03002119): one unit's translation, rotation and scale between two keyframes
    def interpolate(self, track, src, tgt, out):
        if track.tframe == 0:
            return 1
        t = track.rframe
        dur = track.tframe
        rest = dur - t
        s1 = self.sample(src)
        s2 = self.sample(tgt)
        k = ((track.rewrite & 0xFFFFFF) - 1) // 20
        node = self.coords[k]
        node.t = [cdiv(s1[j] * t + s2[j] * rest, dur) for j in range(3)]
        rx, ry, rz = s2[3], s2[4], s2[5]
        a, b, c = s1[3], s1[4], s1[5]
        if dur == 16:
            rx = self._wrap(a, rx)
            ry = self._wrap(b, ry)
            rz = self._wrap(c, rz)
        rot = [s16(cdiv(a * t + rx * rest, dur)), s16(cdiv(b * t + ry * rest, dur)), s16(cdiv(c * t + rz * rest, dur))]
        node.rot = rot
        scale = [s16(cdiv(s1[6 + j] * t + s2[6 + j] * rest, dur)) for j in range(3)]
        node.m = scale_matrix(rot_matrix_yxz(rot[0], rot[1], rot[2]), scale)
        if out is not None:
            self.sample_set(out, [s16(v) for v in node.t] + rot + scale)
        return 0

    @staticmethod
    def _wrap(src, tgt):
        d = s16(src) - s16(tgt)
        if d < 0:
            if s16(tgt) - s16(src) < 2049:
                return s16(tgt)
        elif d < 2049:
            return s16(tgt)
        w = s16(tgt)
        return w - 4096 if w > 0 else w + 4096

    # ---- one draw of the slot: the sequencer, then the controller's output and row handling
    def draw(self):
        self.sequence_step()
        if self.E10 != 0:
            self.control(-1, 0)
        elif self.E0F != 0:
            if self.E0F != self.BF5:
                self.set_row(self.E0F, 0)
            else:
                self.BF6 = 0

    # ---- the row clock, once per VBlank after the draw (it counts the row's length and returns to the base row)
    def row_clock(self):
        length = self.t750_max[self.BF5] << 4
        if self.E06 >= length:
            self.E06 = 0
        v = self.E06 + ROW_CLOCK
        self.E06 = length if v >= length else v
        if self.E10 == 0 and self.E06 >= length and self.BF4 != self.BF6:
            self.set_row(self.BF4, 0)
            self.BF6 = self.BF4
            if self.E0F != 0:
                self.control(0, 0)

    # ---- the active slot's controller tick (the credits' state 0 while no row is playing): returns the row chosen or None
    KIND_BY_STEP = {0: 1, 1: 2, 2: 1, 3: 7, 4: 1}

    def tick(self):
        chosen = None
        if self.E0F == 0:
            frame = self.E15 & 0xFF
            if frame % 30 == 0:
                kind = self.KIND_BY_STEP.get((frame // 30) & 0xFF)
                if kind is not None:
                    chosen = kind
                    self.control(kind, 1)
            self.E15 = (self.E15 + 1) & 0xFF
        return chosen

    def frame(self):
        """One VBlank of the active slot: controller, draw, row clock."""
        kind = self.tick()
        self.draw()
        self.row_clock()
        return kind

    # ---- the root's world-space helper data: the coordinate units' parents and the chain order
    def world_matrices(self):
        """Local-to-world (matrix, translation) of every coordinate unit, composed up the parent chain."""
        W = [None] * len(self.coords)

        def get(k):
            if W[k] is not None:
                return W[k]
            c = self.coords[k]
            if c.parent < 0:
                W[k] = (c.m, list(c.t))
            else:
                PM, Pt = get(c.parent)
                pt = [sum(PM[i][j] * c.t[j] for j in range(3)) >> 12 for i in range(3)]
                M = [[sum(PM[i][j] * c.m[j][q] for j in range(3)) >> 12 for q in range(3)] for i in range(3)]
                W[k] = (M, [pt[i] + Pt[i] for i in range(3)])
            return W[k]
        for k in range(len(self.coords)):
            get(k)
        return W
