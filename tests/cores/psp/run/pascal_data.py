"""Update a generated data section in an ordinary Pascal source, without includes."""
from pathlib import Path


def write_block(path, name, contents):
    path = Path(path)
    begin = '// BEGIN GENERATED ' + name
    end = '// END GENERATED ' + name
    text = path.read_text(encoding='utf-8-sig')
    if text.count(begin) != 1 or text.count(end) != 1:
        raise ValueError(f'Missing or ambiguous generated data markers in {path}')
    first = text.index(begin) + len(begin)
    last = text.index(end, first)
    text = text[:first] + '\n' + contents.rstrip() + '\n' + text[last:]
    path.write_text(text, encoding='utf-8', newline='\n')
