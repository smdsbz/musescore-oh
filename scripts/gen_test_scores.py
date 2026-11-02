#!/usr/bin/env python3
"""Generate open-licensed (CC0) test score fixtures for musescore-oh.

Melody "Ah! vous dirai-je, maman" (Twinkle, Twinkle, Little Star) is a
traditional French tune (public domain, before 1761); the English lyric
line is from Jane Taylor's "The Star" (1806, public domain). The
arrangement and everything generated here are dedicated to the public
domain via CC0 1.0.

Output (testdata/open/):
  twinkle_twinkle_little_star.mscz  multi-instrument 4.60 fixture
  open_marathon.mscz                long piano-only fixture (page/chunk math)

Schema cribbed from real files the engine already parses (take_me 4.60,
stay_with_me 3.01): notes are (pitch, tpc) pairs with tpc C=14 (+1 per
fifth); 4.x KeySig stores concertKey (written key derived from the
instrument template); Tuplet precedes its chords inside <voice>.
"""
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, '..', 'testdata', 'open')

# ---------------------------------------------------------------- note theory

TPC = {'C': 14, 'G': 15, 'D': 16, 'A': 17, 'E': 18, 'B': 19,
       'F#': 20, 'C#': 21, 'G#': 22, 'F': 13, 'Bb': 12}
PITCH = {'C': 0, 'C#': 1, 'D': 2, 'D#': 3, 'E': 4, 'F': 5, 'F#': 6,
         'G': 7, 'G#': 8, 'A': 9, 'A#': 10, 'B': 11}


def n(name, octave):
    """'F#', 4 -> (65, 20)"""
    return (12 * (octave + 1) + PITCH[name], TPC[name])


def tr(note, d_pitch, d_tpc):
    return (note[0] + d_pitch, note[1] + d_tpc)


# concert-pitch melody; rhythm is always q q q q q q h per 7-note phrase
C4, D4, E4, F4, Fs4, G4, A4 = n('C', 4), n('D', 4), n('E', 4), n('F', 4), n('F#', 4), n('G', 4), n('A', 4)
PH1 = [C4, C4, G4, G4, A4, A4, G4]
PH2 = [F4, F4, E4, E4, D4, D4, C4]
PH3 = [G4, G4, F4, F4, E4, E4, D4]
PH6 = [Fs4, Fs4, E4, E4, D4, D4, C4]   # phrase 2 with F# (G-major section)
DURS = ['quarter'] * 6 + ['half']
LYRICS_P1 = [('Twin', 'begin'), ('kle', 'end'), ('twin', 'begin'), ('kle', 'end'),
             ('lit', 'begin'), ('tle', 'end'), ('star', None)]

# ---------------------------------------------------------------- xml helpers

def chord(dur, notes, lyrics=None, tie=None):
    parts = ['        <Chord>\n', f'          <durationType>{dur}</durationType>\n']
    for text, syl in (lyrics or []):
        parts.append('          <Lyrics>\n')
        if syl:
            parts.append(f'            <syllabic>{syl}</syllabic>\n')
        parts.append(f'            <text>{text}</text>\n          </Lyrics>\n')
    for i, (pitch, tpc) in enumerate(notes):
        parts.append('          <Note>\n')
        if tie and i in tie:
            parts.append(f'            <Tie type="{tie[i]}"/>\n')
        parts.append(f'            <pitch>{pitch}</pitch>\n            <tpc>{tpc}</tpc>\n          </Note>\n')
    parts.append('        </Chord>\n')
    return ''.join(parts)


def rest(dur='measure', frac='4/4'):
    if dur == 'measure':
        return f'        <Rest>\n          <durationType>measure</durationType>\n          <duration>{frac}</duration>\n        </Rest>\n'
    return f'        <Rest>\n          <durationType>{dur}</durationType>\n        </Rest>\n'


def keysig(concert):
    return f'        <KeySig>\n          <concertKey>{concert}</concertKey>\n        </KeySig>\n'


def timesig(nn, dd):
    return f'        <TimeSig>\n          <sigN>{nn}</sigN>\n          <sigD>{dd}</sigD>\n        </TimeSig>\n'


TUPLET_Q3 = ('        <Tuplet>\n          <normalNotes>2</normalNotes>\n'
             '          <actualNotes>3</actualNotes>\n          <baseNote>quarter</baseNote>\n'
             '          <Number>\n            <style>Tuplet</style>\n            <text>3</text>\n          </Number>\n'
             '        </Tuplet>\n')


def text_el(style, text):
    return (f'        <Text>\n          <style>{style}</style>\n'
            f'          <text>{text}</text>\n        </Text>\n')


def vbox(title, subtitle):
    return ('      <VBox>\n' + text_el('title', title) + text_el('subtitle', subtitle)
            + text_el('composer', 'Traditional (PD) · arr. CC0') + '      </VBox>\n')


def part_xml(idx, track_name, inst_id, clefs, piano=False):
    out = [f'    <Part id="{idx}">\n']
    for i, clef in enumerate(clefs):
        out.append('      <Staff>\n        <StaffType group="pitched">\n          <name>stdNormal</name>\n        </StaffType>\n')
        if piano and i == 0:
            out.append('        <bracket type="1" span="2" col="2" visible="1"/>\n        <barLineSpan>1</barLineSpan>\n')
        if clef:
            out.append(f'        <defaultClef>{clef}</defaultClef>\n')
        out.append('      </Staff>\n')
    out.append(f'      <trackName>{track_name}</trackName>\n'
               f'      <Instrument id="{inst_id}">\n        <longName>{track_name}</longName>\n'
               f'        <trackName>{track_name}</trackName>\n')
    if piano:
        out.append('        <clef staff="2">F</clef>\n')
    out.append('      </Instrument>\n    </Part>\n')
    return ''.join(out)


def measure(children, last=False):
    out = ['      <Measure>\n        <voice>\n']
    out.extend(children)
    out.append('        </voice>\n')
    if last:
        out.append('        <BarLine>\n          <subtype>double</subtype>\n        </BarLine>\n')
    out.append('      </Measure>\n')
    return ''.join(out)


# ---------------------------------------------------------------- staff music

def melody_bars(trans, triplet=False, lyrics=False):
    """12 bars (4/4), phrases [1,2,3,3,1,6]; returns list of bars."""
    phrases = [PH1, PH2, PH3, PH3, PH1, PH6]
    ev = [(tr(p, *trans), d) for ph in phrases for p, d in zip(ph, DURS)]
    ly = [(l, s) for l, s in LYRICS_P1]
    bars = []
    for b in range(12):
        ph, half = divmod(b, 2)          # phrase occupies two 4/4 bars: 4 notes + (2 notes + half)
        start = ph * 7 + half * 4
        seg = ev[start:start + (4 if half == 0 else 3)]
        ch = []
        if triplet and b == 4:  # bar 5: G(q) + 3:2 quarter triplet (F G F) + rest
            ch = [chord('quarter', [seg[0][0]])]
            ch.append(TUPLET_Q3)
            for p, _ in seg[1:4]:
                ch.append(chord('quarter', [p]))
            ch.append(rest('quarter'))
        elif lyrics and b < 2:
            for i, (p, d) in enumerate(seg):
                li = half * 4 + i  # phrase 1 spans bars 0-1: notes 0-3 / 4-6
                ch.append(chord(d, [p], lyrics=[ly[li]]))
        else:
            for p, d in seg:
                ch.append(chord(d, [p]))
        bars.append(ch)
    return bars


def coda_bar(trans):
    p = [tr(n('C', 4), *trans), tr(n('E', 4), *trans), tr(n('G', 4), *trans)]
    return [chord('quarter', [p[0]]), chord('quarter', [p[1]]), chord('quarter', [p[2]])]


def piano_rh_bars():
    bars = []
    ev = list(zip(PH1, DURS)) + list(zip(PH2, DURS))  # bars 1-4 melody
    for b in range(4):
        bars.append([chord(d, [p]) for p, d in ev[b * 7:(b + 1) * 7]])
    bars += [[rest()] for _ in range(8)]
    return bars


def piano_lh_bars(tied=True):
    pat = [
        chord('whole', [n('C', 3), n('G', 3)], tie={0: '0'}),
        chord('whole', [n('C', 3), n('F', 2)], tie={0: '1'}),
        chord('whole', [n('E', 3), n('C', 3)]),
        chord('whole', [n('G', 2), n('D', 3)]),
        chord('whole', [n('C', 3), n('G', 3)]),
        chord('whole', [n('G', 2), n('D', 3)]),
    ] * 2
    if not tied:
        pat[0] = chord('whole', [n('C', 3), n('G', 3)])
        pat[1] = chord('whole', [n('C', 3), n('F', 2)])
    return [[b] for b in pat]


# ---------------------------------------------------------------- score build

def build_score(title, subtitle, parts, staff_music, key_change=False, coda=False,
                with_vbox=True, part_name=None):
    """parts: [{'name','inst','clefs',[...],'piano':bool}]; staff_music:
    {staff_idx: [bar, ...]} with bar = list of child strings (or None for
    measure rests). Signature events are injected here. part_name sets the
    partName meta tag used as excerpt display name."""
    n_staves = sum(len(p['clefs']) for p in parts)
    out = ['<?xml version="1.0" encoding="UTF-8"?>\n<museScore version="4.60">\n',
           '  <programVersion>4.6.5</programVersion>\n  <Score>\n    <Division>480</Division>\n',
           f'    <metaTag name="workTitle">{title}</metaTag>\n',
           '    <metaTag name="composer">Traditional (Public Domain)</metaTag>\n',
           '    <metaTag name="copyright">CC0 1.0 - musescore-oh open test fixture</metaTag>\n',
           '    <metaTag name="creationDate">2026-11-02</metaTag>\n']
    if part_name:
        out.append(f'    <metaTag name="partName">{part_name}</metaTag>\n')
    sid = 1
    for p in parts:
        out.append(part_xml(sid, p['name'], p['inst'], p['clefs'], piano=p.get('piano', False)))
        sid += len(p['clefs'])
    nbars = max(len(b) for b in staff_music.values())
    for sidx in range(1, n_staves + 1):
        out.append(f'    <Staff id="{sidx}">\n')
        if sidx == 1 and with_vbox:
            out.append(vbox(title, subtitle))
        bars = staff_music.get(sidx) or [[rest()] for _ in range(nbars)]
        for b in range(nbars):
            children = []
            if b == 0:
                children += [keysig(0), timesig(4, 4)]
            if key_change and b == 8:
                children.append(keysig(1))
            if coda and b == nbars - 1:
                children.append(timesig(3, 4))
            children += bars[b]
            out.append(measure(children, last=(b == nbars - 1)))
        out.append('    </Staff>\n')
    out.append('  </Score>\n</museScore>\n')
    return ''.join(out)


# ---------------------------------------------------------------- fixtures

FL, TP, SX = (0, 0), (2, 2), (9, 3)  # (semitones, fifths): Bb trumpet / Eb alto sax


def gen_twinkle():
    parts = [
        {'name': 'Flute', 'inst': 'flute', 'clefs': ['G']},
        {'name': 'Trumpet in Bb', 'inst': 'trumpet', 'clefs': ['G']},
        {'name': 'Alto Saxophone', 'inst': 'alto-saxophone', 'clefs': ['G']},
        {'name': 'Piano', 'inst': 'piano', 'clefs': ['G', 'F'], 'piano': True},
    ]
    music = {
        1: melody_bars(FL, triplet=True, lyrics=True) + [coda_bar(FL)],
        2: melody_bars(TP) + [coda_bar(TP)],
        3: melody_bars(SX) + [coda_bar(SX)],
        4: piano_rh_bars() + [coda_bar((0, 0))],
        5: piano_lh_bars() + [[chord('quarter', [n('C', 2)]), chord('quarter', [n('G', 2)]), chord('quarter', [n('C', 3)])]],
    }
    master = build_score('Twinkle, Twinkle, Little Star', 'Open test fixture (CC0)',
                         parts, music, key_change=True, coda=True)

    # per-part excerpt scores (zip layout: Excerpts/<base>/<base>.mscx,
    # display name from the partName meta tag — see mscloader.cpp)
    per_part = [
        ({'name': 'Flute', 'inst': 'flute', 'clefs': ['G']}, [music[1]]),
        ({'name': 'Trumpet in Bb', 'inst': 'trumpet', 'clefs': ['G']}, [music[2]]),
        ({'name': 'Alto Saxophone', 'inst': 'alto-saxophone', 'clefs': ['G']}, [music[3]]),
        ({'name': 'Piano', 'inst': 'piano', 'clefs': ['G', 'F'], 'piano': True}, [music[4], music[5]]),
    ]
    excerpts = {}
    for i, (pdef, staves) in enumerate(per_part):
        base = f"{i}_{pdef['name'].replace(' ', '_')}"
        sm = {j + 1: bars for j, bars in enumerate(staves)}
        excerpts[base] = build_score(pdef['name'], None, [pdef], sm, key_change=True,
                                     coda=True, with_vbox=False, part_name=pdef['name'])
    return master, excerpts


def gen_marathon(repeats=8):
    parts = [{'name': 'Piano', 'inst': 'piano', 'clefs': ['G', 'F'], 'piano': True}]
    music = {1: [], 2: []}
    for _ in range(repeats):
        music[1] += piano_rh_bars()
        music[2] += piano_lh_bars(tied=False)
    return build_score('Open Marathon Fixture', 'Open test fixture (CC0)',
                       parts, music, key_change=False, coda=False)


def write_mscz(path, mscx, excerpts=None, inner_name='score.mscx'):
    container = ('<?xml version="1.0" encoding="UTF-8"?>\n<container>\n  <rootfiles>\n'
                 f'    <rootfile full-path="{inner_name}"/>\n  </rootfiles>\n</container>\n')
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('META-INF/container.xml', container)
        z.writestr(inner_name, mscx)
        for base, xml in (excerpts or {}).items():
            z.writestr(f'Excerpts/{base}/{base}.mscx', xml)


if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    master, excerpts = gen_twinkle()
    write_mscz(os.path.join(OUT_DIR, 'twinkle_twinkle_little_star.mscz'), master, excerpts)
    write_mscz(os.path.join(OUT_DIR, 'open_marathon.mscz'), gen_marathon())
    print('written to', os.path.normpath(OUT_DIR))
