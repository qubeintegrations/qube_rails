// qube_rails: the behaviour of a QuickBooks question (search boxes, a rows field) and the
// storyboard's copy buttons. Listeners sit on document and key only on data-qube-* attributes, so
// any markup carrying them works, after Turbo navigation too. Plain JavaScript, no build. README,
// "Styling", has the attribute contract.
(function () {
  if (window.qubeRailsQuestion) return; // loaded once per page, however often it's included
  window.qubeRailsQuestion = true;

  var each = function (list, fn) { Array.prototype.forEach.call(list, fn); };
  var timers = new WeakMap();
  var slow = new WeakMap();
  var asked = new WeakMap();
  var uid = 0;

  // A word from the element's data-qube-text-<name> (the app's I18n), else English.
  var words = function (el, name, fallback) {
    return (el && el.getAttribute("data-qube-text-" + name)) || fallback;
  };

  // ---- Search: [data-qube-search] holds [data-qube-search-input], [data-qube-search-value] and
  // [data-qube-search-results]. It's a combobox: arrows move through the matches, Enter picks,
  // Escape or leaving the box closes them.

  var parts = function (box) {
    return {
      input: box.querySelector("[data-qube-search-input]"),
      value: box.querySelector("[data-qube-search-value]"),
      results: box.querySelector("[data-qube-search-results]")
    };
  };

  // Until a match is picked, the form won't send what was typed.
  var check = function (box, p) {
    var unpicked = p.input.value && !p.value.value;
    p.input.setCustomValidity(unpicked ? words(box, "pick-a-match", "Pick one of the matches.") : "");
  };

  var searchUrl = function (box, q) {
    var url = box.getAttribute("data-qube-search");
    url += (url.indexOf("?") === -1 ? "?" : "&") +
      "field=" + encodeURIComponent(box.getAttribute("data-qube-field") || "") +
      "&q=" + encodeURIComponent(q);
    var row = box.getAttribute("data-qube-row");
    if (row) url += "&row=" + encodeURIComponent(row);
    return url;
  };

  var options = function (p) {
    return p.results.querySelectorAll("[data-qube-search-result]");
  };

  var highlighted = function (p) {
    return p.results.querySelector('[data-qube-search-result][aria-selected="true"]');
  };

  // Highlights one match (or none): instant, no animation, scrolled into view from the keyboard.
  var highlight = function (p, option, scroll) {
    each(options(p), function (o) { o.setAttribute("aria-selected", o === option ? "true" : "false"); });
    if (option) {
      p.input.setAttribute("aria-activedescendant", option.id);
      if (scroll && option.scrollIntoView) option.scrollIntoView({ block: "nearest" });
    } else {
      p.input.removeAttribute("aria-activedescendant");
    }
  };

  var setOpen = function (box, p, open, listbox) {
    if (open) box.setAttribute("data-qube-open", "");
    else box.removeAttribute("data-qube-open");
    p.input.setAttribute("aria-expanded", listbox ? "true" : "false");
    if (listbox) p.results.setAttribute("role", "listbox");
    else p.results.removeAttribute("role");
    if (!listbox) p.input.removeAttribute("aria-activedescendant");
  };

  var stopTimers = function (box) {
    clearTimeout(timers.get(box));
    clearTimeout(slow.get(box));
  };

  // Closes the matches at once; an answer still on its way is dropped.
  var close = function (box) {
    var p = parts(box);
    if (!p.input || !p.results) return;
    stopTimers(box);
    asked.set(box, (asked.get(box) || 0) + 1);
    p.results.textContent = "";
    setOpen(box, p, false, false);
  };

  // A line in place of the matches: "No matches", "Searching…", or that the search failed.
  var note = function (box, p, text, kind) {
    var line = document.createElement("div");
    line.setAttribute("data-qube-search-note", kind);
    line.textContent = text;
    p.results.textContent = "";
    p.results.appendChild(line);
    setOpen(box, p, true, false);
  };

  var showMatches = function (box, p, matches) {
    if (!matches.length) return note(box, p, words(box, "no-matches", "No matches"), "empty");
    if (!p.results.id) p.results.id = "qube-search-results-" + (++uid);
    p.input.setAttribute("aria-controls", p.results.id);
    var className = box.getAttribute("data-qube-result-class") || "qube-search-result";
    p.results.textContent = "";
    matches.forEach(function (match, n) {
      var pick = document.createElement("button");
      pick.type = "button";
      pick.tabIndex = -1;
      pick.id = p.results.id + "-" + n;
      pick.className = className;
      pick.setAttribute("role", "option");
      pick.setAttribute("aria-selected", "false");
      pick.setAttribute("data-qube-search-result", "");
      pick.setAttribute("data-value", match.value);
      pick.setAttribute("data-label", match.label);
      var label = document.createElement("span");
      label.textContent = match.label;
      pick.appendChild(label);
      if (match.detail) {
        var detail = document.createElement("span");
        detail.setAttribute("data-qube-search-detail", "");
        detail.textContent = match.detail;
        pick.appendChild(detail);
      }
      p.results.appendChild(pick);
    });
    setOpen(box, p, true, true);
  };

  var search = function (box) {
    var p = parts(box);
    if (!p.input || !p.value || !p.results) return;
    p.value.value = "";
    check(box, p);
    stopTimers(box);
    var n = (asked.get(box) || 0) + 1;
    asked.set(box, n);
    var q = p.input.value.trim();
    if (q.length < 2) {
      p.results.textContent = "";
      setOpen(box, p, false, false);
      return;
    }
    // The matches shown stay until the new ones come; "Searching…" only for a slow answer.
    timers.set(box, setTimeout(function () {
      slow.set(box, setTimeout(function () {
        if (asked.get(box) === n) note(box, p, words(box, "searching", "Searching…"), "loading");
      }, 150));
      fetch(searchUrl(box, q), { headers: { Accept: "application/json" }, credentials: "same-origin" })
        .then(function (res) { return res.ok ? res.json() : []; })
        .then(function (matches) {
          if (asked.get(box) !== n) return; // a later search, or a close, since
          clearTimeout(slow.get(box));
          showMatches(box, p, matches);
        })
        .catch(function () {
          if (asked.get(box) !== n) return;
          clearTimeout(slow.get(box));
          note(box, p, words(box, "search-failed", "Search isn't available right now."), "failed");
        });
    }, 250));
  };

  var pick = function (button) {
    var box = button.closest("[data-qube-search]");
    var p = parts(box);
    p.value.value = button.getAttribute("data-value");
    p.input.value = button.getAttribute("data-label");
    close(box);
    check(box, p);
    p.value.dispatchEvent(new Event("change", { bubbles: true }));
    box.dispatchEvent(new CustomEvent("qube:picked", { bubbles: true }));
    gate(box.closest("form"));
  };

  var keys = function (event, box) {
    var p = parts(box);
    if (!p.results) return;
    var list = options(p);
    var current = highlighted(p);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (!list.length) return;
      event.preventDefault();
      var at = Array.prototype.indexOf.call(list, current);
      var step = event.key === "ArrowDown" ? 1 : -1;
      var next = at === -1 ? (step === 1 ? 0 : list.length - 1) : (at + step + list.length) % list.length;
      highlight(p, list[next], true);
    } else if (event.key === "Enter") {
      if (current) {
        event.preventDefault(); // picks, rather than sending the form
        pick(current);
      }
    } else if (event.key === "Escape") {
      if (box.hasAttribute("data-qube-open")) {
        event.preventDefault();
        close(box);
      }
    }
  };

  // ---- A form choice whose required fields are all searches: its submit waits for a pick
  // (disabled here, never in the markup, so it still posts without the script).

  var gated = function (form) {
    var required = form.querySelectorAll("input[required], select[required], textarea[required]");
    if (!required.length) return false;
    return Array.prototype.every.call(required, function (input) { return input.matches("[data-qube-search-input]"); });
  };

  var gate = function (form) {
    if (!form || !form.matches('[data-qube-choice-kind="form"]') || !gated(form)) return;
    var picked = Array.prototype.every.call(form.querySelectorAll("[data-qube-search]"), function (box) {
      var p = parts(box);
      return !p.input || !p.input.required || (p.value && p.value.value);
    });
    each(form.querySelectorAll('button[type="submit"], input[type="submit"]'), function (button) {
      button.disabled = !picked;
    });
  };

  // ---- Rows: [data-qube-rows] holds records ([data-qube-row][data-qube-values]), their fields
  // ([data-qube-col], with data-qube-when, data-qube-required) and inputs ([data-qube-rows-input]),
  // the "Set all to:" line ([data-qube-rows-set-all="<column>"] with [data-qube-set-all="<value>"]
  // buttons) and each field's "Use for all" ([data-qube-use-for-all]).

  var rowsOf = function (list) {
    return list.querySelectorAll("[data-qube-row][data-qube-values]");
  };

  // A row's answers so far: its preset values, then its shown inputs (a radio when it's checked).
  var answers = function (row) {
    var values = JSON.parse(row.getAttribute("data-qube-values") || "{}");
    each(row.querySelectorAll("[data-qube-col] [data-qube-rows-input]"), function (input) {
      if (input.disabled || (input.type === "radio" && !input.checked)) return;
      if (input.value) values[input.closest("[data-qube-col]").getAttribute("data-qube-col")] = input.value;
    });
    return values;
  };

  var holds = function (when, values) {
    return Object.keys(when).every(function (k) { return when[k].indexOf(values[k]) !== -1; });
  };

  // Shows or hides a field: hidden, its inputs disabled and not required, so it's neither sent nor
  // asked for. The stylesheet fades it in.
  var showCell = function (cell, shown) {
    if (shown === !cell.hidden) return false;
    cell.hidden = !shown;
    if (shown) cell.removeAttribute("data-qube-hidden");
    else cell.setAttribute("data-qube-hidden", "");
    var required = cell.hasAttribute("data-qube-required");
    each(cell.querySelectorAll("input, select, textarea"), function (input) {
      input.disabled = !shown;
      if (required && input.type !== "hidden") input.required = shown;
    });
    return true;
  };

  // Shows each field while its "when" holds, until nothing changes (a field shown or hidden can
  // change what the others see).
  var refresh = function (row) {
    for (var round = 0; round < 5; round++) {
      var values = answers(row);
      var changed = false;
      each(row.querySelectorAll("[data-qube-col]"), function (cell) {
        var shown = holds(JSON.parse(cell.getAttribute("data-qube-when") || "{}"), values);
        if (showCell(cell, shown)) changed = true;
      });
      if (!changed) return;
    }
  };

  // A tint on what was just filled for the person, fading out (the stylesheet's animation).
  var filled = function (cell) {
    cell.removeAttribute("data-qube-filled");
    void cell.offsetWidth; // restarts it
    cell.setAttribute("data-qube-filled", "");
  };

  // A field's value and, for a search, the text it shows.
  var valueOf = function (cell) {
    var hidden = cell.querySelector("[data-qube-search-value]");
    if (hidden) {
      var text = cell.querySelector("[data-qube-search-input]");
      return { value: hidden.value, label: text ? text.value : hidden.value };
    }
    var select = cell.querySelector("select[data-qube-rows-input]");
    return { value: select ? select.value : "", label: null };
  };

  var setValue = function (cell, value) {
    var hidden = cell.querySelector("[data-qube-search-value]");
    if (hidden) {
      hidden.value = value.value;
      var text = cell.querySelector("[data-qube-search-input]");
      if (text) {
        text.value = value.label || value.value;
        text.setCustomValidity("");
      }
      return;
    }
    var select = cell.querySelector("select[data-qube-rows-input]");
    if (select) select.value = value.value;
  };

  // The other rows' shown, empty fields of the same column.
  var targets = function (list, cell) {
    var col = cell.getAttribute("data-qube-col");
    var row = cell.closest("[data-qube-row]");
    return Array.prototype.filter.call(list.querySelectorAll("[data-qube-row] [data-qube-col]"), function (other) {
      return other.getAttribute("data-qube-col") === col && other !== cell && !other.hidden &&
        other.closest("[data-qube-row]") !== row && other.querySelector("[data-qube-use-for-all]") &&
        !valueOf(other).value;
    });
  };

  // "Use for all N" under each filled field that other rows could take.
  var offers = function (list) {
    var template = list.getAttribute("data-qube-text-use-for-all") || "Use for all %{count}";
    each(list.querySelectorAll("[data-qube-use-for-all]"), function (button) {
      var cell = button.closest("[data-qube-col]");
      var n = !cell || cell.hidden || !valueOf(cell).value ? 0 : targets(list, cell).length;
      button.hidden = n === 0;
      if (n) button.textContent = template.replace("%{count}", n);
    });
  };

  var useForAll = function (button) {
    var cell = button.closest("[data-qube-col]");
    var list = cell.closest("[data-qube-rows]");
    var value = valueOf(cell);
    targets(list, cell).forEach(function (other) {
      setValue(other, value);
      refresh(other.closest("[data-qube-row]"));
      filled(other);
    });
    offers(list);
  };

  // Sets the column on every row that offers that value.
  var setAll = function (button) {
    var list = button.closest("[data-qube-rows]");
    var col = button.closest("[data-qube-rows-set-all]").getAttribute("data-qube-rows-set-all");
    var value = button.getAttribute("data-qube-set-all");
    each(rowsOf(list), function (row) {
      var cell = row.querySelector('[data-qube-col="' + col + '"]');
      if (!cell || cell.hidden) return;
      var radio = Array.prototype.find.call(cell.querySelectorAll('input[type="radio"]'), function (r) {
        return r.value === value;
      });
      var select = cell.querySelector("select[data-qube-rows-input]");
      if (radio && !radio.disabled) {
        if (radio.checked) return;
        radio.checked = true;
      } else if (select && !select.disabled && Array.prototype.some.call(select.options, function (o) { return o.value === value; })) {
        if (select.value === value) return;
        select.value = value;
      } else {
        return;
      }
      refresh(row);
      filled(cell);
    });
    offers(list);
  };

  // Each rows field as the page has it.
  var sweep = function () {
    each(document.querySelectorAll("[data-qube-rows]"), function (list) {
      each(rowsOf(list), refresh);
      offers(list);
    });
    each(document.querySelectorAll('[data-qube-choice-kind="form"]'), gate);
  };

  // ---- The storyboard: [data-qube-copy] copies its value.

  var copy = function (button) {
    var text = button.getAttribute("data-qube-copy");
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(text).then(function () {
      var label = button.textContent;
      button.textContent = button.getAttribute("data-qube-copied") || "Copied";
      setTimeout(function () { button.textContent = label; }, 1200);
    });
  };

  // ---- Listeners

  document.addEventListener("input", function (event) {
    var input = event.target.closest && event.target.closest("[data-qube-search-input]");
    var box = input && input.closest("[data-qube-search]");
    if (box) {
      search(box);
      gate(box.closest("form"));
      var list = box.closest("[data-qube-rows]");
      if (list) offers(list);
    }
  });

  document.addEventListener("keydown", function (event) {
    var input = event.target.closest && event.target.closest("[data-qube-search-input]");
    var box = input && input.closest("[data-qube-search]");
    if (box) keys(event, box);
  });

  // A press on the matches keeps the focus in the input, so picking doesn't close them first.
  document.addEventListener("mousedown", function (event) {
    if (event.target.closest && event.target.closest("[data-qube-search-results]")) event.preventDefault();
  });

  // The pointer highlights what it's over (the same highlight the arrows move).
  document.addEventListener("mousemove", function (event) {
    var option = event.target.closest && event.target.closest("[data-qube-search-result]");
    if (!option || option.getAttribute("aria-selected") === "true") return;
    var box = option.closest("[data-qube-search]");
    if (box) highlight(parts(box), option, false);
  });

  document.addEventListener("focusout", function (event) {
    var box = event.target.closest && event.target.closest("[data-qube-search]");
    if (box && box.hasAttribute("data-qube-open") && !(event.relatedTarget && box.contains(event.relatedTarget))) {
      close(box);
    }
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest) return;
    each(document.querySelectorAll("[data-qube-search][data-qube-open]"), function (box) {
      if (!box.contains(event.target)) close(box);
    });
    var result = event.target.closest("[data-qube-search-result]");
    if (result) return pick(result);
    var setAllButton = event.target.closest("[data-qube-set-all]");
    if (setAllButton) return setAll(setAllButton);
    var forAll = event.target.closest("[data-qube-use-for-all]");
    if (forAll) return useForAll(forAll);
    var copyButton = event.target.closest("[data-qube-copy]");
    if (copyButton) copy(copyButton);
  });

  document.addEventListener("change", function (event) {
    var target = event.target;
    if (!target.closest) return;
    var row = target.closest("[data-qube-rows] [data-qube-row][data-qube-values]");
    if (!row) return;
    refresh(row);
    offers(row.closest("[data-qube-rows]"));
  });

  ["DOMContentLoaded", "turbo:load", "turbo:render", "turbo:frame-load"].forEach(function (name) {
    document.addEventListener(name, sweep);
  });
  if (document.readyState !== "loading") sweep();
})();
