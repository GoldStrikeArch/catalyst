defmodule Catalyst.Tools.Computer.Backend do
  @moduledoc """
  The per-OS computer-use backend behaviour (plan §3).

  A backend is the boundary between the pure `computer` tool logic and the
  machine: it enumerates screens and windows, reports the cursor, posts input,
  captures the screen, and reports TCC grant state. The macOS implementation
  drives the `catalyst-input` helper and `screencapture`/`sips`; the
  `Catalyst.Tools.Computer.Unsupported` stub returns
  `{:error, :unsupported_platform}` for every callback.

  The backend is selected by `config :catalyst, :computer_backend` (default:
  `:os.type/0` dispatch), so tests inject a stub and every tool is exercisable
  with no real desktop and no TCC.

  ## Result shapes

  All callbacks return `{:ok, value}` / `{:error, reason}`. Reasons are tagged
  atoms or tuples (`:unsupported_platform`, `:helper_unavailable`,
  `{:helper_error, message}`, `:screen_recording_denied`, …).
  """

  @typedoc "A single display, in point-space bounds with its backing scale."
  @type screen :: %{
          id: non_neg_integer(),
          index: non_neg_integer(),
          main: boolean(),
          bounds: rect(),
          scale: float()
        }

  @typedoc "An on-screen window."
  @type window :: %{
          id: non_neg_integer(),
          pid: non_neg_integer(),
          app: String.t(),
          title: String.t(),
          layer: integer(),
          bounds: rect()
        }

  @typedoc "A rectangle in display points."
  @type rect :: %{x: number(), y: number(), width: number(), height: number()}

  @typedoc "The cursor location, in global display points."
  @type cursor :: %{x: number(), y: number()}

  @typedoc """
  An input op — an action name plus its args, exactly as forwarded to the helper
  (`:mouse_move`, `:click`, `:drag`, `:scroll`, `:type`, `:key`, `:hold_key`,
  `:mouse_down`, `:mouse_up`, `:release_all`). Coordinates are global points.
  """
  @type input_op :: %{required(:op) => atom(), optional(atom()) => term()}

  @typedoc """
  A capture request: a target (`Catalyst.Tools.Computer.Capture.target/0`) plus
  an optional long edge for downscaling.
  """
  @type capture_request :: %{
          required(:target) => Catalyst.Tools.Computer.Capture.target(),
          optional(:long_edge) => pos_integer()
        }

  @typedoc """
  A captured, downscaled image with its provenance. `origin` is the captured
  target's top-left in global display points and `ratio` the applied downscale
  ratio (≤ 1.0) — together with `scale` they are exactly the inputs
  `Catalyst.Tools.Computer.Capture.to_point/4` needs to map a screenshot pixel
  back to a postable point.
  """
  @type capture_result :: %{
          data: binary(),
          mime_type: String.t(),
          scale: float(),
          origin: {number(), number()},
          ratio: float(),
          logical_size: {number(), number()},
          captured_size: {non_neg_integer(), non_neg_integer()},
          bytes: non_neg_integer()
        }

  @typedoc "TCC grant state for the process that will do the work."
  @type grants :: %{accessibility: boolean(), screen_recording: boolean()}

  @doc "Enumerate active displays."
  @callback screens() :: {:ok, [screen()]} | {:error, term()}

  @doc "Enumerate on-screen windows (excludes desktop elements)."
  @callback windows() :: {:ok, [window()]} | {:error, term()}

  @doc "Report the current cursor location in global display points."
  @callback cursor() :: {:ok, cursor()} | {:error, term()}

  @doc """
  Post an input op. Returns `{:ok, map}` with any op-specific result fields
  (e.g. `%{count: 2}` for a double click) or `{:error, reason}`.
  """
  @callback input(input_op()) :: {:ok, map()} | {:error, term()}

  @doc "Capture and downscale the screen for a target."
  @callback capture(capture_request()) :: {:ok, capture_result()} | {:error, term()}

  @doc """
  Report TCC grant state (Accessibility + Screen Recording) **as seen by the
  helper process** — `AXIsProcessTrusted()` and
  `CGPreflightScreenCaptureAccess()` answer for their caller, so this describes
  the native helper, which is the right subject for synthetic input but NOT for
  screenshots (see `capture_grant/0`).
  """
  @callback grants() :: {:ok, grants()} | {:error, term()}

  @doc """
  Whether the process that actually performs captures can capture the screen.

  Screenshots do not go through the helper: on macOS they are taken by
  `screencapture` spawned from the BEAM — a different TCC subject than the
  helper that answers `grants/0`. The two can disagree (the design doc's
  "three TCC subjects" hazard), so screenshot readiness must be probed from
  the capture path itself. Implementations must be cheap, read-only, and must
  never invoke a prompting TCC variant.
  """
  @callback capture_grant() :: {:ok, boolean()} | {:error, term()}

  @doc """
  The backend module for this run: `config :catalyst, :computer_backend` when
  set (tests inject a stub here), else `:os.type/0` dispatch —
  `Catalyst.Tools.Computer.MacOS` on Darwin, `Catalyst.Tools.Computer.Unsupported`
  elsewhere.
  """
  @spec select() :: module()
  def select do
    case Application.get_env(:catalyst, :computer_backend) do
      nil -> default_backend()
      module when is_atom(module) -> module
    end
  end

  defp default_backend do
    case :os.type() do
      {:unix, :darwin} -> Catalyst.Tools.Computer.MacOS
      _other -> Catalyst.Tools.Computer.Unsupported
    end
  end
end
