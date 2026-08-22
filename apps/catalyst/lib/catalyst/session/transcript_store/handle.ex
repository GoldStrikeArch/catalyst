defmodule Catalyst.Session.TranscriptStore.Handle do
  @moduledoc """
  Versioned logical handle for one session's pinned transcript backend.

  `id`, `path`, and `cwd` preserve the current session host's diagnostics while
  `backend_handle` remains private to the selected implementation.
  """

  alias Catalyst.Runtime.Handle, as: RuntimeHandle

  @enforce_keys [
    :runtime_handle,
    :backend_handle,
    :id,
    :path,
    :cwd,
    :metadata
  ]
  defstruct @enforce_keys ++ [version: 1]

  @type t :: %__MODULE__{
          version: 1,
          runtime_handle: RuntimeHandle.t(),
          backend_handle: term(),
          id: String.t(),
          path: String.t(),
          cwd: String.t(),
          metadata: map()
        }
end
