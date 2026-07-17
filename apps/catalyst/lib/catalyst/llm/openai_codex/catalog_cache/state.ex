defmodule Catalyst.LLM.OpenAICodex.CatalogCache.State do
  @moduledoc false

  @enforce_keys [
    :fetcher,
    :clock,
    :enabled?,
    :ttl_ms,
    :retry_ms,
    :refresh_timeout_ms,
    :task_supervisor
  ]
  defstruct entries: [],
            etag: nil,
            fresh_at: nil,
            last_attempt_at: nil,
            refresh: nil,
            refresh_timer: nil,
            waiters: [],
            fetcher: nil,
            clock: nil,
            enabled?: nil,
            ttl_ms: nil,
            retry_ms: nil,
            refresh_timeout_ms: nil,
            task_supervisor: nil
end
