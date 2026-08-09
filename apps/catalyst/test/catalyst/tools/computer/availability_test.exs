defmodule Catalyst.Tools.Computer.AvailabilityTest do
  # async: false — reads and restores the shared :catalyst backend app env.
  use ExUnit.Case, async: false

  alias Catalyst.Tools.Computer.Availability

  setup do
    previous = Application.fetch_env(:catalyst, :computer_backend_available)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:catalyst, :computer_backend_available, value)
        :error -> Application.delete_env(:catalyst, :computer_backend_available)
      end
    end)

    :ok
  end

  test "config/test.exs pins the backend unavailable so the tool set is host-independent" do
    assert {:error, reason} = Availability.status()
    assert reason in [:unsupported_platform, :helper_missing]
    refute Availability.available?()
  end

  test "the override forces either grant state on any host" do
    Application.put_env(:catalyst, :computer_backend_available, true)
    assert Availability.status() == :ok
    assert Availability.available?()

    Application.put_env(:catalyst, :computer_backend_available, false)
    assert {:error, _reason} = Availability.status()
    refute Availability.available?()
  end

  test "detection reports the missing helper binary on a supported platform" do
    Application.delete_env(:catalyst, :computer_backend_available)

    expected =
      case :os.type() do
        {:unix, :darwin} -> {:error, :helper_missing}
        _other -> {:error, :unsupported_platform}
      end

    assert Availability.status() == expected
  end

  test "the helper path is configurable and resolves whether or not it exists" do
    previous = Application.fetch_env(:catalyst, :computer_helper_path)
    Application.put_env(:catalyst, :computer_helper_path, "/nope/catalyst-input")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:catalyst, :computer_helper_path, value)
        :error -> Application.delete_env(:catalyst, :computer_helper_path)
      end
    end)

    assert Availability.helper_path() == "/nope/catalyst-input"

    Application.delete_env(:catalyst, :computer_helper_path)
    assert Availability.helper_path() =~ "bin/catalyst-input"
  end

  # AUDIT: `helper_status/0` accepts any regular file (`File.regular?/1`). A
  # non-executable, wrong-architecture, or truncated file is reported as
  # "Backend ready" and the capability is granted; the failure only surfaces
  # later as `{:helper_open_failed, _}` inside a tool call — exactly the "tool
  # exists but always errors" state this module's @moduledoc rules out.
  # `Binaries.discover/1` already applies the right check (mode &&& 0o111).
  @tag :audit
  test "a present but non-executable helper is not a usable backend" do
    path = Path.join(tmp_dir!(), "catalyst-input")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o644)

    put_env(:computer_backend_available, nil)
    put_env(:computer_helper_path, path)

    case :os.type() do
      {:unix, :darwin} ->
        assert Availability.status() == {:error, :helper_missing}
        refute Availability.available?()

      _other ->
        assert Availability.status() == {:error, :unsupported_platform}
    end
  end

  # AUDIT: `Catalyst.Tools.Binaries` carries a `:catalyst_input` entry and
  # documents `~/.catalyst/bin` -> `priv/bin` -> `$PATH` resolution, but nothing
  # in the computer-use path calls it — Availability hardcodes the priv path. A
  # helper installed where the documented resolver looks is invisible, and the
  # Binaries entry is dead code.
  @tag :audit
  test "the helper is discovered through the documented Binaries resolver" do
    home = tmp_dir!()
    path = Path.join([home, "bin", "catalyst-input"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)

    put_env(:home, home)
    put_env(:computer_helper_path, nil)
    on_exit(fn -> :persistent_term.erase({Catalyst.Tools.Binaries, :catalyst_input}) end)

    assert Availability.helper_path() == path
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:catalyst, key)

    on_exit(fn ->
      case previous do
        {:ok, restored} -> Application.put_env(:catalyst, key, restored)
        :error -> Application.delete_env(:catalyst, key)
      end
    end)

    case value do
      nil -> Application.delete_env(:catalyst, key)
      value -> Application.put_env(:catalyst, key, value)
    end
  end

  defp tmp_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst-availability-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
