# SDD ledger — plan: docs/superpowers/plans/2026-10-13-panel-modes-settings.md

Design approved: user replied 确认方案 on 2026-10-13.
Plan approved: user replied 计划符合，开始实施 on 2026-10-13. Native execution selected.
Baseline: product e68c423 / v0.4.30; Task 1 BASE 4f2d6b57705632d75322cc76689147dd8ffd315c.

Pre-flight: Task 1→2/3/4/5 — Shell on_return and hidden parent lifecycle must preserve live section, not stale values; consumers reopen their direct section after closing the child. No conflict.
Pre-flight: Task 3→4/5 — Dynamic numeric schema and Modes resolve/override cover both full reader values and sparse book patches. Consumers must not call choice-only loops on numeric fields. No conflict.
Pre-flight: Task 4→5 — detector auto_detection and detection_threshold are session request fields; redetect modifies request, not render_options. No conflict.
Pre-flight: Tasks 1–5→6 — six new runtime modules change strict inventory and runtime fingerprint; reports must be refreshed after all runtime edits. No conflict.

Task 1: in progress — window hierarchy and screenshot removal; read task-1-brief.md before implementation.

Task 1 evidence: RED replacement layout erased current input; RED preview Back did not restore caller. GREEN 40 hierarchy / 29 preview / 1299 lifecycle checks; complete Lua traversal and product syntax passed. Updated two injected test boundaries to represent actual dialog ownership and suspension.
Task 1: complete (commits 4f2d6b5..9ed59cd, tests: E:/jiankong/webdav-manga-handoff/.venv/Scripts/python.exe scripts/run_lua_specs.py --all --syntax-root webdavmanga.koplugin → webdav_client_spec: 74 checks)

Task 2 evidence: exact-angle/same-angle/status/menu RED recorded; GREEN 29 layout, 44 settings hierarchy, native menu bands85 and grid80. Full Lua specs228 and syntax113 passed in task-2-full.log.
Task 2: complete (commits 9ed59cd..e6d85f6, tests: E:/jiankong/webdav-manga-handoff/.venv/Scripts/python.exe scripts/run_lua_specs.py spec/panel_controls_layout_spec.lua spec/settings_hierarchy_spec.lua → settings_hierarchy_spec: 44 checks)

Ruling: extend shared PanelOptions numeric validation in Task3 — dynamic minimum side needs fractional values now, not Task4 — existing integer fields retain their defaults and integer rule.
Ruling: keep two unchanged upstream algorithm files under test fixtures for exact output comparison — tests remain runnable without fetching private/local source — extra code is test-only and excluded by strict package inventory.
Ruling: Web shares existing view/navigation configuration while recognition has four independent fields — design requires shared views and separate detection; no additional display schema needed.

Task3 evidence: RED missing Modes/Web and missing dynamic defaults; GREEN modes47, parameters/editor33, exact upstream/extraction13. Full Lua231 / syntax117 passed. One preexisting CRC performance check measured3.132s once; unchanged strict3s passed isolated and the next full suite. No CRC code or threshold changes.
Task 3: complete (commits e6d85f6..0f9fbf3, tests: E:/jiankong/webdav-manga-handoff/.venv/Scripts/python.exe scripts/run_lua_specs.py spec/panel_modes_spec.lua spec/dynamic_panel_parameters_spec.lua spec/web_panel_source_spec.lua → web_panel_source_spec: 13 checks)

Task4 evidence: RED missing profile, native hardcoded threshold, advanced toggle returned wrong parent, and native auto profile used outside-crop background. GREEN Profile279 / numeric-native38; offline real ARM/BB8/Leptonica6 cases, unchanged pixels, zero PIX/BOX/BOXA owners after success and injected failures (task-4-native.log).
Ruling: contrast protection uses min(effective, manual,40) in the same sampled pixel loop — raising detection threshold must not drop faint overflow dialogue — one optional bounded protection map, no extra original reads.
Ruling: native adaptive statistics sample pixel centers inside the requested crop; native floor/ceil clipping stays intact — rounded padding outside the crop biased Otsu — auto-only boundary change.
Ruling: do not add a second weak-line retry switch without real-page accuracy proof — the current bounded adaptive option already covers faint lines, and extra low-threshold passes can add noise — assess real-page evidence again in Task6; no unsupported accuracy claim.

Ruling: optimize the preexisting pure-Lua CRC fallback after repeated strict budget failures (3.132s/3.064s) — each byte ran two 32-step XOR loops — a fixed256-entry nibble table reduces XOR to8steps; native bit path and3s integrity gate remain unchanged. ArchivePages is an extra Task4 file and seven-format ARM validation is still required in Task6.

Task4 full evidence: 232 Lua suites /118 product syntax passed in task-4-full-green.log after CRC optimization; 38 CRC and136 EPUB checks also passed independently.
Task 4: complete (commits 0f9fbf3..427664f, tests: E:/jiankong/webdav-manga-handoff/.venv/Scripts/python.exe scripts/run_lua_specs.py spec/panel_auto_detection_spec.lua spec/dynamic_panel_parameters_spec.lua → dynamic_panel_parameters_spec: 38 checks)

Task5: Ruling: rebuild mode layout transactionally inside the existing PanelSession owner instead of closing/reopening its handle — closing first cannot preserve the visible old panel after render/save rejection; it also adds source opens. Candidate detector/request/layout publish atomically, old prefetch invalidated, old render freed only after accepted replacement. This satisfies one-session and rollback behavior with fewer lifecycle paths.

Task5 evidence: redetection112 / reader73 checks cover one source-open, atomic detector/request/layout/camera, rollback, max2 rendered owners, empty-page continuation, close and stale prefetch; full234 Lua suites /118 syntax passed in task-5-full-green.log.
Task 5: complete (commits 427664f..2df7ff7, tests: E:/jiankong/webdav-manga-handoff/.venv/Scripts/python.exe scripts/run_lua_specs.py spec/panel_mode_reader_spec.lua spec/panel_redetection_spec.lua → panel_redetection_spec: 112 checks)

Task6: seven-original cold/warm/EPUB legacy stream gate PASS, full-file requests0 and decoded bookshelf first pages matched; runtime-bound report verification-runs/panel-modes-0431-20261013/stream-formats.json. ARM144 page/mode cases pass, source pixels intact, native14+6 allocation cases pass; extended min-side16-case native contract is pending final run.
Task6: Ruling: no weak-line retry added — real pages have no annotated ground-truth panel/dialogue boundaries, and automatic thresholds sometimes reduce reliable panel count; a second retry cannot be justified as an accuracy improvement from these counts. Keep explicit auto option and full-page fallback, avoid unsupported precision claims.

Task6 final native: 144 page/mode,16 real dynamic,6 profile native cases PASS; zero PIX/BOX/BOXA owners and original bytes intact. Full235/118, unpacked21/118 PASS. Candidate ZIP134 members, deterministic byte-identical builds; review still pending, no publication or installation yet.

Final review: one fresh strongest reviewer, fixed e68c423..721f906. No Critical, five Important, no Minor. Re-graded all five Important as applicable, reproduced before fixes. ONE fix pass: native dismiss ownership/direct parent, shared menu caller, failed global child restoration, initial fallback-mode transaction, busy edit/source lifetime guard. No second reviewer pass.
Ruling: owned native dismiss uses the explicit return callback instead of native unregistered close — both normal paths return once; teardown invalidates ownership — if wrong a native dialog may need a dedicated close adapter.
Ruling: shared menu records its actual panel/Web caller and clears it at reading/root return — enabled recognition mode is independent of navigation origin — if wrong a new direct entry must supply its own caller.
Ruling: whole-page replacement commits only at first accepted publication; render/save/publish failures restore old mode and next-page detection — no visible session owner exists in this fallback path — if wrong asynchronous failure could retain a stale continuation, covered by late-close tests.
Ruling: reject every panel setting patch while detecting/rendering/configuring/publishing rather than queue it — prevent source closure on a native render stack without another queue/lifecycle — if wrong a user must retry a rare busy edit.
Final review RED: native gray/tone close, global native section, rejected constructor, wrong Web parent; baseline busy-source reproduction; fallback render transition falsely succeeded. GREEN targeted six suites, including synchronous/async first render, save/publish/factory/no-panels/late-close/close-during-save and busy edits. Runtime changed, all bound reports/package must refresh.

Final stable evidence after4a8afe5: full235/118; Python10; fresh stream303+7/zero full requests; fresh panel144+16+6; unpacked21/118; ZIP134 deterministic, sha256 6d6a58d6dea1d9dcfb92adbb90662b544259133da4a9860603f2e1d4fbd573f5. All134 package members match runtime commit4a8afe5. Device disconnected before backup: no new program write; publishing proceeds under earlier explicit authorization.

Final: fixed whole-page mode transition — panel_mode_reader_spec render/async/save/publish/factory/no-panels/late-close/close-save RED→GREEN; stable full235/235 and118 syntax.
Final: fixed native dismiss/direct caller — settings_hierarchy_spec gray/tone/section RED→GREEN; stable full235/235.
Final: fixed shared menu wrong parent — settings_hierarchy_spec Web/panel origin RED→GREEN; stable full235/235.
Final: fixed global child construction failure — settings_hierarchy_spec injected constructor RED→GREEN; stable full235/235.
Final: fixed busy source closure — baseline busy-repro RED→GREEN, panel_mode_reader_spec busy off/navigation; stable full235/235.
Final: Ruling: real Kindle touch/e-ink performance remains an explicit device acceptance boundary — ARM and UI host tests cannot establish physical rendering/latency — cost if wrong: a device-specific bug can require another patch.
Final: Ruling: real panel accuracy requires annotated truth, not detected counts — no unsupported precision claim or extra retry — cost if wrong: complex pages may still need manual settings or full-page reading.
Final: Ruling: leave unused native path/bytes adaptive entry unchanged — production reading provides buffer — cost if wrong: future callers must add the adaptive interface with real native tests.
Final: Ruling: keep packaging CLI stream-report interface and separately validate ARM panel report — approved plan did not request another forced flag — cost if wrong: future release operators must remember both checks; current release ran both against matching source.
Final: minor (deferred): none in the one final review.
Task6 delivery: public main fast-forward e68c423→bdb52aa; v0.4.31 released with2 assets; downloaded ZIP and SHA exactly match6d6a58d6dea1d9dcfb92adbb90662b544259133da4a9860603f2e1d4fbd573f5. Primary134 members byte-identical to tested source. Release readback verification-runs/panel-modes-0431-20261013/github-release-readback-685f86. Device unavailable at install preparation, before any program write; conditional installation remains pending reconnection and is clearly disclosed.
Task 6: complete (commits 2df7ff7..bdb52aa, tests: E:/jiankong/webdav-manga-handoff/.venv/Scripts/python.exe scripts/run_lua_specs.py spec/settings_hierarchy_spec.lua spec/panel_mode_reader_spec.lua spec/rebuild_0431_release_spec.lua → rebuild_0431_release_spec: 17 checks)
