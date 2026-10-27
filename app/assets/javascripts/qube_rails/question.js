// qube_rails: the behaviour of a QuickBooks question (search boxes, the rows table) and the
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

  // ---- Rows: [data-qube-rows] holds rows ([data-qube-row][data-qube-values]), their cells
  // ([data-qube-col], with data-qube-when) and inputs ([data-qube-rows-input]), the row picks
  // ([data-qube-rows-pick], [data-qube-rows-all]), the "Set selected" row ([data-qube-rows-bulk],
  // its count [data-qube-rows-count]) and its cells ([data-qube-bulk]).

  var rowsOf = function (table) {
    return table.querySelectorAll("[data-qube-row][data-qube-values]");
  };

  // A row's answers so far: its preset values, then its inputs.
  var answers = function (row) {
    var values = JSON.parse(row.getAttribute("data-qube-values") || "{}");
    each(row.querySelectorAll("[data-qube-col] [data-qube-rows-input]"), function (input) {
      if (input.value) values[input.closest("[data-qube-col]").getAttribute("data-qube-col")] = input.value;
    });
    return values;
  };

  var holds = function (when, values) {
    return Object.keys(when).every(function (k) { return when[k].indexOf(values[k]) !== -1; });
  };

  // The stylesheet fades it (opacity, then visibility); without it, visibility alone hides it.
  var showCell = function (cell, shown) {
    if (shown) cell.removeAttribute("data-qube-hidden");
    else cell.setAttribute("data-qube-hidden", "");
    cell.style.visibility = shown ? "" : "hidden";
  };

  // Shows a cell while its "when" holds; a hidden one sends nothing and isn't required.
  var refresh = function (row) {
    var values = answers(row);
    each(row.querySelectorAll("[data-qube-col]"), function (cell) {
      var shown = holds(JSON.parse(cell.getAttribute("data-qube-when") || "{}"), values);
      showCell(cell, shown);
      each(cell.querySelectorAll("input, select, textarea"), function (input) { input.disabled = !shown; });
    });
  };

  // The ticks: select-all (indeterminate when some are), each row marked, and "Set selected"
  // shown with its count while any is ticked.
  var picked = function (table) {
    var picks = table.querySelectorAll("[data-qube-rows-pick]");
    var ticked = 0;
    each(picks, function (box) {
      var row = box.closest("[data-qube-row]");
      if (box.checked) ticked++;
      if (row && box.checked) row.setAttribute("data-qube-picked", "");
      else if (row) row.removeAttribute("data-qube-picked");
    });
    var all = table.querySelector("[data-qube-rows-all]");
    if (all) {
      all.checked = ticked > 0 && ticked === picks.length;
      all.indeterminate = ticked > 0 && ticked < picks.length;
    }
    var bulk = table.querySelector("[data-qube-rows-bulk]");
    if (bulk) bulk.hidden = ticked === 0;
    var count = table.querySelector("[data-qube-rows-count]");
    if (count) {
      var text = table.getAttribute(ticked === 1 ? "data-qube-selected-one" : "data-qube-selected-other");
      count.textContent = (text || "%{count} selected").replace("%{count}", ticked);
    }
  };

  // A tint on a cell Apply just filled, fading out (the stylesheet's animation).
  var filled = function (cell) {
    cell.removeAttribute("data-qube-filled");
    void cell.offsetWidth; // restarts it for a second Apply
    cell.setAttribute("data-qube-filled", "");
  };

  // Fills a column on every ticked row that asks it.
  var apply = function (button) {
    var bulk = button.closest("[data-qube-bulk]");
    var table = bulk.closest("[data-qube-rows]");
    var col = bulk.getAttribute("data-qube-bulk");
    var source = bulk.querySelector("[data-qube-bulk-value]");
    var shownLabel = bulk.querySelector("[data-qube-search-input]");
    if (!source || !source.value) return;
    each(rowsOf(table), function (row) {
      var ticked = row.querySelector("[data-qube-rows-pick]");
      if (!ticked || !ticked.checked) return;
      var cell = row.querySelector('[data-qube-col="' + col + '"]');
      var input = cell && cell.querySelector("[data-qube-rows-input]");
      if (!input || input.disabled) return;
      input.value = source.value;
      var text = cell.querySelector("[data-qube-search-input]");
      if (text) {
        text.value = shownLabel ? shownLabel.value : source.value;
        text.setCustomValidity("");
      }
      refresh(row);
      filled(cell);
    });
  };

  // The rows table's scroller fades its edge while there's more to the right.
  var edges = function (scroller) {
    var more = scroller.scrollWidth - scroller.clientWidth - scroller.scrollLeft > 1;
    if (more) scroller.setAttribute("data-qube-overflow", "end");
    else scroller.removeAttribute("data-qube-overflow");
  };

  // Server-rendered hidden cells, hidden without the stylesheet too; the ticks and edges as the
  // page has them.
  var sweep = function () {
    each(document.querySelectorAll("[data-qube-rows] [data-qube-hidden]"), function (cell) {
      cell.style.visibility = "hidden";
    });
    each(document.querySelectorAll("[data-qube-rows]"), picked);
    each(document.querySelectorAll("[data-qube-rows-scroll]"), edges);
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
    var button = event.target.closest("[data-qube-bulk-apply]");
    if (button) return apply(button);
    var copyButton = event.target.closest("[data-qube-copy]");
    if (copyButton) copy(copyButton);
  });

  document.addEventListener("change", function (event) {
    var target = event.target;
    if (!target.closest) return;
    if (target.matches("[data-qube-rows-all]")) {
      var table = target.closest("[data-qube-rows]");
      each(table.querySelectorAll("[data-qube-rows-pick]"), function (box) {
        box.checked = target.checked;
      });
      picked(table);
      return;
    }
    if (target.matches("[data-qube-rows-pick]")) {
      picked(target.closest("[data-qube-rows]"));
      return;
    }
    var row = target.closest("[data-qube-rows] [data-qube-row][data-qube-values]");
    if (row && !target.closest("[data-qube-bulk]")) refresh(row);
  });

  // Scroll doesn't bubble: caught on the way down.
  document.addEventListener("scroll", function (event) {
    var scroller = event.target.closest && event.target.closest("[data-qube-rows-scroll]");
    if (scroller === event.target) edges(scroller);
  }, true);

  window.addEventListener("resize", function () {
    each(document.querySelectorAll("[data-qube-rows-scroll]"), edges);
  });

  ["DOMContentLoaded", "turbo:load", "turbo:render", "turbo:frame-load"].forEach(function (name) {
    document.addEventListener(name, sweep);
  });
  if (document.readyState !== "loading") sweep();
})();
