defmodule Catalyst.Extensions.RecoveryHandshakeTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions.BootGuard

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_recovery_handshake_#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "ready")
    previous_path = System.get_env("CATALYST_RECOVERY_READY_PATH")
    previous_token = System.get_env("CATALYST_RECOVERY_BOOT_TOKEN")

    System.put_env("CATALYST_RECOVERY_READY_PATH", path)
    System.put_env("CATALYST_RECOVERY_BOOT_TOKEN", "boot-token")

    on_exit(fn ->
      restore_env("CATALYST_RECOVERY_READY_PATH", previous_path)
      restore_env("CATALYST_RECOVERY_BOOT_TOKEN", previous_token)
      File.rm_rf(root)
    end)

    %{path: path}
  end

  test "atomically publishes the external host token", %{path: path} do
    assert :ok = BootGuard.mark_recovery_ready()
    assert File.read!(path) == "boot-token:coding-agent\n"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "an invalid token disables the optional handshake", %{path: path} do
    System.put_env("CATALYST_RECOVERY_BOOT_TOKEN", String.duplicate("x", 257))

    assert :ok = BootGuard.mark_recovery_ready()
    refute File.exists?(path)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
