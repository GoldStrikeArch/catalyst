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
  """

  @doc "Path of the marker file (`~/.catalyst/boot_marker`; test-overridable)."
  def marker_path do
    Application.get_env(:catalyst, :boot_marker_path) ||
      Path.join(Path.dirname(Catalyst.Extensions.dir()), "boot_marker")
  end

  @doc "Record that extension loading is starting (called right before load_all at boot)."
  def mark_booting, do: write("booting")

  @doc "Record that the app booted (or reloaded) cleanly with extensions active."
  def mark_ok, do: write("ok")

  @doc "Whether the previous boot died before its extensions were marked stable."
  def crashed_last_boot? do
    case File.read(marker_path()) do
      {:ok, contents} -> String.trim(contents) == "booting"
      _ -> false
    end
  end

  defp write(status) do
    path = marker_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, status <> "\n")
    :ok
  rescue
    # An unwritable marker must never block boot or extension loading.
    _ -> :ok
  end
end
