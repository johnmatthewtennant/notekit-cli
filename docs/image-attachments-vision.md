# Image attachments and reliable saves

Proposed direction, 2026-10-21 (issues #60 and #61).

Edits should enter Notes' normal cloud synchronization path after a successful
local save. A successful command confirms local persistence; iCloud delivery is
asynchronous and depends on Notes.app and account connectivity.

Import PNG/JPEG images through NotesShared's native file-import API, insert a
native attachment at a UTF-16 position, and support removal by attachment ID.
Use stable `![image](notekit-attachment:ID)` references in Markdown so edits of
surrounding paragraphs preserve media and identity. These references resolve
only existing attachments belonging to the destination note; importing arbitrary
Markdown URLs is outside this feature. Test on disposable notes, including
media bytes, positions, Markdown round trips, deletion, and cloud acknowledgement.

Private API availability varies with macOS. Check required selectors before
mutating, and report unsupported operations explicitly.

Design refinement, 2026-10-21: a cross-process editor notification alone did not
schedule existing-note uploads in runtime tests. Use Notes.app's own same-folder
move handler after local persistence. This avoids creating a staging folder or
rewriting HTML, at the cost of a Notes Automation permission and an app round trip.
Keep upload asynchronous and report a local-save warning if that handoff fails.
Implementation and current usage are described in README.md.
