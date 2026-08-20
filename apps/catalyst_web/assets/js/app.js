// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";

import hljs from "../vendor/highlight.es.min.js";
import hljsElixir from "../vendor/hljs-elixir.es.min.js";
import hljsErlang from "../vendor/hljs-erlang.es.min.js";

hljs.registerLanguage("elixir", hljsElixir);
hljs.registerLanguage("erlang", hljsErlang);
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/catalyst_web";
import topbar from "../vendor/topbar";

const setTheme = (theme) => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme");
    document.documentElement.removeAttribute("data-theme");
  } else {
    localStorage.setItem("phx:theme", theme);
    document.documentElement.setAttribute("data-theme", theme);
  }
};

if (!document.documentElement.hasAttribute("data-theme")) {
  setTheme(localStorage.getItem("phx:theme") || "system");
}

window.addEventListener("storage", (e) => {
  if (e.key === "phx:theme") setTheme(e.newValue || "system");
});
window.addEventListener("phx:set-theme", (e) =>
  setTheme(e.target.dataset.phxTheme),
);

// Keep a scroll container pinned to the bottom as content streams in,
// unless the user has scrolled up to read history. The pin changes only on
// USER intent: wheel/touch/keys unpin before the scroll they cause is even
// applied (winning the race against per-delta autoscrolls), the scroll
// listener covers scrollbar drags and momentum tails, and the hook's own
// scrolls are recognized by landing position so they can never re-latch it.
const Hooks = {
  ScrollBottom: {
    atBottom() {
      const el = this.el;
      return el.scrollHeight - el.clientHeight - el.scrollTop < 80;
    },
    setPinned(pinned) {
      this.pinnedToBottom = pinned;
      if (this.pill) {
        this.pill.classList.toggle("hidden", pinned);
        this.pill.classList.toggle("inline-flex", !pinned);
      }
    },
    scrollToBottom() {
      const el = this.el;
      // Already at the hard bottom: writing scrollTop again would only emit a
      // redundant scroll event for the pin bookkeeping to chew on (and, mid
      // rubber-band, fight the bounce — visible as streaming-time jitter).
      if (el.scrollHeight - el.clientHeight - el.scrollTop < 1) return;
      el.scrollTop = el.scrollHeight;
      // scrollTop clamps to the real max; remember where our scroll landed so
      // the resulting async scroll event is attributed to us, not the user.
      this.programmaticTarget = el.scrollTop;
    },
    // Deltas arrive 10-30+/s; coalesce to at most one scroll per frame, and
    // re-check the pin at fire time (an unpin may have landed in between).
    requestScroll() {
      if (!this.pinnedToBottom || this.raf) return;
      this.raf = requestAnimationFrame(() => {
        this.raf = null;
        if (this.pinnedToBottom) this.scrollToBottom();
      });
    },
    mounted() {
      const el = this.el;
      this.raf = null;
      this.programmaticTarget = null;
      this.lastScrollTop = el.scrollTop;
      this.pill = document.getElementById("jump-to-bottom");
      this.setPinned(true);
      this.scrollToBottom();

      // Upward user intent — these fire BEFORE the browser moves the
      // container, so the unpin wins the race against per-delta autoscrolls.
      // The scrollable check keeps wheel fidgeting over a short chat from
      // disabling follow before there is anything to scroll.
      el.addEventListener(
        "wheel",
        (e) => {
          if (e.deltaY < 0 && el.scrollHeight > el.clientHeight) {
            this.setPinned(false);
          }
        },
        { passive: true },
      );
      el.addEventListener(
        "touchstart",
        (e) => (this.lastTouchY = e.touches[0].clientY),
        { passive: true },
      );
      el.addEventListener(
        "touchmove",
        (e) => {
          const y = e.touches[0].clientY;
          // Finger moving down drags earlier content into view.
          if (y > this.lastTouchY && el.scrollHeight > el.clientHeight) {
            this.setPinned(false);
          }
          this.lastTouchY = y;
        },
        { passive: true },
      );
      el.addEventListener("keydown", (e) => {
        if (["ArrowUp", "PageUp", "Home"].includes(e.key)) {
          this.setPinned(false);
        }
      });

      // Covers what the intent listeners can't (scrollbar drags, momentum
      // tails) and re-pins when the user returns to the bottom.
      el.addEventListener("scroll", () => {
        const top = el.scrollTop;
        const up = top < this.lastScrollTop;
        this.lastScrollTop = top;
        if (
          this.programmaticTarget !== null &&
          Math.abs(top - this.programmaticTarget) <= 1
        ) {
          this.programmaticTarget = null; // our own scrollToBottom() landing
          return;
        }
        if (el.scrollHeight - el.clientHeight - top <= 1) {
          // Hard bottom: the user arriving at the end, or a browser clamp
          // after a stream_tail trim shrank the content — pinned either way.
          this.setPinned(true);
        } else if (up) {
          this.setPinned(false);
        } else if (this.atBottom()) {
          this.setPinned(true);
        }
      });

      if (this.pill) {
        this.pill.addEventListener("click", () => {
          this.setPinned(true);
          this.scrollToBottom();
        });
      }

      // Client-side appends (streaming deltas) don't trigger updated(); the
      // StreamingMessage hook dispatches this event instead.
      this.autoscroll = () => this.requestScroll();
      window.addEventListener("catalyst:autoscroll", this.autoscroll);
    },
    updated() {
      this.requestScroll();
    },
    destroyed() {
      window.removeEventListener("catalyst:autoscroll", this.autoscroll);
      if (this.raf) cancelAnimationFrame(this.raf);
    },
  },

  // Syntax-highlight fenced code blocks under this element. PI's hard-won
  // rule: EXPLICIT fence language only (auto-detection misidentifies prose);
  // input goes through textContent, so hljs only ever sees escaped text and
  // inserts its own span markup.
  Highlight: {
    mounted() {
      this.highlightAll();
    },
    updated() {
      this.highlightAll();
    },
    highlightAll() {
      this.el.querySelectorAll("pre code[data-lang]").forEach((code) => {
        if (code.dataset.highlighted === "yes") return;
        const lang = code.dataset.lang.toLowerCase();
        if (!hljs.getLanguage(lang)) return;
        const { value } = hljs.highlight(code.textContent, {
          language: lang,
          ignoreIllegals: true,
        });
        code.innerHTML = value;
        code.dataset.highlighted = "yes";
        // Mark as DOM-managed by the hook to prevent LiveView from patching children
        code.setAttribute("phx-update", "ignore");
      });
    },
  },

  // Pasted screenshots: clipboard images anywhere in the chat form feed the
  // LiveView :image upload (chips render above the input; send attaches them
  // to the prompt as image content blocks).
  // Enter submits (or queues) the inline draft; Shift+Enter inserts a newline.
  ChatSubmit: {
    mounted() {
      this.resize = () => {
        this.el.style.height = "auto";
        this.el.style.height = `${this.el.scrollHeight}px`;
      };
      this.onKey = (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault();
          this.el.form?.requestSubmit();
        }
      };
      this.el.addEventListener("input", this.resize);
      this.el.addEventListener("keydown", this.onKey);
      this.resize();
    },
    updated() {
      this.resize();
    },
    destroyed() {
      this.el.removeEventListener("input", this.resize);
      this.el.removeEventListener("keydown", this.onKey);
    },
  },

  PasteImages: {
    mounted() {
      this.el.addEventListener("paste", (e) => {
        const files = Array.from(e.clipboardData?.items || [])
          .filter(
            (item) => item.kind === "file" && item.type.startsWith("image/"),
          )
          .map((item) => item.getAsFile())
          .filter(Boolean);
        if (files.length === 0) return;
        e.preventDefault();
        this.upload("image", files);
      });
    },
  },

  // The live streaming bubble: the server pushes each text/thinking delta as
  // a "stream_delta" event; append it into the matching [data-stream] span.
  // The element is phx-update="ignore", so LiveView never repaints over the
  // appended text; the finished message removes the whole element.
  StreamingMessage: {
    mounted() {
      this.handleEvent("stream_delta", ({ kind, delta }) => {
        const target = this.el.querySelector(`[data-stream="${kind}"]`);
        if (!target) return;
        target.appendChild(document.createTextNode(delta));
        this.hideDots();
        window.dispatchEvent(new Event("catalyst:autoscroll"));
      });

      // Blocks were committed server-side (rendered above the tail): trim the
      // raw tail to just the still-open block's source.
      this.handleEvent("stream_tail", ({ text }) => {
        const target = this.el.querySelector('[data-stream="text"]');
        if (!target) return;
        target.textContent = text;
        this.hideDots();
        window.dispatchEvent(new Event("catalyst:autoscroll"));
      });
    },
    hideDots() {
      const dots = this.el.querySelector("[data-stream-dots]");
      if (dots) dots.style.display = "none";
    },
  },

  // Turn rail, Delta-style: a compact tick stack vertically centered on the
  // right edge — fixed spacing, NOT proportional to scroll height (the native
  // scrollbar next to it owns "where am I in the document"). One tick per
  // user/assistant turn plus a trailing accent tick for "jump to end". The
  // tick of the turn currently at the top of the viewport stays highlighted
  // while scrolling; hovering a tick enlarges it and grows the preview card
  // out of its middle; click jumps; Alt/⌥+wheel steps turns.
  JumpByTurn: {
    // All class fragments live in these literal tables so Tailwind's @source
    // scan of assets/js emits them. Widths double as the tick length language:
    // user turns are long, assistant turns short, hover longest.
    TICK_BASE:
      "absolute right-2.5 h-[3px] -translate-y-1/2 rounded-full transition-all duration-150",
    TICK_W: {
      user: "w-3.5",
      userCurrent: "w-4",
      assistant: "w-2",
      assistantCurrent: "w-3",
      end: "w-2.5",
      hovered: "w-5",
    },
    TICK_C: {
      idle: "bg-faint/50",
      current: "bg-muted",
      end: "bg-accent/70",
      hovered: "bg-ink",
    },
    SPACING: 14,

    mounted() {
      this.scroller = document.getElementById("messages");
      this.card = document.getElementById("turn-jump-card");
      this.ticks = document.getElementById("turn-jump-ticks");
      this.roleEl = this.card?.querySelector("[data-turn-role]");
      this.prevEl = this.card?.querySelector("[data-turn-preview]");
      this.hovered = null; // tick index under the mouse, or null
      this.currentIdx = -1; // tick index of the turn in view
      this.tickYs = [];
      if (!this.scroller || !this.card || !this.ticks) return;

      this.onMove = (e) => this.hover(e);
      this.onLeave = () => this.hide();
      this.onClick = (e) => {
        if (this.hovered === null) return;
        e.preventDefault();
        this.jumpTo(this.hovered);
      };
      this.onWheel = (e) => {
        if (!e.altKey || this.tickCount() === 0) return;
        e.preventDefault();
        const dir = e.deltaY > 0 ? 1 : -1;
        this.jumpTo(this.clamp(this.scrollIndex() + dir, this.tickCount()));
      };
      this.onPaint = () => {
        if (this.paintRaf) return;
        this.paintRaf = requestAnimationFrame(() => {
          this.paintRaf = null;
          this.paintTicks();
        });
      };
      // Scroll only moves the highlight, never the stack geometry.
      this.onScroll = () => {
        if (this.scrollRaf) return;
        this.scrollRaf = requestAnimationFrame(() => {
          this.scrollRaf = null;
          this.syncCurrent();
        });
      };

      this.scroller.addEventListener("mousemove", this.onMove);
      this.scroller.addEventListener("mouseleave", this.onLeave);
      this.scroller.addEventListener("click", this.onClick);
      this.scroller.addEventListener("wheel", this.onWheel, { passive: false });
      this.scroller.addEventListener("scroll", this.onScroll, { passive: true });
      window.addEventListener("catalyst:autoscroll", this.onPaint);

      this.resizeObs = new ResizeObserver(this.onPaint);
      this.resizeObs.observe(this.scroller);
      this.mutObs = new MutationObserver(this.onPaint);
      this.mutObs.observe(this.scroller, { childList: true, subtree: true });
      this.paintTicks();
    },
    destroyed() {
      if (!this.scroller) return;
      this.scroller.removeEventListener("mousemove", this.onMove);
      this.scroller.removeEventListener("mouseleave", this.onLeave);
      this.scroller.removeEventListener("click", this.onClick);
      this.scroller.removeEventListener("wheel", this.onWheel);
      this.scroller.removeEventListener("scroll", this.onScroll);
      window.removeEventListener("catalyst:autoscroll", this.onPaint);
      this.resizeObs?.disconnect();
      this.mutObs?.disconnect();
      if (this.paintRaf) cancelAnimationFrame(this.paintRaf);
      if (this.scrollRaf) cancelAnimationFrame(this.scrollRaf);
    },
    turns() {
      return [...this.scroller.querySelectorAll("[data-turn]")];
    },
    // turns + the trailing "jump to end" tick (only when there are turns)
    tickCount() {
      const n = this.turns().length;
      return n === 0 ? 0 : n + 1;
    },
    contentTop(el) {
      const s = this.scroller;
      return el.getBoundingClientRect().top - s.getBoundingClientRect().top + s.scrollTop;
    },
    // Tick index for the current scroll position: last turn at/above the
    // viewport top; the end tick when pinned to the hard bottom.
    scrollIndex() {
      const s = this.scroller;
      if (s.scrollHeight - s.clientHeight - s.scrollTop <= 1 && this.tickCount() > 0) {
        return this.tickCount() - 1;
      }
      const turns = this.turns();
      const top = s.scrollTop + 8;
      let i = 0;
      for (let k = 0; k < turns.length; k++) {
        if (this.contentTop(turns[k]) <= top) i = k;
        else break;
      }
      return i;
    },
    clamp(i, n) {
      return Math.max(0, Math.min(n - 1, i));
    },
    // Lay the stack out centered on the rail with fixed spacing (squeezed
    // only when a huge transcript would overflow the rail).
    paintTicks() {
      const n = this.tickCount();
      const turns = this.turns();
      const rail = this.el.clientHeight;
      const spacing = n > 1 ? Math.min(this.SPACING, (rail - 48) / (n - 1)) : 0;
      const first = rail / 2 - ((n - 1) * spacing) / 2;
      while (this.ticks.childElementCount > n) this.ticks.lastChild.remove();
      this.tickYs = [];
      for (let i = 0; i < n; i++) {
        let mark = this.ticks.children[i];
        if (!mark) {
          mark = document.createElement("div");
          mark.dataset.turnTick = "";
          this.ticks.appendChild(mark);
        }
        mark.dataset.role = i === n - 1 ? "end" : turns[i].dataset.turn;
        const y = first + i * spacing;
        this.tickYs.push(y);
        mark.style.top = `${y}px`;
      }
      this.syncCurrent();
    },
    syncCurrent() {
      this.currentIdx = this.tickCount() === 0 ? -1 : this.scrollIndex();
      this.styleTicks();
    },
    styleTicks() {
      [...this.ticks.children].forEach((mark, k) => {
        const role = mark.dataset.role;
        const hovered = k === this.hovered;
        const current = k === this.currentIdx;
        let w, c;
        if (hovered) {
          w = this.TICK_W.hovered;
          c = this.TICK_C.hovered;
        } else if (role === "end") {
          w = this.TICK_W.end;
          c = this.TICK_C.end;
        } else if (current) {
          w = role === "user" ? this.TICK_W.userCurrent : this.TICK_W.assistantCurrent;
          c = this.TICK_C.current;
        } else {
          w = role === "user" ? this.TICK_W.user : this.TICK_W.assistant;
          c = this.TICK_C.idle;
        }
        mark.className = `${this.TICK_BASE} ${w} ${c}`;
      });
    },
    // Hit-test the compact stack: near the right edge AND vertically near a
    // tick. Outside the stack the rail is inert, so the scrollbar and plain
    // reading space stay unobstructed.
    hover(e) {
      const r = this.scroller.getBoundingClientRect();
      const n = this.tickCount();
      if (n === 0 || e.clientX < r.right - 32) return this.hide();
      const track = this.el.getBoundingClientRect();
      const y = e.clientY - track.top;
      let best = -1;
      let bestDist = Infinity;
      this.tickYs.forEach((ty, i) => {
        const d = Math.abs(ty - y);
        if (d < bestDist) {
          bestDist = d;
          best = i;
        }
      });
      if (best < 0 || bestDist > 16) return this.hide();
      if (this.hovered !== best) {
        this.hovered = best;
        this.fillCard(best);
        this.styleTicks();
      }
      // Grow the card out of the tick's middle (origin-right + scale/opacity
      // transition on the card element).
      const h = this.card.offsetHeight;
      const top = this.clamp2(this.tickYs[best] - h / 2, 8, track.height - h - 8);
      this.card.style.top = `${top}px`;
      this.showCard(true);
    },
    fillCard(i) {
      const n = this.tickCount();
      if (i === n - 1) {
        this.roleEl.textContent = "End";
        this.prevEl.textContent = "Jump to the latest message";
        return;
      }
      const turn = this.turns()[i];
      if (!turn) return;
      this.roleEl.textContent = turn.dataset.turn === "user" ? "You" : "Assistant";
      this.prevEl.textContent = (turn.innerText || "").trim().slice(0, 200);
    },
    showCard(shown) {
      this.card.classList.toggle("opacity-0", !shown);
      this.card.classList.toggle("scale-95", !shown);
      this.card.classList.toggle("opacity-100", shown);
      this.card.classList.toggle("scale-100", shown);
    },
    clamp2(v, lo, hi) {
      return Math.max(lo, Math.min(v, hi));
    },
    hide() {
      if (this.hovered === null) return;
      this.hovered = null;
      this.showCard(false);
      this.styleTicks();
    },
    jumpTo(i) {
      const n = this.tickCount();
      if (n === 0) return;
      if (i === n - 1) {
        this.scroller.scrollTo({ top: this.scroller.scrollHeight, behavior: "smooth" });
        return;
      }
      this.turns()[i]?.scrollIntoView({ block: "start", behavior: "smooth" });
    },
  },

  // Footer send button (#run-send): the composer is buttonless, so this
  // submits the chat form from the run bar. requestSubmit fires a real
  // submit event, which LiveView's phx-submit binding intercepts.
  SubmitChat: {
    mounted() {
      this.onClick = () => document.getElementById("chat-form")?.requestSubmit();
      this.el.addEventListener("click", this.onClick);
    },
    destroyed() {
      this.el.removeEventListener("click", this.onClick);
    },
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, ...Hooks },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
