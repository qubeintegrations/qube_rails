# Changelog

## 0.3.1 (unreleased)

No migration.

### Fixed

**Work from before a company file change**
- A run or plain request made before the connection's `company_file_changed_at` is the old file's
  (that time is when the webhook was applied, so it may have run on either file). Its late events
  are still applied and your handlers still run, but no sync mark advances, and `Connection#link`
  (so `link_references` too) writes the link stale, with the id the answer gave, for `LinkCheck`
  to look up on the open file (`Connection#holding_links`, per connection id, fiber-local). It
  never displaces a current link (then `link` returns nil). Before, such a run that completed
  just before the switch recreated the deleted sync mark and made its ids current. A completed old
  run counts for `SyncStatus` once its record's link is current.
- `Operation.start`, `Request.queue`, `Run#retry_start!` and `QueuedRequest#retry_queue!` no
  longer reuse or resend such a run or request when it hasn't ended here: `retry_start` would have
  sent the old reference and input to the new file. It's settled with QuBe Sync first
  (`QubeRails::OldFileWork`, outside the connection's lock, before the record's link check), and
  never ended here on the engine's word alone:
  - a run QuBe Sync knows (its `qube_run_id`, or found by its reference) is cancelled there; one
    that ended failed or cancelled is ended here so; one QuBe Sync completed holds the record (its
    ending is asked for again with `redeliver`, its links come in stale and are checked) rather
    than starting a second;
  - a request QuBe Sync knows is read there, discarded if it's still waiting or retryable, and
    ended with the state QuBe Sync answers; one QuickBooks answered waits for its webhook for up to
    a day (`OldFileWork::DELIVERY_WINDOW`);
  - one QuBe Sync never acknowledged is ended here once 5 minutes (`OldFileWork::UNCONFIRMED_AFTER`)
    have passed since it was last sent (each send stamps `updated_at`): a run `cancelled`
    (`cancel_reason` from the new key `status.company_file_changed`), a request `failed` (`error`
    `{"error_type" => "company_file_changed"}`); a run refused as `realtime_required` at once;
  - otherwise the new `QubeRails::OldFileWorkPending` (a `NotReady`) is raised and nothing is
    sent. Once it has ended, a new run or request is built with a new reference. A retry of a row
    that has ended raises `ArgumentError` as before, as does one whose record is gone; the retry
    route logs `NotReady` rather than failing. `Connection#before_company_file_change?(row)` and
    `QuickbooksRecord#current?` are new.
- A link check from before the switch is settled the same way, so `connected` queues a fresh one
  once QuBe Sync confirms the old one is over.

**Link checks that keep failing or never answer**
- A check QuBe Sync took but never answered (its webhook lost) was never queued again. Now, when a
  held record is sent, one with no word for `LinkCheck::NO_ANSWER_AFTER` (an hour) is failed
  (`error` `{"error_type" => "no_answer"}`, under its lock) and queued again. The hour counts from
  the later of the check's last change and the connection's, so time it was stalled or set up
  again doesn't count, and nothing is revived while it isn't connected. A late answer to a check
  failed that way still settles its links and is reported in `links_checked`.
- An answer a check can't trust (rows it didn't ask for, an odd shape) now fails the check
  (`state` `failed`) rather than leaving it answered.
- A kind whose check kept failing stayed stale for good. Now, counting since the last company file
  change and the kind's last check that answered, after `LinkCheck::MAX_ATTEMPTS` (3) failed checks
  (errors, timeouts, discards, answers it can't trust, no answer), or 3 queues QuBe Sync refused
  for good (400, 404, 422: `LinkCheck::LASTING_REFUSALS`, counted on their own; 401, 403, 408, 429
  and 5xx don't count), its links still stale are kept as missing, reported in `links_checked`, and
  logged. A later answer from the new file that has them makes them current again, or holds them
  for review (`missing_since` cleared; `confirm_link` now also clears `missing_since` and
  `stale_since`). The next company file change starts the count again.
- `links_checked` runs inside the answer's row lock, so a handler that raises rolls the answer back
  and the job's retry settles, reports and queues the next batch again.
- A queue QuBe Sync refuses now keeps `error` `{"error_type" => "refused", "status" => <status>}` on
  its row (any plain request).

**Disconnect**
- The engine's own link checks no longer count as work going: an in-flight check refused
  Disconnect.

**Connect after upgrading from 0.2.0**
- The 0.2.1 migration labelled every existing row `realtime`, so in an app with
  `config.connection_type = "standard"` Connect didn't find a pending row from before the upgrade
  and made a second connection (a never-connected row gets no event to correct its type). Connect
  now asks QuBe Sync the type of up to three never-connected rows no event has typed
  (`revision` nil) and reuses one whose type matches. Each lookup has a short timeout and no
  retries (`QubeRails.quick_client`), the first that gets no answer ends them (logged), and a row
  QuBe Sync typed is kept with `revision` 0 so it isn't asked again (any event is newer), written
  only over no revision, so an event applied meanwhile keeps its own.
  `Connection#refresh_type!` takes `client:` and `remember:`.

**`qube_rails/manage_connection`**
- "Set up QuickBooks again" now shows for any connection QuBe Sync has made
  (`Connection#set_up_again?`), including `pending` (right after "Use a different company file")
  and `setup_cancelled`, where the partial used to render nothing and the customer lost the way
  back to the setup. "Use a different company file" still shows only for a set-up, switchable one.

### New

- `render "qube_rails/review_links", connection:` lists the connection's links under review (the
  oldest `Connection::REVIEW_LINKS_SHOWN`, 100), each with its record (its model's name, or an
  optional `label:` lambda's words), the name it was kept with and QuickBooks' name now, and
  "Same record" / "Not the same" buttons. Nothing renders when none is under review. Before, an app
  had to write its own UI, or a record whose id the new file has under another name raised
  `LinkNeedsReview` on every send.
- `POST quickbooks/connections/:id/links/:link_id/confirm` and `/reject`
  (`connection_confirm_link_path`, `connection_reject_link_path`) call `confirm_link` /
  `reject_link` and redirect (303) back. Scoped like `company_file`: another account's connection,
  or a link on another connection, answers 404; one settled already (a second click, another tab)
  redirects back unchanged. `confirm_link` and `reject_link` lock the link, so two at once can't
  both settle it. Turbo can stay on.
- New keys `connection.review_links.intro`, `.renamed`, `.same`, `.not_same`, and
  `status.company_file_changed`.

## 0.3.0 (2026-11-27)

Run `bin/rails qube_rails:install:migrations` and `bin/rails db:migrate` before this version
serves any traffic: it adds `qube_connections.company_file_changed_at` and
`company_file_revision`, and `qube_quickbooks_records.stale_since`, `missing_since`,
`review_since` and `review_name`, and every link read filters on them, so without
the migration every sync fails.

### New

**A connection switched to another company file**
- `connection.company_file_changed` (the customer chose "Use a different company file" on the
  connection's setup page) sets the connection back to `pending`, clears `stall_reason`, marks
  its `qube_quickbooks_records` rows stale (`stale_since`, ids kept), deletes its sync marks, and
  sets `company_file_changed_at` and `company_file_revision`, under the row's lock with the
  revision check. One that comes after a later event (a retry landing after `connected`) still
  forgets the file when it's newer than `company_file_revision` and runs the hook, leaving
  `status` and `revision` alone; a redelivery does nothing. Then the new
  `ConnectionEvents#company_file_changed(event)` hook runs (it logs by default; the install
  generator's template has it). Pages with a run going on the connection refresh, as for a stall.
- A stale link is never used: `qb_id_for`, `find_linked`, `quickbooks_record`, `in_quickbooks`,
  `not_in_quickbooks` and `SyncStatus` read current links only (`QuickbooksRecord.current`,
  `.stale`, `.missing`, `.under_review`, `#stale?`, `#missing?`, `#under_review?`;
  `Connection#stale_links`, `#missing_links`). `link` makes the row it writes current.
- `QubeRails::LinkCheck`: on the next `connection.connected` it queues a plain request per kind
  with stale links (`<kind>.query` by up to 50 ListIDs or TxnIDs, as the gem's
  `Operations::INDEX` `id_param` says, else the engine's `TXN_KINDS` / `LIST_KINDS`; a kind with
  neither is kept as missing when the check starts, and reported). An id found with the same name (case and spacing ignored), or kept
  without a name, is current again with the answer's EditSequence. One found under another name is
  held for review (`review_since`, `review_name`, unused): ids carry their record's creation time,
  so a shared id means a copied file, and a rename may be a repurposed record.
  `Connection#confirm_link(link)` makes it current with QuickBooks' name, `#reject_link(link)`
  makes it missing; `#review_links`, `#link_under_review?`. One not found is kept as missing
  (`missing_since`, unused). The next company file change makes all of them stale again. An id the answer
  leaves out is missing (QuickBooks' 500 warning still returns every id it has); an answer with rows it didn't ask for
  or an odd shape, or to a check queued before the last company file change, settles nothing.
  After each batch the new
  `ConnectionEvents#links_checked(kind:, found:, relinked:, review:, missing:, stale_left:)` runs
  (it logs by default). `Connection#check_stale_links` starts the checks again by hand.
- `Operation.start` and `Request.queue` raise `QubeRails::LinkBeingChecked` for a record whose link
  is still stale on the connection (`Connection#checking_link?`), first queuing its kind's check
  again when the last one ended (or never got an answer) over `LinkCheck::RETRY_AFTER` (5 minutes)
  ago, and `QubeRails::LinkNeedsReview`
  for one under review (both `NotReady`), so nothing is sent for it until its link is settled.
- `SyncStatus` ignores a run made before `company_file_changed_at`: a record sent to the old file
  reads `:not_sent` until its link is checked.
- `POST quickbooks/connections/:id/company_file` (`connection_company_file_path`): renews the
  connection's links and redirects to its `links.company_file`. 404 for a simulated connection.
- `render "qube_rails/manage_connection", connection:`: "Set up QuickBooks again" and, unless
  it's simulated, "Use a different company file", while the connection is connected or stalled.
  New keys `connection.set_up_again` and `connection.use_different_company_file`;
  `Connection#set_up?`, `#simulated?` and `#company_file_switchable?`.
- The vendored webhook test vectors have `connection.company_file_changed`.

### Changed

**Offered records, a decline and a search at once** (in place of 0.2.1's branch at a time)
- Offered records, a decline and a search show at once. Beside a decline, every record's button
  and the decline are secondary. A decline that says what it is as a row (title, action, lines:
  resolve's "Riverbend · new customer in QuickBooks · Add as new") is a row among the records;
  any other ("None of these") is a button just under them (`QuestionView#alongside`,
  `.qube-choice-alongside`), not in the footer. Without a decline the first record is still the
  main action. Cancel is alone in the footer.
- A search beside offered records is its box alone under them (`QuestionView#searches`, new
  partial `question/_inline_search`, `.qube-search-inline`, new key `question.search_quickbooks`,
  `FieldView#placeholder`, `FieldView#inline?`). Picking a match answers nothing: the match shows
  as a row like the offered ones, focused, and the box empties for another search; a second pick
  replaces it. That row is a slot the page renders hidden and empty (`PickedView`,
  `ChoiceView#slot?` and `#data`), posting the search's choice with the match. A search that finds
  nothing makes the decline the main action, unless a match was picked.
- A search's list opens only for the box being focused or typed in, and a box under offered
  records never shows the error edge: its pick is a row of its own.
- The branch pattern is gone: `QuestionView#chain?`, `#branch`, `#branch_part`, `#shown_part?` and
  `#joined_exits`, `data-qube-branch*` and "← Back to the possible match". An override of
  `_question`, `_footer` or `_choice` copied from 0.2.1 that calls them needs updating, and an
  override of `_pick` must render `choice.data` and hide `choice.slot?`. `question.none_of_these`
  and `question.back_to_offered` are unused.
- An offered record's button is described by the record's name (`aria-describedby`,
  `ChoiceView#label_id`), so a screen reader says which record "Use this one" picks. The search box
  under offered records is hidden until the script runs, since it can't search without it.

**A name clash leads with the existing record**
- A choice about one record can carry `title`, `action`, `lines` (each split on " · ") and
  `facts` (`{label, value}`), in place of `detail`: `ChoiceView#title`, `#action`, `#lines`,
  `#facts` (`FactView`), `#row?`; `.qube-pick-line`, `.qube-pick-facts`, `.qube-pick-fact`,
  `.qube-pick-fact-label`.
- `ensure`'s ask_use shows the existing record's row (QuickBooks' stored name, its lines, and
  Company, Balance, Added) with "Use existing" as the main action. Adding it under another name
  waits behind "or add it under another name…" (new key `question.disclose_choice`,
  `QuestionView#disclosed` and `#mid_sentence`, new partial `question/_disclosure`, a `<details>`
  with `.qube-choice-disclosure` and `data-qube-disclosure`); opened, its submit is the main
  action and the focus goes to its first field. A refusal of its answer opens it.

**An offered record's button is its only target**
- An offered record's row (`.qube-pick`) is now a `div`, and its "Use this one"
  (`.qube-pick-action`) is the submit button: a click on the record's name or details does
  nothing. A row without its own button (a plain option) is still a button whole. Styles keyed
  on `button.qube-pick` for an offered record need `.qube-pick`.

**Smaller**
- Option rows sit on a quiet fill rather than a border, so they aren't boxes inside the card.
- The storyboard's search in a rows field returns only records of the row's kind, as QuBe Sync's
  search scopes by `row`. Its notes say in plain words what brings each screen up and what your
  user can do.

## 0.2.1 (2026-11-17)

Connections keep their type, so workflows aren't started on standard ones, and run webhooks are
read as QuBe Sync now sends them. Run `bin/rails qube_rails:install:migrations` and
`bin/rails db:migrate`.

### Added

**Connections and onboarding**
- `qube_connections.connection_type` (`realtime`, `standard` or `simulated`), set when Connect
  makes the connection and kept up to date by the connection's events; `Connection#standard?` and
  `Connection#refresh_type!` (reads it from QuBe Sync after an upgrade in the dashboard).
- Connect (`POST quickbooks/connections`) takes `type=realtime` or `type=standard`, else
  `config.connection_type`; any other type answers 422. It sends back through setup only a
  never-connected connection of that type.

**Starting workflows**
- `Operation.start` on a standard connection raises `QubeRails::RealtimeRequired` before writing a
  run or calling QuBe Sync.
- A start QuBe Sync refuses with 422 `realtime_required` keeps its run, as state
  `realtime_required` with `error` `{code, detail}`, rather than failing it. The run status shows
  the detail and the "Try sending again" button, and `run.retry_start!` (or starting again) sends
  it with the same Idempotency-Key once the connection is upgraded: QuBe Sync stores nothing for
  that refusal.

**Questions**
- A rows field (`add_transaction`'s `ask_missing`) of two records or more asks one record at a
  time: a step count ("1 of 3", `aria-live`), Back and Next in the form's button row (see
  Changed), the question's submit on the last record only, "Set all to:" hidden. Every record
  stays in the form, so the answer is still one POST with every row. It needs the script (see
  Changed). New keys `question.step`, `question.back`, `question.next`; the rows partial carries
  them and the `button` / `button_secondary` classes as `data-qube-*` attributes.
- The question screen has no horizontal rules: its sections (the details, the choices, the footer,
  each record of a rows field, the "or" between choices) are set apart by space alone.
- Choices are weighed by the `role` QuBe Sync now sends with each (`pick`, `search`, `decline`,
  `cancel`, `answer`): the offered records as option rows with no heading of their own (the
  question's message says what they are), the first one's "Use this one" the screen's primary button and the
  rest secondary; a search after them, a branch at a time (see below), or a section of its own
  when nothing is offered; decline in the footer; cancel at the start of the footer row, as a ghost. An answer shows by its shape, as before. Without roles (an
  older QuBe Sync), choices show by their shape as before. `ChoiceView#role` and `#cancel?`,
  `QuestionView#roles?`, `#matches?` and `#ui_text` (the one lookup for the engine's new words,
  "Possible matches" and the step line; `RowsView#ui_text` defers to it); forms carry
  `data-qube-choice-role`. New CSS only for cancel's place in the footer row; the heading and
  buttons use classes the stylesheet already styles.
- Offered records with a search (a chain, `QuestionView#chain?`) show a branch at a time. The
  offered records come first, the footer row holding cancel and "Not this one" / "None of these"
  (new key `question.none_of_these`, `data-qube-branch="search"`); that swaps them for the search,
  with "← Back to the possible match" / "← Back to the %{count} possible matches" above it (new key
  `question.back_to_offered`, `.qube-branch-back`, `data-qube-branch="offered"`), its button row
  holding cancel, the decline and its submit (the footer's forms, through `form=`). Moving to the
  search focuses its box, Back the first record, and what was typed or picked stays. A refusal of
  the search's answer starts on the search. Each part carries `data-qube-branch-part` ("offered" or
  "search"), `hidden` when not on show; `QuestionView#branch`, `#branch_part`, `#shown_part?`,
  `#offered_count`, `#joined_exits`, `#divided?`. Without the script a chain shows the records and
  a footer of cancel and the decline, as forms that post. Other questions are unchanged.
- Motion for a chain: a branch the person moves to comes in from its side over 200 ms (the
  search from the right, the records from the left; the script sets `data-qube-branch-moved`, so
  a page load is still), and "Use this one" fades in as a match is picked. With reduced motion
  both only fade.
- A search's button row that also holds the decline puts its end on top and cancel under it in a
  question narrower than 44rem, before and after a pick, so "Use this one" arriving moves nothing.
- A search's submit ("Use this one") is hidden until a match is picked (`ChoiceView#waits_for_pick?`),
  then shows as the primary button; after a search of two characters or more that finds nothing,
  the decline is the primary button until a pick or a search that finds matches. Until either,
  nothing in that row is primary.
- `question.step` reads "%{position} of %{count}" ("1 of 2"): the record's block already names its
  kind. A `%{name}` in your own wording still works.
- The storyboard's questions carry roles and QuBe Sync's current wording ("It's not in QuickBooks",
  "Not listed? Search QuickBooks", "Don't add the invoice").

**Run status**
- `run.headline`, every event's sentence for a person (`qube_runs.headline`), shown for an ended
  run whose reason doesn't already say it (`.qube-run-headline`).
- `Run#with_errors?`: an outcome such as `push_records`' `pushed_with_errors` reads "Done, but some
  didn't go through" (`status.done_with_errors`) and adds `.qube-run-with-errors`.

### Changed

**The question's layout: one button row**
- A form choice ends in one button row (`.qube-choice-actions`, new `ui_classes` piece
  `choice_actions`): cancel at the start, as a ghost; at the end, the right edge of the fields
  above, the submit with any other exit beside it. When a question has one form, no picks and no
  exit with a description, its exits' buttons join that row and submit their own (hidden, empty)
  forms through the `form` attribute, so it works without the script; new partials
  `question/_submit` and `question/_exit_button`. Otherwise the exits have their own row, laid out
  the same way: cancel at the start, decline and the like at the end, or stacked with cancel last
  when they have descriptions. Cancel is now always at the start (it was at the far right, or the
  left when it had a description).
- A rows field in steps puts its step count ("2 of 3"), Back and Next in that row, before the
  submit, instead of a step line above the records and a row of its own; the row reads cancel …
  2 of 3, Back, Next (or the submit on the last record).
- The question card has sections: a hairline under what it's about, another above the way out
  (the exits' row, or a lone form's button row). A card that is one form is as wide as the form;
  a chain's search keeps the width its offered records had.
- Beside full-width picks (a near match, a name clash) a form takes the full width too, so its
  submit shares the picks' and exits' right edge.
- A form's fields and button row share one column (`--qube-form-width`, 36rem; a rows field takes
  the whole width), so the submit lines up with the fields' right edge.
- On a narrow question (a container under 30rem) the row's end comes first, its buttons filling
  the line, and cancel goes under it.
- A choice promoted to an option row (name clash's "Use the existing record") ends in a secondary
  "Use this one" button, as an offered record's does, not a link.
- The question card keeps a gap under the record's status when it follows it.

**Decisions from the review**
- No submit or Next is disabled any more: the browser's own validation (required fields, a search's
  "Pick one of the matches.") says what's missing and focuses it, and Next on an incomplete record
  does the same.
- A field that isn't required says "(optional)" after its label (`question.optional`); a checkbox
  doesn't.
- After a cancel is posted the status reads "Cancelling…" (`status.cancelling`, run state
  `cancelling`, the engine's own) until the run's next event; a quiet one offers redelivery as a
  running one does.
- A rows field needs the script: it and its submit are hidden until the script runs, and a
  `<noscript>` line says answering needs JavaScript (`question.needs_script`). Cancel still works.
- A ghost button with no `button_ghost` piece takes no host class (it took `button_secondary`'s), so
  cancel and "← Back to the possible match" keep the engine's quiet look.

**Styling and Tailwind**
- The stylesheet sits in the `components` cascade layer, after declaring `@layer theme, base,
  components, utilities;`. Unlayered, the engine's rules beat every Tailwind v4 utility class
  (`ui_classes` couldn't change a padding or a background); now utilities and any unlayered app CSS
  win, and Tailwind v4's preflight (`@layer base`) still doesn't strip the engine's look. Tailwind
  v3's preflight is unlayered and does reset borders, button backgrounds and paddings: give those
  pieces classes, or use v4 (README, "Styling").
- The generated initializer, `Configuration#ui_classes=` and the README show Tailwind classes first;
  Bootstrap is a second, shorter example (with `form-check-input mt-0`).
- `qube_rails_assets` adds `data-turbo-track="reload"` to both tags: under Turbo Drive a page kept
  the old script after an update (and the script's once-per-page guard skipped the new one), which
  is how a browser could still show Back and the submit on two rows after that fix.


- A failed run's `error` is QuBe Sync's `{code, type, message, quickbooks_message, hint}`:
  `reason_text` is its message and `error_detail` its hint. An error stored by 0.2.0 (a sentence,
  or code, message and detail) still reads.
- A run's `cancel_url` is cleared when it ends; `links.decisions` and `links.search` may be absent.
- A `rows` field's boolean columns answer `true` or `false`, not the text `"true"`.
- The storyboard's sample prompts drop `options`, which run webhooks no longer carry.

### Fixed

- A start keeps the run's `run_url`: it's read from the start answer's `links.self` (a
  `WorkflowRun`'s), falling back to `links.run` (a webhook's). 0.2.0 read only `run`, so it stayed
  nil.
- A start QuBe Sync refuses with a 4xx (other than 409 and `realtime_required`) keeps why on the
  failed run: `error` is `{code: "refused", message, detail}`, the message a sentence from the
  answer's body (field errors joined, or its sentence) and the detail its status. The run status
  shows it in place of "it couldn't be sent".
- A search's picked match shows as the selection: a check in the box and an accent edge
  (`data-qube-picked`, set by the script), cleared as soon as the text changes.
- `link_references` takes add_transaction's new shapes (QuBe Sync's docs/workflow-record-events.md): a
  `records` notification (`data.records`, each with `paths`, `action`, `kind`, `sent` and `record`,
  linked as each pass settles them, with the record's name and edit sequence) or an ending's
  `output.refs` (`{path => {list_id, type}}`). The block still gets the path and an entry
  (`list_id`, `type`, and from a notification `kind`, `action`, `full_name`, `edit_sequence`, `sent`).
  `output.references` is no longer read: QuBe Sync doesn't send it.
- A search box focused empty (or cleared) lists the first active records of its list (QuBe Sync's
  search with `q` empty), so an account can be picked without knowing its name; the search route
  passes an empty `q` through.
- A rows column's `default` (QuBe Sync's new prompt key, one of its `enum` values) starts checked or
  selected, and counts for the other columns' `when`, so add_transaction's missing records start at
  "Create it". A blank rows label shows no heading. The storyboards' cancel reads "Cancel adding the
  invoice", with no note.
- A ghost button's description (Cancel's "Stop here. Nothing is created.") starts where the
  button's text does. The storyboard's missing-records question uses QuBe Sync's new wording.
- Motion in the question: a pick's check pops in (240ms) and the box's tint eases in; fades only
  under reduced motion.
- A pick's detail wraps between its parts (`similar name ·`, the email, the phone), each a
  `.qube-detail-part`, so a phone number no longer breaks across lines and no line starts with
  the separator.
- An exit's hidden form beside a lone form (`detached`) no longer takes a row of the choices' grid,
  which left blank space under the buttons: `.qube-choice` set `display` and won over `hidden`. The
  layer's last rule now hides a `hidden` `.qube-choice`, `.qube-choice-button` and
  `[data-qube-branch-part]` (zero specificity, so it has to come after the rules that set display).
- A search box with text but no pick shows its error edge once the focus leaves it, not while
  it's being typed in (after a first try it was red through every later search).
- A search's "No matches" or failed-search note is a line under the box, in flow, not a floating
  list over the buttons below it.
- On the last record of a rows field, Back and the question's submit share a row: the step nav
  (`data-qube-step-nav`) now sits where the form's submit was and holds it, after Back and Next.
- After a 409 (or a 400 such as `not_awaiting_input`) for an answer, the run reads as running
  ("Syncing with QuickBooks") rather than "Needs your answer" with no question shown, and the
  message (new key `errors.question_moved_on`) no longer says the page shows the latest. A newer
  question already on the run is left alone. In 0.2.0 too. A one-shot error now shows under the
  status line, inside the status block, not above it.
- "Use for all N" is now "Use for the other record too" / "Use for the other %{count} records too"
  (`question.use_for_all`, pluralized; a plain string still works), and once pressed it's replaced
  by a note, "Also filled in on the other record." (new key `question.used_for_all`), until the
  value changes. A record filled while hidden in a later step flashes the fill tint as it comes on
  show, so nothing changes out of sight unannounced.
- A refused answer (422) keeps what was typed: the choice's text, number, select and checkbox
  fields come back filled, marked `aria-invalid` and described by the refusal, which now shows
  inside the question rather than above the run status. The refusal travels in
  `flash[:qube_rails_refusal]` (`token`, `choice`, `message`, `values`), shown only on the question
  it was for; values over 1,000 characters aren't kept (cookie sessions). `_error` takes an `id:`.
- Phone width: a wrapped button no longer touches its border (`.qube-choice-button` has 8px block
  padding, `box-sizing: border-box`); under 30rem an offered record's "Use this one" goes under its
  text, full width, so an email in its detail isn't broken mid-word; a search match's detail is
  split into `.qube-detail-part`s like a pick's, so a phone number doesn't break at its hyphen.
- With a host class on the search input (Bootstrap's `form-control`), the picked check no longer
  overlaps the text: the script sets the room for it inline. A segment's label stays centred when
  a reset sets `label { display: inline-block }` (padding and `text-align`, not flex alone).
- A select starts on "Choose…" (new key `question.choose`) rather than a blank row.
- A search the route answers 409 (the question changed) says "This question has changed. Reload
  the page to see the latest." (new key `question.search_changed`, `data-qube-text-search-changed`)
  rather than "No matches"; any other failed answer says the search isn't available.

### Compatibility

Matches QuBe Sync's reshaped workflow-run webhooks (qube PR #61): the error object, `headline`,
an `output` per outcome without `output.outcome` (add_transaction's `added` keeps `record`;
`link_references` now reads `output.refs` or a `records` notification, under Changed, and no
longer `output.references`), links only while they work, no
`prompt.options`, and `summary.changes` in place of `summary.side_effects` (the engine read
neither). Webhooks in the old shape are still read. The start's 422 `realtime_required` answer is
the same before and after that change.

## 0.2.0 (2026-10-27)

A rewrite on QuBe Sync's v2 API. The engine now holds the code QuBe Sync's integration kit used to
generate into every Rails app (the webhook endpoint, onboarding, questions, connections, runs and
QuickBooks ids), so your app keeps only its own operations, its connection events class and one
initializer, and gets fixes with `bundle update qube_rails`. Nothing from 0.1.0 carries over.

### Added

**Install and configure**
- `rails g qube_rails:install`: the initializer, your app's `QuickbooksDesktop::ConnectionEvents`,
  the engine's migrations and the mount line (`mount QubeRails::Engine => "/"`).
- `QubeRails.configure` in `config/initializers/qube_rails.rb`: operations, connection_events,
  current_account, authorize_question, enqueue, queue, dedupe, parent_controller and the API
  settings. A setting left unset raises `QubeRails::NotConfigured` naming that file.

**Connections and onboarding**
- Engine tables and models, from `bin/rails qube_rails:install:migrations`:
  `QubeRails::Connection` (`qube_connections`; an account can have any number, one per company
  file), `QubeRails::Run` (`qube_runs`: each run's reference, revision, state and question) and
  `QubeRails::QuickbooksRecord` (`qube_quickbooks_records`: QuickBooks ids by connection). Your
  own tables need no QuBe Sync columns. JSON is stored as text, the same on PostgreSQL, MySQL and
  SQLite.
- Onboarding routes: `POST quickbooks/connections` (Connect) and
  `POST quickbooks/connections/:id/onboarding`. Connect reuses the account's newest
  never-connected connection; `new=1` makes another.
- Onboarding makes realtime connections (`config.connection_type`, `"realtime"` by default),
  since workflows run only on realtime connections.
- Connect with `simulated=1`, outside production, makes a connection to a simulated QuickBooks
  company file, connected as soon as it's made, for testing without a Windows computer.
- A connection event for a row that doesn't have its QuBe Sync id yet adopts the QuBe Sync
  connection made with that row's webhook URL and name, created at or after the row (a
  never-connected or simulated one), or raises `QubeRails::NotReady` to be retried.
- `DELETE quickbooks/connections/:id` (`connection_path`) disconnects a connection: QuBe Sync's
  first, then the row with its runs, requests and links (`Connection#disconnect!`), after
  `ConnectionEvents#disconnected`, where your app deletes its own rows that point at it.

**Starting workflows**
- `QubeRails::Operation`, the base of your operations: `start(record, connection)` returns the
  run. A record's run that hasn't ended on that connection is returned (`run.reused?`) rather
  than a second one started, so a double click can't add an invoice twice; an unconfirmed start
  is sent again with the same reference (the Idempotency-Key) and input.
- A start that gets no answer stays `starting` with its input; `Run#retry_start!` and
  `Operation.retry_start` resend it with the same Idempotency-Key. Only a 4xx, or an input that
  raised, marks a run failed.
- `Operation#quickbooks_ref` and `#link_references`, and `QubeRails::MissingReference`, raised
  from `input` when a reference QuickBooks requires has no link and no name, so the start fails
  before anything is sent.
- Typed workflow starts: `bin/rails g qube_rails:workflows [--drafts] [--check]` writes
  `app/qube/qube_workflows.rb` (`QubeWorkflows`, autoloaded) and `sig/qube_workflows.rbs` from
  your app's workflow input types, with a typed start and input method per workflow and branch.
  `Operation#input` can return one of those input methods' Hashes. `--check` exits 1 when the
  file is out of date or the API key is refused, and warns but passes when QuBe Sync can't be
  reached.
- A start QuBe Sync refuses because the connection isn't realtime raises
  `QubeRails::RealtimeRequired`, whose message says how to upgrade.

**Plain requests**
- `QubeRails::Request`, the base of a plain v2 request (`OPERATION`, `SLUG`, `params`, and the
  handlers `answered`, `done`, `failed`, `retrying`, `timed_out`). `.queue(record, connection)`
  returns a `QubeRails::QueuedRequest`: one at a time per record, slug and connection, its
  reference the Idempotency-Key, `retry_queue!` to send it again. Their webhooks arrive at
  `POST webhooks/qube/requests/:id`; each delivery is taken once by `page_request_id:state`, and
  `done` fires once every page is in.

**Webhooks**
- The webhook endpoint, `POST webhooks/qube/runs/:id` and `POST webhooks/qube/connections/:id`,
  verifies each delivery and hands it to `QubeRails::WebhookJob` (ActiveJob), or to
  `QubeRails.run(kind, id, body)` from your own queue. It answers 503 when the enqueue fails, so
  QuBe Sync retries. A refused delivery's log line names its path and what to check (the webhook
  secret, the clock, or a sender that isn't QuBe Sync).
- The reference, connection id, revision and delivery id are checked under the row's lock, and
  notifications are deduplicated in the engine's `qube_notifications` table in the same
  transaction as your handler, so a handler that raises runs again on the redelivery
  (`QubeRails::CacheDedupe` is an option). `WebhookJob` retries (`job_attempts`, default 10) and
  logs when it gives up. A delivery for a deleted run, connection or record is logged and dropped.
- `QubeRails::ConnectionEvents`, the base of your connection events class.

**Questions**
- The question routes, `POST qube/questions/runs/:id` and `GET .../search`, and the
  `qube_rails/_question.html.erb` partial showing a record's latest run's question, which you can
  override. `authorize_question` defaults to allowing only the account that owns the run's
  connection; a refused one answers 404.
- When a question changed after the page showed it, the answer isn't sent and the page says
  where it stands now.
- A rows field (the missing-records question) shows a block per record: its choice ("Create it",
  "Use an existing one") as a segmented control, then only the fields that choice needs, with a
  search per record column. "Set all to" and "Use for all N" fill every record at once. It never
  scrolls sideways. A fixed list shows as a select.
- A question whose answer QuBe Sync took is `running` again at once (`Operation#answered(token,
  taken: true)`), rather than waiting for the Web Connector's next poll.

**Runs and sync status**
- Every ending is kept on the run (state, outcome, error, cancel reason, ended at) before your
  handler runs: `Run#ended?`, `#failed?`, `#cancelled?`, `#summary_text`, and the
  `qube_rails/run_status` partial (taking `connection:`). A start unconfirmed for a minute reads
  "Still waiting for QuickBooks" with a "Try sending again" button
  (`POST qube/runs/:id/retry_start`).
- A run that looks stuck (`Run#looks_stuck?`) gets a "Check for updates" button, which has QuBe
  Sync send its latest event again (`POST qube/runs/:id/redeliver`).
- While the connection a sending run waits on is stalled, the status reads "Waiting for
  QuickBooks" and says why and what to do. `connection.stalled` and `connection.resumed` refresh
  the pages of records with a run going on that connection.
- Sync status, derived from runs and links and never stored:
  `connection.sync_status(record, operation:)` (`QubeRails::SyncStatus`: `:not_sent`,
  `:sending`, `:needs_answer`, `:in_quickbooks`, `:done`, `:failed`, `:cancelled`, with `qb_id`,
  `error` and `retry?`), `SyncStatus.latest`, and the connection's scopes `in_quickbooks`,
  `not_in_quickbooks`, `needing_answer` and `sending`. Tested on SQLite, PostgreSQL and MySQL.
- The partials show why an answer or a retried start didn't go through, and with turbo-rails 2
  a record's pages refresh when an event changes its run, and once more 5 seconds later
  (`QubeRails::RefreshJob`) for a page that was still loading.
- `config.prune_runs_after` and `QubeRails::PruneRunsJob`: opt-in pruning of ended runs and
  requests (`Run.prunable`), never within a day of their end; links stay. `qube_sync_marks` keeps
  when each connection's last completed run of a workflow started
  (`Connection#last_synced_at(workflow)`, `Operation#last_synced_at`), so a sync's next `since`
  outlives pruned runs.

**Screens and styling** (README, "Styling")
- The question and run status partials (`render "qube_rails/question"`, `render
  "qube_rails/run_status"`) are made of small pieces under `qube_rails/question/*`,
  `qube_rails/run_status/*` and `qube_rails/_error`, each overridable at its path and rendered
  from view-models whose fields are the contract (`QubeRails::QuestionView`, `ChoiceView`,
  `FieldView`, `RowsView`, `RowView`, `CellView`, `RunStatusView`). A question's choices show by
  kind: suggested records as option rows, each form in its own section with the one filled
  button, and "None of these" and "Cancel" in a footer.
- `config.ui_classes`: your CSS framework's classes by piece, beside the `qube-` classes; an
  unknown piece raises.
- `<%= qube_rails_assets %>` in your layout (`rails g qube_rails:install` adds it) serves the
  behaviour script `qube_rails/question.js` (search boxes, rows fields), keyed only on
  `data-qube-*` attributes, so it works on any markup, after Turbo navigation, with no CSP nonce.
  `qube_rails_assets stylesheet: true` adds the opt-in stylesheet `qube_rails.css`: zero
  specificity, themed by `--qube-*` variables, light and dark, no global styles.
- The screens never name QuBe Sync, runs, webhooks or ListIDs to your users, and every word comes
  from I18n under `qube_rails.*` (`config/locales/en.yml`; `QubeRails.t`), so you can reword or
  translate them.
- The storyboard, `GET qube/storyboard(/:screen)` (`config.storyboard`, on in development):
  every screen from sample data, in your layout, with each piece's override path. Nothing is sent
  or saved.

**QuickBooks ids**
- `Connection#link`, `#qb_id_for`, `#find_linked(qb_id, kind: nil)` and
  `#quickbooks_record(qb_id, kind: nil)`. QuickBooks ids are kept by connection and list family
  (`QuickbooksRecord.family_for`: one family for customers, vendors, employees and other names,
  one for items, and each other list or transaction type its own), since QuickBooks gives out
  ListIDs that way.

### Changed
- Needs Ruby 3.3, Rails 7.0 and qube_sync 0.5.0 or later. The source stays Ruby 2.7 and Rails
  5.2 compatible, and every call to qube_sync goes through `QubeRails::Backend`, so the kit can
  vendor it into older apps.

### Removed
- Everything from 0.1.0 (v1): the generator's models, migrations, controllers and jobs, and the
  path dependency on qube_sync.

## 0.1.0 (2024-01-21)

The v1 engine: generated QuickBooks entity models, connection and request tables, and a webhook
job for customer queries.
