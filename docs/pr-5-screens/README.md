# PR #5 screens

Every question screen the engine draws, rendered in headless Chrome (2x) from the storyboard
(`GET /qube/storyboard/<screen>`) and the dummy app's invoice page, for review of
[PR #5](https://github.com/qubeintegrations/qube_rails/pull/5). Screens 19 to 30 and a few others use extra
sample prompts built from the shipped charts in QuBe Sync's `priv/workflows/templates/` (not added to the engine).

| # | Screen | What it shows | Image |
| --- | --- | --- | --- |
| 01 | Near match (resolve ask) | roles pick, search (behind the disclosure), decline, cancel | [01-near-match-pick-search-decline-cancel.png](01-near-match-pick-search-decline-cancel.png) |
| 02 | Search opened, empty box focused | disclosure open; QuBe Sync's browse (empty q lists first records) | [02-near-match-search-opened-browse.png](02-near-match-search-opened-browse.png) |
| 03 | Search with results | typed q, matches with details | [03-near-match-search-results.png](03-near-match-search-results.png) |
| 04 | Keyboard highlight | ArrowDown moves the highlighted match | [04-near-match-search-keyboard-highlight.png](04-near-match-search-keyboard-highlight.png) |
| 05 | No matches | search answered [] | [05-near-match-search-no-matches.png](05-near-match-search-no-matches.png) |
| 06 | Picked match | check, tint, the search form's own submit enabled | [06-near-match-search-picked.png](06-near-match-search-picked.png) |
| 07 | Search failed | fetch network error | [07-near-match-search-failed.png](07-near-match-search-failed.png) |
| 08 | Searching… | slow answer (>150 ms) | [08-near-match-search-slow-searching.png](08-near-match-search-slow-searching.png) |
| 09 | Unpicked text | typed text but no pick: submit disabled, input invalid | [09-near-match-unpicked-text-submit.png](09-near-match-unpicked-text-submit.png) |
| 10 | Several offered records | first primary, rest secondary | [10-record-search-several-picks.png](10-record-search-several-picks.png) |
| 11 | Search only, nothing offered | search is a section of its own (resolve ask_pick with no active records) | [11-search-only-nothing-offered.png](11-search-only-nothing-offered.png) |
| 12 | Search only, focused | browse list | [12-search-only-browse-focused.png](12-search-only-browse-focused.png) |
| 13 | Pick from a list | storyboard choose | [13-pick-from-a-list.png](13-pick-from-a-list.png) |
| 14 | Prompt without roles | older QuBe Sync: weighed by shape | [14-no-roles-older-qube-sync.png](14-no-roles-older-qube-sync.png) |
| 15 | Enum field | select | [15-enum-select.png](15-enum-select.png) |
| 16 | Number and boolean fields | number + checkbox | [16-number-and-boolean.png](16-number-and-boolean.png) |
| 17 | Required text and number | before submit | [17-required-text-and-number.png](17-required-text-and-number.png) |
| 18 | Required fields left empty | browser validation on submit | [18-required-fields-left-empty.png](18-required-fields-left-empty.png) |
| 19 | resolve ask_name | one required text field, details row | [19-resolve-ask-name.png](19-resolve-ask-name.png) |
| 20 | resolve ask_detail | four optional text fields | [20-resolve-ask-detail-narrow-it-down.png](20-resolve-ask-detail-narrow-it-down.png) |
| 21 | resolve_transaction ask | transaction picks, None of these, Cancel | [21-resolve-transaction-ask.png](21-resolve-transaction-ask.png) |
| 22 | ensure ask_use (name clash) | promoted plain choice + rename form, descriptions | [22-ensure-ask-use-name-clash.png](22-ensure-ask-use-name-clash.png) |
| 23 | upsert 3100 name taken | ensure ask_use for a vendor holding the name | [23-upsert-3100-name-taken.png](23-upsert-3100-name-taken.png) |
| 24 | ensure ask_rename | rename only | [24-ensure-ask-rename.png](24-ensure-ask-rename.png) |
| 25 | ensure ask_rename refused (422) | refusal shown in the question | [25-ensure-ask-rename-refused-422.png](25-ensure-ask-rename-refused-422.png) |
| 26 | add_transaction ask_about_add | lost answer with a candidate | [26-add-transaction-lost-answer.png](26-add-transaction-lost-answer.png) |
| 27 | ask_about_add, no candidates | plain question: decline primary | [27-add-transaction-lost-answer-no-candidates.png](27-add-transaction-lost-answer-no-candidates.png) |
| 28 | record_payment ask_over | plain question, three choices with descriptions | [28-record-payment-overpayment.png](28-record-payment-overpayment.png) |
| 29 | record_payment ask_invoice | open invoices as picks, unapplied form with optional number | [29-record-payment-missing-invoice.png](29-record-payment-missing-invoice.png) |
| 30 | ask_invoice, none open | form + cancel only | [30-record-payment-missing-invoice-none-open.png](30-record-payment-missing-invoice-none-open.png) |
| 31 | Missing record, one row | rows of one: no steps, Create it default | [31-missing-record-one-row-create.png](31-missing-record-one-row-create.png) |
| 32 | Missing record, use existing | Which one search appears | [32-missing-record-use-existing.png](32-missing-record-use-existing.png) |
| 33 | Rows step 1 of 3 | step line, Next, submit hidden | [33-rows-step-1-of-3.png](33-rows-step-1-of-3.png) |
| 34 | Step 1, use existing, searching | row search open | [34-rows-step-1-use-existing-search.png](34-rows-step-1-use-existing-search.png) |
| 35 | Step 1 picked | Next enabled | [35-rows-step-1-picked-next-enabled.png](35-rows-step-1-picked-next-enabled.png) |
| 36 | Step 2 of 3 | item: item type + income account, Back | [36-rows-step-2-of-3-create-item.png](36-rows-step-2-of-3-create-item.png) |
| 37 | Step 2 income account browse | focused empty search | [37-rows-step-2-income-account-browse.png](37-rows-step-2-income-account-browse.png) |
| 38 | Step 2 filled | Use for all 1 | [38-rows-step-2-filled-use-for-all.png](38-rows-step-2-filled-use-for-all.png) |
| 39 | Step 2 inventory part | asset and COGS accounts appear | [39-rows-step-2-inventory-part-extra-accounts.png](39-rows-step-2-inventory-part-extra-accounts.png) |
| 40 | Step 3 of 3 (last) | preset item type, submit shown but disabled | [40-rows-step-3-of-3-last.png](40-rows-step-3-of-3-last.png) |
| 41 | Step 3 complete | submit enabled | [41-rows-step-3-complete-submit.png](41-rows-step-3-complete-submit.png) |
| 42 | Back to step 2 | values kept | [42-rows-back-to-step-2.png](42-rows-back-to-step-2.png) |
| 43 | Final submit | storyboard no-op: Storyboard: nothing was sent. | [43-rows-submitted-nothing-sent.png](43-rows-submitted-nothing-sent.png) |
| 44 | Rows without the script | every record at once, Set all to | [44-rows-without-script.png](44-rows-without-script.png) |
| 45 | Invoice page asking | real dummy-app page: status + question | [45-invoice-page-asking.png](45-invoice-page-asking.png) |
| 46 | Invoice page answered | 200 from decisions: question gone, Syncing | [46-invoice-page-answered.png](46-invoice-page-answered.png) |
| 47 | Asked another | next question after an answer | [47-invoice-page-asked-another.png](47-invoice-page-asked-another.png) |
| 48 | Answer expired (409) | question forgotten, error shown | [48-invoice-page-answer-expired-409.png](48-invoice-page-answer-expired-409.png) |
| 49 | Answer refused (422) | real 422 round trip | [49-invoice-page-answer-refused-422.png](49-invoice-page-answer-refused-422.png) |
| 50 | Cancel posted | after Cancel adding the invoice | [50-invoice-page-cancel-posted.png](50-invoice-page-cancel-posted.png) |
| 51 | Status: waiting for an answer | storyboard run status | [51-status-waiting-for-an-answer.png](51-status-waiting-for-an-answer.png) |
| 52 | Status: cancelled | storyboard run status | [52-status-cancelled.png](52-status-cancelled.png) |
| 53 | One-shot error | question_changed message | [53-one-shot-error.png](53-one-shot-error.png) |
| 54 | Themed (Bootstrap ui_classes + variables): near match |  | [54-themed-bootstrap-near-match.png](54-themed-bootstrap-near-match.png) |
| 55 | Themed: number and boolean |  | [55-themed-bootstrap-number-boolean.png](55-themed-bootstrap-number-boolean.png) |
| 56 | Themed: rows step 2 |  | [56-themed-bootstrap-rows-step-2.png](56-themed-bootstrap-rows-step-2.png) |
| 57 | Dark canvas: near match |  | [57-dark-near-match.png](57-dark-near-match.png) |
| 58 | Dark canvas: rows step 2 |  | [58-dark-rows-step-2.png](58-dark-rows-step-2.png) |
| 59 | Phone 390px: near match |  | [59-phone-near-match.png](59-phone-near-match.png) |
| 60 | Phone 390px: rows step 2 with search open |  | [60-phone-rows-step-2-search.png](60-phone-rows-step-2-search.png) |
| 61 | Phone 390px: record_payment ask_invoice |  | [61-phone-record-payment-missing-invoice.png](61-phone-record-payment-missing-invoice.png) |
| 62 | Phone 390px: resolve ask_detail |  | [62-phone-resolve-ask-detail.png](62-phone-resolve-ask-detail.png) |
| 63 | Keyboard: first Tab | focus ring on the first pick | [63-keyboard-focus-first-tab.png](63-keyboard-focus-first-tab.png) |
| 64 | Search open without the script | the Cancel shows though it can't work | [64-near-match-search-open-without-script.png](64-near-match-search-open-without-script.png) |
