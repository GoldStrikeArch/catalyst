defmodule Catalyst.Prompt.Request do
  @moduledoc "An immutable prompt-resolution request."

  defstruct purpose: :system,
            model: nil,
            cwd: nil,
            session_id: nil,
            override: nil,
            opts: []

  @type purpose :: :system | :compaction

  @type t :: %__MODULE__{
          purpose: purpose(),
          model: Catalyst.Model.t() | nil,
          cwd: Path.t() | nil,
          session_id: String.t() | nil,
          override: String.t() | nil,
          opts: keyword()
        }
end
