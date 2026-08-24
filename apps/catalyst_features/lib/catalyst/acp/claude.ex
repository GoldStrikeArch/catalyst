defmodule Catalyst.ACP.Claude do
  @moduledoc """
  Builds the documented Claude ACP session metadata.

  Claude keeps its own default system prompt unless the Catalyst session has an
  explicit override. Overrides can replace that prompt or append to the
  `claude_code` preset. Ambient Claude setting sources are disabled by default
  for the local experiment and can be enabled explicitly per session.
  """

  @setting_sources ~w(user project local)

  @doc "Build Claude-specific `_meta` for an ACP session lifecycle request."
  @spec session_meta(map()) :: {:ok, map()} | {:error, term()}
  def session_meta(%{prompt_override: prompt, opts: opts}) when is_list(opts) do
    with {:ok, system_prompt} <- system_prompt(prompt, opts),
         {:ok, setting_sources} <- setting_sources(opts) do
      options = %{"settingSources" => setting_sources}

      %{"claudeCode" => %{"options" => options}}
      |> maybe_put_system_prompt(system_prompt)
      |> then(&{:ok, &1})
    end
  end

  def session_meta(config), do: {:error, {:invalid_claude_acp_config, config}}

  defp system_prompt(nil, _opts), do: {:ok, nil}

  defp system_prompt(prompt, opts) when is_binary(prompt) and byte_size(prompt) > 0 do
    case Keyword.get(opts, :acp_claude_prompt_mode, :replace) do
      :replace -> {:ok, prompt}
      :append -> {:ok, %{"append" => prompt}}
      mode -> {:error, {:invalid_acp_claude_prompt_mode, mode}}
    end
  end

  defp system_prompt(prompt, _opts), do: {:error, {:invalid_acp_claude_system_prompt, prompt}}

  defp setting_sources(opts) do
    case Keyword.get(opts, :acp_claude_setting_sources, []) do
      sources when is_list(sources) ->
        case Enum.all?(sources, &(&1 in @setting_sources)) and Enum.uniq(sources) == sources do
          true -> {:ok, sources}
          false -> {:error, {:invalid_acp_claude_setting_sources, sources}}
        end

      sources ->
        {:error, {:invalid_acp_claude_setting_sources, sources}}
    end
  end

  defp maybe_put_system_prompt(meta, nil), do: meta
  defp maybe_put_system_prompt(meta, prompt), do: Map.put(meta, "systemPrompt", prompt)
end
