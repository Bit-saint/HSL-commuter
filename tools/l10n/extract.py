#!/usr/bin/env python3
"""Lists the localization keys used in the app's Swift sources, as Xcode would generate them.

Covers SwiftUI initializers that take a LocalizedStringKey literal (Text, Label, Button, ... and
ternaries of two literals) and String(localized:) calls. Interpolations become %@ or %lld.
Usage: extract.py DIR... -> prints keys, one JSON string per line.
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from swiftstrings import literal_end, interpolations

SWIFTUI = r'(?<![A-Za-z.])(Text|Label|Button|Toggle|Section|Link|Picker|TextField|SecureField|Stepper|LabeledContent|ContentUnavailableView|Menu|Tab|NavigationLink|navigationTitle|accessibilityLabel|alert|help)\('
INT_EXPR = re.compile(r'^(-?\s*Int\(.*\)|.*\.count|mins|minutes|m|wait|count|saved|late|lateMinutes|n|k|seg\.minutes|e\.reports|max\(mins, 0\)|-?best\.delayVsPlan|-?option\.delayVsPlan|item\.recording\.(vehicles|locations)\.count|i)$')

def key_for(body):
    out = ''
    for kind, part in interpolations(body):
        if kind == 't':
            out += part.replace('%', '%%').replace('\\"', '"').replace('\\n', '\n')
        else:
            expr = part.strip()
            out += '%lld' if INT_EXPR.match(expr) else '%@'
    return out

def first_arg(src, i):
    """src[i] is just after '('. Returns the first argument's source text."""
    depth, j = 0, i
    while j < len(src):
        c = src[j]
        if c == '"':
            j = literal_end(src, j); continue
        if c in '([{': depth += 1
        elif c in ')]}':
            if depth == 0: return src[i:j]
            depth -= 1
        elif c == ',' and depth == 0:
            return src[i:j]
        j += 1
    return src[i:]

def literals_in(arg):
    """Literals of a LocalizedStringKey argument: "x" or cond ? "a" : "b". None if it isn't one."""
    arg = arg.strip()
    lits, j = [], 0
    rest = ''
    while j < len(arg):
        if arg[j] == '"':
            e = literal_end(arg, j)
            lits.append(arg[j + 1:e - 1]); rest += '#'; j = e; continue
        rest += arg[j]; j += 1
    if not lits: return None
    if rest.strip() == '#': return lits
    if re.fullmatch(r'[^"#]*\?\s*#\s*:\s*#', rest.strip()): return lits
    return None

def keys_in(src):
    keys = set()
    for m in re.finditer(r'String\(localized:\s*"', src):
        q = m.end() - 1
        keys.add(key_for(src[q + 1:literal_end(src, q) - 1]))
    for m in re.finditer(SWIFTUI, src):
        arg = first_arg(src, m.end())
        if arg.lstrip().startswith(('verbatim:', 'LocalizedStringKey(')): continue
        lits = literals_in(arg)
        if lits:
            for l in lits: keys.add(key_for(l))
    return keys

def scan(dirs):
    keys = set()
    for d in dirs:
        for root, _, files in os.walk(d):
            for f in files:
                if f.endswith('.swift'):
                    keys |= keys_in(open(os.path.join(root, f)).read())
    return {k for k in keys if re.search(r'[A-Za-z]', k)}

if __name__ == '__main__':
    for k in sorted(scan(sys.argv[1:])):
        print(json.dumps(k, ensure_ascii=False))
