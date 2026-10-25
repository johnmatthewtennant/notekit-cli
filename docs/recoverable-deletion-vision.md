# Recoverable note deletion

Proposed direction, 2026-10-25 (issue #63).

`delete` should move a note into its own account's Recently Deleted folder through
Notes.app, retain its content and attachments for recovery, and enter Notes'
normal asynchronous cloud synchronization path. It must not hard-delete rows.
Identify the destination by folder type and account, never a localized title or
the default account. If Notes Automation fails or the destination is missing or
ambiguous, return an error without deleting local data. Normal active-note
lookups should exclude Recently Deleted.

Verify the retained note, account, content, visibility and cloud acknowledgement
on disposable data. Test destination selection and error propagation separately
without personal data. The related `delete-folder` path requires its own runtime
assessment; deleting a parent before child moves upload can violate cloud
references, as observed during the earlier fixture cleanup.
