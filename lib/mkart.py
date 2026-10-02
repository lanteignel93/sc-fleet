#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mkart.py — regenerate the logo block in sckit.sh from the drawing below.

The logo is stored in the kit as literal lines because bash has no business
composing anything at startup. That makes the drawing here the source of truth:
edit the sprites, run this, paste the output over the block in sckit.sh from
the SC_ART_ROLES line through SC_LOGO_W.

    python3 lib/mkart.py

The scene is plain ASCII art; every character also carries a palette role, and
the rows name ${F_<role>}, which the kit defines from the worn theme. So the
cowboy wears whatever `dye` says, and without colour (a pipe, NO_COLOR,
`sc logo` into a README) the ${F_*} are empty and the same rows print as the
plain drawing.
"""

W, H = 66, 18
chars = [[" "] * W for _ in range(H)]
roles = [[None] * W for _ in range(H)]


def put(x, y, art, role=None, mask=None, rolemap=None, only_empty=False):
    """Place a sprite: one role for every character, or a mask whose keys map to roles."""
    mlines = mask.split("\n") if mask else []
    for dy, line in enumerate(art.split("\n")):
        for dx, c in enumerate(line):
            X, Y = x + dx, y + dy
            if c == " " or not (0 <= X < W and 0 <= Y < H) or (only_empty and chars[Y][X] != " "):
                continue
            chars[Y][X] = c
            k = mlines[dy][dx] if mask and dx < len(mlines[dy]) else None
            roles[Y][X] = (rolemap or {})[k] if mask else role


# --- sky: a ringed planet, the moon ------------------------------------------
put(2, 0, "   .-~~-.\n--(      )--\n   `-..-'",
    mask="   pppppp\noop      poo\n   pppppp", rolemap={"p": "cursor", "o": "fg"})
put(55, 0, "   _..._\n .'  .-'\n/   /\n|  |\n\\   '.\n '._  '-.\n    ''", "bright")

# --- a saguaro ------------------------------------------------------------------
put(3, 7, "    _\n   | |\n _ | |  _\n| || | | |\n| || |_| |\n \\_| |__/\n   | |\n   | |\n   | |", "lime")

# --- the cowboy: hat, bandana, open arms, belt and buckle, boots -------------------
COWBOY = """\
          ___
     ____|___|____
    (_____________)
        | o o |
        |  -  |
      __\\vvvvv/__
     /  |     |  \\
    /   |  |  |   \\
   (_)  |  |  |  (_)
        |__|__|
        |  |  |
        |  |  |
       _|  |  |_
      (___) (___)"""
MASK = """\
          hhh
     hhhhhhhhhhhhh
    hhhhhhhhhhhhhhh
        ffffffff
        ffffffff
      ccBBBBBBBcc
     c  cxxxxxc  c
    c   cxxxxxc   c
   fff  cxxxxxc  fff
        LLLYLLL
        pp pp p
        pp pp p
       pp pp  pp
      ooooo ooooo"""
put(19, 2, COWBOY, mask=MASK, rolemap={"h": "cursor", "f": "peach", "B": "rose", "c": "fg", "x": "fg2",
                                       "L": "border", "Y": "butter", "p": "dim", "o": "border"})

# --- his terminal, running the fleet ------------------------------------------------
IN = 13
put(42, 8, "\n".join([
    " ." + "-" * (IN + 4) + ".",
    " | ." + "-" * IN + ". |",
    " | |" + " " * IN + "| |",
    " | |" + " " * IN + "| |",
    " | '" + "-" * IN + "' |",
    " '" + "-" * ((IN + 3) // 2) + "." + "-" * ((IN + 4) // 2) + "'",
    " " * ((IN + 5) // 2 - 2) + "___|___",
    " " * ((IN + 5) // 2 - 3) + "'-------'"]), "fg")
put(47, 10, "$ sc", "lime"); put(47, 11, "> _", "mint")

# --- stars, only where the sky is empty -----------------------------------------------
for x, y, c in [(17, 1, "*"), (24, 0, "."), (33, 2, "."), (40, 0, "*"), (46, 3, "."), (14, 4, "."),
                (29, 4, "+"), (44, 6, "."), (1, 6, "."), (43, 1, "*")]:
    put(x, y, c, "bright" if c in "*+" else "dim", only_empty=True)

# --- the desert floor ----------------------------------------------------------------
put(0, 16, "~" * W, "dim")
put(0, 17, "   .      '         .            ,          .         '     .", "border")


def row(y):
    """One scene row: a ${F_role} wherever the role changes, reset at the end."""
    line, cur = "", None
    last = max((x for x in range(W) if chars[y][x] != " "), default=-1)
    for x in range(last + 1):
        c, r = chars[y][x], roles[y][x]
        if c != " " and r != cur:
            line += "${F_%s}" % r; cur = r
        line += "\\" + c if c in '\\`"$' else c     # the rows are double-quoted bash strings
    return line + "${A_0}" if line else line


F5 = {"S":["#####","#....","#####","....#","#####"],"P":["#####","#...#","#####","#....","#...."],
      "A":[".###.","#...#","#####","#...#","#...#"],"C":["#####","#....","#....","#....","#####"],
      "E":["#####","#....","####.","#....","#####"],"O":["#####","#...#","#...#","#...#","#####"],
      "W":["#...#","#...#","#.#.#","##.##","#...#"],"B":["####.","#...#","####.","#...#","####."],
      "Y":["#...#","#...#",".###.","..#..","..#.."]}


def word(w_):
    """The wordmark: 5-pixel letters, two pixel rows per text row."""
    g = [" ".join(F5[c][r] for c in w_) for r in range(5)] + [" " * (6 * len(w_) - 1)]
    out = []
    for y in range(0, 6, 2):
        out.append("".join("█" if g[y][x] == "#" and g[y+1][x] == "#" else "▀" if g[y][x] == "#"
                           else "▄" if g[y+1][x] == "#" else " " for x in range(len(g[0]))).rstrip())
    return out


SPACE, COWBOY_W = word("SPACE"), word("COWBOY")
WS = max(len(l) for l in SPACE)
WORD_A = [SPACE[i].ljust(WS) + "   " for i in range(3)]      # in lime: your work
WORD_B = COWBOY_W                                            # in the cursor colour
SCENE = [row(y) for y in range(H)]
LOGO_W = max(W, max(len(WORD_A[i] + WORD_B[i]) for i in range(3)))
ROLES = sorted({r for rr in roles for r in rr if r} | {"lime", "cursor"})


def arr(name, lines):
    return "%s=(\n%s\n)" % (name, "\n".join('  "%s"' % l for l in lines))


print("\n".join([
    "# The project logo (tier 3). Generated from the drawing in lib/mkart.py, never",
    "# hand-edited: change it there and paste the output back over this block. A",
    "# tool prints sc_mark; only the dispatcher and a README use this.",
    "SC_ART_ROLES=(%s)" % " ".join(ROLES),
    "# One foreground escape per role, from SC_RGB_<role> (the builtins above, or",
    "# the worn bundle's). Empty without colour, so the rows print as plain ASCII.",
    'for _r in "${SC_ART_ROLES[@]}"; do _v="SC_RGB_$_r"',
    "  if [[ -n \"$A_0\" ]]; then printf -v \"F_$_r\" '\\e[38;2;%sm' \"${!_v}\"; else printf -v \"F_$_r\" %s \"\"; fi",
    "done; unset _r _v",
    "# The scene: ${F_*} expand here, when the kit is sourced.",
    arr("SC_LOGO_SCENE", SCENE),
    arr("SC_LOGO_WORD_A", WORD_A),
    arr("SC_LOGO_WORD_B", WORD_B),
    "SC_LOGO_W=%d" % LOGO_W,
]))
