defmodule Catalyst.Prompt.Store do
  @moduledoc """
  File-backed storage for prompts editable by users.

  Files are written atomically into the paths already consumed by
  `Catalyst.SystemPrompt`; no additional persistence or resolution layer is
  introduced. Changes therefore apply when the next run resolves its prompt.
  """

  alias Catalyst.Files.AtomicWrite
  alias Catalyst.SystemPrompt
  alias Catalyst.Tools.Truncate

  @max_bytes 64 * 1024

  @type target ::
          :default
          | :append
          | {:api, String.t()}
          | {:model, String.t()}

  @doc "Reads a stored prompt, returning `:missing` when no file exists."
  @spec read(target()) :: {:ok, String.t()} | :missing | {:error, term()}
  def read(target) do
    with {:ok, path} <- path(target) do
      case File.read(path) do
        {:ok, text} -> {:ok, Truncate.scrub_utf8(text)}
        {:error, :enoent} -> :missing
        {:error, reason} -> {:error, {:read_prompt, path, reason}}
      end
    end
  end

  @doc """
  Atomically stores a nonblank UTF-8 prompt of at most 64 KiB.

  Parent directories are created as needed. Expected validation and filesystem
  failures are returned as tagged errors.
  """
  @spec save(target(), term()) :: :ok | {:error, term()}
  def save(target, text) do
    with {:ok, path} <- path(target),
         {:ok, text} <- validate_text(text),
         :ok <- mkdir(path),
         :ok <- write(path, text) do
      :ok
    end
  end

  @doc "Deletes a stored prompt. Missing files are already reset and succeed."
  @spec delete(target()) :: :ok | {:error, term()}
  def delete(target) do
    with {:ok, path} <- path(target) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:delete_prompt, path, reason}}
      end
    end
  end

  @doc "Returns the file path consumed by `Catalyst.SystemPrompt` for `target`."
  @spec path(target()) :: {:ok, Path.t()} | {:error, term()}
  def path(:default), do: {:ok, SystemPrompt.path()}
  def path(:append), do: {:ok, Path.join(SystemPrompt.prompts_dir(), "append.md")}
  def path({kind, key}) when kind in [:api, :model], do: keyed_path(kind, key)
  def path(target), do: {:error, {:invalid_prompt_target, target}}

  defp keyed_path(kind, key) when is_binary(key) do
    case String.trim(key) do
      "" -> {:error, {:invalid_prompt_key, kind, key}}
      _nonblank -> {:ok, Path.join(SystemPrompt.prompts_dir(), SystemPrompt.slug(key) <> ".md")}
    end
  end

  defp keyed_path(kind, key), do: {:error, {:invalid_prompt_key, kind, key}}

  defp validate_text(text) when not is_binary(text), do: {:error, {:invalid_prompt_text, text}}
  defp validate_text(text) when byte_size(text) > @max_bytes, do: {:error, :prompt_too_large}

  defp validate_text(text) do
    cond do
      not String.valid?(text) -> {:error, :invalid_prompt_utf8}
      String.trim(text) == "" -> {:error, :blank_prompt}
      true -> {:ok, text}
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:create_prompt_directory, Path.dirname(path), reason}}
    end
  end

  defp write(path, text) do
    case AtomicWrite.write(path, text) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_prompt, path, reason}}
    end
  end
end
