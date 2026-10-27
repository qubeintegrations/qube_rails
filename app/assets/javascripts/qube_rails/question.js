// qube_rails: the behaviour of a QuBe Sync question (search boxes, the rows table). Listeners sit
// on document and key only on data-qube-* attributes, so any markup carrying them works, after
// Turbo navigation too. Plain JavaScript, no build. README, "Styling", has the attribute contract.
(function () {
  if (window.qubeRailsQuestion) return; // loaded once per page, however often it's included
  window.qubeRailsQuestion = true;

  var each = function (list, fn) { Array.prototype.forEach.call(list, fn); };
  var timers = new WeakMap();
  var asked = new WeakMap();

  // ---- Search: [data-qube-search] holds [data-qube-search-input], [data-qube-search-value] and
  // [data-qube-search-results].

  var parts = function (box) {
    return {
      input: box.querySelector("[data-qube-search-input]"),
      value: box.querySelector("[data-qube-search-value]"),
      results: box.querySelector("[data-qube-search-results]")
    };
  };

  // Until a match is picked, the form won't send what was typed.
  var check = function (p) {
    var unpicked = p.input.value && !p.value.value;
    p.input.setCustomValidity(unpicked ? "Pick one of the matches." : "");
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

  var showMatches = function (box, p, matches) {
    p.results.textContent = matches.length ? "" : "No matches.";
    var className = box.getAttribute("data-qube-result-class") || "qube-search-result";
    matches.forEach(function (match) {
      var pick = document.createElement("button");
      pick.type = "button";
      pick.className = className;
      pick.setAttribute("data-qube-search-result", "");
      pick.setAttribute("data-value", match.value);
      pick.setAttribute("data-label", match.label);
      pick.textContent = match.label + (match.detail ? " · " + match.detail : "");
      p.results.appendChild(pick);
    });
  };

  var search = function (box) {
    var p = parts(box);
    if (!p.input || !p.value || !p.results) return;
    p.value.value = "";
    check(p);
    clearTimeout(timers.get(box));
    p.results.textContent = "";
    var q = p.input.value.trim();
    if (q.length < 2) return;
    timers.set(box, setTimeout(function () {
      var n = (asked.get(box) || 0) + 1;
      asked.set(box, n);
      fetch(searchUrl(box, q), { headers: { Accept: "application/json" }, credentials: "same-origin" })
        .then(function (res) { return res.ok ? res.json() : []; })
        .then(function (matches) {
          if (asked.get(box) !== n) return; // a later search has gone out since
          showMatches(box, p, matches);
        })
        .catch(function () { if (asked.get(box) === n) p.results.textContent = "The search didn't answer."; });
    }, 250));
  };

  var pick = function (button) {
    var box = button.closest("[data-qube-search]");
    var p = parts(box);
    p.value.value = button.getAttribute("data-value");
    p.input.value = button.getAttribute("data-label");
    p.results.textContent = "";
    check(p);
    p.value.dispatchEvent(new Event("change", { bubbles: true }));
    box.dispatchEvent(new CustomEvent("qube:picked", { bubbles: true }));
  };

  // ---- Rows: [data-qube-rows] holds rows ([data-qube-row][data-qube-values]), their cells
  // ([data-qube-col], with data-qube-when) and inputs ([data-qube-rows-input]), the row picks
  // ([data-qube-rows-pick], [data-qube-rows-all]) and the "Set selected" cells ([data-qube-bulk]).

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

  // Fills a column on every ticked row that asks it.
  var apply = function (button) {
    var bulk = button.closest("[data-qube-bulk]");
    var table = bulk.closest("[data-qube-rows]");
    var col = bulk.getAttribute("data-qube-bulk");
    var source = bulk.querySelector("[data-qube-bulk-value]");
    var shownLabel = bulk.querySelector("[data-qube-search-input]");
    if (!source || !source.value) return;
    each(rowsOf(table), function (row) {
      var picked = row.querySelector("[data-qube-rows-pick]");
      if (!picked || !picked.checked) return;
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
    });
  };

  // Server-rendered hidden cells, hidden without the stylesheet too.
  var sweep = function () {
    each(document.querySelectorAll("[data-qube-rows] [data-qube-hidden]"), function (cell) {
      cell.style.visibility = "hidden";
    });
  };

  document.addEventListener("input", function (event) {
    var input = event.target.closest && event.target.closest("[data-qube-search-input]");
    var box = input && input.closest("[data-qube-search]");
    if (box) search(box);
  });

  document.addEventListener("click", function (event) {
    if (!event.target.closest) return;
    var result = event.target.closest("[data-qube-search-result]");
    if (result) return pick(result);
    var button = event.target.closest("[data-qube-bulk-apply]");
    if (button) apply(button);
  });

  document.addEventListener("change", function (event) {
    var target = event.target;
    if (!target.closest) return;
    if (target.matches("[data-qube-rows-all]")) {
      each(target.closest("[data-qube-rows]").querySelectorAll("[data-qube-rows-pick]"), function (box) {
        box.checked = target.checked;
      });
      return;
    }
    var row = target.closest("[data-qube-rows] [data-qube-row][data-qube-values]");
    if (row && !target.closest("[data-qube-bulk]")) refresh(row);
  });

  ["DOMContentLoaded", "turbo:load", "turbo:render", "turbo:frame-load"].forEach(function (name) {
    document.addEventListener(name, sweep);
  });
  if (document.readyState !== "loading") sweep();
})();
