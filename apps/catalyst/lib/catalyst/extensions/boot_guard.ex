defmodule Catalyst.Extensions.BootGuard do
  @moduledoc """
  Crash-loop detection for extension loading — the safety net that makes
  aggressive self-modification recoverable by a plain app relaunch.

  Before extensions load at boot, a marker file is set to `booting`; once the
  app has stayed up for a stabilization window it flips to `ok`. If a boot finds
  a stale `booting` marker, the previous boot died while (or shortly after)
  loading extensions — so this boot skips them (safe mode) instead of loading
  the same brick again. The marker stays stale until an explicit, successful
  `Catalyst.Extensions.load_all/0` (the `reload_extensions` tool) marks it `ok`,
  so safe mode is sticky until the bad extension is actually fixed.

  Limitation: a crash *after* the stabilization window (e.g. an extension that
  only blows up on first use, taking the VM down minutes in) is not detected —
  this guards boot-time bricking specifically.

  False-positive containment: quitting the app inside the stabilization window
  leaves the marker at `booting`, indistinguishable from a crash. Three
  mitigations: graceful stops mark clean via `Catalyst.Application.stop/1`; the
  desktop window's quit menu marks clean before its `System.halt` (which skips
  stop callbacks); and a stale marker with an *empty* extensions directory is
  ignored at boot (nothing to guard) and self-heals. Residual: a halt-quit
  (⌘Q via the Apple menu, window close) inside the window *with extensions
  installed* still reads as a crash on the next boot.
  """

  require Logger

  alias Catalyst.Files.AtomicWrite

  @doc "Path of the marker file (`~/.catalyst/boot_marker`; test-overridable)."
  @spec marker_path() :: Path.t()
  def marker_path do
    Application.get_env(:catalyst, :boot_marker_path) ||
      Catalyst.Paths.boot_marker()
  end

  @doc "Record that extension loading is starting (called right before load_all at boot)."
  @spec mark_booting() :: :ok
  def mark_booting, do: write("booting")

  @doc "Arm a uniquely identified boot marker for a later conditional stabilization."
  @spec arm() :: String.t()
  def arm do
    token = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    :ok = write("booting:" <> token)
    token
  end

  @doc "Record that the app booted (or reloaded) cleanly with extensions active."
  @spec mark_ok() :: :ok
  def mark_ok, do: write("ok")

  @doc "Mark clean only when the marker still belongs to the identified boot."
  @spec mark_ok(String.t()) :: :ok
  def mark_ok(token) do
    case File.read(marker_path()) do
      {:ok, contents} when is_binary(token) ->
        case String.trim(contents) == "booting:" <> token do
          true -> write("ok")
          false -> :ok
        end

      _missing_or_unidentified ->
        :ok
    end
  end

  @doc "Notify an external Recovery Host of this VM's ready token and effective product."
  @spec mark_recovery_ready() :: :ok
  def mark_recovery_ready do
    case recovery_handshake() do
      {:ok, path, token} -> write_recovery_ready(path, token)
      :disabled -> :ok
    end
  end

  @doc "Whether the previous boot died before its extensions were marked stable."
  @spec crashed_last_boot?() :: boolean()
  def crashed_last_boot? do
    case File.read(marker_path()) do
      {:ok, contents} -> String.starts_with?(String.trim(contents), "booting")
      _ -> false
    end
  end

  defp write(status) do
    path = marker_path()

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, status <> "\n") do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[extensions] could not write boot marker #{path}: #{inspect(reason)}")

        :ok
    end
  end

  defp recovery_handshake do
    path = System.get_env("CATALYST_RECOVERY_READY_PATH")
    token = System.get_env("CATALYST_RECOVERY_BOOT_TOKEN")

    case {path, token} do
      {path, token}
      when is_binary(path) and path != "" and is_binary(token) and token != "" and
             byte_size(token) <= 256 ->
        {:ok, path, token}

      _disabled_or_invalid ->
        :disabled
    end
  end

  defp write_recovery_ready(path, token) do
    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <-
             AtomicWrite.write(path, token <> ":" <> Catalyst.Product.id() <> "\n", mode: 0o600) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[extensions] could not signal Recovery Host at #{path}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
