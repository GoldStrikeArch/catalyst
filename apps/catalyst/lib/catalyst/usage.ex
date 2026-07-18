defmodule Catalyst.Usage do
  @moduledoc "Token/cost accounting for an assistant turn."
  defstruct input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            total_tokens: 0,
            cost: 0.0,
            context_digest: nil

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost: float(),
          context_digest: String.t() | nil
        }
end
