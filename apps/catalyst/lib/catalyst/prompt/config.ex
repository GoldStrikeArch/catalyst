defmodule Catalyst.Prompt.Config do
  @moduledoc """
  Validates and reads the live purpose-aware `:prompts` application setting.

  The accepted shape is:

      config :catalyst, :prompts, %{
        system: %{"model-id" => "...", default: "..."},
        compaction: %{"model-id" => "...", default: "..."}
      }

  Configuration is checked on every read so post-boot changes take effect and
  malformed values fail explicitly instead of silently falling through.
  """

  alias Catalyst.Tools.Truncate

  @purposes [:system, :compaction]

  @type purpose :: :system | :compaction
  @type model_key :: String.t() | :default

  @doc "Read one prompt from the current `:prompts` application setting."
  @spec lookup(purpose(), model_key()) :: {:ok, binary()} | :error | {:error, term()}
  def lookup(purpose, model_key) do
    :catalyst
    |> Application.get_env(:prompts, %{})
    |> lookup(purpose, model_key)
  end

  @doc "Validate and read one prompt from an explicit configuration map."
  @spec lookup(term(), purpose(), model_key()) ::
          {:ok, binary()} | :error | {:error, term()}
  def lookup(config, purpose, model_key) do
    with :ok <- validate(config),
         :ok <- validate_lookup(purpose, model_key) do
      fetch(config, purpose, model_key)
    end
  end

  @doc "Validate the complete purpose-aware prompt configuration."
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(config) when is_map(config) do
    config
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> Enum.reduce_while(:ok, &validate_purpose/2)
  end

  def validate(config), do: invalid({:expected_map, config})

  @doc false
  @spec valid_purpose?(term()) :: boolean()
  def valid_purpose?(purpose), do: purpose in @purposes

  @doc """
  Ordered lookup keys for a model: its id, its api, then `:default`.

  Shared by every model-keyed overlay resolution (system prompts, context
  thresholds) so the precedence can't drift between subsystems.
  """
  @spec model_keys(term()) :: [term()]
  def model_keys(nil), do: [:default]

  def model_keys(model) when is_map(model) do
    [Map.get(model, :id), Map.get(model, :api), :default]
    |> Enum.filter(&valid_model_key?/1)
    |> Enum.uniq()
  end

  def model_keys(_model), do: [:default]

  @doc false
  @spec valid_model_key?(term()) :: boolean()
  def valid_model_key?(:default), do: true

  def valid_model_key?(model_key) when is_binary(model_key) do
    model_key
    |> Truncate.scrub_utf8()
    |> String.trim()
    |> Kernel.!=("")
  end

  def valid_model_key?(_model_key), do: false

  @doc false
  @spec nonblank_text?(term()) :: boolean()
  def nonblank_text?(text) when is_binary(text) do
    text
    |> Truncate.scrub_utf8()
    |> String.trim()
    |> Kernel.!=("")
  end

  def nonblank_text?(_text), do: false

  defp validate_purpose({purpose, entries}, :ok) do
    cond do
      not valid_purpose?(purpose) -> {:halt, invalid({:unknown_purpose, purpose})}
      not is_map(entries) -> {:halt, invalid({:expected_purpose_map, purpose, entries})}
      true -> continue_validation(validate_entries(purpose, entries))
    end
  end

  defp validate_entries(purpose, entries) do
    entries
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> Enum.reduce_while(:ok, fn {model_key, text}, :ok ->
      cond do
        not valid_model_key?(model_key) ->
          {:halt, invalid({:invalid_model_key, purpose, model_key})}

        not is_binary(text) ->
          {:halt, invalid({:invalid_text, purpose, model_key, text})}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_lookup(purpose, model_key) do
    cond do
      not valid_purpose?(purpose) -> invalid({:unknown_purpose, purpose})
      not valid_model_key?(model_key) -> invalid({:invalid_model_key, purpose, model_key})
      true -> :ok
    end
  end

  defp fetch(config, purpose, model_key) do
    with {:ok, purpose_entries} <- Map.fetch(config, purpose),
         {:ok, text} <- Map.fetch(purpose_entries, model_key) do
      selected_text(text, purpose, model_key)
    else
      :error -> :error
    end
  end

  defp selected_text(text, purpose, model_key) do
    case nonblank_text?(text) do
      true -> {:ok, text}
      false -> invalid({:blank_text, purpose, model_key})
    end
  end

  defp continue_validation(:ok), do: {:cont, :ok}
  defp continue_validation({:error, _reason} = error), do: {:halt, error}

  defp invalid(reason), do: {:error, {:invalid_prompt_config, reason}}
end
