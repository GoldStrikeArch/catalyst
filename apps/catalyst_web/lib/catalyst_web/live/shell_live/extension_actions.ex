defmodule CatalystWeb.ShellLive.ExtensionActions do
  @moduledoc """
  Runs slow extensions-panel operations outside the LiveView process.

  Compilation and git operations execute in a supervised task. The caller keeps
  the returned task reference in `:ext_action`, allowing `ShellLive` to correlate
  the result and disable conflicting panel actions while work is in flight.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Catalyst.Extensions

  @type action ::
          :reload_all
          | :rollback_last
          | {:reload, String.t()}
          | {:rollback, String.t()}
          | {:disable, String.t()}
          | {:enable, String.t()}
  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @doc "Starts one supervised extension action and records it on the socket."
  @spec start(socket(), action()) :: socket()
  def start(socket, action) do
    {label, operation} = operation(action)
    task = Task.Supervisor.async_nolink(Catalyst.TaskSupervisor, operation)
    assign(socket, :ext_action, %{ref: task.ref, label: label})
  end

  defp operation(:reload_all), do: {"reloading all extensions", &reload_all/0}
  defp operation(:rollback_last), do: {"rolling back", fn -> rollback(nil) end}
  defp operation({:reload, owner}), do: {"reloading #{owner}", fn -> reload(owner) end}
  defp operation({:rollback, owner}), do: {"rolling back #{owner}", fn -> rollback(owner) end}
  defp operation({:disable, owner}), do: {"disabling #{owner}", fn -> disable(owner) end}
  defp operation({:enable, owner}), do: {"enabling #{owner}", fn -> enable(owner) end}

  @spec reload_all() :: result()
  defp reload_all do
    case Extensions.load_all() do
      {:ok, %{loaded: loaded, failed: []}} ->
        {:ok, "Reloaded #{length(loaded)} extension file(s)." <> warnings_section(loaded)}

      {:ok, %{loaded: loaded, failed: failed}} ->
        {:error,
         "Reloaded #{length(loaded)} file(s); #{length(failed)} failed — " <>
           failure_lines(failed) <> warnings_section(loaded)}

      {:error, reason} ->
        {:error, "Reload failed: " <> Extensions.format_error(reason)}
    end
  end

  @spec reload(String.t()) :: result()
  defp reload(owner) do
    case Extensions.reload(owner) do
      {:ok, summary} ->
        {:ok, "Reloaded #{owner}" <> summary_suffix(summary)}

      {:error, reason} ->
        {:error, "Reload of #{owner} failed: " <> Extensions.format_error(reason)}
    end
  end

  @spec disable(String.t()) :: result()
  defp disable(owner) do
    case Extensions.disable(owner) do
      {:ok, _path} ->
        {:ok, "Disabled #{owner} — its file is kept (.ex.disabled) and skipped at boot."}

      {:error, reason} ->
        {:error, "Disable of #{owner} failed: " <> Extensions.format_error(reason)}
    end
  end

  @spec enable(String.t()) :: result()
  defp enable(owner) do
    case Extensions.enable(owner) do
      {:ok, summary} ->
        {:ok, "Enabled #{owner}" <> summary_suffix(summary)}

      {:error, reason} ->
        {:error, "Enable of #{owner} failed: " <> Extensions.format_error(reason)}
    end
  end

  # Presentation only — the lock → revert → reload orchestration is the
  # tagged `Extensions.rollback/1` domain operation.
  @spec rollback(String.t() | nil) :: result()
  defp rollback(owner) do
    what = rollback_scope(owner)

    case Extensions.rollback(owner) do
      {:ok, %{loaded: loaded, failed: []}} ->
        {:ok,
         "Rolled back #{what} and reloaded #{length(loaded)} file(s)." <>
           warnings_section(loaded)}

      {:ok, %{loaded: loaded, failed: failed}} ->
        {:error,
         "Rolled back #{what}, but #{length(failed)} file(s) failed to load — " <>
           failure_lines(failed) <> warnings_section(loaded)}

      {:error, :no_file} ->
        {:error, "Rollback failed: no source file found for #{owner}."}

      {:error, :nothing_to_rollback} ->
        {:error, "Nothing to roll back for #{what} — recent changes were all reverted already."}

      {:error, {:reload_failed, reason}} ->
        {:error, "Rolled back #{what}, but reload failed: " <> Extensions.format_error(reason)}

      {:error, reason} ->
        {:error, "Rollback of #{what} failed: #{inspect(reason)}"}
    end
  end

  defp rollback_scope(nil), do: "the most recent extension change"
  defp rollback_scope(owner), do: "#{owner}'s most recent change"

  defp summary_suffix(summary) do
    tools =
      case summary.tools do
        [] -> "."
        tools -> " — tools: #{Enum.join(tools, ", ")}."
      end

    case Map.get(summary, :warning) do
      nil -> tools
      warning -> tools <> " Warning: #{warning}"
    end
  end

  defp failure_lines(failed) do
    Enum.map_join(failed, "; ", fn {path, reason} ->
      "#{Path.basename(path)}: #{Extensions.format_error(reason)}"
    end)
  end

  defp warnings_section(loaded) do
    warnings =
      for summary <- loaded,
          warning = Map.get(summary, :warning),
          is_binary(warning),
          do: "#{summary.owner}: #{warning}"

    case warnings do
      [] -> ""
      warnings -> " Warnings — " <> Enum.join(warnings, "; ")
    end
  end
end
