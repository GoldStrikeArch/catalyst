defmodule Catalyst.Tools.Computer.Availability do
  @moduledoc """
  Whether this host can run the computer-use backend at all.

  Availability is **part of the `:computer_use` grant**, not a runtime check the
  tools perform for themselves: on a non-Darwin host, or when the native input
  helper (`catalyst-input`) is missing or not executable, the capability is
  never granted, the tools are never advertised, and the `/computer` page
  explains why. There is no "the tool exists but always errors" state.

  Resolution order for the helper binary:

    1. `config :catalyst, :computer_helper_path` — an explicit absolute path
    2. the shared `Catalyst.Tools.Binaries` resolver for `:catalyst_input` —
       `~/.catalyst/bin`, then the bundled `<priv_dir>/bin`, then `$PATH`,
       then the Homebrew locations
    3. `<priv_dir>/bin/catalyst-input` — the default install location, named
       even when nothing exists there yet, so `/computer` can say what is
       missing

  Discovery goes through `Catalyst.Tools.Binaries.discover/1`, which never
  touches the `:persistent_term` cache — installing or removing the helper is
  observed on the very next check, and nothing leaks between tests.

  `config :catalyst, :computer_backend_available` (`true` | `false`) overrides
  detection so both grant states are testable on any host. `true` forces
  availability; `false` models an unusable backend and reports the detected
  reason when there is one. Below that override, an explicitly configured
  `config :catalyst, :computer_backend` module counts as available (except
  `Catalyst.Tools.Computer.Unsupported`) — the configurer, usually a test
  injecting a stub, took responsibility for its usability.

  No side effects beyond reading application env and a handful of
  `File.stat/2` calls.
  """

  alias Catalyst.Tools.Binaries

  @helper_basename "catalyst-input"

  @typedoc "Why the backend cannot be used, or `:ok` when it can."
  @type status :: :ok | {:error, :unsupported_platform} | {:error, :helper_missing}

  @doc "Whether the computer-use backend can run here — the grant precondition."
  @spec available?() :: boolean()
  def available?, do: status() == :ok

  @doc """
  The backend's availability, with a reason when it is unavailable.

  Returns `:ok`, `{:error, :unsupported_platform}` (not macOS), or
  `{:error, :helper_missing}` (no **executable** helper binary at
  `helper_path/0` — a present but non-executable, truncated, or otherwise
  unrunnable file must not grant a capability that would only fail later
  inside a tool call).
  """
  @spec status() :: status()
  def status do
    case Application.get_env(:catalyst, :computer_backend_available) do
      true -> :ok
      false -> forced_unavailable()
      _detect -> detect()
    end
  end

  @doc """
  The resolved path of the native input helper.

  The explicit `:computer_helper_path` config wins; otherwise the documented
  `Catalyst.Tools.Binaries` resolution order applies. The path resolves
  whether or not the binary exists — a helper found nowhere falls back to the
  bundled default location — so `/computer` can name what is missing.
  """
  @spec helper_path() :: String.t()
  def helper_path do
    case Application.get_env(:catalyst, :computer_helper_path) do
      nil -> discovered_helper_path()
      configured -> configured
    end
  end

  defp discovered_helper_path do
    case Binaries.discover(:catalyst_input) do
      {:ok, path} -> path
      {:error, _missing} -> default_helper_path()
    end
  end

  defp forced_unavailable do
    case detect() do
      :ok -> {:error, :helper_missing}
      {:error, _reason} = error -> error
    end
  end

  # An explicitly configured backend (`config :catalyst, :computer_backend`)
  # takes responsibility for its own usability: a stub is available without a
  # helper binary, and configuring `Unsupported` models "no backend" directly.
  # The default (nil) keeps the platform + helper-binary detection.
  defp detect do
    case Application.get_env(:catalyst, :computer_backend) do
      nil -> detect_platform()
      Catalyst.Tools.Computer.Unsupported -> {:error, :unsupported_platform}
      _configured_module -> :ok
    end
  end

  defp detect_platform do
    case :os.type() do
      {:unix, :darwin} -> helper_status()
      _other_platform -> {:error, :unsupported_platform}
    end
  end

  # The same usability bar `Binaries` applies to every discovered candidate;
  # re-checked here so a configured override path (which bypasses discovery)
  # is held to it too.
  defp helper_status do
    case Binaries.executable?(helper_path()) do
      true -> :ok
      false -> {:error, :helper_missing}
    end
  end

  defp default_helper_path do
    case :code.priv_dir(:catalyst) do
      {:error, _not_loaded} -> Path.join(["priv", "bin", @helper_basename])
      priv -> priv |> List.to_string() |> Path.join("bin") |> Path.join(@helper_basename)
    end
  end
end
