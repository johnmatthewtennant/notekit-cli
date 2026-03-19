#!/usr/bin/env python3
"""
Generate notekit.m from NotesShared private API.

USAGE:
    python3 generate-notes-cli.py > notekit.m
    # Then: make notekit

MAINTENANCE:
    This generator reads the current notekit.m, regenerates the noteToDict()
    function from NOTE_READ_PROPS, and outputs the assembled result.

    To add a new READ property:
        1. Add to NOTE_READ_PROPS below
        2. Regenerate: python3 generate-notes-cli.py > notekit.m && make notekit

    To add a new command or modify existing code:
        1. Edit notekit.m directly (all sections except noteToDict)
        2. Run: python3 generate-notes-cli.py > notekit.m && make notekit
           (this regenerates noteToDict and preserves your changes)

    To discover new properties/methods:
        make notes-inspect && ./notes-inspect 2>&1 | less

    Architecture:
        notes-inspect.m       → dumps ObjC runtime properties/methods
        generate-notes-cli.py → regenerates noteToDict in notekit.m (this file)
        notekit.m             → source of truth for all code except noteToDict
"""

import os
import sys

# --- Configuration ---

# Properties to expose on ICNote (read)
NOTE_READ_PROPS = {
    "title":               ("title",         "string"),
    "noteAsPlainTextWithoutTitle": ("body",  "string"),
    "folderName":          ("folder",        "string"),
    "creationDate":        ("createdAt",     "date"),
    "modificationDate":    ("modifiedAt",    "date"),
    "hasChecklist":        ("hasChecklist",  "bool"),
    "isPinned":            ("isPinned",      "bool"),
    "hasTags":             ("hasTags",       "bool"),
    "identifier":          ("id",            "string"),
    "snippet":             ("snippet",       "string"),
}

# Section markers in notekit.m
SECTION_MARKER = '// --- Note Serialization (generated from NOTE_READ_PROPS) ---'
NOTETODICT_START = 'static NSDictionary *noteToDict(id note) {'


def generate_note_to_dict():
    """Generate the noteToDict function from NOTE_READ_PROPS."""
    lines = [
        'static NSDictionary *noteToDict(id note) {',
        '    NSMutableDictionary *dict = [NSMutableDictionary dictionary];',
        '',
    ]

    for prop, (json_key, type_hint) in NOTE_READ_PROPS.items():
        if type_hint == "string":
            lines.append(f'    @try {{')
            lines.append(f'        NSString *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("{prop}"));')
            lines.append(f'        if (val) dict[@"{json_key}"] = val;')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "bool":
            lines.append(f'    @try {{')
            lines.append(f'        BOOL val = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("{prop}"));')
            lines.append(f'        dict[@"{json_key}"] = @(val);')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "date":
            lines.append(f'    @try {{')
            lines.append(f'        NSDate *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("{prop}"));')
            lines.append(f'        if (val) dict[@"{json_key}"] = dateToISO(val);')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        lines.append('')

    # URL property (not from a simple ObjC property — uses ICAppURLUtilities)
    lines.append('    @try {')
    lines.append('        Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");')
    lines.append('        if (ICAppURLUtilities) {')
    lines.append('            NSURL *appURL = ((id (*)(id, SEL, id))objc_msgSend)(')
    lines.append('                ICAppURLUtilities, sel_registerName("appURLForNote:"), note);')
    lines.append('            if (appURL) dict[@"url"] = [appURL absoluteString];')
    lines.append('        }')
    lines.append('    } @catch (NSException *e) {}')
    lines.append('')
    lines.append('    return dict;')
    lines.append('}')
    return '\n'.join(lines)


def main():
    # Find notekit.m relative to this script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    notekit_path = os.path.join(script_dir, 'notekit.m')

    if not os.path.exists(notekit_path):
        print(f"Error: {notekit_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(notekit_path, 'r') as f:
        content = f.read()

    lines = content.split('\n')

    # Find the section marker and noteToDict boundaries
    marker_line = None
    func_start = None
    func_end = None

    for i, line in enumerate(lines):
        if line.strip() == SECTION_MARKER:
            marker_line = i
        if line.strip() == NOTETODICT_START:
            func_start = i
        # Find closing brace of noteToDict (first } at column 0 after func_start)
        if func_start is not None and func_end is None and i > func_start:
            if line == '}':
                func_end = i
                break

    if marker_line is None or func_start is None or func_end is None:
        print("Error: Could not find noteToDict section boundaries in notekit.m", file=sys.stderr)
        print(f"  marker_line={marker_line}, func_start={func_start}, func_end={func_end}", file=sys.stderr)
        sys.exit(1)

    # Section 1: everything before the section marker (header)
    # Include up to but not including the marker line
    header = '\n'.join(lines[:marker_line])

    # Section 2: the section marker + blank line + regenerated noteToDict
    section2 = SECTION_MARKER + '\n\n' + generate_note_to_dict()

    # Section 3: everything after noteToDict closing brace
    rest = '\n'.join(lines[func_end + 1:])

    # Assemble and output
    output = header + '\n' + section2 + '\n' + rest
    print(output, end='')


if __name__ == '__main__':
    main()
