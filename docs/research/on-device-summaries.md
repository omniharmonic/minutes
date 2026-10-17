# Apple on-device summaries — 2026-10-14

`MinutesSummarize.FoundationModelsProvider` is a real adapter to Apple's on-device `SystemLanguageModel`. It creates a fresh `LanguageModelSession` per bounded request and uses guided generation (`@Generable` claims plus evidence IDs). It does not use Private Cloud Compute, a BYO server, or an external package. No API key or application-managed model download is involved. Availability depends on Apple Intelligence eligibility, enablement, and local model readiness.

The adapter compiles against the installed Apple SDK with macOS/iOS 26 availability guards. Minutes retains its existing macOS 15/iOS 18 deployment targets; older operating systems can use separately selected extractive notes. The Mac binary's FoundationModels load command is weak-linked. This is build/link evidence, not a physical-device test on every supported OS.

## Explicit selection and errors

The public API is `FoundationModelsProvider.availability()` returning `LocalSummaryAvailability`, with an actionable `message`. Status distinguishes available, newer OS required, unsupported hardware, Apple Intelligence disabled, model not ready, and unknown unavailability. Selecting the Apple provider does not silently substitute extractive notes if it is unavailable or fails. The user must explicitly choose the extractive engine.

```
minutes-cli summarize <meeting-id> --engine apple --template general --data-dir <library-directory>
minutes-cli summarize <meeting-id> --engine extractive --template interview --data-dir <library-directory>
```

`SummaryCommandOptions` validates engines, templates, missing values, duplicates, and unknown options before provider invocation. Defaults remain extractive/general. Templates are General, 1:1 (`oneToOne`), Standup, and Interview. They change model organization instructions, not evidence or factual authority. The extractive engine retains its quoted-candidate format; template instructions apply to generated notes. The CLI saves the summary and meeting status together in a database transaction.

## Evidence and long meetings

The old prompt requested timestamps but omitted them from the input. The new prompt supplies JSON evidence records containing actual start/end timecodes and stable transcript IDs. Untimed text imports stay explicitly untimed. Personal user notes are separate `user_notes` records with an N reference and no invented recording time. Their quoted context is not treated as meeting speech or confirmed decisions.

Combined instructions and prompt are bounded by the provider's declared UTF-8 byte budget. The Apple adapter uses 2,800 bytes and reserves a maximum of 512 generated tokens. This is a conservative budget for the 26.x model's documented 4,096-token session; exact tokenization and schema overhead remain framework-dependent, and context errors are surfaced. Oversized individual statements/notes are split on Unicode scalar boundaries while preserving their original ID and original time range. Tests reconstruct all long transcript and note text from the actual requests, including Unicode. They also check the actual combined byte count, rather than counting utterances as a proxy for context size.

Every chunk uses a new model session, avoiding accumulation of earlier session history. Long meetings produce labeled evidence-part sections; there is no unbounded second-pass prompt or hidden truncation. Personal notes remain independently cited. A generated non-heading line must cite only IDs supplied in that request; missing and unknown citations reject the draft. Empty output or provider errors do not become a successful extractive result.

Citation validation establishes reference provenance, not semantic truth. Model-generated prose still requires human review. It does not populate structured decisions, action owners, or confirmed speaker identities. The structured summary fields and overview retain the explicitly labeled extractive candidates; generated prose appears in the Markdown's review-required section. The extractive engine quotes real speech and labels possible decisions/follow-ups for review.

## Verification

Model-free tests exercise real prompt bytes, complete Unicode evidence preservation, precise source timing, untimed text, separate personal notes, bad references, uncited claims, empty responses, and CLI selections. Normal `swift test` does not invoke the model. The native smoke is explicitly gated by `MINUTES_LOCAL_SUMMARY=1` and checks availability before requesting inference.

Three fictional on-device requests were made during implementation, with no microphone, user transcript, personal account, or model setup action. Two free-form responses failed the strict evidence validator; one repeated an unsupported note ID. The adapter was changed to guided typed generation. The third request passed in approximately 1.96 seconds with supported citations to the fictional source. This proves that the installed local model and typed adapter can execute on this host. It does not establish meeting-summary accuracy, long-session latency, or equivalent availability on other hardware, languages, regions, or iOS devices.

## Primary references

- [Apple SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
- [Generating content and performing tasks](https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models)

Exact API availability, guided-generation signatures, `GenerationOptions`, and availability reasons were also checked in the installed SDK's FoundationModels Swift interface. The adapter's runtime request uses the on-device model explicitly.
