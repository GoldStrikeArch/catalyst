defmodule Catalyst.Prompt do
  @moduledoc """
  Resolves purpose-aware prompts for one model and run boundary.

  Policies receive a `Catalyst.Prompt.Request` and own the complete returned
  `Catalyst.Prompt.Resolution`, including its ordered provenance. The active
  policy is selected through `Catalyst.Prompt.Registry`; callers that execute
  extension policies must invoke `resolve/1` from supervised worker code.
  """

  alias Catalyst.{Tasks, Tools}
  alias Catalyst.Prompt.{Registry, Request, Resolution}

  @default_policy_timeout 5_000

  @doc """
  Resolve a complete prompt and ordered provenance for one request.

  Policies should return expected failures as `{:error, reason}`; callers run
  extension policies in supervised, bounded work.
  """
  @callback resolve(Request.t()) :: {:ok, Resolution.t()} | {:error, term()}

  @doc "Resolve `request` with the current runtime, application, or built-in policy."
  @spec resolve(Request.t()) :: {:ok, Resolution.t()} | {:error, term()}
  def resolve(%Request{} = request) do
    with {:ok, policy, _source} <- Registry.policy() do
      policy.resolve(request)
    end
  end

  @doc "Resolve through a supervised, bounded policy call and normalize its result."
  @spec resolve_bounded(Request.t(), timeout()) ::
          {:ok, Resolution.t()} | {:error, term()}
  def resolve_bounded(%Request{} = request, timeout \\ policy_timeout()) do
    task = Tasks.async(fn -> resolve(request) end)

    case Tasks.await(task, timeout) do
      {:ok, {:ok, %Resolution{} = resolution}} -> normalize_resolution(resolution)
      {:ok, {:error, reason}} -> {:error, {:prompt_resolution, reason}}
      {:ok, invalid} -> {:error, {:invalid_prompt_policy_return, invalid}}
      {:exit, reason} -> {:error, {:prompt_policy_exit, reason}}
      :timeout -> {:error, :prompt_policy_timeout}
    end
  end

  @doc """
  Validate and canonicalize a prompt resolution.

  The single home for resolution validation (`Session.RunContext` calls it for
  hook-installed prompts too): scrubs invalid UTF-8 from the text, rejects
  blank text with `{:error, :blank_prompt_resolution}`, and rejects bad
  provenance with `{:error, {:invalid_prompt_provenance, source}}` carrying the
  first invalid source. Non-resolutions return
  `{:error, {:invalid_prompt_resolution, value}}`.
  """
  @spec normalize_resolution(term()) :: {:ok, Resolution.t()} | {:error, term()}
  def normalize_resolution(%Resolution{text: text, sources: sources})
      when is_binary(text) and is_list(sources) do
    resolution = Resolution.new(Tools.Truncate.scrub_utf8(text), sources)

    cond do
      String.trim(resolution.text) == "" -> {:error, :blank_prompt_resolution}
      not Resolution.valid_sources?(sources) -> invalid_provenance(sources)
      true -> {:ok, resolution}
    end
  end

  def normalize_resolution(resolution),
    do: {:error, {:invalid_prompt_resolution, resolution}}

  defp invalid_provenance(sources) do
    invalid = Enum.find(sources, &(not Resolution.valid_source?(&1)))
    {:error, {:invalid_prompt_provenance, invalid}}
  end

  defp policy_timeout,
    do: Application.get_env(:catalyst, :prompt_policy_timeout, @default_policy_timeout)
end
