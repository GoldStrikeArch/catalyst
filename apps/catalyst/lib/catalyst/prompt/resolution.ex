defmodule Catalyst.Prompt.Resolution do
  @moduledoc "A resolved prompt together with its digest and ordered provenance."

  alias Catalyst.Tools.Truncate

  @enforce_keys [:text, :sources, :digest]
  defstruct [:text, :sources, :digest]

  @type source ::
          {:session, :override}
          | {:extension, term(), term()}
          | {:application, term()}
          | {:file, Path.t()}
          | {:hook, :prepare_next_turn}
          | :builtin

  @type t :: %__MODULE__{
          text: String.t(),
          sources: [source()],
          digest: String.t()
        }

  @doc "Build a resolution, repairing UTF-8 before computing its SHA-256 digest."
  @spec new(binary(), [source()]) :: t()
  def new(text, sources) when is_binary(text) and is_list(sources) do
    text = Truncate.scrub_utf8(text)
    %__MODULE__{text: text, sources: sources, digest: digest(text)}
  end

  @doc false
  @spec valid_sources?(term()) :: boolean()
  def valid_sources?(sources) when is_list(sources), do: Enum.all?(sources, &valid_source?/1)
  def valid_sources?(_sources), do: false

  @doc false
  @spec valid_source?(term()) :: boolean()
  def valid_source?(:builtin), do: true
  def valid_source?({:session, :override}), do: true
  def valid_source?({:extension, _owner, _key}), do: true
  def valid_source?({:application, _key}), do: true
  def valid_source?({:file, path}) when is_binary(path), do: true
  def valid_source?({:hook, :prepare_next_turn}), do: true
  def valid_source?(_source), do: false

  @doc "Return the lowercase hexadecimal SHA-256 digest of prompt text."
  @spec digest(binary()) :: String.t()
  def digest(text) when is_binary(text) do
    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
  end
end
