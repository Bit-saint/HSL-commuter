"""Tiny Swift string-literal scanner shared by the localization tools."""
import re

def literal_end(src, i):
    """src[i] == '"'. Returns index after the closing quote (handles \\( ... ) with nested literals)."""
    assert src[i] == '"'
    j = i + 1
    while j < len(src):
        c = src[j]
        if c == '\\':
            if src[j + 1] == '(':
                depth, k = 1, j + 2
                while depth:
                    if src[k] == '"':
                        k = literal_end(src, k)
                        continue
                    if src[k] == '(':
                        depth += 1
                    elif src[k] == ')':
                        depth -= 1
                    k += 1
                j = k
                continue
            j += 2
            continue
        if c == '"':
            return j + 1
        if c == '\n':
            raise ValueError("unterminated literal")
        j += 1
    raise ValueError("unterminated literal")

def interpolations(lit):
    """Splits a literal body into text and \\(expr) parts: [('t', text) | ('e', expr)]."""
    out, j, buf = [], 0, ''
    while j < len(lit):
        if lit[j] == '\\' and j + 1 < len(lit) and lit[j + 1] == '(':
            depth, k = 1, j + 2
            while depth:
                if lit[k] == '"':
                    k = literal_end(lit, k)
                    continue
                if lit[k] == '(':
                    depth += 1
                elif lit[k] == ')':
                    depth -= 1
                k += 1
            if buf: out.append(('t', buf)); buf = ''
            out.append(('e', lit[j + 2:k - 1]))
            j = k
        elif lit[j] == '\\':
            buf += lit[j:j + 2]; j += 2
        else:
            buf += lit[j]; j += 1
    if buf: out.append(('t', buf))
    return out

def is_user_text(body):
    plain = ''.join(t for k, t in interpolations(body) if k == 't')
    if not re.search(r'[A-Za-zÄÖÅäöå]{2,}', plain):
        return False
    if re.fullmatch(r'[a-z0-9]+(\.[a-z0-9]+)+', plain):      # SF Symbol / id
        return False
    return True
