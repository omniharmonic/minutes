# Meeting folders

Implemented 2026-10-15. Folders organize the local meeting library; they do not change exported meeting payloads, speaker identity, calendar membership, or recording files.

## Filing behavior

- A library without folders gets three starters once: Work, Personal and Learning. Existing folders are preserved. The durable `starter_folders_v1` marker in the append-only `v7_library_settings` migration prevents deleted starters from returning, including after deleting every folder and restarting. Initialization creates folders only; it never files or edits existing meetings. Independent connections serialize initialization in one immediate transaction.
- All Meetings shows the complete library. Unfiled includes meetings without a folder.
- Creating a recording or import while a folder is selected files it there as a manual choice.
- A manual move, including a move to Unfiled, is persistent and protected from automatic filing. Folder deletion preserves all meetings and records their new Unfiled state as manual.
- Automatic filing considers new completed/imported meetings when enabled. Organize Unfiled is the explicit operation for existing eligible meetings. It also preserves manual choices.
- Folders have stable UUID identities. Renaming a folder or editing its description does not move its meetings. Descriptions can explain the folder's intended subject.

The additive `v6_meeting_folders` migration creates `meeting_folder` and `meeting_folder_membership`. Membership stores `manual`/`automatic` provenance and a monotonically increasing revision. A manual Unfiled choice is a row with a null folder ID, rather than an absent row. `applyAutomaticFolder(meetingID:folderID:expectedRevision:)` uses an immediate SQLite transaction and rejects manual, stale, missing-meeting, and missing-folder writes. No shipped schema block was changed. The repository's existing `user_version` convention remains unchanged; the tables are idempotently added on opening an older library.

## Local semantic matching

`FolderClassifier` uses Apple's installed `NLEmbedding` sentence model for the input's detected language. No cloud request or model download is made. An unsupported language, absent asset, malformed vector, cancellation, or other model failure produces an abstention.

Every candidate folder is compared. Its name and description, plus up to five caller-supplied manually filed examples, are embedded using the same language/model as the meeting. The app and CLI supply at most three manual examples per folder. Automatically filed meetings never become training examples. Folder identity is its ID, not its editable name.

The highest cosine similarity among a folder's description and examples is its score. Filing requires a score of at least **0.72** and a gap of at least **0.12** above the runner-up. These values are conservative heuristics, **not calibrated probabilities or confidence percentages**. A single folder still must clear the similarity threshold. Weak, ambiguous, and unrelated inputs remain Unfiled. This intentionally favors precision over coverage; short or sparse content often cannot be filed automatically.

Inputs are bounded before embedding: title 200 characters, summary 1,000, notes 600; each folder description 1,000, each manual example 1,200. Audio, speaker embeddings, and biometric profiles are never read by the classifier. The app rechecks the meeting content, folder definitions, membership snapshot, preference and revision after inference; the app and CLI also recheck their candidate example text before applying a result.

## CLI

Use `--data-dir` for an isolated library:

```sh
minutes-cli folders create --name Finance --description 'Budgets, invoices and financial planning' --data-dir /tmp/minutes-demo
minutes-cli folders list --data-dir /tmp/minutes-demo
minutes-cli folders seed --data-dir /tmp/minutes-demo
minutes-cli folders update <folder-id> --name Accounting --description 'Spending and accounts' --data-dir /tmp/minutes-demo
minutes-cli folders move <meeting-id> --folder <folder-id> --data-dir /tmp/minutes-demo
minutes-cli folders move <meeting-id> --unfiled --data-dir /tmp/minutes-demo
minutes-cli folders meetings --folder <folder-id> --data-dir /tmp/minutes-demo
minutes-cli folders classify <meeting-id> --data-dir /tmp/minutes-demo
minutes-cli folders classify <meeting-id> --apply --data-dir /tmp/minutes-demo
minutes-cli folders delete <folder-id> --data-dir /tmp/minutes-demo
```

`classify` previews a result; only `--apply` can commit automatic filing. Even then, a manual filing/Unfiled lock wins. CRUD and classification output include stable IDs, so duplicate or renamed display names do not become identifiers. Unknown flags and conflicting destinations are rejected.

`seed` explicitly runs the same one-time starter initialization used by the app. It reports whether folders were created or an existing/initialized library was preserved; it is not a reset or restore-defaults command.

## Verification and limits

Default tests require no model or network. They cover persistence/reload, rename identity, non-destructive deletion, manual Unfiled protection, stale automatic results, all-folder ranking (including a twentieth candidate), malformed/missing vectors, ambiguity, unrelated content, example caps, and CLI flag validation. AppState tests additionally race manual moves, target-note edits and example-note edits against an in-flight classifier, verify batch rollback, and check automatic filing after recording plus explicit-folder recording.

The explicitly gated fictional acceptance test is:

```sh
MINUTES_MODELS=1 swift test --package-path MinutesKit --filter actualModelPrecisionAndManualExamples
```

On the development Mac's installed English sentence model, revision 1, dimension 512:

| Fictional fixture | Observed result |
| --- | --- |
| Finance note, folder descriptions only | 0.6854 best similarity, 0.1600 margin: abstained |
| Same note with a related manually filed finance example | 0.8716 similarity, 0.3462 margin: matched Finance |
| Customer onboarding versus engineering/customer descriptions | Abstained |
| Gardening note versus work folders | Abstained |

The compiled CLI also passed an isolated temporary-library smoke covering create/list/update, manual filing, real installed-model classification/application, manual Unfiled protection, rejected invalid flags, and folder deletion without meeting deletion. These few fictional cases establish functioning local inference and conservative behavior, not general classification accuracy, multilingual coverage, or equivalent assets on every phone. More representative acceptance evaluation is needed before making reliability claims.
