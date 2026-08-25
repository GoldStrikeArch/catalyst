defmodule Catalyst.Context.Compaction do
  @moduledoc """
  A context policy's proposed chronological transcript replacement.

  The replacement is advisory until `Catalyst.Context.Guard` validates the
  message shape and recomputes authoritative accounting for the staged request.
  """

  @enforce_keys [:replacement]
  defstruct [:replacement, :summary]

  @type t :: %__MODULE__{
          replacement: [Catalyst.Message.t()],
          summary: Catalyst.Message.User.t() | nil
        }
end

defmodule Catalyst.Context.Policy do
  @moduledoc """
  Behaviour for request-time context thresholds and persistent compaction.

  Both callbacks run in a supervised workflow task.  A policy returns the full
  chronological replacement list; `Catalyst.Context.Guard` remains the authority
  that validates, estimates, emits, and installs it.
  """

  @doc """
  Resolve the request-time token threshold for a model and policy context.

  Return `:none` to disable Catalyst-managed compaction for this request. Lower
  precedence threshold resolution happens before the selected policy callback
  is invoked.
  """
  @callback threshold(Catalyst.Model.t() | nil, map()) ::
              {:ok, pos_integer()} | :none | {:error, term()}

  @doc """
  Build a chronological replacement for an oversized transcript.

  The guard validates transcript structure, progress, and token size before it
  persists or installs the returned compaction.
  """
  @callback compact([Catalyst.Message.t()], map()) ::
              {:ok, Catalyst.Context.Compaction.t()} | {:error, term()}
end
