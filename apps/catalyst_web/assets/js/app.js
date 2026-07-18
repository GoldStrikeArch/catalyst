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
      this.el.scrollTop = this.el.scrollHeight;
      // scrollTop clamps to the real max; remember where our scroll landed so
      // the resulting async scroll event is attributed to us, not the user.
      this.programmaticTarget = this.el.scrollTop;
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
